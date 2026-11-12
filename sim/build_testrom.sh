#!/bin/bash
# Assemble the test BIOS (sim/tb/testrom.S) and the ARM60 instruction set checks
# (sim/tb/arm6_isa.S) for the ARM60 (ARMv3, big-endian).
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
# ARM60 instruction set checks for tb_arm6 (sim/tb/arm6_isa.S)
${CROSS}as -EB -march=armv4 -mfloat-abi=soft "$HERE/tb/arm6_isa.S" -o "$OUT/arm6_isa.o"
${CROSS}ld -EB -Ttext=0 -o "$OUT/arm6_isa.elf" "$OUT/arm6_isa.o"
${CROSS}objcopy -O binary "$OUT/arm6_isa.elf" "$OUT/arm6_isa.bin"
${CROSS}objdump -d "$OUT/arm6_isa.elf" > "$OUT/arm6_isa.lst"
echo "arm6_isa: $(stat -c %s "$OUT/arm6_isa.bin") bytes"
# ARM60 interrupt checks for tb_arm6 +fiq +irq (sim/tb/arm6_fiq.S)
${CROSS}as -EB -march=armv4 -mfloat-abi=soft "$HERE/tb/arm6_fiq.S" -o "$OUT/arm6_fiq.o"
${CROSS}ld -EB -Ttext=0 -o "$OUT/arm6_fiq.elf" "$OUT/arm6_fiq.o"
${CROSS}objcopy -O binary "$OUT/arm6_fiq.elf" "$OUT/arm6_fiq.bin"
${CROSS}objdump -d "$OUT/arm6_fiq.elf" > "$OUT/arm6_fiq.lst"
echo "arm6_fiq: $(stat -c %s "$OUT/arm6_fiq.bin") bytes"
