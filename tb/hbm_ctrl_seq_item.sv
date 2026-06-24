//=============================================================================
// File        : hbm_ctrl_seq_item.sv
// Description : UVM Sequence Item (Transaction) for HBM Controller
//               Represents one HBM command: WRITE or READ on a 32-bit bus
//               Constraints reflect HBM architecture rules:
//               - wr_en and rd_en are mutually exclusive
//               - ECC error injection is a rare event (<5% probability)
//=============================================================================

class hbm_ctrl_seq_item extends uvm_sequence_item;

  // 1. ALL VARIABLES MUST BE DECLARED FIRST (Before UVM macros)
  rand logic        wr_en;
  rand logic        rd_en;
  rand logic [5:0]  addr;
  rand logic [31:0] wdata;
  
  logic [31:0] rdata;
  logic        ready;
  logic        ecc_err;

  // 2. UVM FACTORY MACROS GO HERE
  `uvm_object_utils_begin(hbm_ctrl_seq_item)
    `uvm_field_int(wr_en,    UVM_ALL_ON)
    `uvm_field_int(rd_en,    UVM_ALL_ON)
    `uvm_field_int(addr,     UVM_ALL_ON)
    `uvm_field_int(wdata,    UVM_ALL_ON)
    `uvm_field_int(rdata,    UVM_ALL_ON)
    `uvm_field_int(ready,    UVM_ALL_ON)
    `uvm_field_int(ecc_err,  UVM_ALL_ON)
  `uvm_object_utils_end

  //----------------------------------------------------------
  // Constraints
  //----------------------------------------------------------
  constraint c_cmd_mutex { !(wr_en && rd_en); }
  
  constraint c_cmd_active { (wr_en || rd_en); }
  
  constraint c_addr_range { addr inside {[6'h00 : 6'h3F]}; }
  
  constraint c_wdata_distribution {
    wdata dist {
      32'h0000_0000 := 5,
      32'hFFFF_FFFF := 5,
      [32'h0000_0001 : 32'hFFFFFFFE] := 90
    };
  }

  //----------------------------------------------------------
  // Constructor
  //----------------------------------------------------------
  function new(string name = "hbm_ctrl_seq_item");
    super.new(name);
  endfunction : new

endclass : hbm_ctrl_seq_item
