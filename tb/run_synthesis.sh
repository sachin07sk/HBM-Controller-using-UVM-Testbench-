#!/bin/bash
#==============================================================================
# run_synthesis.sh — HBM Stack Controller Synthesis Script
# Supports: Synopsys DC Shell, Cadence Genus
#==============================================================================

TOOL=${1:-dc}
TOP=hbm_stack_ctrl

echo "============================================"
echo " HBM Stack Controller RTL Synthesis"
echo " Tool : $TOOL | Top : $TOP"
echo "============================================"

case $TOOL in
  dc)
    # Synopsys Design Compiler
    dc_shell -f - << 'EOF'
set_app_var search_path [concat $search_path "."]
set_app_var target_library "your_lib.db"
set_app_var link_library   "* your_lib.db"

# Read design
analyze -format sverilog -vcs {-f hbm_design.f}
elaborate hbm_stack_ctrl

# Apply constraints
read_sdc hbm_ctrl_constraints.sdc

# Synthesize
compile_ultra -no_autoungroup

# Reports
report_area    > reports/hbm_area.rpt
report_timing  > reports/hbm_timing.rpt
report_power   > reports/hbm_power.rpt
report_qor     > reports/hbm_qor.rpt

# Write netlist
write_file -format verilog -hierarchy -output netlists/hbm_stack_ctrl_netlist.v
write_sdc netlists/hbm_stack_ctrl_mapped.sdc
EOF
    ;;
  genus)
    # Cadence Genus
    genus -legacy_ui -f - << 'EOF'
set_db init_lib_search_path {.}
read_libs your_lib.lib

read_hdl -sv {-f hbm_design.f}
elaborate  hbm_stack_ctrl
read_sdc   hbm_ctrl_constraints.sdc

set_db syn_generic_effort  high
set_db syn_map_effort      high
set_db syn_opt_effort      high
syn_generic
syn_map
syn_opt

report_area    > reports/hbm_area.rpt
report_timing  > reports/hbm_timing.rpt
report_power   > reports/hbm_power.rpt

write_hdl > netlists/hbm_stack_ctrl_netlist.v
write_sdc > netlists/hbm_stack_ctrl_mapped.sdc
EOF
    ;;
  *)
    echo "Unknown tool: $TOOL. Use: dc | genus"
    exit 1
    ;;
esac

#==============================================================================
# README — HBM Stack Controller RTL Design
#==============================================================================
cat << 'README'

╔══════════════════════════════════════════════════════════════════════╗
║           HBM STACK CONTROLLER — RTL DESIGN PACKAGE                 ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  File                    Module              Description             ║
║  ─────────────────────── ──────────────────  ──────────────────────  ║
║  hbm_ctrl_pkg.sv         hbm_ctrl_pkg        Types, params, structs  ║
║  hbm_ecc_engine.sv       hbm_ecc_engine      SEC-DED ECC (base die)  ║
║  hbm_power_mgr.sv        hbm_power_mgr       IR-drop / throttle PMU  ║
║  hbm_refresh_engine.sv   hbm_refresh_engine  tREFI/tRFC refresh      ║
║  hbm_cmd_arbiter.sv      hbm_cmd_arbiter     8ch round-robin + PH    ║
║  hbm_channel_ctrl.sv     hbm_channel_ctrl    Per-channel DRAM FSM    ║
║  hbm_stack_ctrl.sv       hbm_stack_ctrl      TOP — full integration  ║
║  hbm_ctrl_constraints.sdc                    SDC timing constraints  ║
║  hbm_design.f                                Compile filelist        ║
║                                                                      ║
║  Architecture (LinkedIn post basis):                                 ║
║  • HBM3E: 1,024-bit bus, 8 channels, 896–1,280 GB/s per stack       ║
║  • HBM4:  2,048-bit bus, 32 channels, >2.0 TB/s per stack           ║
║  • Base die: ECC + power management + signal conditioning            ║
║  • TSV:   10–20 μm vertical interconnects, thousands per stack       ║
║  • CoWoS: primary integration vehicle, sub-100 μm bump pitch         ║
║                                                                      ║
║  Key design parameters (hbm_ctrl_pkg.sv):                           ║
║  • HBM_CHANNEL_WIDTH  = 128 bits                                     ║
║  • HBM_NUM_CHANNELS   = 8   (set to 32 for HBM4)                    ║
║  • HBM_MEM_DEPTH      = 64  entries per channel (RTL model)          ║
║  • HBM_ECC_BITS       = 8   (SEC-DED over 128-bit word)              ║
║  • HBM4_MODE          = 0/1 (enables 75% reduced IR-drop model)      ║
║  • tRCD = 4, tCL = 4, tWR = 6, tRP = 4, tRFC = 64, tREFI = 3900    ║
║                                                                      ║
║  To simulate with UVM testbench:                                     ║
║    cd ../hbm_uvm_tb && ./run_sim.sh questa hbm_ctrl_wr_rd_test       ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

README
