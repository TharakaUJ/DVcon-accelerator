# =============================================================================
# Makefile — DVCon accelerator simulation with Icarus Verilog + GTKWave
#
# Targets
#   make sim            — compile + simulate the selected testbench
#   make wave           — open GTKWave with saved signals
#   make lint           — run iverilog in lint mode
#   make clean          — remove build artifacts
#
# Testbench selection
#   make sim TB=pe      — run tb/pe_tb.sv
#   make sim TB=array   — run tb/systolic_array_tb.sv
#   make sim TB=...     — override with a custom testbench path
# =============================================================================

IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

RTL_DIR  = rtl
TB_DIR   = tb
BUILD_DIR = build

TB ?= array

ifeq ($(TB),pe)
TB_TOP := $(TB_DIR)/pe_tb.sv
GTKW_SAVE := $(BUILD_DIR)/pe.gtkw
WAVEFILE := $(BUILD_DIR)/pe_wave.vcd
else ifeq ($(TB),array)
TB_TOP := $(TB_DIR)/systolic_array_tb.sv
GTKW_SAVE := $(BUILD_DIR)/array.gtkw
WAVEFILE := $(BUILD_DIR)/array_wave.vcd
else
TB_TOP := $(TB)
GTKW_SAVE := $(BUILD_DIR)/waves.gtkw
WAVEFILE := $(BUILD_DIR)/waves.vcd
endif

SIMOUT := $(BUILD_DIR)/sim.vvp

SRCS := $(TB_TOP) $(shell find $(RTL_DIR) -type f -name '*.sv' 2>/dev/null)

FLAGS = -g2012 -DSIMULATION -I$(RTL_DIR) -Wall

.PHONY: all sim wave lint clean dirs

all: sim

dirs:
	@mkdir -p $(BUILD_DIR)

sim: dirs
	@echo "=== Compiling ==="
	$(IVERILOG) $(FLAGS) -o $(SIMOUT) $(SRCS)
	@echo "=== Simulating ==="
	$(VVP) $(SIMOUT)

wave: $(WAVEFILE)
	@if [ -f $(GTKW_SAVE) ]; then \
	  $(GTKWAVE) $(WAVEFILE) $(GTKW_SAVE); \
	else \
	  $(GTKWAVE) $(WAVEFILE); \
	fi

lint: dirs
	$(IVERILOG) $(FLAGS) -tnull $(SRCS)
	@echo "Lint clean."

clean:
	rm -f $(BUILD_DIR)/*.vcd $(BUILD_DIR)/*.gtkw $(SIMOUT)
	@echo "Cleaned."