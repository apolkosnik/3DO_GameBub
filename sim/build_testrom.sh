#!/bin/bash
# Assemble the test BIOS (sim/tb/testrom.S) for the ARM60 (ARMv3, big-endian).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
OUT=${OUT:-$ROOT/build/sim}
CROSS=${CROSS:-arm-none-linux-gnueabihf-}
mkdir -p "$OUT"
${CROSS}as -EB -march=armv4 -mfloat-abi=soft "$HERE/tb/testrom.S" -o "$OUT/testrom.o"
${CROSS}ld -EB -Ttext=0 -o "$OUT/testrom.elf" "$OUT/testrom.o"
${CROSS}objcopy -O binary "$OUT/testrom.elf" "$OUT/testrom.bin"
${CROSS}objdump -d "$OUT/testrom.elf" > "$OUT/testrom.lst"
echo "testrom: $(stat -c %s "$OUT/testrom.bin") bytes"
