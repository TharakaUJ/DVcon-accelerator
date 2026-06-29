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

TB ?= pe  # Default testbench if none specified

TB_FILES := $(wildcard $(TB_DIR)/tb_*.sv)
ALL_TBS  := $(patsubst $(TB_DIR)/tb_%.sv,%,$(TB_FILES))


# Assumes: pe_tb.sv, systolic_array_tb.sv, conv_tb.sv, axilite_tb.sv
# Assumes VCDs are named: build/pe.vcd, build/conv.vcd, etc.

# If the file exists in the tb directory, use the pattern. Otherwise, treat TB as a custom path.
ifneq ($(wildcard $(TB_DIR)/tb_$(TB).sv),)
    TB_TOP    := $(TB_DIR)/tb_$(TB).sv
    GTKW_SAVE := $(BUILD_DIR)/$(TB).gtkw
    WAVEFILE  := $(BUILD_DIR)/$(TB).vcd
else
    TB_TOP    := $(TB)
    GTKW_SAVE := $(BUILD_DIR)/waves.gtkw
    WAVEFILE  := $(BUILD_DIR)/waves.vcd
endif

SIMOUT := $(BUILD_DIR)/sim.vvp

TB_SUPPORT := $(filter-out $(TB_DIR)/tb_%.sv, $(wildcard $(TB_DIR)/*.sv))
SRCS := $(TB_TOP) $(shell find $(RTL_DIR) -type f -name '*.sv' 2>/dev/null) $(TB_SUPPORT)

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

test:
	@if [ -z "$(ALL_TBS)" ]; then \
		echo "Error: No testbenches matching 'tb_*.sv' found in $(TB_DIR)/"; \
		exit 1; \
	fi; \
	set -e; \
	for tb in $(ALL_TBS); do \
		echo "========================================"; \
		echo " Running Discovered Testbench: $$tb"; \
		echo "========================================"; \
		$(MAKE) lint TB=$$tb; \
		$(MAKE) sim TB=$$tb; \
	done


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