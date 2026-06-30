# =============================================================================
# Makefile  —  Vivado xsim regression for the DV testbenches
# =============================================================================
#  Flow per testbench:  xvlog (compile, shared)  ->  xelab  ->  xsim -R
#  Usage:
#     make            # compile all, run every tb, print + log a summary
#     make <tb_top>   # run a single tb, e.g.  make tb_im2col_engine
#     make summary    # re-print pass/fail summary from existing logs
#     make clean      # remove xsim work products + logs
#
#  Requires the Vivado tools on PATH (xvlog/xelab/xsim) and GNU make.
#  Run from this directory (Accl2.srcs/sources_1/imports/DV/tb).
# =============================================================================

RTL    := $(wildcard ../rtl/*.sv)
TB     := $(wildcard tb_*.sv)
LOGDIR := logs
SUMMARY:= $(LOGDIR)/regression_summary.log

# All testbench top modules (one snapshot + run each)
TOPS := \
  tb_pe tb_pe_pair tb_buffer_reg tb_generic_mux tb_register_bank \
  tb_shift_reg_buffer tb_systolic_array tb_systolic_array_shadow \
  tb_axi4_lite_slave tb_silu tb_vector_unit tb_control_unit \
  tb_bram_act_buffer tb_bram_weight_buffer tb_bram_out_buffer \
  tb_line_buffer tb_im2col_engine \
  tb_accelerator tb_system_top tb_system_top_bram

# Failure markers (verdict-level, so a "0 FAILED" count line is NOT a failure)
FAIL_RE := TESTS FAILED|TEST: FAILED|RESULT: FAILED|FAILED \(|FAILED <<<|WATCHDOG|Watchdog|ERROR: |  FAIL

.PHONY: all compile summary clean $(TOPS)

all: compile $(TOPS) summary

# ---- shared compile of every rtl + tb source into the xsim work library ----
compile:
	@mkdir -p $(LOGDIR)
	xvlog -sv $(RTL) $(TB) -log $(LOGDIR)/xvlog.log

# ---- per-testbench elaborate + run into results/<tb>/ (never aborts batch) ----
$(TOPS): compile
	@echo "=== $@ ==="
	@mkdir -p $(LOGDIR)/$@
	-xelab -debug typical $@ -s $@_sim -log $(LOGDIR)/$@/xelab.log
	-xsim $@_sim -R -wdb $(LOGDIR)/$@/$@.wdb -log $(LOGDIR)/$@/$@.log
	-@[ -f $@.vcd ] && mv -f $@.vcd $(LOGDIR)/$@/$@.vcd || true

# ---- pass/fail roll-up ----
summary:
	@echo "================ XSIM REGRESSION SUMMARY ================" | tee $(SUMMARY)
	@for t in $(TOPS); do \
	  log=$(LOGDIR)/$$t/$$t.log; \
	  if [ ! -f $$log ]; then \
	    printf "  %-26s NO-LOG\n" $$t | tee -a $(SUMMARY); \
	  elif grep -Eq "$(FAIL_RE)" $$log; then \
	    printf "  %-26s FAIL\n" $$t | tee -a $(SUMMARY); \
	  elif grep -qi "pass" $$log; then \
	    printf "  %-26s PASS\n" $$t | tee -a $(SUMMARY); \
	  else \
	    printf "  %-26s ????\n" $$t | tee -a $(SUMMARY); \
	  fi; \
	done
	@echo "========================================================" | tee -a $(SUMMARY)
	@fails=`grep -c " FAIL$$" $(SUMMARY)`; \
	 echo "  $$fails testbench(es) FAILED  (full logs in $(LOGDIR)/)" | tee -a $(SUMMARY)

clean:
	rm -rf $(LOGDIR) xsim.dir .Xil *.jou *.log *.pb *.vcd *.wdb xvlog.* xelab.* xsim.* webtalk*
