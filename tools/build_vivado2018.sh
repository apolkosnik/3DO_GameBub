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
IMPL="$B"/P3DOCore-gamebub_rev4.runs/impl_1
RPT="$IMPL"/top_handheld_timing_summary_postroute_physopted.rpt
[ -f "$RPT" ] || RPT="$IMPL"/top_handheld_timing_summary_routed.rpt
read -r WNS TNS _ _ WHS _ < <(grep -A2 -m1 "WNS(ns)" "$RPT" | tail -1)
echo "Timing ($(basename "$RPT")): WNS $WNS ns, TNS $TNS ns, WHS $WHS ns"
if awk -v w="$WNS" -v h="$WHS" 'BEGIN { exit !(w < 0 || h < 0) }'; then
	echo "ERROR: timing not met" >&2
	exit 1
fi
