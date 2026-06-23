//=============================================================================
// File        : hbm_channel_ctrl.sv
// Description : HBM Single Channel Controller
//               Implements the per-channel DRAM command FSM with:
//               1. Activate (ACT) → CAS timing (tRCD enforcement)
//               2. Read (RD) with CAS latency pipeline (tCL)
//               3. Write (WR) with write recovery (tWR)
//               4. Precharge (PRE) with tRP enforcement
//               5. Refresh accept + tRFC stall
//               6. Open-page tracking (row buffer management)
//               7. ECC encode on write / decode on read pipeline
//
//               One instance per HBM pseudo-channel.
//               8 instances per HBM3E stack (32 for HBM4).
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_channel_ctrl #(
  parameter int CHANNEL_ID = 0
) (
  input  logic                          clk,
  input  logic                          reset,

  //----------------------------------------------------------
  // Host command interface
  //----------------------------------------------------------
  input  logic                          cmd_valid,
  input  hbm_cmd_pkt_t                  cmd_pkt,
  output logic                          cmd_ready,     // accept new command

  //----------------------------------------------------------
  // Response interface
  //----------------------------------------------------------
  output hbm_rsp_pkt_t                  rsp_pkt,
  output logic                          rsp_valid,

  //----------------------------------------------------------
  // Refresh interface (from refresh engine)
  //----------------------------------------------------------
  input  logic                          ref_req,
  output logic                          ref_ack,

  //----------------------------------------------------------
  // Power interface (from power manager)
  //----------------------------------------------------------
  input  logic                          stack_ready,

  //----------------------------------------------------------
  // Row buffer status (exported to arbiter for page-hit)
  //----------------------------------------------------------
  output logic                          row_open,
  output logic [HBM_MEM_ADDR_W-1:0]    open_row_addr,

  //----------------------------------------------------------
  // Debug
  //----------------------------------------------------------
  output hbm_ctrl_state_t               dbg_state
);

  //----------------------------------------------------------
  // Internal DRAM Model (64 x 128-bit per channel)
  // Data + parity storage
  //----------------------------------------------------------
  logic [HBM_CHANNEL_WIDTH-1:0] dram_data [0:HBM_MEM_DEPTH-1];
  logic [HBM_ECC_BITS-1:0]      dram_ecc  [0:HBM_MEM_DEPTH-1];

  //----------------------------------------------------------
  // FSM and timing registers
  //----------------------------------------------------------
  hbm_ctrl_state_t state_r, state_nxt;
  logic [5:0] timing_cnt;          // shared timing countdown
  logic [HBM_MEM_ADDR_W-1:0] active_row;
  logic row_open_r;

  // Latched command
  hbm_cmd_pkt_t  latched_cmd;
  logic          cmd_latched;

  //----------------------------------------------------------
  // ECC engine wires
  //----------------------------------------------------------
  logic [HBM_CHANNEL_WIDTH-1:0] ecc_enc_data_out;
  logic [HBM_ECC_BITS-1:0]      ecc_enc_parity;
  logic [HBM_CHANNEL_WIDTH-1:0] ecc_dec_data_out;
  logic [HBM_ECC_BITS-1:0]      ecc_dec_syndrome;
  logic                         ecc_corrected, ecc_uncorrect, ecc_clean;
  logic                         ecc_enc_valid, ecc_dec_valid;

  //----------------------------------------------------------
  // ECC Engine Instantiation
  //----------------------------------------------------------
  hbm_ecc_engine u_ecc (
    .clk                (clk),
    .reset              (reset),
    .enc_valid          (ecc_enc_valid),
    .enc_data_in        (latched_cmd.wdata),
    .enc_data_out       (ecc_enc_data_out),
    .enc_parity_out     (ecc_enc_parity),
    .dec_valid          (ecc_dec_valid),
    .dec_data_in        (dram_data[latched_cmd.addr]),
    .dec_parity_in      (dram_ecc[latched_cmd.addr]),
    .dec_data_out       (ecc_dec_data_out),
    .dec_syndrome       (ecc_dec_syndrome),
    .dec_ecc_corrected  (ecc_corrected),
    .dec_ecc_uncorrect  (ecc_uncorrect),
    .dec_ecc_clean      (ecc_clean)
  );

  //----------------------------------------------------------
  // FSM Next State Logic
  //----------------------------------------------------------
  always_comb begin : chan_fsm_nxt
    state_nxt = state_r;
    case (state_r)
      ST_RESET    : state_nxt = ST_INIT;
      ST_INIT     : state_nxt = (timing_cnt == '0) ? ST_IDLE : ST_INIT;
      ST_IDLE     : begin
        if (ref_req)
          state_nxt = ST_REFRESH;
        else if (cmd_valid && stack_ready && cmd_latched) begin
          case (latched_cmd.cmd)
            HBM_CMD_ACT : state_nxt = ST_ACTIVE;
            HBM_CMD_RD  : state_nxt = row_open_r ? ST_READ  : ST_ACTIVE;
            HBM_CMD_WR  : state_nxt = row_open_r ? ST_WRITE : ST_ACTIVE;
            HBM_CMD_PRE : state_nxt = ST_PRECHARGE;
            HBM_CMD_REF : state_nxt = ST_REFRESH;
            default     : state_nxt = ST_IDLE;
          endcase
        end
      end
      ST_ACTIVE   : state_nxt = (timing_cnt == '0) ?
                                  ((latched_cmd.cmd == HBM_CMD_RD) ? ST_READ : ST_WRITE)
                                  : ST_ACTIVE;
      ST_READ     : state_nxt = (timing_cnt == '0) ? ST_IDLE : ST_READ;
      ST_WRITE    : state_nxt = (timing_cnt == '0) ? ST_IDLE : ST_WRITE;
      ST_PRECHARGE: state_nxt = (timing_cnt == '0) ? ST_IDLE : ST_PRECHARGE;
      ST_REFRESH  : state_nxt = (timing_cnt == '0) ? ST_IDLE : ST_REFRESH;
      default     : state_nxt = ST_IDLE;
    endcase
  end : chan_fsm_nxt

  //----------------------------------------------------------
  // FSM Sequential Logic
  //----------------------------------------------------------
  always_ff @(posedge clk) begin : chan_fsm_seq
    if (reset) begin
      state_r       <= ST_RESET;
      timing_cnt    <= 6'hFF;  // Init delay
      active_row    <= '0;
      row_open_r    <= 1'b0;
      cmd_latched   <= 1'b0;
      latched_cmd   <= '0;
      ref_ack       <= 1'b0;
      rsp_valid     <= 1'b0;
      rsp_pkt       <= '0;
      ecc_enc_valid <= 1'b0;
      ecc_dec_valid <= 1'b0;
      foreach (dram_data[i]) dram_data[i] <= '0;
      foreach (dram_ecc[i])  dram_ecc[i]  <= '0;
    end
    else begin
      state_r       <= state_nxt;
      rsp_valid     <= 1'b0;
      ref_ack       <= 1'b0;
      ecc_enc_valid <= 1'b0;
      ecc_dec_valid <= 1'b0;

      // Latch incoming command
      if (cmd_valid && !cmd_latched) begin
        latched_cmd <= cmd_pkt;
        cmd_latched <= 1'b1;
      end

      // Timing countdown
      if (timing_cnt > 6'h0)
        timing_cnt <= timing_cnt - 1'b1;

      case (state_r)
        //----------------------------------------------------
        ST_INIT : begin
          if (timing_cnt == '0)
            timing_cnt <= '0;
        end

        //----------------------------------------------------
        ST_IDLE : begin
          cmd_latched <= 1'b0; // clear latch after processing
          if (ref_req) begin
            ref_ack    <= 1'b1;
            timing_cnt <= tRFC[5:0];
          end
        end

        //----------------------------------------------------
        ST_ACTIVE : begin
          // tRCD: minimum delay from ACT to RD/WR
          if (state_nxt == ST_ACTIVE && timing_cnt == 6'h0)
            timing_cnt <= tRCD[5:0];
          active_row <= latched_cmd.addr;
          row_open_r <= 1'b1;
        end

        //----------------------------------------------------
        ST_READ : begin
          // tCL: CAS latency — initiate ECC decode
          timing_cnt    <= tCL[5:0];
          ecc_dec_valid <= 1'b1;
          // Response issued after tCL
          if (timing_cnt == 6'h0) begin
            rsp_pkt.rdata            <= ecc_dec_data_out;
            rsp_pkt.ecc_syndrome     <= ecc_dec_syndrome;
            rsp_pkt.ecc_corrected    <= ecc_corrected;
            rsp_pkt.ecc_uncorrectable <= ecc_uncorrect;
            rsp_pkt.valid            <= 1'b1;
            rsp_valid                <= 1'b1;
          end
        end

        //----------------------------------------------------
        ST_WRITE : begin
          // Encode ECC then write to DRAM array
          ecc_enc_valid <= 1'b1;
          timing_cnt    <= tWR[5:0];
          if (timing_cnt == 6'h0) begin
            dram_data[latched_cmd.addr] <= ecc_enc_data_out;
            dram_ecc [latched_cmd.addr] <= ecc_enc_parity;
          end
        end

        //----------------------------------------------------
        ST_PRECHARGE : begin
          timing_cnt <= tRP[5:0];
          if (timing_cnt == 6'h0)
            row_open_r <= 1'b0;  // close the row
        end

        //----------------------------------------------------
        ST_REFRESH : begin
          // Hold for tRFC; no commands allowed
          if (timing_cnt == 6'h0) begin
            ref_ack    <= 1'b0;
            row_open_r <= 1'b0;  // all rows precharged after refresh
          end
        end

        default : ;
      endcase
    end
  end : chan_fsm_seq

  //----------------------------------------------------------
  // Combinational Output Assignments
  //----------------------------------------------------------
  assign cmd_ready    = (state_r == ST_IDLE) && stack_ready && !ref_req;
  assign row_open     = row_open_r;
  assign open_row_addr = active_row;
  assign dbg_state    = state_r;

endmodule : hbm_channel_ctrl
