//=============================================================================
// File        : hbm_ctrl_pkg.sv
// Description : HBM Stack Controller — Design Package
//               All shared types, parameters, and enumerations for the
//               HBM Stack Controller RTL hierarchy.
//
//               Architecture basis (LinkedIn post):
//               - HBM3E: 1,024-bit interface, up to 1,280 GB/s per stack
//               - HBM4 : 2,048-bit interface, 32 independent channels, >2 TB/s
//               - Base die: ECC, power management, signal conditioning
//               - TSV:  10–20 μm diameter, thousands per stack
//               - Micro-bumps: 25–40 μm pitch between dies
//=============================================================================

package hbm_ctrl_pkg;

  //----------------------------------------------------------
  // Global Architecture Parameters
  //----------------------------------------------------------

  // HBM channel data bus width (HBM3E = 128-bit per channel x 8 channels = 1024)
  parameter int HBM_CHANNEL_WIDTH   = 128;
  parameter int HBM_NUM_CHANNELS    = 8;
  parameter int HBM_TOTAL_BUS_WIDTH = HBM_CHANNEL_WIDTH * HBM_NUM_CHANNELS; // 1024

  // Address width: HBM3E supports 16-Hi stacks, 48 GB total
  // Row: 14-bit, Col: 6-bit, Bank: 4-bit, BankGroup: 2-bit, Pseudo-channel: 1-bit
  parameter int HBM_ROW_BITS        = 14;
  parameter int HBM_COL_BITS        = 6;
  parameter int HBM_BANK_BITS       = 4;
  parameter int HBM_BANKGRP_BITS    = 2;
  parameter int HBM_PC_BITS         = 1;   // Pseudo-channel select
  parameter int HBM_ADDR_BITS       = HBM_ROW_BITS + HBM_COL_BITS +
                                       HBM_BANK_BITS + HBM_BANKGRP_BITS +
                                       HBM_PC_BITS; // 27-bit total

  // DRAM array depth per channel (simplified RTL model)
  parameter int HBM_MEM_DEPTH       = 64;   // 64 locations per channel slice
  parameter int HBM_MEM_ADDR_W      = 6;    // log2(64)

  // Stack configuration
  parameter int HBM_STACK_HEIGHT    = 16;   // 16-Hi HBM3E
  parameter int HBM_DIES_PER_STACK  = HBM_STACK_HEIGHT + 1; // +1 base die

  // ECC width: HBM uses 8-bit ECC per 128-bit data word
  parameter int HBM_ECC_BITS        = 8;

  // Power throttle threshold (IR-drop recovery, HBM4: 75% reduction vs HBM2E)
  parameter int HBM_THROTTLE_THRESH = 16;   // de-assert ready every N writes
  parameter int HBM_THROTTLE_CYCLES = 4;    // recovery window cycles

  //----------------------------------------------------------
  // Command Encoding (HBM3E command bus)
  //----------------------------------------------------------
  typedef enum logic [3:0] {
    HBM_CMD_NOP     = 4'b0000,
    HBM_CMD_ACT     = 4'b0001,   // Activate row
    HBM_CMD_RD      = 4'b0010,   // Read
    HBM_CMD_WR      = 4'b0011,   // Write
    HBM_CMD_PRE     = 4'b0100,   // Precharge
    HBM_CMD_REF     = 4'b0101,   // Refresh
    HBM_CMD_MRS     = 4'b0110,   // Mode Register Set
    HBM_CMD_RSTDLL  = 4'b0111,   // Reset DLL
    HBM_CMD_IDLE    = 4'b1111    // Bus idle
  } hbm_cmd_t;

  //----------------------------------------------------------
  // FSM State Definitions
  //----------------------------------------------------------

  // Main controller FSM
  typedef enum logic [2:0] {
    ST_RESET     = 3'b000,
    ST_INIT      = 3'b001,
    ST_IDLE      = 3'b010,
    ST_ACTIVE    = 3'b011,
    ST_READ      = 3'b100,
    ST_WRITE     = 3'b101,
    ST_PRECHARGE = 3'b110,
    ST_REFRESH   = 3'b111
  } hbm_ctrl_state_t;

  // Power management FSM (base die power delivery)
  typedef enum logic [1:0] {
    PWR_NORMAL    = 2'b00,
    PWR_THROTTLE  = 2'b01,
    PWR_RECOVERY  = 2'b10,
    PWR_SHUTDOWN  = 2'b11
  } hbm_pwr_state_t;

  // ECC FSM
  typedef enum logic [1:0] {
    ECC_IDLE      = 2'b00,
    ECC_CHECK     = 2'b01,
    ECC_CORRECT   = 2'b10,
    ECC_UNCORRECT = 2'b11
  } hbm_ecc_state_t;

  //----------------------------------------------------------
  // Structs — Command / Response
  //----------------------------------------------------------

  // HBM command struct (issued by host GPU to controller)
  typedef struct packed {
    hbm_cmd_t           cmd;
    logic [HBM_MEM_ADDR_W-1:0] addr;
    logic [HBM_CHANNEL_WIDTH-1:0] wdata;
    logic [HBM_BANK_BITS-1:0]   bank;
    logic [HBM_BANKGRP_BITS-1:0] bankgrp;
    logic                        pc_sel;    // Pseudo-channel select
  } hbm_cmd_pkt_t;

  // HBM response struct (returned to host)
  typedef struct packed {
    logic [HBM_CHANNEL_WIDTH-1:0] rdata;
    logic [HBM_ECC_BITS-1:0]      ecc_syndrome;
    logic                         ecc_corrected;
    logic                         ecc_uncorrectable;
    logic                         valid;
  } hbm_rsp_pkt_t;

  //----------------------------------------------------------
  // Timing Parameters (HBM3E @ 1.0 GHz controller clock)
  //   All values in clock cycles
  //----------------------------------------------------------
  parameter int tRCD    = 4;    // RAS-to-CAS delay
  parameter int tRP     = 4;    // Precharge period
  parameter int tCL     = 4;    // CAS latency
  parameter int tWR     = 6;    // Write recovery
  parameter int tRFC    = 64;   // Refresh cycle time
  parameter int tREFI   = 3900; // Average refresh interval

endpackage : hbm_ctrl_pkg
