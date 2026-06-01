# tb/Makefile — clock-rework regression harness
#
#   make verilate   build + run all Verilog/SV testbenches (verilator)
#   make ghdl       analyze + run all VHDL testbenches (ghdl)
#   make regress    run everything; print overall PASS/FAIL
#   make <name>     run a single test (e.g. `make hv_count_diff`)
#   make clean
#
# See docs/clock-rework/ANALYSIS.md §7. Verilator handles Verilog/SV; ghdl
# handles the VHDL CPU cores. Modules that MIX Verilog + VHDL (e.g. the Z80 in
# dkong3_main) cannot be simulated whole by either free tool — for those we
# drive the Verilog glue with a recorded/scripted bus model (added when needed).

RTL  := ../rtl
TBC  := common
BUILD := build

# ---- Verilator -------------------------------------------------------------
VERILATOR ?= verilator
VFLAGS := --binary --timing -j 0 -I$(TBC) \
          -Wno-fatal -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-CASEINCOMPLETE -Wno-CASEX -Wno-UNOPTFLAT -Wno-IMPLICIT -Wno-COMBDLY \
          -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST

# define_vtest <name>,<tb.sv>,<rtl files...>
# Builds to $(BUILD)/<name>/<name> and the run target greps for "PASS".
define define_vtest
.PHONY: $(1)
$(1):
	@echo "=== verilator: $(1) ==="
	@mkdir -p $(BUILD)/$(1)
	@$$(VERILATOR) $$(VFLAGS) --top-module $(1)_tb --Mdir $(BUILD)/$(1) -o $(1) $(2) $(3)
	@./$(BUILD)/$(1)/$(1)
VTESTS += $(1)
endef

# ---- test registry ---------------------------------------------------------
# Unit tests (self-contained module checks).
$(eval $(call define_vtest,clk_en_unit,unit/clk_en_unit_tb.sv,$(RTL)/clk_en.v))

# Differential equivalence tests (golden vs reworked). Add one line per module.
$(eval $(call define_vtest,hv_count_diff,diff/hv_count_diff_tb.sv,$(RTL)/dkong3_hv_count.v))

# ---- GHDL (VHDL cores) -----------------------------------------------------
GHDL ?= ghdl
# GHDL 6.0 mcode backend: analyze (-a) then elaborate-and-run (-r); no separate
# binary is produced. --ieee-asserts=disable silences power-up metavalue noise.
GHDLFLAGS := --std=08 -frelaxed
GHDL_WORK := $(BUILD)/ghdl
T80SRC := $(RTL)/t80asd_ip/T80_Pack.vhd $(RTL)/t80asd_ip/T80_MCode.vhd \
          $(RTL)/t80asd_ip/T80_ALU.vhd $(RTL)/t80asd_ip/T80_Reg.vhd \
          $(RTL)/t80asd_ip/T80.vhd $(RTL)/t80asd_ip/T80as.vhd

.PHONY: t80_smoke
t80_smoke:
	@echo "=== ghdl: t80_smoke ==="
	@mkdir -p $(GHDL_WORK)
	@$(GHDL) -a $(GHDLFLAGS) --workdir=$(GHDL_WORK) $(T80SRC) ghdl/t80_smoke_tb.vhd
	@$(GHDL) -r $(GHDLFLAGS) --workdir=$(GHDL_WORK) t80_smoke_tb \
	    --stop-time=50us --ieee-asserts=disable-at-0 2>&1 | grep -E "PASS:|FAIL:" || true
	@$(GHDL) -r $(GHDLFLAGS) --workdir=$(GHDL_WORK) t80_smoke_tb \
	    --stop-time=50us --ieee-asserts=disable-at-0 2>&1 | grep -q "PASS: t80_smoke"

GTESTS := t80_smoke

# ---- aggregate targets -----------------------------------------------------
.PHONY: verilate ghdl regress clean
verilate: $(VTESTS)
ghdl: $(GTESTS)

regress:
	@echo "############ CLOCK-REWORK REGRESSION ############"
	@fail=0; \
	for t in $(VTESTS) $(GTESTS); do \
	  if $(MAKE) -s $$t >/tmp/tb_$$t.log 2>&1; then \
	    echo "  PASS  $$t"; \
	  else \
	    echo "  FAIL  $$t   (see /tmp/tb_$$t.log)"; fail=1; \
	  fi; \
	done; \
	echo "#################################################"; \
	if [ $$fail -eq 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES"; exit 1; fi

clean:
	rm -rf $(BUILD)
