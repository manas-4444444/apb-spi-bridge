# ============================================================================
# APB-to-SPI Bridge: verification, formal and implementation flow
#
# Tools (all in OSS CAD Suite): iverilog/vvp, verilator, yosys, sby + yices,
#   nextpnr-ice40, gtkwave, plus python3 and a C++ compiler
#
#   make sim_orig     random regression on the ORIGINAL RTL (shows the bug)
#   make formal_orig  formal check of the ORIGINAL RTL -> counterexample waveform
#   make lint         Verilator -Wall lint of rtl/
#   make sim          one random regression run on rtl/
#   make regress      5 clock dividers x 5 seeds x ~1000 transfers on rtl/
#   make wave         short run with a VCD, opened in GTKWave
#   make formal       unbounded proofs + cover traces           (needs Stage 2)
#   make synth        Yosys synthesis for Lattice iCE40 HX8K + gate-level netlist
#   make pnr          nextpnr place & route, Fmax over 5 seeds + routed netlist
#   make gls          gate-level simulation: post-synthesis AND post-route netlists
#   make cov          Verilator line / branch / toggle coverage
#   make all          lint regress formal pnr gls cov
# ============================================================================

RTL_DIR  ?= rtl
MODES    ?= 1
CLK_DIV  ?= 4
NUM_TX   ?= 1000
SEED     ?= 1
DIVIDERS ?= 2 4 6 8 16
SEEDS    ?= 1 2 3 4 5

RTL      = $(RTL_DIR)/apb_spi_wrapper.v $(RTL_DIR)/spi_master.v
TB       = tb/tb_apb_spi_random.v
BUILD    = build
DEFS     = -DHAS_BUSY $(if $(filter 1,$(MODES)),-DHAS_MODES,)
YOSYS_DAT := $(shell yosys-config --datdir 2>/dev/null || echo /usr/share/yosys)

.PHONY: all lint sim sim_orig regress wave formal formal_orig synth pnr gls cov clean

all: lint regress formal pnr gls cov

$(BUILD):
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------- lint
lint:
	verilator --lint-only -Wall --top-module apb_spi_wrapper $(RTL)
	@echo "LINT CLEAN"

# ---------------------------------------------------------------- simulation
sim: | $(BUILD)
	iverilog -g2012 $(DEFS) -DCLK_DIV=$(CLK_DIV) -DNUM_TX=$(NUM_TX) -o $(BUILD)/sim $(TB) $(RTL)
	vvp -n $(BUILD)/sim +seed=$(SEED)

sim_orig: | $(BUILD)
	iverilog -g2012 -DORIG_RTL -DNUM_TX=$(NUM_TX) -o $(BUILD)/sim_orig $(TB) rtl_orig/apb_spi_wrapper.v rtl_orig/spi_master.v
	vvp -n $(BUILD)/sim_orig +seed=$(SEED)

regress: | $(BUILD)
	@fail=0; \
	for d in $(DIVIDERS); do \
	  iverilog -g2012 $(DEFS) -DCLK_DIV=$$d -DNUM_TX=$(NUM_TX) -o $(BUILD)/sim_$$d $(TB) $(RTL) || exit 1; \
	  for s in $(SEEDS); do \
	    line=$$(vvp -n $(BUILD)/sim_$$d +seed=$$s | grep -E "Transfers|Per SPI" | tr '\n' ' '); \
	    echo "CLK_DIV=$$d seed=$$s  $$line"; \
	    echo "$$line" | grep -q "Errors: 0" || fail=1; \
	  done; \
	done; \
	if [ $$fail -eq 0 ]; then echo "REGRESSION: ALL RUNS PASS"; else echo "REGRESSION: FAILURES"; exit 1; fi

wave: | $(BUILD)
	iverilog -g2012 $(DEFS) -DDUMP -DCLK_DIV=$(CLK_DIV) -DNUM_TX=20 -o $(BUILD)/sim_wave $(TB) $(RTL)
	cd $(BUILD) && vvp -n sim_wave +seed=$(SEED)
	gtkwave $(BUILD)/tb_apb_spi_random.vcd &

