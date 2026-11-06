@ Test "BIOS" for the Game Bub 3DO core system testbench (tb_top).
@
@ Runs on the core's ARM60 (ARMv3, big-endian) straight out of the BIOS ROM
@ (slow bus -> ddram.sv -> ddr_bridge -> SDRAM secondary port) and checks:
@   1. DRAM word write/read (SDRAM TDM part), several pages
@   2. DRAM byte writes (lane enables) + word read
@   3. VRAM in the on-chip BRAM1 window (0x260000) and the VDL area (0x2FC000)
@   4. VRAM in the SDRAM overflow tier (0x200000, 0x2A0000) via ddram.sv
@   5. ROM data reads (literal table in ROM)
@   6. NVRAM byte writes/reads (0x03140000, one byte per word, low byte)
@ Result record in NVRAM bytes 0x100..0x10F (read back by the testbench over
@ the host interface, FileReadStart(3)):
@   0x100: 'P','A','S','S' or 'F','A','I','L'
@   0x104: number of the failing test (0 = none)
@   0x108: failing address (big-endian, 4 bytes)
@   0x10C: number of checks performed (big-endian, 4 bytes)
@ Only ARMv3 instructions are used (no LDRH/STRH/BX).
@
@ Copyright (c) 2026 Adam Polkosnik
@ SPDX-License-Identifier: GPL-3.0-or-later

	.text
	.arm
	.global _start

	.equ ROM_BASE,   0x03000000
	.equ NVRAM_BASE, 0x03140000

_start:
	@ At reset the ROM is also visible at 0; jump to its real address (the
	@ first read from 0x030xxxxx turns the boot mapping off).
	ldr	pc, =ROM_BASE + entry

entry:
	mov	r11, #0			@ checks performed
	mov	r12, #0			@ current test number

	@ ---- 1. DRAM words: 4 pages x 64 words ----
	mov	r12, #1
	ldr	r0, =0x00002000
	mov	r3, #4			@ pages
1:	mov	r1, #64
	mov	r2, r0
	ldr	r4, =0x13579BDF
2:	eor	r5, r4, r2
	str	r5, [r2], #4
	subs	r1, r1, #1
	bne	2b
	mov	r1, #64
	mov	r2, r0
3:	eor	r5, r4, r2
	ldr	r6, [r2]
	cmp	r5, r6
	bne	fail
	add	r11, r11, #1
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	3b
	add	r0, r0, #0x4000		@ next 3DO page area
	subs	r3, r3, #1
	bne	1b

	@ ---- 2. DRAM byte writes ----
	mov	r12, #2
	ldr	r2, =0x00008000
	ldr	r5, =0xFFFFFFFF
	str	r5, [r2]
	mov	r5, #0x11
	strb	r5, [r2, #0]		@ big-endian: byte 0 is bits 31..24
	mov	r5, #0x33
	strb	r5, [r2, #2]
	ldr	r6, [r2]
	ldr	r5, =0x11FF33FF
	cmp	r5, r6
	bne	fail
	add	r11, r11, #1

	@ ---- 3. VRAM, on-chip BRAM1 window and VDL area ----
	mov	r12, #3
	ldr	r0, =0x00260000
	bl	vram_test
	ldr	r0, =0x002FC000
	bl	vram_test

	@ ---- 4. VRAM, SDRAM overflow tier (ddram.sv) ----
	mov	r12, #4
	ldr	r0, =0x00200000
	bl	vram_test
	ldr	r0, =0x002A0400
	bl	vram_test
	@ re-check the first block after the second one evicted the line cache
	ldr	r0, =0x00200000
	bl	vram_check

	@ ---- 5. ROM data ----
	mov	r12, #5
	ldr	r2, =ROM_BASE + romdata
	ldr	r6, [r2]
	ldr	r5, =0xCAFEF00D
	cmp	r5, r6
	bne	fail
	ldr	r6, [r2, #4]
	ldr	r5, =0x0BADBEEF
	cmp	r5, r6
	bne	fail
	add	r11, r11, #2

	@ ---- 6. NVRAM bytes 0x80..0x8F ----
	mov	r12, #6
	ldr	r0, =NVRAM_BASE + 0x80 * 4
	mov	r1, #16
	mov	r5, #0xA5
4:	strb	r5, [r0], #4
	add	r5, r5, #0x13
	and	r5, r5, #0xFF
	subs	r1, r1, #1
	bne	4b
	ldr	r0, =NVRAM_BASE + 0x80 * 4
	mov	r1, #16
	mov	r5, #0xA5
	@ NVRAM is byte-wide in the low byte of each word (MADAM slow bus);
	@ read it as words and mask, like 3DO software does.
5:	ldr	r6, [r0], #4
	and	r6, r6, #0xFF
	cmp	r5, r6
	bne	fail
	add	r11, r11, #1
	add	r5, r5, #0x13
	and	r5, r5, #0xFF
	subs	r1, r1, #1
	bne	5b

	@ ---- all passed ----
	mov	r12, #0
	mov	r2, #0
	ldr	r7, =0x50415353		@ "PASS"
	b	report

fail:
	ldr	r7, =0x4641494C		@ "FAIL"

report:
	ldr	r0, =NVRAM_BASE + 0x100 * 4
	mov	r8, r7
	bl	put_word		@ 0x100: PASS/FAIL
	mov	r8, r12
	bl	put_word		@ 0x104: test number
	mov	r8, r2
	bl	put_word		@ 0x108: address
	mov	r8, r11
	bl	put_word		@ 0x10C: checks
	ldr	r0, =0x00001000		@ also leave the record in DRAM
	str	r7, [r0]
	str	r12, [r0, #4]
	str	r11, [r0, #8]
done:	b	done

@ store r8 as 4 NVRAM bytes (big-endian) at r0, r0 += 16
put_word:
	mov	r9, r8, lsr #24
	strb	r9, [r0], #4
	mov	r9, r8, lsr #16
	strb	r9, [r0], #4
	mov	r9, r8, lsr #8
	strb	r9, [r0], #4
	strb	r8, [r0], #4
	mov	pc, lr

@ write and verify 64 words of VRAM at r0
vram_test:
	mov	r1, #64
	mov	r2, r0
	ldr	r4, =0x2468ACE1
6:	eor	r5, r4, r2, lsl #3
	str	r5, [r2], #4
	subs	r1, r1, #1
	bne	6b
vram_check:
	mov	r1, #64
	mov	r2, r0
	ldr	r4, =0x2468ACE1
7:	eor	r5, r4, r2, lsl #3
	ldr	r6, [r2]
	cmp	r5, r6
	bne	fail
	add	r11, r11, #1
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	7b
	mov	pc, lr

	.ltorg
	.align 4
romdata:
	.word	0xCAFEF00D
	.word	0x0BADBEEF
