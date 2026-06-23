//=============================================================================
// File        : hbm_power_mgr.sv
// Description : HBM Base Die — Power Management Unit (PMU)
//
//               Architecture basis:
//               "Power delivery improvements in HBM4 — including all-around
//                power TSVs and higher TSV count — reduce IR drop by up to
//                75% compared to HBM2E, directly addressing power integrity
//                as a first-class architectural concern."
//               — LinkedIn post
//
//               This module implements:
//               1. Activity counter — tracks write/read burst density
//               2. IR-drop model — de-asserts 'ready' when burst exceeds
//                  threshold (simulates voltage droop on power TSVs)
//               3. Recovery timer — holds stack in throttle for N cycles
//               4. HBM4 mode — reduced throttle depth due to improved TSV
//               5. Thermal counter — accumulates heat per burst event
//               6. Shutdown path — asserts thermal_trip on over-temperature
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_power_mgr #(
  parameter int THROTTLE_THRESH  = HBM_THROTTLE_THRESH,  // burst count before throttle
  parameter int THROTTLE_CYCLES  = HBM_THROTTLE_CYCLES,  // recovery hold cycles
  parameter bit HBM4_MODE        = 1'b0                  // 1 = HBM4 (75% less IR-drop)
) (
  input  logic        clk,
  input  logic        reset,

  //----------------------------------------------------------
  // Activity inputs
  //----------------------------------------------------------
  input  logic        wr_active,     // write command in progress
  input  logic        rd_active,     // read command in progress
  input  logic        cmd_valid,     // any command on bus

  //----------------------------------------------------------
  // Power status outputs
  //----------------------------------------------------------
  output logic        ready,         // stack ready to accept commands
  output logic        throttle_active, // 1 = currently throttling
  output logic        thermal_trip,  // over-temperature shutdown
  output logic [7:0]  thermal_level, // 0–255 thermal accumulator

  //----------------------------------------------------------
  // Power state output (for debug / monitoring)
  //----------------------------------------------------------
  output hbm_pwr_state_t pwr_state
);

  //----------------------------------------------------------
  // Internal Registers
  //----------------------------------------------------------
  hbm_pwr_state_t state_r, state_nxt;
  logic [$clog2(THROTTLE_THRESH)-1:0] burst_cnt;
  logic [$clog2(THROTTLE_CYCLES*4)-1:0] recovery_cnt;
  logic [7:0]  thermal_acc;
  logic        thermal_trip_r;
  int effective_throttle;

  // HBM4 reduces IR-drop by 75% → throttle recovery cycles are shorter
  assign effective_throttle = HBM4_MODE ?
                              (THROTTLE_CYCLES / 4) + 1 :
                               THROTTLE_CYCLES;

  //----------------------------------------------------------
  // FSM — Next State Logic (combinational)
  //----------------------------------------------------------
  always_comb begin : pwr_fsm_nxt
    state_nxt = state_r;
    case (state_r)
      PWR_NORMAL : begin
        if (thermal_trip_r)
          state_nxt = PWR_SHUTDOWN;
        else if (burst_cnt >= THROTTLE_THRESH[($clog2(THROTTLE_THRESH)-1):0])
          state_nxt = PWR_THROTTLE;
      end
      PWR_THROTTLE : begin
        state_nxt = PWR_RECOVERY;
      end
      PWR_RECOVERY : begin
        if (thermal_trip_r)
          state_nxt = PWR_SHUTDOWN;
        else if (recovery_cnt == '0)
          state_nxt = PWR_NORMAL;
      end
      PWR_SHUTDOWN : begin
        // Latch shutdown until external reset
        state_nxt = PWR_SHUTDOWN;
      end
      default: state_nxt = PWR_NORMAL;
    endcase
  end : pwr_fsm_nxt

  //----------------------------------------------------------
  // FSM — Sequential Logic
  //----------------------------------------------------------
  always_ff @(posedge clk) begin : pwr_fsm_seq
    if (reset) begin
      state_r       <= PWR_NORMAL;
      burst_cnt     <= '0;
      recovery_cnt  <= '0;
      thermal_acc   <= 8'h00;
      thermal_trip_r <= 1'b0;
    end
    else begin
      state_r <= state_nxt;

      case (state_r)
        //----------------------------------------------------
        PWR_NORMAL : begin
          // Count active command cycles to detect burst density
          if (cmd_valid) begin
            burst_cnt <= burst_cnt + 1'b1;
            // Thermal model: writes generate more heat than reads
            if (wr_active)
              thermal_acc <= (thermal_acc < 8'hF0) ?
                              thermal_acc + 8'h03 : 8'hFF;
            else if (rd_active)
              thermal_acc <= (thermal_acc < 8'hFE) ?
                              thermal_acc + 8'h01 : 8'hFF;
          end
          else begin
            // Natural cooling when bus is idle
            thermal_acc <= (thermal_acc > 8'h00) ?
                            thermal_acc - 8'h01 : 8'h00;
            burst_cnt   <= (burst_cnt > 0) ? burst_cnt - 1'b1 : '0;
          end
          // Thermal shutdown threshold (modelled at 85% of max)
          if (thermal_acc >= 8'hD8)
            thermal_trip_r <= 1'b1;
        end

        //----------------------------------------------------
        PWR_THROTTLE : begin
          // Load recovery counter
          recovery_cnt <= effective_throttle[$clog2(THROTTLE_CYCLES*4)-1:0];
          burst_cnt    <= '0; // Reset burst count
        end

        //----------------------------------------------------
        PWR_RECOVERY : begin
          // Count down recovery window
          if (recovery_cnt > 0)
            recovery_cnt <= recovery_cnt - 1'b1;
          // Allow thermal to recover during throttle
          thermal_acc <= (thermal_acc > 8'h04) ?
                          thermal_acc - 8'h04 : 8'h00;
          if (thermal_acc < 8'hA0)
            thermal_trip_r <= 1'b0;
        end

        //----------------------------------------------------
        PWR_SHUTDOWN : begin
          // Hold outputs; cleared only by external reset
          thermal_trip_r <= 1'b1;
        end
      endcase
    end
  end : pwr_fsm_seq

  //----------------------------------------------------------
  // Output Assignments
  //----------------------------------------------------------
  always_comb begin : pwr_outputs
    ready            = (state_r == PWR_NORMAL);
    throttle_active  = (state_r == PWR_THROTTLE) || (state_r == PWR_RECOVERY);
    thermal_trip     = (state_r == PWR_SHUTDOWN);
    thermal_level    = thermal_acc;
    pwr_state        = state_r;
  end : pwr_outputs

endmodule : hbm_power_mgr
