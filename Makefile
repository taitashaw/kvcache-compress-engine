# ==========================================================================
# KV-Cache Compression Engine — Makefile
# ==========================================================================
#   make golden         Phase 1: Python golden model + test vectors
#   make lint           Phase 2: Verilator lint (0 errors, 0 warnings)
#   make sim            Phase 3: Verilator simulation
#   make wave           View VCD waveforms
#   make xsim_gui       Phase 4: Vivado xsim
#   make synth          Phase 5: 400 MHz synthesis
#   make block_design   Phase 6: Full SoC + bitstream
#   make clean          Remove build artifacts
# ==========================================================================

PYTHON   ?= python3
VERILATOR ?= verilator
GTKWAVE  ?= gtkwave
VIVADO   ?= vivado

TOP      = kvcache_compress_top
TB       = tb_top

RTL_FILES = \
    rtl/group_quantizer.sv \
    rtl/group_dequantizer.sv \
    rtl/kvcache_compress_top.sv

TB_FILES = \
    tb/tb_top.sv

# ==========================================================================
# Phase 1: Golden Model
# ==========================================================================
.PHONY: golden
golden:
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 1: Golden Model + Test Vectors"
	@echo "═══════════════════════════════════════════"
	$(PYTHON) model/golden_model.py

# ==========================================================================
# Phase 2: Lint
# ==========================================================================
.PHONY: lint
lint:
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 2: Verilator Lint"
	@echo "═══════════════════════════════════════════"
	$(VERILATOR) --lint-only -Wall --timing \
	    -Wno-DECLFILENAME -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
	    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNSIGNED \
	    $(RTL_FILES) $(TB_FILES)
	@echo "  >>> LINT PASSED <<<"

# ==========================================================================
# Phase 3: Simulation
# ==========================================================================
.PHONY: sim
sim: build/obj_dir/kvcache_sim
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 3: Running Simulation"
	@echo "═══════════════════════════════════════════"
	cd build/obj_dir && ./kvcache_sim

build/obj_dir/kvcache_sim: $(RTL_FILES) $(TB_FILES)
	@mkdir -p build
	$(VERILATOR) --binary --timing -j 0 \
	    -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-UNUSEDPARAM \
	    --top-module $(TB) \
	    -o kvcache_sim \
	    --Mdir build/obj_dir \
	    --trace \
	    $(RTL_FILES) $(TB_FILES)
	$(MAKE) -C build/obj_dir -f V$(TB).mk

# ==========================================================================
# Waveform Viewer
# ==========================================================================
.PHONY: wave
wave:
	@echo "  VCD waveform: build/obj_dir/kvcache_compress.vcd"
	@echo "  Open with:    $(GTKWAVE) build/obj_dir/kvcache_compress.vcd"
	$(GTKWAVE) build/obj_dir/kvcache_compress.vcd &

# ==========================================================================
# Phase 4: Vivado xsim
# ==========================================================================
.PHONY: xsim_gui
xsim_gui:
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 4: Vivado xsim Simulation"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/sim_build
	cd vivado/sim_build && $(VIVADO) -mode gui -source ../sim.tcl

# ==========================================================================
# Phase 5: Synthesis
# ==========================================================================
.PHONY: synth
synth:
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 5: Synthesis @ 400 MHz"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/synth_build
	cd vivado/synth_build && $(VIVADO) -mode batch -source ../synth.tcl 2>&1 | tee synth.log
	@echo ""
	@echo "  Reports:"
	@echo "    vivado/synth_build/utilization_impl.rpt"
	@echo "    vivado/synth_build/timing_impl.rpt"

# ==========================================================================
# Phase 6: Block Design + Bitstream
# ==========================================================================
.PHONY: block_design
block_design:
	@echo ""
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 6: Block Design + Bitstream"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/bd_build
	cd vivado/bd_build && $(VIVADO) -mode batch -source ../block_design.tcl 2>&1 | tee bd_build.log
	@echo ""
	@echo "  Bitstream: vivado/bd_build/kvcache_soc.runs/impl_1/*_wrapper.bit"
	@echo "  XSA:       vivado/bd_build/kvcache_soc.xsa"

# ==========================================================================
# Clean
# ==========================================================================
.PHONY: clean
clean:
	rm -rf build/ vivado/sim_build/ vivado/synth_build/ vivado/bd_build/
	rm -rf test_vectors/

.PHONY: help
help:
	@echo "KV-Cache Compression Engine — Build Targets"
	@echo ""
	@echo "    make golden         Golden model + test vectors"
	@echo "    make lint           Verilator lint"
	@echo "    make sim            Verilator simulation"
	@echo "    make wave           GTKWave waveform viewer"
	@echo "    make xsim_gui       Vivado xsim"
	@echo "    make synth          400 MHz synthesis"
	@echo "    make block_design   Full SoC + bitstream"
	@echo "    make clean          Remove build artifacts"
