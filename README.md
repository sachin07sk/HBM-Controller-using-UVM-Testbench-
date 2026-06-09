# HBM-Controller-using-UVM-Testbench-
Pre-Flight Plan — HBM Stack Controller DUT Based on the LinkedIn post, I'm modelling a HBM Controller (hbm_ctrl) with these key behaviors:  Write to stacked DRAM via address + write data Read back from stacked DRAM with read data response ECC/error flag output  Bandwidth throttle / ready-valid handshake (reflects power/IR-drop gating in HBM4)
