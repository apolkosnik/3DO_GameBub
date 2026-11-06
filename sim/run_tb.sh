#!/bin/bash
# Build and run one testbench with Verilator.
#   sim/run_tb.sh <tb_name> [simulation plusargs]   (VARGS="..." for extra verilator args)
# The core RTL is prepared with prep_rtl.py (translate_off regions removed)
# so the simulation compiles exactly the code Vivado synthesises.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TB=$1; shift
BUILD=${BUILD:-$ROOT/build/sim}
RTL=$BUILD/rtl
mkdir -p "$BUILD"
python3 -I "$HERE/prep_rtl.py" "$ROOT/rtl" "$RTL"
source "$HERE/filelist.sh"
FILES=()
for f in "${RTL_FILES[@]}"; do FILES+=("$RTL/$f"); done
FILES+=("$HERE/models/xilinx_sim.sv" "$HERE/models/sdram_model.sv")
[ -f "$HERE/tb/$TB.deps" ] && while read -r d; do [ -n "$d" ] && FILES+=("$HERE/$d"); done < "$HERE/tb/$TB.deps"
FILES+=("$HERE/tb/$TB.sv")
verilator --binary --timing -j "$(nproc)" -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
    -Wno-PINMISSING -Wno-DEFPARAM -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-UNOPTFLAT \
    -Wno-INITIALDLY -Wno-COMBDLY -Wno-MULTITOP -Wno-ASCRANGE -Wno-SELRANGE -Wno-ZERODLY \
    --timescale 1ns/1ps -O2 --top-module "$TB" --Mdir "$BUILD/obj_$TB" -o "$TB" "${FILES[@]}" $VARGS > "$BUILD/$TB.build.log" 2>&1 \
    || { tail -40 "$BUILD/$TB.build.log"; exit 1; }
"$BUILD/obj_$TB/$TB" "$@"
