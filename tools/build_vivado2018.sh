#!/bin/bash
# Build with Vivado 2018.3 (the framework targets 2023.2+). Runs the normal
# framework flow, then removes the two xpm_fifo_async parameters that the
# 2018.3 XPM library does not know from the generated wrappers and re-runs
# the generated Vivado flow. Needs JAVA_HOME and a Python 3.12/3.13 first in PATH.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
./mill -i root.buildCore --target gamebub_rev4 || true
B=build/P3DOCore-gamebub_rev4
sed -i '/\.CASCADE_HEIGHT(0),/d; /\.SIM_ASSERT_CHK(/d' "$B"/generated/XpmFifoAsync*.sv
# Implementation directives. With the default placer, the framework's 200 MHz
# SPI receiver (spi/shiftInCounter -> request FIFO write data, 4 LUT levels,
# mostly routing) misses timing by up to 0.08 ns, depending on what the core
# places around it (block RAM use is ~89%). Timing-driven placement plus
# physical optimisation after placement and after routing closes it.
RUN_TCL="$B"/P3DOCore-gamebub_rev4_run.tcl
if ! grep -q "STEPS.PLACE_DESIGN.ARGS.DIRECTIVE" "$RUN_TCL"; then
	sed -i '/^  launch_runs impl_1 /i\
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]\
  set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]\
  set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]\
  set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]\
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]\
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]' "$RUN_TCL"
fi
grep -q "STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt" "$RUN_TCL"
rm -rf "$B"/P3DOCore-gamebub_rev4.runs "$B"/P3DOCore-gamebub_rev4.xpr "$B"/P3DOCore-gamebub_rev4.cache
make -C "$B"
ls -la "$B"/P3DOCore-gamebub_rev4.bit
# Fail the build if routed timing is not met (the bitstream is written anyway).
# The verdict comes from the final routed checkpoint timed in a fresh Vivado
# session. The run's own post-route summary once put an SDRAM read data input
# (sdram_dq[4] -> dq_in_r, launched by sdram_clk_out) at -1.42 ns, the only
# failing endpoint, while the same checkpoint timed afresh gives +0.46 ns: its
# source clock delay of sdram_clk_out counted the 1.875 ns phase of clk_sdram a
# second time (14.710 ns, against 12.835 ns, the sum of the delays it lists).
# Another build's route_design summary had one endpoint at -1.42 ns too. The
# run's own figures are printed as well.
IMPL="$B"/P3DOCore-gamebub_rev4.runs/impl_1
RPT="$IMPL"/top_handheld_timing_summary_postroute_physopted.rpt
DCP="$IMPL"/top_handheld_postroute_physopt.dcp
[ -f "$RPT" ] || { RPT="$IMPL"/top_handheld_timing_summary_routed.rpt; DCP="$IMPL"/top_handheld_routed.dcp; }
read -r RWNS RTNS _ _ RWHS _ < <(grep -A2 -m1 "WNS(ns)" "$RPT" | tail -1)
echo "Timing in the run ($(basename "$RPT")): WNS $RWNS ns, TNS $RTNS ns, WHS $RWHS ns"
CHK="$IMPL"/timing_recheck.rpt
rm -f "$CHK"
vivado -mode batch -nojournal -nolog -source "$ROOT"/tools/recheck_timing.tcl -tclargs "$DCP" "$CHK" > "$IMPL"/timing_recheck.log 2>&1
read -r WNS TNS _ _ WHS _ < <(grep -A2 -m1 "WNS(ns)" "$CHK" | tail -1)
echo "Timing ($(basename "$DCP") timed afresh, $(basename "$CHK")): WNS $WNS ns, TNS $TNS ns, WHS $WHS ns"
[ "$WNS $TNS $WHS" = "$RWNS $RTNS $RWHS" ] || echo "NOTE: the run's timing summary differs from the fresh one; see $CHK"
if awk -v w="$WNS" -v h="$WHS" 'BEGIN { exit !(w < 0 || h < 0) }'; then
	echo "ERROR: timing not met" >&2
	exit 1
fi
