# =============================================================================
# run_xsim.ps1  —  Vivado xsim regression (Windows / PowerShell)
#   Compiles all rtl + tb, then for each testbench elaborates, runs, and collects
#   ALL its outputs into a per-testbench folder:  results\<tb>\
#       <tb>\xelab.log        elaboration log
#       <tb>\xelab.console    elaboration stdout/stderr
#       <tb>\<tb>.log         simulation log (PASS/FAIL lines)
#       <tb>\<tb>.console     simulation stdout/stderr
#       <tb>\<tb>.vcd         VCD waveform ($dumpfile)
#       <tb>\<tb>.wdb         xsim native waveform database
#   Top level keeps  results\xvlog.log  and  results\regression_summary.log .
#
#   Usage (from this directory):
#     $env:PATH = 'D:\AMD\2025.2\Vivado\bin;' + $env:PATH    # if not already
#     ./run_xsim.ps1
#     ./run_xsim.ps1 -Only tb_im2col_engine                  # single tb
# =============================================================================
param([string]$Only = '')

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$res = Join-Path $here 'results'
New-Item -ItemType Directory -Force $res | Out-Null

$tops = @(
  'tb_pe','tb_pe_pair','tb_buffer_reg','tb_generic_mux','tb_register_bank',
  'tb_shift_reg_buffer','tb_systolic_array','tb_systolic_array_shadow','tb_axi4_lite_slave',
  'tb_silu','tb_vector_unit','tb_control_unit','tb_bram_act_buffer','tb_bram_weight_buffer',
  'tb_bram_out_buffer','tb_line_buffer','tb_im2col_engine','tb_accelerator',
  'tb_system_top','tb_system_top_bram')
if ($Only) { $tops = $tops | Where-Object { $_ -eq $Only } }

# ---- shared compile (one work library for all tbs) ----
$rtl = (Get-ChildItem ..\rtl\*.sv | ForEach-Object { $_.FullName })
$tbs = (Get-ChildItem tb_*.sv     | ForEach-Object { $_.FullName })
Write-Host "[compile] xvlog ..."
& xvlog -sv $rtl $tbs -log "$res\xvlog.log" *> "$res\xvlog.console.log"
if ($LASTEXITCODE -ne 0) { Write-Host "xvlog FAILED — see $res\xvlog.log"; exit 1 }

# ---- elaborate + run each, collecting outputs per testbench ----
foreach ($t in $tops) {
  Write-Host "[run] $t"
  $d = Join-Path $res $t
  New-Item -ItemType Directory -Force $d | Out-Null
  # xsim.dir lives in this (tb) dir, so run the tools here, then gather outputs.
  & xelab -debug typical $t -s "${t}_sim" -log "$d\xelab.log" *> "$d\xelab.console"
  & xsim  "${t}_sim" -R -wdb "$d\$t.wdb" -log "$d\$t.log" *> "$d\$t.console"
  # VCD ($dumpfile "<tb>.vcd") lands in the cwd → move it into the tb folder
  if (Test-Path "$t.vcd") { Move-Item -Force "$t.vcd" "$d\$t.vcd" }
}

# stray journals/pb from the tools (keep the tree tidy)
Remove-Item -Force -ErrorAction SilentlyContinue *.jou, *.pb, xelab.log, xsim.log, vivado*.backup.* 2>$null

# ---- summary (verdict-level; failure markers are case-sensitive) ----
$failRe = 'TESTS FAILED|TEST: FAILED|RESULT: FAILED|FAILED \(|FAILED <<<|WATCHDOG|TIMEOUT|ERROR:|  FAIL '
$lines = @('================ XSIM REGRESSION SUMMARY ================')
$nfail = 0
foreach ($t in $tops) {
  $log = "$res\$t\$t.log"
  if (-not (Test-Path $log)) { $v = 'NO-LOG' }
  else {
    $c = Get-Content $log -Raw
    if     ($c -cmatch $failRe) { $v = 'FAIL' }
    elseif ($c -imatch 'pass')  { $v = 'PASS' }
    else                        { $v = '????' }
  }
  if ($v -ne 'PASS') { $nfail++ }
  $lines += ('  {0,-26} {1}' -f $t, $v)
}
$lines += '========================================================'
$lines += ("  {0} testbench(es) not PASS  (per-tb outputs in {1}\<tb>\)" -f $nfail, $res)
$lines | Tee-Object -FilePath "$res\regression_summary.log"
