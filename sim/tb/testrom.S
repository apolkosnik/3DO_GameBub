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
@   7. CD-ROM through CLIO XBUS -> OSA -> 3DO_CDROM -> cdd_emu -> SDRAM:
@      "read capacity" (disc-info block) and a 2-sector data read (NEXT)
@   8. CLIO software reset (CSTAT bits 4 and 5, the BIOS's DIPIR reset): the
@      ARM must start at 0 in SVC mode with IRQ and FIQ disabled (CPSR I and F
@      set, flags kept), the interrupted CPSR in SPSR_svc and the interrupted
@      PC in R14_svc (ARM60 datasheet, reset; Portfolio's DIPIR code returns
@      through them). The power-on CPSR (0xD3) is checked too.
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
	.equ CLIO_CSTAT, 0x03400028
	.equ SRST_FLAG,  0x00001100	@ DRAM: magic while a software reset is expected
	.equ SRST_MAGIC, 0x53525354	@ "SRST"
	.equ PON_CPSR,   0x00001104	@ DRAM: CPSR found at power-on
	.equ SRST_SAVE,  0x00001108	@ DRAM: checks performed before the reset
	.equ SRST_STUB,  0x00001200	@ DRAM: code that triggers the software reset

_start:
	@ At reset the ROM is also visible at 0; jump to its real address (the
	@ first read from 0x030xxxxx turns the boot mapping off).
	ldr	pc, =ROM_BASE + entry

entry:
	@ Reset state, before anything changes it (the jump above does not)
	mrs	r8, cpsr
	mrs	r9, spsr
	mov	r10, lr
	ldr	r0, =SRST_FLAG
	ldr	r1, [r0]
	ldr	r2, =SRST_MAGIC
	cmp	r1, r2
	beq	after_soft_reset
	ldr	r0, =PON_CPSR
	str	r8, [r0]

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

	@ ---- 7. CD-ROM via XBUS: read capacity, then 2 sectors (LBA 1, 2) ----
	@ The testbench loads a 4-sector ISO whose byte i of sector L is
	@ (7*i + L) & 0xFF (sector 0 starts with an Opera volume header).
	mov	r12, #7
	ldr	r0, =0x03400500		@ XBUS select: device 0 (CD drive)
	mov	r1, #0
	str	r1, [r0]
	@ Read capacity (0x85): status 85 00 mm ss ff stat; lead-out of a
	@ 4-sector disc is LBA 154 = 00:02:04
	mov	r1, #0x85
	bl	cd_cmd
	mov	r1, #0
	mov	r3, #6
8:	bl	cd_cmd			@ 6 parameter bytes (zeros)
	subs	r3, r3, #1
	bne	8b
	bl	cd_wait_stat
	bl	cd_stat			@ 0x85
	cmp	r6, #0x85
	bne	fail
	bl	cd_stat			@ 0x00
	bl	cd_stat			@ mm
	mov	r9, r6, lsl #16
	bl	cd_stat			@ ss
	orr	r9, r9, r6, lsl #8
	bl	cd_stat			@ ff
	orr	r9, r9, r6
	bl	cd_stat			@ status
	mov	r2, r9
	ldr	r5, =0x00000204
	cmp	r9, r5
	bne	fail
	add	r11, r11, #1

	@ Read data (0x10): LBA mode, address 151 (= sector 1), 2 blocks
	mov	r1, #0x10
	bl	cd_cmd
	mov	r1, #0
	bl	cd_cmd
	bl	cd_cmd
	mov	r1, #151
	bl	cd_cmd
	mov	r1, #1			@ LBA addressing
	bl	cd_cmd
	mov	r1, #0
	bl	cd_cmd
	mov	r1, #2
	bl	cd_cmd
	mov	r8, #1			@ sector being read
9:	ldr	r0, =0x03400540		@ poll until data is available
10:	ldr	r1, [r0]
	tst	r1, #0x20
	beq	10b
	ldr	r0, =0x034005C0
	mov	r3, #0
11:	ldr	r6, [r0]
	and	r6, r6, #0xFF
	rsb	r5, r3, r3, lsl #3	@ 7 * i
	add	r5, r5, r8
	and	r5, r5, #0xFF
	cmp	r5, r6
	orrne	r2, r3, r8, lsl #16
	bne	fail
	add	r3, r3, #1
	cmp	r3, #2048
	bne	11b
	add	r11, r11, #1
	add	r8, r8, #1
	cmp	r8, #3
	bne	9b

	@ ---- 8. CLIO software reset ----
	mov	r12, #8
	ldr	r0, =PON_CPSR		@ power-on: SVC mode, IRQ and FIQ disabled, flags clear
	ldr	r6, [r0]
	cmp	r6, #0xD3
	movne	r2, r6
	bne	fail
	add	r11, r11, #1
	ldr	r0, =SRST_SAVE
	str	r11, [r0]
	ldr	r0, =SRST_FLAG
	ldr	r1, =SRST_MAGIC
	str	r1, [r0]
	@ The BIOS resets from its kernel in DRAM; do the same (from ROM, the
	@ fetch still in flight at the reset would end MADAM's boot mapping).
	ldr	r3, =SRST_STUB
	adr	r4, srst_code
	ldmia	r4, {r5, r6}
	stmia	r3, {r5, r6}
	ldr	r0, =CLIO_CSTAT
	mov	r1, #0x30		@ software reset + clear DIPIR, as the BIOS writes it
	ldr	r4, =0xA0000013		@ interrupted state: N and C set, SVC mode,
	msr	cpsr_fc, r4		@ IRQ and FIQ enabled (register form: the
	mov	pc, r3			@ core does not decode MSR #immediate)

srst_code:				@ copied to SRST_STUB
	str	r1, [r0]
1:	b	1b			@ the reset lands here (or on the store)

after_soft_reset:
	mov	r1, #0
	str	r1, [r0]		@ r0 = SRST_FLAG: not expected any more
	ldr	r0, =SRST_SAVE
	ldr	r11, [r0]
	mov	r12, #8
	ldr	r5, =0xA00000D3		@ CPSR: SVC, I and F set, flags kept
	cmp	r8, r5
	movne	r2, r8
	bne	fail
	add	r11, r11, #1
	ldr	r5, =0xA0000013		@ SPSR_svc: the interrupted CPSR
	cmp	r9, r5
	movne	r2, r9
	bne	fail
	add	r11, r11, #1
	ldr	r5, =SRST_STUB		@ R14_svc: the interrupted code
	cmp	r10, r5
	movcc	r2, r10
	bcc	fail
	add	r5, r5, #12
	cmp	r10, r5
	movhi	r2, r10
	bhi	fail
	add	r11, r11, #1

	@ ---- all passed ----
	mov	r12, #0
	mov	r2, #0
	ldr	r7, =0x50415353		@ "PASS"
	b	report

fail:
	ldr	r7, =0x4641494C		@ "FAIL"

report:
	@ The status word goes last: the testbench reads the record as soon as
	@ it sees PASS or FAIL.
	ldr	r0, =NVRAM_BASE + 0x104 * 4
	mov	r8, r12
	bl	put_word		@ 0x104: test number
	mov	r8, r2
	bl	put_word		@ 0x108: address
	mov	r8, r11
	bl	put_word		@ 0x10C: checks
	ldr	r0, =NVRAM_BASE + 0x100 * 4
	mov	r8, r7
	bl	put_word		@ 0x100: PASS/FAIL
	ldr	r0, =0x00001000		@ also leave the record in DRAM
	str	r7, [r0]
	str	r12, [r0, #4]
	str	r11, [r0, #8]
done:	b	done

@ CD command byte r1 -> XBUS command register (keeps r1)
cd_cmd:
	ldr	r10, =0x03400580
	str	r1, [r10]
	mov	pc, lr

@ wait until the drive has status (poll bit 4)
cd_wait_stat:
	ldr	r10, =0x03400540
12:	ldr	r6, [r10]
	tst	r6, #0x10
	beq	12b
	mov	pc, lr

@ next status byte -> r6
cd_stat:
	ldr	r10, =0x03400580
	ldr	r6, [r10]
	and	r6, r6, #0xFF
	mov	pc, lr

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
