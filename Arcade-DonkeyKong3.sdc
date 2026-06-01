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
