//=============================================================================
// File        : hbm_cmd_arbiter.sv
// Description : HBM Command Arbiter — 8-Channel Round-Robin
//               Arbitrates commands from 8 HBM pseudo-channels to the
//               shared DRAM bank array. Implements:
//
//               1. Round-robin fairness across all 8 channels
//               2. Refresh priority: REF requests preempt all commands
//               3. Page-hit promotion: back-to-back accesses to open rows
//                  are promoted ahead of idle channels (latency reduction)
//               4. Stall output: de-asserts grant when stack is throttled
//
//               Architecture basis:
//               "HBM4 doubles the interface width to 2,048 bits and
//                32 independent channels" — LinkedIn post
//               This arbiter is parameterized to support 8 (HBM3E) or
//               32 (HBM4) channels via NUM_CHANNELS parameter.
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_cmd_arbiter #(
  parameter int NUM_CHANNELS = HBM_NUM_CHANNELS   // 8 for HBM3E, 32 for HBM4
) (
  input  logic                          clk,
  input  logic                          reset,

  //----------------------------------------------------------
  // Per-channel request inputs
  //----------------------------------------------------------
  input  logic [NUM_CHANNELS-1:0]       req,         // command request per channel
  input  hbm_cmd_t [NUM_CHANNELS-1:0]   cmd_in,      // command type per channel

  //----------------------------------------------------------
  // Shared resource constraints
  //----------------------------------------------------------
  input  logic                          stack_ready,  // from power_mgr
  input  logic                          ref_req,      // from refresh engine

  //----------------------------------------------------------
  // Grant output
  //----------------------------------------------------------
  output logic [NUM_CHANNELS-1:0]       grant,        // one-hot grant to winner
  output logic [$clog2(NUM_CHANNELS)-1:0] grant_id,   // encoded winner channel
  output logic                          grant_valid,  // any grant issued this cycle

  //----------------------------------------------------------
  // Page-hit tracking (open-row buffer, one per channel)
  //----------------------------------------------------------
  input  logic [HBM_MEM_ADDR_W-1:0]    open_row [NUM_CHANNELS],
  input  logic [NUM_CHANNELS-1:0]       row_open,
  input  logic [HBM_MEM_ADDR_W-1:0]    req_row  [NUM_CHANNELS]
);

  //----------------------------------------------------------
  // Round-robin pointer
  //----------------------------------------------------------
  logic [$clog2(NUM_CHANNELS)-1:0] rr_ptr;

  //----------------------------------------------------------
  // Page-hit vector: channel i has a page hit if its requested
  // row matches the currently open row
  //----------------------------------------------------------
  logic [NUM_CHANNELS-1:0] page_hit;
  genvar gi;
  generate
    for (gi = 0; gi < NUM_CHANNELS; gi++) begin : gen_page_hit
      assign page_hit[gi] = row_open[gi] && (req_row[gi] == open_row[gi]);
    end
  endgenerate

  //----------------------------------------------------------
  // Arbitration Logic (combinational)
  //----------------------------------------------------------
  logic [NUM_CHANNELS-1:0] grant_comb;
  logic [$clog2(NUM_CHANNELS)-1:0] winner;
  logic found;

  always_comb begin : arbiter_logic
    grant_comb = '0;
    winner     = '0;
    found      = 1'b0;

    // Refresh takes absolute priority — stall all channels
    if (ref_req || !stack_ready) begin
      grant_comb = '0;
      found      = 1'b0;
    end
    else begin
      // Phase 1: Prefer page-hit channels starting from rr_ptr
      for (int i = 0; i < NUM_CHANNELS; i++) begin
        int idx;
        idx = (rr_ptr + i) % NUM_CHANNELS;
        if (!found && req[idx] && page_hit[idx]) begin
          grant_comb[idx] = 1'b1;
          winner           = idx[$clog2(NUM_CHANNELS)-1:0];
          found            = 1'b1;
        end
      end

      // Phase 2: Fall back to round-robin if no page hits
      if (!found) begin
        for (int i = 0; i < NUM_CHANNELS; i++) begin
          int idx;
          idx = (rr_ptr + i) % NUM_CHANNELS;
          if (!found && req[idx]) begin
            grant_comb[idx] = 1'b1;
            winner           = idx[$clog2(NUM_CHANNELS)-1:0];
            found            = 1'b1;
          end
        end
      end
    end
  end : arbiter_logic

  //----------------------------------------------------------
  // Registered outputs + round-robin pointer advance
  //----------------------------------------------------------
  always_ff @(posedge clk) begin : arb_reg
    if (reset) begin
      grant       <= '0;
      grant_id    <= '0;
      grant_valid <= 1'b0;
      rr_ptr      <= '0;
    end
    else begin
      grant       <= grant_comb;
      grant_id    <= winner;
      grant_valid <= found;

      // Advance pointer past the winner to ensure fairness
      if (found)
        rr_ptr <= (winner + 1'b1) % NUM_CHANNELS[$clog2(NUM_CHANNELS):0];
    end
  end : arb_reg

endmodule : hbm_cmd_arbiter
