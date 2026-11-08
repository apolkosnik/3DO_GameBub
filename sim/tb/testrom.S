@ Test "BIOS" for the Game Bub 3DO core system testbench (tb_top).
@
@ Runs on the core's ARM60 (ARMv3, big-endian) straight out of the BIOS ROM
@ (slow bus -> ddram.sv -> ddr_bridge -> SDRAM secondary port) and checks:
@   1. DRAM word write/read (SDRAM TDM part), several pages
@   2. DRAM byte writes (lane enables) + word read
@   3. VRAM in the on-chip BRAM1 window (0x260000) and the VDL area (0x2FC000)
@   4. VRAM through ddram.sv: 0x200000 (block 0, in the SRAM by default,
@      vram_sram.sv) and 0x2A0400 (block A, in the SDRAM overflow tier)
@   5. ROM data reads (literal table in ROM)
@   6. NVRAM byte writes/reads (0x03140000, one byte per word, low byte)
@   7. CD-ROM through CLIO XBUS -> OSA -> 3DO_CDROM -> cdd_emu -> SDRAM:
@      "read capacity" (disc-info block) and a 2-sector data read (NEXT),
@      then its status
@  14. CD-DA and raw sectors (streamed disc with an audio track, see
@      tb_top; skipped, and counted as one check, on a disc of one data
@      track): disc info and the TOC entries of both tracks; Set Mode
@      block length 2352, two audio sectors (the controller's buffer must
@      start each block at its byte 0), Read Sub-Q at the audio track; a raw
@      data sector (sync, header, user data); Read Sub-Q at the data track;
@      double speed (status bit 1) and 2448-byte blocks (CD-DA and a zero
@      subcode); 2048 bytes and single speed again, a data sector; Abort and
@      Flush. Every status is compared byte for byte.
@   9. SPORT copies (the CPU's read transfer of a row, then its write
@      transfer into another) and flash writes with write masks (the data the
@      CPU writes to SPORT space is the mask: 1 bits are written, 0 bits keep
@      the row's), in on-chip VRAM (0x262000), block 0 (SRAM) and block A
@      (SDRAM): masks with some bits, none, all, different in the two VRAM
@      halves; every word of the destination row is checked after each, and
@      the row after it at the end. Runs from DRAM (copied there), before 8.
@  10. CLIO from the CPU: the timer controls read back at both addresses of
@      a bank; TimerSlack reads back (336 after power-on, 10 bits); a
@      cascaded timer pair 0001:0000 reads 0000:FFFF right after the low
@      timer's borrow (the high timer takes it in the same count); INT0 bit
@      31 is the summary of the enabled INT1 interrupts. Before 8.
@  11. MADAM's matrix engine from the CPU: a 3x3 matrix with negative
@      entries times a vector (16.16, signed products): rows -0.75, 2.875,
@      1.0. Before 8.
@  12. The CEL engine's PLUT from the CPU (SDK madam.h): 16 pairs written at
@      0x03300180 (entries 2n in bits 31-16, 2n+1 in 15-0), the 32 entries
@      read back one per word; pair 2 written again changes only entries 4
@      and 5. Before 8.
@  13. Audio DMA (WO 94/10641): writing a channel's current address clears
@      its next address and writing its length the next length (channel 0,
@      DSPPToRam0; not RamToUncle); DSPPToRam0 with 4 words and no next
@      buffer, filled by a DSP program: the words arrive, the transfer ends
@      in its short last burst (nothing at address 0 or past the buffer) and
@      the channel's enable bit clears. Before 8.
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
	.equ SPORT_CODE, 0x00010000	@ DRAM: test 9's code, copied there
	.equ SPORT_REF,  0x00012000	@ DRAM: test 9's expected destination row
	.equ CD_BUF,     0x00016000	@ DRAM: CD status bytes (test 14)
	.equ CD_CODE,    0x00018000	@ DRAM: test 14's block check code, copied there
	.equ CD_DATA,    0x0001A000	@ DRAM: the CD block being checked (test 14)

@ call the block check code in DRAM (cdblk_code)
	.macro CDBLK
	mov	lr, pc
	ldr	pc, =CD_CODE
	.endm

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

	@ ---- 4. VRAM through ddram.sv: SRAM (0x200000) and SDRAM (0x2A0400) ----
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
	@ 4-sector disc is LBA 154 = 00:02:04, with the 6 sectors of the
	@ streamed disc's audio track 160 = 00:02:10 (test 14 tells them apart)
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
	ldrne	r5, =0x0000020A
	cmpne	r9, r5
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
	ldr	r4, =ROM_BASE + st_read		@ the read's status: 10 C1
	mov	r3, #2
	bl	cd_check_stat

	@ ---- 14. CD-DA and raw sectors (streamed disc with an audio track) ----
	@ Disc (tb_top +stream): track 1 data, abs LBA 150-153; track 2 audio,
	@ 154-159; lead-out 160 = 00:02:10. Byte i of the audio sector at abs
	@ LBA L is (3i + L + (i >> 8)) & 0xFF.
	mov	r12, #14
	ldr	r3, =CD_CODE
	ldr	r4, =ROM_BASE + cdblk_code
	ldr	r5, =ROM_BASE + cdblk_code_end
25:	ldr	r6, [r4], #4
	str	r6, [r3], #4
	cmp	r4, r5
	bcc	25b
	ldr	r4, =ROM_BASE + cmd_info
	bl	cd_send7
	ldr	r4, =CD_BUF
	mov	r3, #8
	bl	cd_get_stat
	ldr	r4, =CD_BUF
	ldrb	r0, [r4, #3]		@ last track
	cmp	r0, #1
	bne	14f
	ldr	r5, =ROM_BASE + st_info_iso	@ one data track (preloaded ISO): no CD-DA
	mov	r3, #8
	bl	cd_cmp_buf
	b	15f
14:	ldr	r5, =ROM_BASE + st_info
	mov	r3, #8
	bl	cd_cmp_buf
	ldr	r4, =ROM_BASE + cmd_toc1	@ TOC: track 1 data at 00:02:00
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_toc1
	mov	r3, #10
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_toc2	@ track 2 audio at 00:02:04
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_toc2
	mov	r3, #10
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_mode2352
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_mode
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_read_a	@ MSF 00:02:05 (abs 155), 2 blocks
	bl	cd_send7
	mov	r9, #0
	ldr	r3, =2352
	mov	r8, #155
	CDBLK
	mov	r8, #156
	CDBLK
	ldr	r4, =ROM_BASE + st_read
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_subq
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_subq_a	@ track 2 index 1, 00:02:06, 00:00:02
	mov	r3, #12
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_read_d	@ LBA 151, 1 block: the raw data sector
	bl	cd_send7
	mov	r9, #1
	ldr	r3, =2352
	mov	r8, #151
	CDBLK
	ldr	r4, =ROM_BASE + st_read
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_subq
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_subq_d	@ track 1 index 1, 00:02:01, 00:00:01
	mov	r3, #12
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_speed2x
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_mode2x	@ status bit 1: double speed
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_mode2448
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_mode2x
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_read_a2	@ MSF 00:02:07 (abs 157), 2 blocks
	bl	cd_send7
	mov	r9, #0
	ldr	r3, =2448
	mov	r8, #157
	CDBLK
	mov	r8, #158
	CDBLK
	ldr	r4, =ROM_BASE + st_read2x
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_mode2048
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_mode2x
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_speed1x
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_mode
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_read_d2	@ LBA 152, 1 block of 2048 bytes
	bl	cd_send7
	mov	r9, #2
	mov	r3, #2048
	mov	r8, #152
	CDBLK
	ldr	r4, =ROM_BASE + st_read
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_abort
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_abort
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_flush
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_flush
	mov	r3, #2
	bl	cd_check_stat
15:

	@ ---- 9. SPORT copies and flash writes with write masks ----
	@ (before test 8, which ends with the reset; from DRAM: fetches from
	@ the ROM would make its 20000 checks slow)
	mov	r12, #9
	ldr	r3, =SPORT_CODE
	ldr	r4, =ROM_BASE + sport_code
	ldr	r5, =ROM_BASE + sport_code_end
13:	ldr	r6, [r4], #4
	str	r6, [r3], #4
	cmp	r4, r5
	bcc	13b
	ldr	r3, =SPORT_CODE
	mov	lr, pc
	mov	pc, r3

	@ ---- 10. CLIO timers and interrupt summary from the CPU ----
	@ (FIQ is masked in the CPSR here: the INT1 interrupt does nothing else)
	mov	r12, #10
	ldr	r0, =0x03400000
	mvn	r1, #0
	str	r1, [r0, #0x204]	@ all timer controls clear
	str	r1, [r0, #0x20C]
	mov	r1, #0x72
	str	r1, [r0, #0x200]
	add	r2, r0, #0x200		@ controls 0-7, set address
	ldr	r6, [r2]
	cmp	r6, #0x72
	bne	fail
	add	r2, r0, #0x204		@ ... clear address
	ldr	r6, [r2]
	cmp	r6, #0x72
	bne	fail
	mov	r1, #0x30000000
	str	r1, [r0, #0x208]
	add	r2, r0, #0x20C		@ controls 8-15, clear address
	ldr	r6, [r2]
	cmp	r6, #0x30000000
	bne	fail
	mvn	r1, #0
	str	r1, [r0, #0x204]
	str	r1, [r0, #0x20C]
	add	r2, r0, #0x220		@ TimerSlack: 336 after power-on
	ldr	r6, [r2]
	cmp	r6, #336
	bne	fail
	ldr	r1, =0xFFFF
	str	r1, [r0, #0x220]
	ldr	r6, [r2]
	ldr	r5, =0x3FF		@ 10 bits (and 43 us between counts below)
	cmp	r6, r5
	bne	fail
	add	r11, r11, #5
	@ cascaded pair 0001:0000 (timer 1 on timer 0), both reloading FFFF
	mov	r1, #0
	str	r1, [r0, #0x100]
	ldr	r1, =0xFFFF
	str	r1, [r0, #0x104]
	str	r1, [r0, #0x10C]
	mov	r1, #1
	str	r1, [r0, #0x108]
	mov	r1, #0x73
	str	r1, [r0, #0x200]
	add	r2, r0, #0x100
14:	ldr	r6, [r2]		@ until timer 0 borrows
	cmp	r6, #0
	beq	14b
	add	r2, r0, #0x108
	ldr	r5, [r2]		@ timer 1 took the borrow in the same count
	cmp	r5, #0
	bne	fail
	ldr	r5, =0xFFFF
	cmp	r6, r5
	addne	r2, r0, #0x100
	bne	fail
	mvn	r1, #0
	str	r1, [r0, #0x204]
	mov	r1, #336
	str	r1, [r0, #0x220]
	add	r11, r11, #2
	@ INT0 bit 31: the summary of the enabled INT1 interrupts
	add	r2, r0, #0x40
	mvn	r1, #0
	str	r1, [r0, #0x6C]		@ INT1 interrupts disabled
	mov	r1, #2
	str	r1, [r0, #0x60]		@ INT1 source 1 pending
	ldr	r6, [r2]
	tst	r6, #0x80000000		@ not enabled: no summary
	bne	fail
	str	r1, [r0, #0x68]		@ enabled
	ldr	r6, [r2]
	tst	r6, #0x80000000
	beq	fail
	str	r1, [r0, #0x64]		@ acknowledged
	ldr	r6, [r2]
	tst	r6, #0x80000000
	bne	fail
	str	r1, [r0, #0x6C]
	add	r11, r11, #3

	@ ---- 11. MADAM matrix engine (signed 16.16) ----
	@ M = [-0.5 0.25 0; 0.75 -1 0.5; 0 0 1], V = [0.5 -2 1]
	mov	r12, #11
	ldr	r0, =0x03300000
	mov	r1, #0
	mov	r2, #0x600		@ clear the matrix (16 words) and the vector
15:	str	r1, [r0, r2]
	add	r2, r2, #4
	cmp	r2, #0x650
	bne	15b
	ldr	r1, =0xFFFF8000		@ -0.5
	str	r1, [r0, #0x600]	@ M[0][0]
	mov	r1, #0x4000		@ 0.25
	str	r1, [r0, #0x604]	@ M[0][1]
	mov	r1, #0xC000		@ 0.75
	str	r1, [r0, #0x610]	@ M[1][0]
	ldr	r1, =0xFFFF0000		@ -1
	str	r1, [r0, #0x614]	@ M[1][1]
	mov	r1, #0x8000		@ 0.5
	str	r1, [r0, #0x618]	@ M[1][2]
	mov	r1, #0x10000		@ 1
	str	r1, [r0, #0x628]	@ M[2][2]
	mov	r1, #0x8000
	str	r1, [r0, #0x640]	@ V[0]
	ldr	r1, =0xFFFE0000		@ -2
	str	r1, [r0, #0x644]	@ V[1]
	mov	r1, #0x10000
	str	r1, [r0, #0x648]	@ V[2]
	mov	r1, #2			@ 3x3 multiply
	add	r2, r0, #0x7F0
	str	r1, [r2, #0xC]
16:	ldr	r6, [r2, #0x8]		@ until done
	tst	r6, #1
	bne	16b
	mov	r1, #0
	str	r1, [r2, #0xC]		@ result bank to the CPU
	add	r2, r0, #0x660		@ row 0: -0.75
	ldr	r6, [r2]
	ldr	r5, =0xFFFF4000
	cmp	r6, r5
	bne	fail
	add	r2, r2, #4		@ row 1: 2.875
	ldr	r6, [r2]
	ldr	r5, =0x0002E000
	cmp	r6, r5
	bne	fail
	add	r2, r2, #4		@ row 2: 1.0
	ldr	r6, [r2]
	cmp	r6, #0x10000
	bne	fail
	add	r11, r11, #3

	@ ---- 12. CEL engine PLUT from the CPU (SDK madam.h) ----
	@ a write to 0x03300180 + 4n sets entries 2n (bits 31-16) and 2n+1;
	@ a read of 0x03300180 + 4n returns entry n. Entry e = 0x1000 + e * 0x123;
	@ then pair 2 (0x188) is written again: only entries 4 and 5 change.
	mov	r12, #12
	ldr	r0, =0x03300180
	ldr	r7, =0x123
	mov	r3, #0x1000
	mov	r2, r0
17:	add	r4, r3, r7		@ the odd entry
	orr	r1, r4, r3, lsl #16
	str	r1, [r2], #4
	add	r3, r4, r7
	add	r1, r0, #0x40
	cmp	r2, r1
	bne	17b
	mov	r8, #0			@ 0: all pairs written, 1: pair 2 written again
18:	mov	r3, #0x1000
	mov	r2, r0
19:	ldr	r6, [r2]
	mov	r6, r6, lsl #16
	mov	r6, r6, lsr #16
	mov	r5, r3
	cmp	r8, #0
	beq	20f
	sub	r1, r2, r0
	cmp	r1, #0x10
	ldreq	r5, =0x6002		@ entry 4
	cmp	r1, #0x14
	ldreq	r5, =0x7002		@ entry 5
20:	cmp	r6, r5
	bne	fail
	add	r3, r3, r7
	add	r2, r2, #4
	add	r1, r0, #0x80
	cmp	r2, r1
	bne	19b
	add	r11, r11, #32
	cmp	r8, #0
	bne	21f
	mov	r8, #1
	ldr	r1, =0x60027002
	str	r1, [r0, #8]
	b	18b
21:

	@ ---- 13. Audio DMA (WO 94/10641): reload clearing, end of transfer ----
	mov	r12, #13
	ldr	r0, =0x03300000
	@ (a) a current address write clears the next address, a remaining
	@ length write the next length: channel 0 (0x400) and DSPPToRam0 (0x500)
	mov	r3, #0x400
30:	add	r4, r0, r3
	ldr	r1, =0x00012340
	str	r1, [r4, #8]		@ next address
	ldr	r1, =0x00000FFC
	str	r1, [r4, #0xC]		@ next length
	ldr	r1, =0x00020000
	str	r1, [r4]		@ current address
	add	r2, r4, #8
	ldr	r6, [r2]
	cmp	r6, #0			@ next address cleared
	bne	fail
	add	r2, r4, #0xC
	ldr	r6, [r2]
	ldr	r5, =0x00000FFC
	cmp	r6, r5			@ next length kept
	bne	fail
	ldr	r1, =0x00012340
	str	r1, [r4, #8]
	mov	r1, #0xC
	str	r1, [r4, #4]		@ remaining length
	add	r2, r4, #0xC
	ldr	r6, [r2]
	cmp	r6, #0			@ next length cleared
	bne	fail
	add	r2, r4, #8
	ldr	r6, [r2]
	ldr	r5, =0x00012340
	cmp	r6, r5			@ next address kept
	bne	fail
	add	r11, r11, #4
	cmp	r3, #0x500
	movne	r3, #0x500
	bne	30b
	add	r4, r0, #0x4D0		@ RamToUncle is not an audio group
	ldr	r1, =0x00012340
	str	r1, [r4, #8]
	ldr	r1, =0x00020000
	str	r1, [r4]
	add	r2, r4, #8
	ldr	r6, [r2]
	ldr	r5, =0x00012340
	cmp	r6, r5
	bne	fail
	mov	r1, #0
	str	r1, [r4, #8]
	str	r1, [r4]
	add	r11, r11, #1
	@ (b) DSPPToRam0: 4 words to 0x40000, no next buffer. The DSP fills
	@ output FIFO 0 with 1..8 every frame; CLIO asks at 6 samples (3 words), so
	@ the second burst ends after one word: the transfer must end there, not
	@ go on at address 0, and the channel must not start again.
	ldr	r3, =0x00040000
	ldr	r1, =0xDEAD0000
	mov	r4, #0
31:	add	r5, r1, r4
	str	r5, [r3, r4, lsl #2]
	add	r4, r4, #1
	cmp	r4, #8
	bne	31b
	mov	r4, #0
	ldr	r7, [r4]		@ DRAM word 0, restored below
	ldr	r1, =0x5EED5EED
	str	r1, [r4]
	ldr	r8, =0x03400000
	ldr	r4, =0x034017E8
	mov	r1, #0
	str	r1, [r4, #0x14]		@ DSP stopped (0x17FC)
	add	r4, r8, #0x300
	mov	r1, #0x10000
	str	r1, [r4]		@ output FIFO 0 initialised (its DMA off)
	add	r4, r0, #0x500
	str	r3, [r4]		@ current address 0x40000
	mov	r1, #0xC
	str	r1, [r4, #4]		@ 16 bytes (the next registers clear)
	add	r4, r8, #0x2000		@ DSP: 8 x MOVE output FIFO 0 <- k, SLEEP
	ldr	r5, =0x9BF0
	ldr	r6, =0xC001
	mov	r1, #8
32:	str	r5, [r4], #4
	str	r6, [r4], #4
	add	r6, r6, #1
	subs	r1, r1, #1
	bne	32b
	ldr	r5, =0x8380
	str	r5, [r4], #4
	ldr	r5, =0x8000
	str	r5, [r4], #4
	str	r5, [r4], #4
	add	r4, r8, #0x300
	mov	r1, #0x10000
	str	r1, [r4, #4]		@ DMA from output FIFO 0 enabled
	ldr	r4, =0x034017E8
	mov	r1, #0
	str	r1, [r4]		@ DSP from 0
	mov	r1, #1
	str	r1, [r4, #0x14]		@ run
	ldr	r1, =5000		@ about 35 DSP frames
33:	subs	r1, r1, #1
	bne	33b
	mov	r1, #0
	str	r1, [r4, #0x14]		@ DSP stopped
	ldr	r5, =0x00010002		@ samples 1,2 3,4 5,6 7,8
	ldr	r1, =0x00020002
	mov	r4, #0
34:	add	r2, r3, r4, lsl #2
	ldr	r6, [r2]
	cmp	r6, r5
	bne	fail
	add	r5, r5, r1
	add	r4, r4, #1
	cmp	r4, #4
	bne	34b
	add	r2, r3, #0x10		@ the word after the buffer
	ldr	r6, [r2]
	ldr	r5, =0xDEAD0004
	cmp	r6, r5
	bne	fail
	mov	r2, #0			@ address 0
	ldr	r6, [r2]
	ldr	r5, =0x5EED5EED
	cmp	r6, r5
	bne	fail
	str	r7, [r2]
	add	r2, r8, #0x304		@ the channel stopped itself
	ldr	r6, [r2]
	tst	r6, #0x10000
	bne	fail
	add	r11, r11, #7

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

@ the 7 command bytes at r4 -> XBUS command register (uses r1, r3, r10)
cd_send7:
	mov	r3, #7
	ldr	r10, =0x03400580
16:	ldrb	r1, [r4], #1
	str	r1, [r10]
	subs	r3, r3, #1
	bne	16b
	mov	pc, lr

@ wait for status, then its r3 bytes -> [r4] (uses r0, r6, r10)
cd_get_stat:
	ldr	r10, =0x03400540
17:	ldr	r6, [r10]
	tst	r6, #0x10
	beq	17b
	ldr	r10, =0x03400580
	mov	r0, #0
18:	ldr	r6, [r10]
	strb	r6, [r4, r0]
	add	r0, r0, #1
	cmp	r0, r3
	bne	18b
	mov	pc, lr

@ compare r3 bytes at r4 with the expected ones at r5; r11++ (one check).
@ A mismatch fails with r2 = expected << 16 | got << 8 | byte index.
cd_cmp_buf:
	mov	r0, #0
19:	ldrb	r6, [r4, r0]
	ldrb	r1, [r5, r0]
	cmp	r1, r6
	orrne	r2, r0, r6, lsl #8
	orrne	r2, r2, r1, lsl #16
	bne	fail
	add	r0, r0, #1
	cmp	r0, r3
	bne	19b
	add	r11, r11, #1
	mov	pc, lr

@ wait for status and compare its r3 bytes with the ones at r4; r11++
@ (uses r0, r1, r5, r6, r7, r10)
cd_check_stat:
	mov	r7, lr
	mov	r5, r4
	ldr	r4, =CD_BUF
	bl	cd_get_stat
	bl	cd_cmp_buf
	mov	pc, r7

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

@ CD commands (7 bytes) and the status they must give (test 14; C1: door
@ closed, disc in, ready; C3: and double speed)
cmd_info:	.byte	0x8B, 0, 0, 0, 0, 0, 0
cmd_toc1:	.byte	0x8C, 0, 1, 0, 0, 0, 0
cmd_toc2:	.byte	0x8C, 0, 2, 0, 0, 0, 0
cmd_mode2352:	.byte	0x09, 0x00, 0x00, 0x09, 0x30, 0x00, 0	@ density: 2352 bytes
cmd_mode2448:	.byte	0x09, 0x00, 0x00, 0x09, 0x30, 0x40, 0	@ flags 0x40: 2448 (subcode)
cmd_mode2048:	.byte	0x09, 0x00, 0x00, 0x08, 0x00, 0x00, 0
cmd_speed2x:	.byte	0x09, 0x03, 0x80, 0, 0, 0, 0
cmd_speed1x:	.byte	0x09, 0x03, 0x00, 0, 0, 0, 0
cmd_read_a:	.byte	0x10, 0, 2, 5, 0, 0, 2		@ MSF 00:02:05, 2 blocks
cmd_read_a2:	.byte	0x10, 0, 2, 7, 0, 0, 2		@ MSF 00:02:07, 2 blocks
cmd_read_d:	.byte	0x10, 0, 0, 151, 1, 0, 1	@ LBA 151, 1 block
cmd_read_d2:	.byte	0x10, 0, 0, 152, 1, 0, 1	@ LBA 152, 1 block
cmd_subq:	.byte	0x87, 0, 0, 0, 0, 0, 0
cmd_abort:	.byte	0x08, 0, 0, 0, 0, 0, 0
cmd_flush:	.byte	0x0B, 0, 0, 0, 0, 0, 0
st_info:	.byte	0x8B, 0x00, 1, 2, 0, 2, 10, 0xC1	@ DA/CD-ROM, tracks 1-2, lead-out 00:02:10
st_info_iso:	.byte	0x8B, 0x00, 1, 1, 0, 2, 4, 0xC1		@ one track, lead-out 00:02:04
st_toc1:	.byte	0x8C, 0, 0x04, 1, 0, 0, 2, 0, 0, 0xC1
st_toc2:	.byte	0x8C, 0, 0x00, 2, 0, 0, 2, 4, 0, 0xC1
st_mode:	.byte	0x09, 0xC1
st_mode2x:	.byte	0x09, 0xC3
st_read:	.byte	0x10, 0xC1
st_read2x:	.byte	0x10, 0xC3
st_abort:	.byte	0x08, 0xC1
st_flush:	.byte	0x0B, 0xC1
@ Read Sub-Q: ctrl, track, index, 0, abs M S F, rel M S F (binary)
st_subq_a:	.byte	0x87, 0x00, 2, 1, 0, 0, 2, 6, 0, 0, 2, 0xC1
st_subq_d:	.byte	0x87, 0x04, 1, 1, 0, 0, 2, 1, 0, 0, 1, 0xC1
@ raw MODE1 sector header at 00:02:01: sync, BCD MSF, mode
raw_hdr151:	.byte	0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x02, 0x01, 0x01
	.align 4

@ read an r3-byte block from the CD data port and check it; r8 = abs LBA,
@ r9 = 0: CD-DA ((3i + L + (i >> 8)) & 0xFF), 1: the raw data sector
@ (sync, header, user data (7(i-16) + L - 150) & 0xFF, EDC/ECC as zeros
@ in the testbench's model), 2: user data (7i + L - 150) & 0xFF; zeros
@ after byte 2351 of the sector. r11++. A mismatch fails with
@ r2 = L << 16 | i. (uses r0, r1, r5, r6, r7, r10)
@ Copied to CD_CODE and run there (position independent, its own literal
@ pool; called with CDBLK): from the ROM, the CPU would take longer than a
@ sector time for a block, and the drive's CD-DA rate would not be seen.
	.align 4
cdblk_code:
	ldr	r10, =0x03400540
20:	ldr	r6, [r10]
	tst	r6, #0x20
	beq	20b
	ldr	r10, =0x034005C0
	ldr	r1, =CD_DATA		@ the block into DRAM first, then the check:
	mov	r0, r3			@ the CPU must read a block in less than a
26:	ldr	r6, [r10]		@ sector time at double speed
	strb	r6, [r1], #1
	subs	r0, r0, #1
	bne	26b
	ldr	r10, =CD_DATA
	sub	r7, r8, #150		@ sector of the data track
	mov	r0, #0
21:	ldrb	r6, [r10, r0]
	cmp	r9, #2
	beq	24f
	cmp	r0, #2352
	movhs	r5, #0
	bhs	23f
	cmp	r9, #0
	bne	22f
	add	r5, r0, r0, lsl #1	@ CD-DA: 3i + L + (i >> 8)
	add	r5, r5, r8
	add	r5, r5, r0, lsr #8
	b	23f
22:	cmp	r0, #16			@ raw data sector
	ldrlo	r1, =ROM_BASE + raw_hdr151
	ldrlob	r5, [r1, r0]
	blo	23f
	ldr	r1, =2064
	cmp	r0, r1
	movhs	r5, #0
	bhs	23f
	sub	r1, r0, #16
	rsb	r5, r1, r1, lsl #3	@ 7 (i - 16)
	add	r5, r5, r7
	b	23f
24:	rsb	r5, r0, r0, lsl #3	@ user data: 7i + sector
	add	r5, r5, r7
23:	and	r5, r5, #0xFF
	cmp	r5, r6
	orrne	r2, r0, r8, lsl #16
	ldrne	pc, =ROM_BASE + fail
	add	r0, r0, #1
	cmp	r0, r3
	bne	21b
	add	r11, r11, #1
	mov	pc, lr

	.ltorg
cdblk_code_end:

@ ---- test 9, copied to SPORT_CODE and run there (position independent,
@ its own literal pool). r11 = checks; a mismatch goes to fail with its
@ address in r2. The CPU's SPORT accesses (MADAM: 0x0320xxxx, row in
@ address bits 10..2): a read is a read transfer of the row into the CPU's
@ shift register, a write a write transfer from it with the written data
@ as the mask; a write with address bit 13 loads the flash colour, with
@ bit 14 flash-writes the row (mask: the written data). Bits 31..16 go to
@ the left VRAM half, 15..0 to the right one, each with its own mask.
	.align 4
sport_code:
	mov	r7, lr
	ldr	r0, =0x00262000		@ on-chip VRAM (BRAM1 window)
	bl	sp_region
	ldr	r0, =0x00204000		@ block 0 (SRAM, SDRAM with it off)
	bl	sp_region
	ldr	r0, =0x002A4000		@ block A (SDRAM)
	bl	sp_region
	mov	pc, r7

@ source row r0, destination row r0 + 0x800, guard row r0 + 0x1000
sp_region:
	mov	r13, lr
	sub	r8, r0, #0x00200000	@ SPORT address of the source row:
	mov	r8, r8, lsr #9		@ 0x03200000 + 4 * row, row = offset / 0x800
	add	r8, r8, #0x03200000
	add	r9, r8, #4		@ ... of the destination row
	@ every word of the three rows its own; the destination's in SPORT_REF
	mov	r1, #512
	mov	r2, r0
	ldr	r4, =0x2468ACE1
	ldr	r5, =0x13579BDF
	ldr	r10, =SPORT_REF
51:	eor	r6, r4, r2, lsl #3
	str	r6, [r2]
	eor	r6, r5, r2, lsl #5
	str	r6, [r2, #0x800]
	str	r6, [r10], #4
	mvn	r6, r6
	add	r3, r2, #0x1000
	str	r6, [r3]
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	51b
	bl	sp_check
	ldr	r3, =0x00FF0F0F		@ copies: mask r3
	bl	sp_copy
	mov	r3, #0
	bl	sp_copy
	ldr	r4, =0x12345678		@ flash writes: colour r4, mask r3
	ldr	r3, =0xF0F0FF00
	bl	sp_flash
	ldr	r4, =0x9ABCDEF0
	mov	r3, #0
	bl	sp_flash
	ldr	r3, =0xFFFF3C3C
	bl	sp_copy
	ldr	r4, =0x24681357
	ldr	r3, =0xFFFF0000
	bl	sp_flash
	ldr	r4, =0x75318642
	ldr	r3, =0x0000FFFF
	bl	sp_flash
	ldr	r3, =0x0000A5A5
	bl	sp_copy
	ldr	r4, =0x0F1E2D3C
	ldr	r3, =0x5555FFFF
	bl	sp_flash
	ldr	r4, =0x4B4BB4B4
	mvn	r3, #0
	bl	sp_flash
	mvn	r3, #0
	bl	sp_copy
	@ the guard row: no transfer wrote it
	mov	r1, #512
	add	r2, r0, #0x1000
	ldr	r4, =0x13579BDF
52:	sub	r3, r2, #0x1000		@ its source row's address made its value
	eor	r6, r4, r3, lsl #5
	mvn	r6, r6
	ldr	r5, [r2]
	cmp	r5, r6
	ldrne	pc, =ROM_BASE + fail
	add	r11, r11, #1
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	52b
	mov	pc, r13

@ copy with mask r3: read transfer of the source row, write transfer into
@ the destination row; reference = (source & mask) | (reference & ~mask)
sp_copy:
	ldr	r6, [r8]
	str	r3, [r9]
	mov	r1, #512
	mov	r2, r0
	ldr	r10, =SPORT_REF
	ldr	r5, =0x2468ACE1
53:	eor	r6, r5, r2, lsl #3
	and	r6, r6, r3
	ldr	r4, [r10]
	bic	r4, r4, r3
	orr	r4, r4, r6
	str	r4, [r10], #4
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	53b
	b	sp_check

@ flash write of colour r4 with mask r3 into the destination row;
@ reference = (colour & mask) | (reference & ~mask)
sp_flash:
	add	r6, r9, #0x2000
	str	r4, [r6]
	add	r6, r9, #0x4000
	str	r3, [r6]
	and	r4, r4, r3
	mov	r1, #512
	ldr	r10, =SPORT_REF
54:	ldr	r6, [r10]
	bic	r6, r6, r3
	orr	r6, r6, r4
	str	r6, [r10], #4
	subs	r1, r1, #1
	bne	54b
	@ fall through

@ every word of the destination row against the reference
sp_check:
	mov	r1, #512
	add	r2, r0, #0x800
	ldr	r10, =SPORT_REF
55:	ldr	r5, [r2]
	ldr	r6, [r10], #4
	cmp	r5, r6
	ldrne	pc, =ROM_BASE + fail
	add	r11, r11, #1
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	55b
	mov	pc, lr

	.ltorg
sport_code_end:
