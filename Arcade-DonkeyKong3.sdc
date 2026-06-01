derive_pll_clocks
derive_clock_uncertainty

# Clock rework: the entire core now runs in a single clock domain (the 98.304 MHz
# `clk`, PLL outclk_0). The legacy cross-PLL CDC band-aids (4/24 MHz -> 21.477 MHz
# sound syncs, clk_sys -> clk_main/clk_sub reset deassertion false_paths) are gone
# because those domains no longer exist.
#
# Many registers advance only on a clock-enable far slower than 98.304 MHz, so
# their data paths are genuine multicycle paths. Constrain them with evidence
# from the timing report (added below as needed). NOTE: keep these in sync with
# clk_en.v if the enable cadence changes.
#
#   cen_cpu  (Z80)      ~4.000 MHz  -> ~24 clk multicycle
#   cen_snd  (2A03)    ~21.477 MHz  -> ~4  clk multicycle
#   cen_o_clk (12.288) /8 of master -> ~8  clk multicycle (video/RAM)
#   cen_24m   (24.576) /4 of master -> ~4  clk multicycle

# --- Z80 (T80as) : advances only on cen_cpu (~4 MHz, /24.576 of the master), and
# its DI_Reg is captured on the INVERTED master edge (a half master-cycle path at
# 98.304 otherwise). The ROM/RAM read data feeding it is stable for >=8 master
# clk (the cen_o_clk period) and the core consumes it ~24 clk apart, so these are
# multicycle paths. 4/3 stays well inside the >=8-clk stable window. ---
set z80_regs [get_registers {*Z80IP_CEN:CPU|T80as_ce:z80core|*}]
set_multicycle_path -setup -end 4 -to   $z80_regs
set_multicycle_path -hold  -end 3 -to   $z80_regs
set_multicycle_path -setup -end 4 -from $z80_regs
set_multicycle_path -hold  -end 3 -from $z80_regs

# --- Sound 2A03 cores (T65 + APU): T65 advances at the 2A03 cpu rate
# (~1.79 MHz, cpu_ce & cen_snd) and the APU on cen_snd; both far slower than the
# master, so their internal logic is multicycle. (The APU's PHI2-edge detector
# is a trivial per-clk path that meets single-cycle regardless, so relaxing it is
# harmless.) ---
set snd_regs [get_registers {*dkong3_sub_sync:*|*}]
set_multicycle_path -setup -end 4 -to   $snd_regs
set_multicycle_path -hold  -end 3 -to   $snd_regs
set_multicycle_path -setup -end 4 -from $snd_regs
set_multicycle_path -hold  -end 3 -from $snd_regs

# --- Core video output (clk, updated at the cen_24m_p / pixel rate) -> framework
# arcade_video (clk_sys). clk (PLL outclk_0, 98.304) and clk_sys (outclk_1,
# 24.576) are phase-locked 4:1 from the same PLL; the RGB/sync data is held a
# full pixel period, so this same-rate handoff is multicycle (relaxes the hold
# race where a clk launch edge sits just after a clk_sys capture edge).
# NOTE: glob '[' is a char-class, so the bracket chars are matched with '?'. ---
set clk_master [get_clocks {emu|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_sys_c  [get_clocks {emu|pll|pll_inst|altera_pll_i|general?1?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -from $clk_master -to $clk_sys_c -setup -end 4
set_multicycle_path -from $clk_master -to $clk_sys_c -hold  -end 3
