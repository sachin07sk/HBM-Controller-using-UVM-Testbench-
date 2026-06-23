//=============================================================================
// File        : hbm_stack_ctrl.sv
// Description : HBM Stack Controller — Top-Level Integration
//               Full production-grade HBM3E/HBM4 controller integrating:
//
//               ┌──────────────────────────────────────────────────────┐
//               │                  hbm_stack_ctrl                      │
//               │                                                      │
//               │  ┌─────────────┐    ┌──────────────────────────┐     │
//               │  │ hbm_power_  │    │   hbm_refresh_engine     │     │
//               │  │    mgr      │    │ (tREFI/tRFC timer)       │     │
//               │  └──────┬──────┘    └───────────┬──────────────┘     │
//               │         │ ready/throttle         │ ref_req/ref_ack   │
//               │  ┌──────▼──────────────────────▼──────────────┐     │
//               │  │           hbm_cmd_arbiter                  │     │
//               │  │    (round-robin + page-hit + REF priority)   │     │
//               │  └──────────────────┬───────────────────────────┘     │
//               │                     │ grant[7:0]                     │
//               │  ┌──────────────────▼───────────────────────────┐     │
//               │  │  hbm_channel_ctrl[0..7]  (FSM + ECC + DRAM)  │     │
//               │  └──────────────────────────────────────────────┘     │
//               └──────────────────────────────────────────────────────┘
//
//               Parameterized:
//               - NUM_CHANNELS: 8 (HBM3E) or 32 (HBM4)
//               - HBM4_MODE: enables improved power delivery model
//               - CHANNEL_WIDTH: 128-bit (HBM3E)
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_stack_ctrl #(
  parameter int NUM_CHANNELS  = HBM_NUM_CHANNELS,  // 8 (HBM3E) or 32 (HBM4)
  parameter bit HBM4_MODE     = 1'b0               // 0 = HBM3E, 1 = HBM4
) (
  input  logic                           clk,
  input  logic                           reset,

  //----------------------------------------------------------
  // Host GPU / SoC command interface
  // (one shared interface — arbiter distributes to channels)
  //----------------------------------------------------------
  input  logic                           host_cmd_valid,
  input  hbm_cmd_pkt_t                   host_cmd_pkt,
  output logic                           host_cmd_ready,

  //----------------------------------------------------------
  // Host response interface
  //----------------------------------------------------------
  output hbm_rsp_pkt_t                   host_rsp_pkt,
  output logic                           host_rsp_valid,

  //----------------------------------------------------------
  // Simplified single-channel external interface
  // (backwards-compatible with hbm_ctrl.sv used in testbench)
  //----------------------------------------------------------
  input  logic                           wr_en,
  input  logic                           rd_en,
  input  logic [HBM_MEM_ADDR_W-1:0]      addr,
  input  logic [31:0]                    wdata,
  output logic [31:0]                    rdata,
  output logic                           ready,
  output logic                           ecc_err,

  //----------------------------------------------------------
  // Status / debug outputs
  //----------------------------------------------------------
  output logic                           thermal_trip,
  output logic [7:0]                     thermal_level,
  output hbm_pwr_state_t                 pwr_state,
  output hbm_ctrl_state_t [NUM_CHANNELS-1:0] dbg_chan_state
);

  //----------------------------------------------------------
  // Internal wires
  //----------------------------------------------------------

  // Power manager
  logic stack_ready_w;
  logic throttle_active_w;

  // Refresh engine
  logic ref_req_w;
  logic ref_ack_w;
  logic ref_active_w;

  // Per-channel command/response
  logic [NUM_CHANNELS-1:0]               chan_cmd_valid;
  hbm_cmd_pkt_t                          chan_cmd_pkt   [NUM_CHANNELS];
  logic [NUM_CHANNELS-1:0]               chan_cmd_ready;
  hbm_rsp_pkt_t                          chan_rsp_pkt   [NUM_CHANNELS];
  logic [NUM_CHANNELS-1:0]               chan_rsp_valid;
  logic [NUM_CHANNELS-1:0]               chan_ref_ack;

  // Arbiter
  logic [NUM_CHANNELS-1:0]               arb_grant;
  logic [$clog2(NUM_CHANNELS)-1:0]       arb_grant_id;
  logic                                  arb_grant_valid;
  hbm_cmd_t [NUM_CHANNELS-1:0]           arb_cmd_in;      // FIX: Clean, packed enum array for u_arbiter

  // Page-hit tracking
  logic [NUM_CHANNELS-1:0]               row_open_w;
  logic [HBM_MEM_ADDR_W-1:0]             open_row_w    [NUM_CHANNELS];

  // Broadcast command to all channels; grant selects active channel
  hbm_cmd_pkt_t latched_host_cmd;
  logic         cmd_broadcast;

  //----------------------------------------------------------
  // Simple interface → cmd_pkt conversion (testbench compat)
  //----------------------------------------------------------
  always_comb begin : simple_if_conv
    latched_host_cmd      = '0;
    latched_host_cmd.addr = addr;
    if (wr_en) begin
      latched_host_cmd.cmd   = HBM_CMD_WR;
      latched_host_cmd.wdata = {{(HBM_CHANNEL_WIDTH-32){1'b0}}, wdata};
    end
    else if (rd_en) begin
      latched_host_cmd.cmd   = HBM_CMD_RD;
      latched_host_cmd.wdata = '0;
    end
    else begin
      latched_host_cmd.cmd   = HBM_CMD_NOP;
    end
    // Mux: use host_cmd_pkt if host_cmd_valid, else use simple interface
    cmd_broadcast = host_cmd_valid || wr_en || rd_en;
  end : simple_if_conv

  //----------------------------------------------------------
  // Distribute commands to channels via grant
  //----------------------------------------------------------
  always_comb begin : cmd_distribute
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      // Channel receives command only when arbiter grants it
      chan_cmd_valid[i] = arb_grant[i] && cmd_broadcast;
      chan_cmd_pkt[i]   = host_cmd_valid ? host_cmd_pkt : latched_host_cmd;
      
      // FIX: Map unpacked channel packet struct enum down into the packed arbiter array
      arb_cmd_in[i]     = chan_cmd_pkt[i].cmd;
    end
  end : cmd_distribute

  //----------------------------------------------------------
  // Collect responses — output from granted channel
  //----------------------------------------------------------
  always_comb begin : rsp_collect
    host_rsp_pkt   = '0;
    host_rsp_valid = 1'b0;
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (chan_rsp_valid[i]) begin
        host_rsp_pkt   = chan_rsp_pkt[i];
        host_rsp_valid = 1'b1;
      end
    end
  end : rsp_collect

  // Simple interface outputs (channel 0 for backwards compat)
  assign rdata   = host_rsp_pkt.rdata[31:0];
  assign ecc_err = host_rsp_pkt.ecc_uncorrectable | host_rsp_pkt.ecc_corrected;
  assign ready   = stack_ready_w;

  // Top-level cmd_ready
  assign host_cmd_ready = |chan_cmd_ready;

  //----------------------------------------------------------
  // Refresh ACK aggregation (any channel ACK)
  //----------------------------------------------------------
  assign ref_ack_w = |chan_ref_ack;

  //==========================================================
  // Sub-module Instantiations
  //==========================================================

  //----------------------------------------------------------
  // Power Manager
  //----------------------------------------------------------
  hbm_power_mgr #(
    .THROTTLE_THRESH (HBM_THROTTLE_THRESH),
    .THROTTLE_CYCLES (HBM_THROTTLE_CYCLES),
    .HBM4_MODE       (HBM4_MODE)
  ) u_power_mgr (
    .clk             (clk),
    .reset           (reset),
    .wr_active       (wr_en | (host_cmd_valid && host_cmd_pkt.cmd == HBM_CMD_WR)),
    .rd_active       (rd_en | (host_cmd_valid && host_cmd_pkt.cmd == HBM_CMD_RD)),
    .cmd_valid       (cmd_broadcast),
    .ready           (stack_ready_w),
    .throttle_active (throttle_active_w),
    .thermal_trip    (thermal_trip),
    .thermal_level   (thermal_level),
    .pwr_state       (pwr_state)
  );

  //----------------------------------------------------------
  // Refresh Engine
  //----------------------------------------------------------
  hbm_refresh_engine #(
    .TREFI_CYCLES (tREFI),
    .TRFC_CYCLES  (tRFC)
  ) u_refresh (
    .clk          (clk),
    .reset        (reset),
    .ref_req      (ref_req_w),
    .ref_ack      (ref_ack_w),
    .ref_active   (ref_active_w),
    .trefi_cnt_out(),
    .trfc_cnt_out ()
  );

  //----------------------------------------------------------
  // Command Arbiter
  //----------------------------------------------------------
  hbm_cmd_arbiter #(
    .NUM_CHANNELS (NUM_CHANNELS)
  ) u_arbiter (
    .clk          (clk),
    .reset        (reset),
    .req          (chan_cmd_valid | ({NUM_CHANNELS{cmd_broadcast}} & ~arb_grant)),
    .cmd_in       (arb_cmd_in),  // <--- FIXED: Linked to the clean packed array input
    .stack_ready  (stack_ready_w),
    .ref_req      (ref_req_w),
    .grant        (arb_grant),
    .grant_id     (arb_grant_id),
    .grant_valid  (arb_grant_valid),
    .open_row     (open_row_w),
    .row_open     (row_open_w),
    .req_row      ('{default: addr})
  );

  //----------------------------------------------------------
  // Channel Controllers — generate NUM_CHANNELS instances
  //----------------------------------------------------------
  genvar ch;
  generate
    for (ch = 0; ch < NUM_CHANNELS; ch++) begin : gen_channels
      hbm_channel_ctrl #(
        .CHANNEL_ID (ch)
      ) u_channel (
        .clk          (clk),
        .reset        (reset),
        .cmd_valid    (chan_cmd_valid[ch]),
        .cmd_pkt      (chan_cmd_pkt[ch]),
        .cmd_ready    (chan_cmd_ready[ch]),
        .rsp_pkt      (chan_rsp_pkt[ch]),
        .rsp_valid    (chan_rsp_valid[ch]),
        .ref_req      (ref_req_w),
        .ref_ack      (chan_ref_ack[ch]),
        .stack_ready  (stack_ready_w),
        .row_open     (row_open_w[ch]),
        .open_row_addr(open_row_w[ch]),
        .dbg_state    (dbg_chan_state[ch])
      );
    end
  endgenerate

endmodule : hbm_stack_ctrl
