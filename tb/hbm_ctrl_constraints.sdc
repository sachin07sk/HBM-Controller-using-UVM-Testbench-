#==============================================================================
# File        : hbm_ctrl_constraints.sdc
# Description : Synthesis Constraints for HBM Stack Controller
#               Synopsys Design Constraints (SDC) format.
#               Compatible with: Synopsys DC, Cadence Genus, Quartus
#
# Target:  1.0 GHz controller clock (CoWoS bump clock domain)
#          HBM3E: 3.6 Gbps per-pin rate = 1.8 GHz DDR → 900 MHz controller
#          Using 1.0 GHz for timing margin.
#==============================================================================

#--------------------------------------------------------------
# 1. Clock Definition
#--------------------------------------------------------------

# Primary HBM controller clock (attached to CoWoS interposer PHY)
create_clock -name HBM_CTRL_CLK \
             -period 1.0 \
             -waveform {0.0 0.5} \
             [get_ports clk]

# HBM PHY reference clock (if PHY layer included — 900 MHz DDR reference)
# create_clock -name HBM_PHY_CLK \
#              -period 1.111 \
#              [get_ports phy_clk]

#--------------------------------------------------------------
# 2. Clock Uncertainty and Transition
#--------------------------------------------------------------
set_clock_uncertainty -setup 0.05 [get_clocks HBM_CTRL_CLK]
set_clock_uncertainty -hold  0.02 [get_clocks HBM_CTRL_CLK]
set_clock_transition   0.03       [get_clocks HBM_CTRL_CLK]

#--------------------------------------------------------------
# 3. Input / Output Delays
#    Based on CoWoS micro-bump parasitics (~0.1–0.2 ns propagation)
#--------------------------------------------------------------
set INPUT_DELAY   0.15   ;# ns — CoWoS bump + interposer trace
set OUTPUT_DELAY  0.15   ;# ns

set_input_delay  $INPUT_DELAY  -clock HBM_CTRL_CLK [all_inputs]
set_output_delay $OUTPUT_DELAY -clock HBM_CTRL_CLK [all_outputs]

# Exclude clock and reset from I/O delay constraints
set_input_delay 0 -clock HBM_CTRL_CLK [get_ports {clk reset}]

#--------------------------------------------------------------
# 4. Drive Strength and Load
#    Silicon interposer trace load (~0.05 pF per bump)
#--------------------------------------------------------------
set_driving_cell -lib_cell BUFX4 -pin Z [all_inputs]
set_load 0.05 [all_outputs]

#--------------------------------------------------------------
# 5. False Paths
#--------------------------------------------------------------
# Reset path is asynchronous to functional timing
set_false_path -from [get_ports reset]

# Debug outputs are not timing-critical
set_false_path -to [get_ports {dbg_chan_state* pwr_state thermal_level}]

#--------------------------------------------------------------
# 6. Multi-Cycle Paths
#    ECC syndrome computation spans 2 cycles (encode + check)
#--------------------------------------------------------------
set_multicycle_path 2 -setup \
    -from [get_cells {*u_ecc*}] \
    -to   [get_cells {*dec_ecc*}]

set_multicycle_path 1 -hold \
    -from [get_cells {*u_ecc*}] \
    -to   [get_cells {*dec_ecc*}]

# Refresh counter is updated every tREFI (3900 cycles) — relax timing
set_multicycle_path 2 -setup \
    -from [get_cells {*u_refresh*trefi_cnt*}]

#--------------------------------------------------------------
# 7. Area and Power Targets
#    HBM base die integration: logic must fit within 10 mm² budget
#--------------------------------------------------------------
set_max_area 0   ;# minimize area (synthesis goal)

#--------------------------------------------------------------
# 8. Operating Conditions
#    HBM3E: junction temperature range -40°C to +125°C (JEDEC)
#--------------------------------------------------------------
# set_operating_conditions -library <your_lib> WORST
