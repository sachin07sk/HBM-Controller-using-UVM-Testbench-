//=============================================================================
// File        : hbm_ctrl_sequencer.sv
// Description : UVM Sequencer for HBM Controller
//               Pass-through sequencer — arbitrates sequence items from
//               sequences to the driver on the HBM command channel.
//=============================================================================

class hbm_ctrl_sequencer extends uvm_sequencer#(hbm_ctrl_seq_item);

  //----------------------------------------------------------
  // UVM Factory Registration
  //----------------------------------------------------------
  `uvm_component_utils(hbm_ctrl_sequencer)

  //----------------------------------------------------------
  // Constructor
  //----------------------------------------------------------
  function new(string name = "hbm_ctrl_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction : new

endclass : hbm_ctrl_sequencer
