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
rm -rf "$B"/P3DOCore-gamebub_rev4.runs "$B"/P3DOCore-gamebub_rev4.xpr "$B"/P3DOCore-gamebub_rev4.cache
make -C "$B"
ls -la "$B"/P3DOCore-gamebub_rev4.bit
