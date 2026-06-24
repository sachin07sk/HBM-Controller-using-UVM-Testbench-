//=============================================================================
// File        : tbench_top.sv
// Description : Top-Level Testbench Module for HBM Stack Controller
//               - Generates HBM clock (500 MHz → 1ns half-period)
//               - Applies synchronous reset
//               - Instantiates interface and DUT
//               - Sets virtual interface in config_db
//               - Launches UVM test via run_test()
//
//               Clock frequency 1 GHz (1ns period) chosen to match
//               HBM3E operational range; adjust half_period for HBM4.
//=============================================================================

`include "top.svh"

module tbench_top;

  //----------------------------------------------------------
  // Clock and Reset
  //----------------------------------------------------------
  logic clk;
  logic reset;

  // 1 GHz HBM clock (1ns period, 500ps half-period)
  initial clk = 1'b0;
  always #0.5 clk = ~clk;

  // Synchronous reset: assert for 10 cycles
  initial begin
    reset = 1'b1;
    repeat(10) @(posedge clk);
    reset = 1'b0;
    `uvm_info("TBENCH_TOP", "Reset released — HBM stack controller active", UVM_MEDIUM)
  end

  //----------------------------------------------------------
  // Interface Instantiation
  //----------------------------------------------------------
  hbm_ctrl_if intf(.clk(clk), .reset(reset));

  //----------------------------------------------------------
  // DUT Instantiation
  //----------------------------------------------------------
  hbm_ctrl DUT (
    .clk     (clk),
    .reset   (reset),
    .wr_en   (intf.wr_en),
    .rd_en   (intf.rd_en),
    .addr    (intf.addr),
    .wdata   (intf.wdata),
    .rdata   (intf.rdata),
    .ready   (intf.ready),
    .ecc_err (intf.ecc_err)
  );

  //----------------------------------------------------------
  // UVM Config DB — publish virtual interface
  //----------------------------------------------------------
  initial begin
    uvm_config_db#(virtual hbm_ctrl_if)::set(
      uvm_root::get(), "*", "vif", intf
    );
  end

  //----------------------------------------------------------
  // Launch UVM Test
  //----------------------------------------------------------
  initial begin
    run_test();
  end

endmodule : tbench_top
