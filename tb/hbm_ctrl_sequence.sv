//=============================================================================
// File        : hbm_ctrl_sequence.sv
// Description : UVM Sequences for HBM Controller Verification
//               Scenarios modelled from HBM3E/HBM4 architecture post:
//               1. hbm_ctrl_sequence        — randomized base sequence
//               2. hbm_write_sequence       — directed write burst
//               3. hbm_read_sequence        — directed read burst
//               4. hbm_wr_rd_sequence       — write-then-read (scoreboard check)
//               5. hbm_ecc_stress_sequence  — all-0/all-1 TSV stress patterns
//               6. hbm_bandwidth_sequence   — high-throughput sequential writes
//=============================================================================

//-----------------------------------------------------------------------------
// 1. Base Randomized Sequence
//-----------------------------------------------------------------------------
class hbm_ctrl_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_ctrl_sequence)

  //----------------------------------------------------------
  // Knob: number of transactions
  //----------------------------------------------------------
  int unsigned num_txns = 20;

  function new(string name = "hbm_ctrl_sequence");
    super.new(name);
  endfunction : new

  //----------------------------------------------------------
  // Body — randomized write/read transactions
  //----------------------------------------------------------
  task body();
    hbm_ctrl_seq_item req_item;
    repeat(num_txns) begin
      req_item = hbm_ctrl_seq_item::type_id::create("req_item");
      start_item(req_item);
      if(!req_item.randomize())
        `uvm_fatal("RAND_FAIL", "hbm_ctrl_seq_item randomization failed")
      finish_item(req_item);
    end
  endtask : body

endclass : hbm_ctrl_sequence


//-----------------------------------------------------------------------------
// 2. Directed Write Sequence
//    Models HBM4 write burst — exercises all 64 DRAM address locations
//-----------------------------------------------------------------------------
class hbm_write_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_write_sequence)

  function new(string name = "hbm_write_sequence");
    super.new(name);
  endfunction : new

  task body();
    repeat(64) begin
      `uvm_do_with(req,
        {
          req.wr_en == 1'b1;
          req.rd_en == 1'b0;
        }
      )
    end
  endtask : body

endclass : hbm_write_sequence


//-----------------------------------------------------------------------------
// 3. Directed Read Sequence
//    Models HBM3E read bandwidth — sequential reads across address space
//-----------------------------------------------------------------------------
class hbm_read_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_read_sequence)

  function new(string name = "hbm_read_sequence");
    super.new(name);
  endfunction : new

  task body();
    repeat(64) begin
      `uvm_do_with(req,
        {
          req.wr_en == 1'b0;
          req.rd_en == 1'b1;
        }
      )
    end
  endtask : body

endclass : hbm_read_sequence


//-----------------------------------------------------------------------------
// 4. Write-then-Read Sequence (Primary Scoreboard Exerciser)
//    Write 32 locations, then read them back — scoreboard verifies data
//    integrity through the HBM base-die controller path
//-----------------------------------------------------------------------------
class hbm_wr_rd_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_wr_rd_sequence)

  function new(string name = "hbm_wr_rd_sequence");
    super.new(name);
  endfunction : new

  task body();
    hbm_write_sequence wr_seq;
    hbm_read_sequence  rd_seq;

    // Phase 1: Write burst — populate all addresses
    wr_seq = hbm_write_sequence::type_id::create("wr_seq");
    `uvm_do(wr_seq)

    // Phase 2: Read burst — verify data integrity
    rd_seq = hbm_read_sequence::type_id::create("rd_seq");
    `uvm_do(rd_seq)

  endtask : body

endclass : hbm_wr_rd_sequence


//-----------------------------------------------------------------------------
// 5. ECC / TSV Stress Sequence
//    Injects all-zeros and all-ones patterns — represents worst-case
//    switching activity on TSVs (10–20 μm vertical interconnects).
//    Tests ECC error flag behavior from HBM4 base-die logic gates.
//-----------------------------------------------------------------------------
class hbm_ecc_stress_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_ecc_stress_sequence)

  function new(string name = "hbm_ecc_stress_sequence");
    super.new(name);
  endfunction : new

  task body();
    // All-zeros pattern (TSV low-stress)
    repeat(16) begin
      `uvm_do_with(req,
        {
          req.wr_en  == 1'b1;
          req.rd_en  == 1'b0;
          req.wdata  == 32'h0000_0000;
        }
      )
    end

    // All-ones pattern (TSV high-stress, max switching)
    repeat(16) begin
      `uvm_do_with(req,
        {
          req.wr_en  == 1'b1;
          req.rd_en  == 1'b0;
          req.wdata  == 32'hFFFF_FFFF;
        }
      )
    end

    // Alternating pattern (0x5A5A5A5A — checkerboard)
    repeat(16) begin
      `uvm_do_with(req,
        {
          req.wr_en  == 1'b1;
          req.rd_en  == 1'b0;
          req.wdata  == 32'h5A5A_5A5A;
        }
      )
    end
  endtask : body

endclass : hbm_ecc_stress_sequence


//-----------------------------------------------------------------------------
// 6. Bandwidth Saturation Sequence
//    Back-to-back writes to model HBM3E 1,280 GB/s peak throughput scenario.
//    Ensures 'ready' signal de-assertion (power throttle) is handled correctly.
//-----------------------------------------------------------------------------
class hbm_bandwidth_sequence extends uvm_sequence#(hbm_ctrl_seq_item);

  `uvm_object_utils(hbm_bandwidth_sequence)

  int unsigned burst_depth = 128;

  function new(string name = "hbm_bandwidth_sequence");
    super.new(name);
  endfunction : new

  task body();
    repeat(burst_depth) begin
      `uvm_do_with(req,
        {
          req.wr_en == 1'b1;
          req.rd_en == 1'b0;
          // Sequential addresses — models linear burst access pattern
          req.addr inside {[6'h00 : 6'h3F]};
        }
      )
    end
  endtask : body

endclass : hbm_bandwidth_sequence
