derive_pll_clocks
derive_clock_uncertainty

# Relax 4 MHz / 24 MHz -> 21.477 MHz crossings into the sound subsystem to one
# clk_sub period. The 2-flop syncs in dkong3_sound.v don't need cycle-accurate
# capture; the source (Z80 DO, VBlank, 4E_Q strobes) is held stable for many
# clk_sub periods before the receiver consumes it.

set sync_max 46.5

# Z80 DO -> data sync
set_max_delay -from [get_registers {*Z80IP:CPU|T80as:z80core|T80:u0|DO[*]}] \
              -to   [get_registers {*dkong3_sound:sound|I_MCPU_DO_S1[*]}] $sync_max

# VBlank -> sub-CPU NMI sync
set_max_delay -to [get_registers {*dkong3_sound:sound|I_SUB_NMIn_S1}] $sync_max

# 4E_Q latch strobes -> 3-flop strobe syncs
set_max_delay -to [get_registers {*dkong3_sound:sound|*q0_s1*}] $sync_max
set_max_delay -to [get_registers {*dkong3_sound:sound|*q1_s1*}] $sync_max
set_max_delay -to [get_registers {*dkong3_sound:sound|*q2_s1*}] $sync_max
