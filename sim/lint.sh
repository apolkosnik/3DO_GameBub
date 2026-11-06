#!/bin/bash
# Lint the complete core (as synthesised) with Verilator.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
OUT=${OUT:-$ROOT/build/sim_rtl}
rm -rf "$OUT"
python3 -I "$HERE/prep_rtl.py" "$ROOT/rtl" "$OUT"
source "$HERE/filelist.sh"
cd "$OUT"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-DEFPARAM -Wno-IMPLICITSTATIC -Wno-PINMISSING \
    -Igamebub -Ip3do -Iarm6 --top-module p3do_gamebub "${RTL_FILES[@]}" "$HERE/models/xilinx_sim.sv" "$HERE/models/gb_clocks_lint.sv" "$@"
