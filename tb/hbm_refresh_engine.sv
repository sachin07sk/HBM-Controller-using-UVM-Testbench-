//=============================================================================
// File        : hbm_refresh_engine.sv
// Description : HBM DRAM Refresh Engine
//               Implements auto-refresh using tREFI (average interval) and
//               tRFC (refresh cycle duration) timing parameters from
//               hbm_ctrl_pkg.
//
//               HBM3E row refresh must occur within tREFI = 3900 cycles
//               (7.8 μs at 500 MHz). The controller issues a REF command,
//               stalls all other commands for tRFC cycles, then resumes.
//
//               Refresh request is prioritised over normal read/write
//               to prevent DRAM data retention failure — critical for
//               the 16-Hi stacked die where heat increases leakage.
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_refresh_engine #(
  parameter int TREFI_CYCLES = tREFI,
  parameter int TRFC_CYCLES  = tRFC
) (
  input  logic  clk,
  input  logic  reset,

  //----------------------------------------------------------
  // Refresh control interface
  //----------------------------------------------------------
  output logic  ref_req,      // Refresh required — hold new commands
  input  logic  ref_ack,      // Controller acknowledges, bank precharged
  output logic  ref_active,   // Refresh cycle in progress

  //----------------------------------------------------------
  // Status
  //----------------------------------------------------------
  output logic [15:0] trefi_cnt_out,  // countdown to next refresh
  output logic [7:0]  trfc_cnt_out    // countdown within refresh cycle
);

  //----------------------------------------------------------
  // tREFI countdown — refresh interval timer
  //----------------------------------------------------------
  logic [15:0] trefi_cnt;
  logic [7:0]  trfc_cnt;
  logic        refreshing;

  always_ff @(posedge clk) begin : refresh_seq
    if (reset) begin
      trefi_cnt  <= TREFI_CYCLES[15:0];
      trfc_cnt   <= '0;
      ref_req    <= 1'b0;
      refreshing <= 1'b0;
    end
    else begin
      if (!refreshing) begin
        // Count down to next refresh
        if (trefi_cnt > 16'h0) begin
          trefi_cnt <= trefi_cnt - 1'b1;
        end
        else begin
          // tREFI expired — assert refresh request
          ref_req   <= 1'b1;
          trefi_cnt <= TREFI_CYCLES[15:0]; // reload interval
        end

        // Wait for controller to acknowledge and precharge all banks
        if (ref_req && ref_ack) begin
          ref_req    <= 1'b0;
          refreshing <= 1'b1;
          trfc_cnt   <= TRFC_CYCLES[7:0];
        end
      end
      else begin
        // Active tRFC window — no commands allowed to banks
        if (trfc_cnt > 8'h0)
          trfc_cnt <= trfc_cnt - 1'b1;
        else
          refreshing <= 1'b0; // tRFC expired — banks available again
      end
    end
  end : refresh_seq

  //----------------------------------------------------------
  // Outputs
  //----------------------------------------------------------
  assign ref_active     = refreshing;
  assign trefi_cnt_out  = trefi_cnt;
  assign trfc_cnt_out   = trfc_cnt;

endmodule : hbm_refresh_engine