# ---------------------------------------------------------------- formal
formal:
	cd formal && sby -f core.sby prove
	cd formal && sby -f core.sby cover
	cd formal && sby -f bridge.sby prove
	cd formal && sby -f bridge.sby cover
	@echo "FORMAL: all proofs passed. Cover traces in formal/core_cover/engine_0/ and formal/bridge_cover/engine_0/"

formal_orig:
	-cd formal && sby -f bridge.sby orig
	@echo "Counterexample waveform: formal/bridge_orig/engine_0/trace.vcd  (open with gtkwave)"

# ---------------------------------------------------------------- implementation
synth:
	cd syn && yosys -q -s synth_ice40.ys && cat synth_ice40_stat.txt

pnr: synth
	@cd syn && for s in 1 2 3 4 5; do \
	  nextpnr-ice40 --hx8k --package ct256 --json apb_spi.json --pcf apb_spi.pcf \
	    --pcf-allow-unconstrained --freq 100 --seed $$s > nextpnr_seed$$s.log 2>&1; \
	  echo "seed $$s: $$(grep 'Max frequency for clock' nextpnr_seed$$s.log | tail -1 | sed 's/.*: //')"; \
	done; grep -E "ICESTORM_LC:|SB_IO:" nextpnr_seed1.log
	@cd syn && nextpnr-ice40 --hx8k --package ct256 --json apb_spi.json --pcf apb_spi.pcf \
	    --pcf-allow-unconstrained --freq 100 --seed 1 --write apb_spi_routed.json > nextpnr_routed.log 2>&1 && \
	  yosys -q -p "read_json apb_spi_routed.json; rename top apb_spi_wrapper; write_verilog -noattr apb_spi_routed_netlist.v" && \
	  echo "routed netlist: syn/apb_spi_routed_netlist.v"

# ---------------------------------------------------------------- gate-level simulation
# Runs the same random testbench (all 4 SPI modes) on the synthesized netlist
# and on the placed-and-routed netlist, using Yosys's iCE40 cell models.
gls: pnr | $(BUILD)
	python3 gls/patch_ice40_cells.py $(YOSYS_DAT)/ice40/cells_sim.v $(BUILD)/ice40_cells_sim_gls.v
	iverilog -g2012 -DGATE_LEVEL $(DEFS) -DNUM_TX=$(NUM_TX) -o $(BUILD)/gls_syn $(TB) syn/apb_spi_netlist.v $(BUILD)/ice40_cells_sim_gls.v
	iverilog -g2012 -DGATE_LEVEL $(DEFS) -DNUM_TX=$(NUM_TX) -o $(BUILD)/gls_route $(TB) syn/apb_spi_routed_netlist.v $(BUILD)/ice40_cells_sim_gls.v
	@echo "post-synthesis : $$(vvp -n $(BUILD)/gls_syn   +seed=$(SEED) | grep -E 'Transfers|RESULT' | tr '\n' ' ')"
	@echo "post-route     : $$(vvp -n $(BUILD)/gls_route +seed=$(SEED) | grep -E 'Transfers|RESULT' | tr '\n' ' ')"

# ---------------------------------------------------------------- coverage
cov:
	cd cov && rm -rf obj_dir coverage.dat && \
	verilator --cc --exe --build --timing --coverage-line --coverage-toggle \
	  -Wno-fatal -Wno-lint -Wno-style $(DEFS) -DCLK_DIV=4 -DNUM_TX=500 \
	  --top-module tb_apb_spi_random ../$(TB) $(addprefix ../,$(RTL)) cov_main.cpp -o vtb > build.log 2>&1 && \
	./obj_dir/vtb +seed=3 | grep -E "Transfers|RESULT" && \
	python3 cov_report.py coverage.dat

clean:
	rm -rf $(BUILD) formal/core_* formal/bridge_* syn/*.json syn/*.asc syn/*.log syn/*_stat.txt \
	       syn/apb_spi_netlist.v syn/apb_spi_routed_netlist.v cov/obj_dir cov/coverage.dat cov/build.log
