derive_pll_clocks
derive_clock_uncertainty

# Core specific constraints

# Treat unrelated PLL outputs as asynchronous. The core uses pll outclk_0 (24.576 MHz),
# outclk_1 (21.477 MHz subclk) and outclk_2 (4 MHz CPU) independently.
set_clock_groups -asynchronous \
  -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll*|divclk}] \
  -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].gpll*|divclk}] \
  -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].gpll*|divclk}]

# Explicitly cut timing between the 21.477 MHz (general[1]) and 4 MHz (general[2]) PLL outputs.
set_clock_groups -asynchronous \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Generated clocks produced inside dkong3_hv_count (24M -> 12M pixel).
# These keep TimeQuest from treating H/V counter bits as unconstrained clocks.
create_generated_clock -name dk3_pix_12m \
  -divide_by 2 \
  -source [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll*|divclk}] \
  [get_pins -hierarchical *dkong3_hv_count:hv|H_CNT_r\\[0\\]*|Q]

# H_CNT[0] is the 6 MHz tap used by the palette logic. Define it relative to 12M.
create_generated_clock -name dk3_pix_6m \
  -divide_by 2 \
  -source [get_clocks dk3_pix_12m] \
  [get_pins -hierarchical *dkong3_hv_count:hv|H_CNT_r\\[1\\]*|Q]

# Sprite timing taps used as clocks inside dkong3_obj (gated divides of 24M).
create_generated_clock -name dk3_obj_clk4l \
  -divide_by 8 \
  -source [get_clocks dk3_pix_12m] \
  [get_pins -hierarchical *dkong3_obj:sprites|CLK_4L|Q]

create_generated_clock -name dk3_obj_clk3e \
  -divide_by 4 \
  -source [get_clocks dk3_pix_12m] \
  [get_pins -hierarchical *dkong3_obj:sprites|CLK_3E|Q]

# Mark HV blank pulses that are used as strobes, not clocks.
set_false_path -through [get_pins {*|dkong3_hv_count:hv|V_BLANK}]
set_false_path -through [get_pins {*|dkong3_hv_count:hv|H_BLANK}]

# Mark the CDC into the sound domain synchronizers as asynchronous.
set_false_path \
  -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_registers -hierarchical *dkong3_sound:sound|mcpu_do_meta*]
set_false_path \
  -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_registers -hierarchical *dkong3_sound:sound|mcpu_ctrl_meta*]
