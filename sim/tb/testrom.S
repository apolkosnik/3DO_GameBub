@ Test "BIOS" for the Game Bub 3DO core system testbench (tb_top).
@
@ Runs on the core's ARM60 (ARMv3, big-endian) straight out of the BIOS ROM
@ (slow bus -> ddram.sv -> ddr_bridge -> SDRAM secondary port) and checks:
@   1. DRAM word write/read (SDRAM TDM part), several pages
@   2. DRAM byte writes (lane enables) + word read
@   3. VRAM in the on-chip BRAM1 window (0x260000) and the VDL area (0x2FC000)
@   4. VRAM through ddram.sv: 0x200000 (block 0, in the SDRAM overflow tier
@      by default) and 0x2A0400 (block A, in the SRAM, vram_sram.sv)
@   5. ROM data reads (literal table in ROM)
@   6. NVRAM byte writes/reads (0x03140000, one byte per word, low byte)
@   7. CD-ROM through CLIO XBUS -> OSA -> 3DO_CDROM -> cdd_emu -> SDRAM:
@      "read capacity" (disc-info block) and a 2-sector data read (NEXT),
@      then its status
@  14. CD-DA and raw sectors (streamed disc with an audio track, see
@      tb_top; skipped, and counted as one check, on a disc of one data
@      track): disc info and the TOC entries of both tracks; Set Mode
@      block length 2352, two audio sectors (the controller's buffer must
@      start each block at its byte 0), Read Sub-Q at the audio track,
@      then a READ of the next audio sector (it continues the stream: tb_top
@      checks that it comes one sector time after the previous) and Read
@      Sub-Q there; a raw
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
@  15. Page copies with the video DMA on: a VDL entry (in the VDL area) for
@      240 lines of a frame buffer outside the FPGA (through the read-transfer
@      cache), MCTL CLUTXEN and VSCTXEN on; from line 40 of the next frame
@      (CLIO's line count) 600 page copies (the CPU's read transfer of a
@      source row, its write transfer into the next of the destination rows)
@      back to back while the picture is being shown; every destination row
@      must hold the source row. Twice: 0x210000, 64 rows (SDRAM), and
@      0x2A0000, 32 rows (block A: SRAM unless it is off). tb_top checks that
@      every video line had both of its read transfers before its scanout
@      (a copy's transfer must not hold a line's transfer past it). Before 8.
@  16. VDL next pointer relative (header bit 18, VDL_RELSEL; patent: the
@      next CLUT list address is absolute or relative, REL = target - PC - 4,
@      Opera next += entry + 16): entry A (4 lines, relative, word 3 = 0xF0)
@      must chain to A + 0x100 (B), not to A + 16 (C); read back at MADAM
@      0x584 (the next VDL pointer, B's own) at line 100. Before 8.
@  17. Cel face culling on the cel engine's 1:1 path (HDX or HDY 1.0, VDY or
@      VDX 1.0, no HDDX/HDDY): a 4x4 uncoded 16-bit cel drawn by MADAM
@      (SPRSTRT, first CCB at 0x5A4) with ACW or ACCW only, as stored,
@      flipped up/down and turned 90 degrees; the winding is the sign of
@      HDX * VDY - HDY * VDX (Opera), so the flipped cel needs ACCW. The
@      pixels drawn are counted (16 or 0). Before 8.
@  18. Cel drawing into the shown frame buffer: the video DMA on (a VDL entry
@      for 240 lines of 0x210000, in the SDRAM), 2 translucent cels (a 4x4
@      source scaled to 256x100, PIXC reading the frame buffer: every pixel a
@      frame buffer read and write) drawn into it. tb_top checks every line's
@      transfers: the CEL engine's SDRAM accesses pause the 3DO and must not
@      hold a line's video request past its scanout. Before 8.
@  19. The light gun on the control port (Game Bub registers 0x1014-0x101C,
@      set by tb_top): read by MADAM's player bus DMA as Portfolio reads it;
@      the gun's 40 bits first (ID 0x4D, trigger, the scan count of the
@      aimed pixel, line pulses: player one's gun first in the chain), then
@      the pad word, then no more devices. Before 8.
@  20. The mouse on the control port (Controller setting 2, a motion packet
@      and the buttons from the Game Bub registers 0x1030/0x1034, set by
@      tb_top after test 19's transfer): the pad word, the mouse's 32 bits
@      (ID 0x49, buttons, dy, dx), then no more devices. Before 8.
@  22. The mouse before the pad (Controller setting 3, "Mouse + pad": player
@      1 for games that take the first device as player 1, as Mad Dog
@      McCree does; tb_top sets it after test 20's transfer and writes
@      another motion packet): the mouse's 32 bits, then the pad word, then
@      no more devices. After 20, before 21.
@  23. Two mice before the pad (Controller setting 4, "2 mice + pad": a mouse
@      for each of two players; tb_top sets it after test 22's transfer, the
@      second mouse's right button, and a motion packet for each mouse):
@      mouse 1's 32 bits, mouse 2's, the pad word, then no more devices.
@      After 22, before 21.
@  24. The dock's gamepads as pads of their own (InputV1; Controller setting
@      0, tb_top connects three gamepads after test 23's transfer: the
@      first's B, the second's Start, the third's left stick held left): pad
@      1 (the handheld's buttons and the first gamepad: B), pad 2 (P), pad 3
@      (left), then no more devices. After 23, before 21.
@  21. A software video decoder's in-place decode into screens outside the
@      FPGA, as Killing Time's EZFlix intro does it (Opera, instrumented:
@      every access a 32-bit CPU access, the screens 0x20E800 and 0x234000
@      alternating per picture, the shown one never decoded into): pass 1
@      stores 8-word groups of samples into the screen, alternate groups
@      on alternate line pairs, reading back a word written ~30 accesses
@      before; pass 2 loads each 4-word group of samples (written a pass
@      earlier) and 2-10 accesses later stores pixels over them and into the
@      next line pair, so the next group's first two words are read after
@      they were overwritten. 16 line pairs x 128 columns at the screen's
@      start (its first half-row is the one the read-transfer cache fetches
@      again every frame for the VDL's previous frame buffer). Three
@      pictures with the video DMA on (the VDL as the OS lays a screen out:
@      16 lines without video DMA, then 240 lines): into the screen not
@      shown (twice, switching the VDL between them) and into the shown
@      one. After each:
@      every word read back (random reads), and two rows copied through the
@      CPU's read transfer (the read-transfer cache) and compared. Runs from
@      DRAM (copied there), before 8.
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
	.equ VID_CODE,   0x0001C000	@ DRAM: test 15's code, copied there
	.equ EZ_CODE,    0x00020000	@ DRAM: test 21's code, copied there
	.equ EZ_TMP,     0x00023000	@ DRAM: test 21's words to store next
	.equ EZ_SEED,    0x00023040	@ DRAM: test 21's picture number
	.equ EZ_LR,      0x00023044	@ DRAM: test 21's return address
	.equ EZ_MCTL,    0x00023048	@ DRAM: MCTL before test 21
	.equ EZ_LR2,     0x0002304C	@ DRAM: test 21's helpers' return address

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

	@ ---- 4. VRAM through ddram.sv: SDRAM (0x200000) and SRAM (0x2A0400) ----
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
	ldr	r4, =ROM_BASE + cmd_read_a3	@ MSF 00:02:07 (abs 157), 1 block: continues the stream
	bl	cd_send7
	mov	r9, #0
	ldr	r3, =2352
	mov	r8, #157
	CDBLK
	ldr	r4, =ROM_BASE + st_read
	mov	r3, #2
	bl	cd_check_stat
	ldr	r4, =ROM_BASE + cmd_subq
	bl	cd_send7
	ldr	r4, =ROM_BASE + st_subq_a3	@ track 2 index 1, 00:02:07, 00:00:03
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

	@ ---- 15. page copies with the video DMA on (from DRAM) ----
	mov	r12, #15
	ldr	r3, =VID_CODE
	ldr	r4, =ROM_BASE + vid_code
	ldr	r5, =ROM_BASE + vid_code_end
14:	ldr	r6, [r4], #4
	str	r6, [r3], #4
	cmp	r4, r5
	bcc	14b
	ldr	r3, =VID_CODE
	mov	lr, pc
	mov	pc, r3

	@ ---- 16. VDL next pointer relative (header bit 18) ----
	mov	r12, #16
	ldr	r10, =0x002FC100	@ entry A: 4 lines, relative next
	ldr	r6, =0x00040004
	str	r6, [r10]
	mov	r6, #0
	str	r6, [r10, #4]
	str	r6, [r10, #8]
	mov	r6, #0xF0		@ next = A + 16 + 0xF0 = A + 0x100 (B)
	str	r6, [r10, #12]
	add	r3, r10, #0x10		@ entry C right after A's 4 words: absolute,
	mov	r6, #0xF0		@ 240 lines, next = itself (the old RTL's
	str	r6, [r3]		@ relative next lands here)
	mov	r6, #0
	str	r6, [r3, #4]
	str	r6, [r3, #8]
	str	r3, [r3, #12]
	add	r4, r10, #0x100		@ entry B: absolute, 240 lines, next = itself
	mov	r6, #0xF0
	str	r6, [r4]
	mov	r6, #0
	str	r6, [r4, #4]
	str	r6, [r4, #8]
	str	r4, [r4, #12]
	ldr	r5, =0x03300000
	str	r10, [r5, #0x580]
	ldr	r9, [r5, #8]
	orr	r6, r9, #0x2000		@ MCTL CLUTXEN (VDL DMA only)
	str	r6, [r5, #8]
	@ A is taken at the next frame start; wait for CLIO's line count to go
	@ back to the top, then for line 100 (A's 4 lines are over, B fetched)
	ldr	r8, =0x03400000
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
16:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	16b
17:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, #100
	bcc	17b
	ldr	r2, [r5, #0x584]	@ the next VDL pointer: B's, i.e. B
	str	r9, [r5, #8]		@ MCTL back
	cmp	r2, r4
	bne	fail
	add	r11, r11, #1

	@ ---- 17. cel face culling on the 1:1 path ----
	mov	r12, #17
	ldr	r0, =ROM_BASE + cel_cases
	mov	r1, #5
18:	bl	cel_case
	add	r0, r0, #24
	subs	r1, r1, #1
	bne	18b

	@ ---- 18. cel drawing into a shown SDRAM frame buffer ----
	mov	r12, #18
	bl	cel_shown

	@ ---- 19. light gun on the control port (player bus DMA) ----
	mov	r12, #19
	bl	pbus_dma
	ldr	r1, =0x4D8050D9		@ gun ID, trigger, count[19], count[18:3]
	ldr	r2, =0x3F8000FF		@ count[2:0], hits, the pad word, then 1s
	bl	pbus_check

	@ ---- 20. mouse on the control port ----
	@ tb_top switches the Controller setting to the mouse and sets the left
	@ button after test 19's transfer, and writes one motion packet (dx +5,
	@ dy -3) when this test enables its transfer: the control port is
	@ latched every field (MADAM_PLAYER's PBCLK, lines 0-15), which takes
	@ the mouse's motion whether or not a DMA reads it, so the packet must
	@ come in the field before the one the DMA reads. A frame start, then
	@ lines 30..150 for the enable (the next latch is a whole field away).
	mov	r12, #20
	ldr	r8, =0x03400000
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
20:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	20b
21:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, #30
	bcc	21b
	cmp	r6, #150
	bhi	21b
	bl	pbus_dma
	ldr	r1, =0x8000498F		@ pad word, mouse ID 0x49, left button, dy -3 (bits 19:10) ...
	ldr	r2, =0xF405FFFF		@ ... dy, dx +5 (bits 9:0), then 1s (one count per unit written)
	bl	pbus_check

	@ ---- 22. the mouse before the pad ----
	@ tb_top sets the Controller setting to 3 (mouse + pad) after test 20's
	@ transfer, and writes one motion packet (dx +5, dy -3; the left button
	@ still held) when this test enables its transfer, as for test 20.
	mov	r12, #22
	ldr	r8, =0x03400000
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
20:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	20b
21:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, #30
	bcc	21b
	cmp	r6, #150
	bhi	21b
	bl	pbus_dma
	ldr	r1, =0x498FF405		@ mouse ID 0x49, left button, dy -3, dx +5 first ...
	ldr	r2, =0x8000FFFF		@ ... then the pad word, then 1s
	bl	pbus_check

	@ ---- 23. two mice before the pad ----
	@ tb_top sets the Controller setting to 4 (2 mice + pad) and the second
	@ mouse's right button after test 22's transfer, and writes a motion
	@ packet for each mouse (mouse 1 dx +5 dy -3, mouse 2 dx -7 dy +2) when
	@ this test enables its transfer, as for test 20.
	mov	r12, #23
	ldr	r8, =0x03400000
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
20:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	20b
21:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, #30
	bcc	21b
	cmp	r6, #150
	bhi	21b
	bl	pbus_dma
	ldr	r4, =0x00032000
	ldr	r3, [r4, #4]
	ldr	r1, =0x498FF405		@ mouse 1: left button, dy -3, dx +5
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	ldr	r3, [r4, #8]
	ldr	r1, =0x49200BF9		@ mouse 2: right button, dy +2, dx -7
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	ldr	r3, [r4, #12]
	ldr	r1, =0x8000FFFF		@ the pad word, then 1s
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	ldr	r3, [r4, #16]
	mvn	r1, #0			@ no more devices
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1

	@ ---- 24. the dock's gamepads as pads of their own ----
	mov	r12, #24
	ldr	r8, =0x03400000
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
20:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	20b
21:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, #30
	bcc	21b
	cmp	r6, #150
	bhi	21b
	bl	pbus_dma
	ldr	r1, =0x80808020		@ pad 1: B; pad 2: P
	ldr	r2, =0x8200FFFF		@ pad 3: left; then 1s
	bl	pbus_check

	@ ---- 21. in-place video decode into screens outside the FPGA ----
	mov	r12, #21
	ldr	r3, =EZ_CODE
	ldr	r4, =ROM_BASE + ez_code
	ldr	r5, =ROM_BASE + ez_code_end
22:	ldr	r6, [r4], #4
	str	r6, [r3], #4
	cmp	r4, r5
	bcc	22b
	ldr	r3, =EZ_CODE
	mov	lr, pc
	mov	pc, r3

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
	ldr	r1, =EZ_TMP		@ 0x110, 0x114: the value found and the one
	ldr	r8, [r1]		@ expected, where a test left them there
	bl	put_word
	ldr	r8, [r1, #4]
	bl	put_word
	ldr	r0, =NVRAM_BASE + 0x100 * 4
	mov	r8, r7
	bl	put_word		@ 0x100: PASS/FAIL
	ldr	r0, =0x00001000		@ also leave the record in DRAM
	str	r7, [r0]
	str	r12, [r0, #4]
	str	r11, [r0, #8]
done:	b	done

@ one cel of test 17: r0 = its record (CCB flags, HDX, HDY, VDX, VDY, the
@ number of pixels it must draw); a 4x4 uncoded 16-bit literal cel at
@ (16, 8) into the frame buffer at 0x280000 (320 wide), after clearing its
@ first 64 pixel pairs of rows 0-15. Keeps r0, r1; r11++.
cel_case:
	mov	r13, lr
	ldr	r4, =0x00280000
	mov	r5, #0
	mov	r6, #8
1:	mov	r7, #64
2:	str	r5, [r4], #4
	subs	r7, r7, #1
	bne	2b
	add	r4, r4, #1280 - 256
	subs	r6, r6, #1
	bne	1b
	ldr	r4, =0x00031000		@ the CCB
	ldr	r6, [r0]
	str	r6, [r4]		@ flags
	str	r5, [r4, #4]		@ next (none, LAST)
	ldr	r6, =0x00031100
	str	r6, [r4, #8]		@ source
	str	r5, [r4, #12]		@ PLUT (not loaded)
	mov	r6, #0x00100000
	str	r6, [r4, #16]		@ X 16 (16.16)
	mov	r6, #0x00080000
	str	r6, [r4, #20]		@ Y 8
	ldr	r6, [r0, #4]
	str	r6, [r4, #24]		@ HDX (12.20)
	ldr	r6, [r0, #8]
	str	r6, [r4, #28]		@ HDY (12.20)
	ldr	r6, [r0, #12]
	str	r6, [r4, #32]		@ VDX (16.16)
	ldr	r6, [r0, #16]
	str	r6, [r4, #36]		@ VDY (16.16)
	str	r5, [r4, #40]		@ HDDX
	str	r5, [r4, #44]		@ HDDY
	ldr	r6, =0x1F001F00		@ PIXC: x 8 / 8, nothing added
	str	r6, [r4, #48]
	mov	r6, #0xD6		@ PRE0: 4 rows (VCNT 3), LINEAR, 16 bpp
	str	r6, [r4, #52]
	ldr	r6, =0x00001003		@ PRE1: WOFFSET 0, TLLSB PDC0, 4 pixels
	str	r6, [r4, #56]
	ldr	r4, =0x00031100		@ the pixels: 4 rows of 2 words
	ldr	r6, =0x12341234
	mov	r7, #8
3:	str	r6, [r4], #4
	subs	r7, r7, #1
	bne	3b
	ldr	r4, =0x03300000
	ldr	r6, =0x00001414		@ REGCTL0: modulo 320 (256 + 64) both ways
	str	r6, [r4, #0x130]
	ldr	r6, =0x00EF013F		@ REGCTL1: clip 319, 239
	str	r6, [r4, #0x134]
	ldr	r6, =0x00280000
	str	r6, [r4, #0x138]	@ REGCTL2, REGCTL3: the frame buffer
	str	r6, [r4, #0x13C]
	ldr	r6, =0x00031000
	str	r6, [r4, #0x5A4]	@ the first CCB
	str	r6, [r4, #0x100]	@ SPRSTRT
4:	ldr	r6, [r4, #0x28]		@ until SPRON (STATBits 0x10) clears
	tst	r6, #0x10
	bne	4b
	ldr	r4, =0x00280000		@ count the pixels drawn
	mov	r8, #0
	mov	r6, #8
5:	mov	r7, #64
6:	ldr	r9, [r4], #4
	movs	r10, r9, lsl #16
	addne	r8, r8, #1
	movs	r10, r9, lsr #16
	addne	r8, r8, #1
	subs	r7, r7, #1
	bne	6b
	add	r4, r4, #1280 - 256
	subs	r6, r6, #1
	bne	5b
	ldr	r6, [r0, #20]
	cmp	r8, r6
	movne	r2, r8
	bne	fail
	add	r11, r11, #1
	mov	pc, r13
	.ltorg

@ test 18: video DMA on (VDL entry at 0x2FC000: 240 lines of the frame buffer
@ at 0x210000, in the SDRAM), then 2 translucent cels drawn into that frame
@ buffer: a 4x4 16-bit source scaled to 256x100 at (32, 20), PIXC (PDC x 4 /
@ 8) + (CFBD / 2), so every pixel reads the frame buffer and writes it.
@ tb_top checks that no shown line started before its read transfers. r11++.
cel_shown:
	mov	r13, lr
	ldr	r10, =0x002FC000
	ldr	r6, =0x002180F0
	str	r6, [r10]
	ldr	r6, =0x00210000
	str	r6, [r10, #4]
	str	r6, [r10, #8]
	str	r10, [r10, #12]
	ldr	r5, =0x03300000
	str	r10, [r5, #0x580]
	ldr	r9, [r5, #8]
	orr	r6, r9, #0x6000		@ MCTL CLUTXEN, VSCTXEN
	str	r6, [r5, #8]
	ldr	r8, =0x03400000		@ the next frame start (CLIO's line count)
	ldr	r7, =0x1FF
	ldr	r0, [r8, #0x34]
	and	r0, r0, r7
1:	ldr	r6, [r8, #0x34]
	and	r6, r6, r7
	cmp	r6, r0
	mov	r0, r6
	bcs	1b
	ldr	r4, =0x00031100		@ the source: 4 rows of 2 words
	ldr	r6, =0x5A3C5A3C
	mov	r7, #8
2:	str	r6, [r4], #4
	subs	r7, r7, #1
	bne	2b
	ldr	r6, =0x00001414		@ REGCTL0: modulo 320
	str	r6, [r5, #0x130]
	ldr	r6, =0x00EF013F		@ REGCTL1: clip 319, 239
	str	r6, [r5, #0x134]
	ldr	r6, =0x00210000
	str	r6, [r5, #0x138]	@ REGCTL2: CFBD source
	str	r6, [r5, #0x13C]	@ REGCTL3: destination
	mov	r3, #2
3:	ldr	r4, =0x00031000		@ the CCB
	ldr	r6, =0x7F660000		@ LAST NPABS SPABS PPABS LDSIZE LDPRS LDPPMP CCBPRE YOXY ACW ACCW
	str	r6, [r4]
	mov	r6, #0
	str	r6, [r4, #4]
	ldr	r6, =0x00031100
	str	r6, [r4, #8]
	mov	r6, #0
	str	r6, [r4, #12]
	mov	r6, #0x00200000		@ X 32
	str	r6, [r4, #16]
	mov	r6, #0x00140000		@ Y 20
	str	r6, [r4, #20]
	mov	r6, #0x04000000		@ HDX 64.0 (12.20)
	str	r6, [r4, #24]
	mov	r6, #0
	str	r6, [r4, #28]		@ HDY
	str	r6, [r4, #32]		@ VDX
	mov	r6, #0x00190000		@ VDY 25.0 (16.16)
	str	r6, [r4, #36]
	mov	r6, #0
	str	r6, [r4, #40]
	str	r6, [r4, #44]
	ldr	r6, =0x0F810F81		@ PIXC: PDC x 4 / 8 + CFBD / 2
	str	r6, [r4, #48]
	mov	r6, #0xD6		@ PRE0: 4 rows, LINEAR, 16 bpp
	str	r6, [r4, #52]
	ldr	r6, =0x00001003		@ PRE1: 4 pixels
	str	r6, [r4, #56]
	str	r4, [r5, #0x5A4]	@ the first CCB
	str	r4, [r5, #0x100]	@ SPRSTRT
4:	ldr	r6, [r5, #0x28]		@ until SPRON clears
	tst	r6, #0x10
	bne	4b
	subs	r3, r3, #1
	bne	3b
	str	r9, [r5, #8]		@ MCTL back
	add	r11, r11, #1
	mov	pc, r13
	.ltorg

@ tests 19 and 20: the control port read by MADAM's player bus DMA (MCTL bit 15, the
@ ControlPort registers at 0x570: to RAM, length in bytes - 4, from RAM), as
@ Portfolio reads it every field. The first word written is the port's
@ leftover ("control-port sludge", Portfolio ControlPort.c); the data
@ follow it. tb_top sets the Game Bub registers first:
@ Controller pad + light gun (0x1014), aim x 0x4000, y 0x8000 (pixel 80, 120
@ of 320 x 240), trigger held (0x101C). Expected: the pad word 8000 (no
@ button), the gun's 40 bits 4D 80 50 D9 3F (count 0x286C9 = ceil((120 *
@ 12707 + 80 * 10300 / 320) / 10) + 12835, 31 line pulses), then 1s (no
@ more devices). Test 20: the mouse (ID 0x49) with the left button, dy -3
@ and dx +5 in 10 bits each (HPS2PAD moves one count per unit written).
pbus_dma:
	mov	r13, lr
	ldr	r5, =0x03300000
	ldr	r4, =0x00032000		@ the buffer the port is read into
	ldr	r6, =0x00032100		@ the data shifted out to the port: all 1s
	mov	r7, #8
	mvn	r1, #0
	mov	r2, #0
1:	str	r2, [r4], #4
	str	r1, [r6], #4
	subs	r7, r7, #1
	bne	1b
	ldr	r4, =0x00032000
	ldr	r6, =0x00032100
	str	r4, [r5, #0x570]	@ to RAM
	mov	r1, #0x1C		@ 32 bytes
	str	r1, [r5, #0x574]
	str	r6, [r5, #0x578]	@ from RAM
	ldr	r9, [r5, #8]
	orr	r1, r9, #0x8000		@ MCTL PLAYXEN
	str	r1, [r5, #8]
2:	ldr	r1, [r5, #8]		@ MADAM clears it at the end of the transfer
	tst	r1, #0x8000
	bne	2b
	str	r9, [r5, #8]
	mov	pc, r13

@ the words after the first (the port's leftover, Portfolio ControlPort.c;
@ Opera DMAPBus) of the buffer pbus_dma read: r1, r2, then all 1s (no more
@ devices). r11 += 3.
pbus_check:
	ldr	r4, =0x00032000
	ldr	r3, [r4, #4]
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	ldr	r3, [r4, #8]
	cmp	r3, r2
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	ldr	r3, [r4, #12]
	mvn	r1, #0
	cmp	r3, r1
	movne	r2, r3
	bne	fail
	add	r11, r11, #1
	mov	pc, lr
	.ltorg

@ test 17's cels: flags, HDX, HDY, VDX, VDY, pixels drawn. The winding is
@ the sign of HDX * VDY - HDY * VDX (Opera TestInitVisual): positive takes
@ ACW, negative ACCW. LAST, NPABS, SPABS, PPABS, LDSIZE, LDPRS, LDPPMP,
@ CCBPRE, YOXY = 0x7F600000; ACW 0x40000, ACCW 0x20000.
cel_cases:
	.word	0x7F640000, 0x00100000, 0, 0, 0x00010000, 16	@ ACW, as stored
	.word	0x7F640000, 0x00100000, 0, 0, 0xFFFF0000, 0	@ ACW, flipped up/down
	.word	0x7F620000, 0x00100000, 0, 0, 0xFFFF0000, 16	@ ACCW, flipped up/down
	.word	0x7F620000, 0x00100000, 0, 0, 0x00010000, 0	@ ACCW, as stored
	.word	0x7F640000, 0, 0x00100000, 0xFFFF0000, 0, 16	@ ACW, 90 degrees

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
cmd_read_a3:	.byte	0x10, 0, 2, 7, 0, 0, 1		@ MSF 00:02:07, 1 block
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
st_subq_a3:	.byte	0x87, 0x00, 2, 1, 0, 0, 2, 7, 0, 0, 3, 0xC1
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

@ ---- test 15, copied to VID_CODE and run there (position independent, its
@ own literal pool). r11 = checks; a mismatch goes to fail with its address
@ in r2.
	.align 4
vid_code:
	mov	r7, lr
	ldr	r0, =0x00210000		@ frame buffer rows 0x20-0x5F (SDRAM), source row 0x7F
	mov	r1, #0x7F
	mov	r2, #0x20
	mov	r3, #64
	bl	vid_pass
	ldr	r0, =0x002A0000		@ rows 0x140-0x15F (block A: SRAM unless it is off), source 0x17F
	ldr	r1, =0x17F
	ldr	r2, =0x140
	mov	r3, #32
	bl	vid_pass
	mov	pc, r7

@ one pass: frame buffer r0 (the VDL's line addresses), source row r1,
@ destination rows r2 .. r2 + r3 - 1 (r3 a power of 2)
vid_pass:
	mov	r13, lr
	@ VDL entry at 0x2FC000: ENVIDDMA, LDCURR, LDPREV, no optional words,
	@ 240 lines; current and previous line address r0; the next entry is
	@ this one (absolute: bit 18 clear)
	ldr	r10, =0x002FC000
	ldr	r6, =0x002180F0
	str	r6, [r10]
	str	r0, [r10, #4]
	str	r0, [r10, #8]
	str	r10, [r10, #12]
	@ the source row: word i = 0x5A5A0000 + 512 - i
	mov	r5, r1, lsl #11
	add	r5, r5, #0x00200000
	mov	r9, #512
	ldr	r4, =0x5A5A0000
71:	add	r6, r4, r9
	str	r6, [r5], #4
	subs	r9, r9, #1
	bne	71b
	@ video DMA on: the VDL address, MCTL CLUTXEN (bit 13) and VSCTXEN (14)
	ldr	r10, =0x03300000
	ldr	r6, =0x002FC000
	str	r6, [r10, #0x580]
	ldr	r9, [r10, #8]
	orr	r6, r9, #0x6000
	str	r6, [r10, #8]
	@ the VDL is taken at the next frame start: wait for CLIO's line count
	@ (0x03400034, bits 8-0) to go back to the top, then for line 40
	ldr	r8, =0x03400000
	ldr	r4, =0x1FF
	ldr	r5, [r8, #0x34]
	and	r5, r5, r4
72:	ldr	r6, [r8, #0x34]
	and	r6, r6, r4
	cmp	r6, r5
	mov	r5, r6
	bcs	72b
73:	ldr	r6, [r8, #0x34]
	and	r6, r6, r4
	cmp	r6, #40
	bcc	73b
	@ 600 copies: the source row into the destination rows in turn
	ldr	r8, =0x03200000
	add	r4, r8, r2, lsl #2	@ SPORT address of the first destination row
	add	r8, r8, r1, lsl #2	@ ... of the source row
	sub	r3, r3, #1
	mvn	r1, #0			@ write mask: all bits
	ldr	r0, =600
	mov	r5, #0
74:	ldr	r6, [r8]		@ read transfer of the source row
	str	r1, [r4, r5, lsl #2]	@ write transfer into the next row
	add	r5, r5, #1
	and	r5, r5, r3
	subs	r0, r0, #1
	bne	74b
	@ video DMA off again
	str	r9, [r10, #8]
	@ every word of the destination rows: the source row's
	mov	r2, r2, lsl #11
	add	r2, r2, #0x00200000
	add	r3, r3, #1
	ldr	r4, =0x5A5A0000
75:	mov	r1, #512
76:	add	r6, r4, r1
	ldr	r5, [r2]
	cmp	r5, r6
	ldrne	pc, =ROM_BASE + fail
	add	r2, r2, #4
	subs	r1, r1, #1
	bne	76b
	add	r11, r11, #1
	subs	r3, r3, #1
	bne	75b
	mov	pc, r13

	.ltorg
vid_code_end:

@ ---- test 21, copied to EZ_CODE and run there (position independent, its
@ own literal pool). r11 = checks; a mismatch goes to fail with its address
@ in r2.
@ The picture: line pairs 0-15 of the screen (1280 bytes each: a word is a
@ pixel of each line of the pair), columns 16-143. Values are functions of
@ the word's address and the picture number (EZ_SEED): v0 (the area before
@ the picture), v1 (pass 1's samples), v2 (pass 2's pixels).
@ Pass 1: for line pairs q, q+1 (q even), group g = 0..15 of 8 words at
@ column 16 + 8g goes to line pair q + (g & 1): alternate 8-word groups on
@ alternate line pairs. After group g, the first word of group g - 2 (the
@ same line pair) is read back.
@ Pass 2: for every line pair p and 4-word subgroup at column C = 16 + 4s
@ that holds samples (its 8-word group is p's: (s >> 1) & 1 == p & 1), the
@ 4 words are loaded, then 4 pixels are stored into line pair p + 1 at C
@ and 4 into p at C + 2: the second subgroup of a group has its first two
@ words overwritten before it is loaded. Final content, columns 16-143 of
@ line pair p, group g = (col - 16) / 8, w = (col - 16) & 7: a group of p's
@ samples holds v1 in w < 2 and v2 after; another group v2 in w < 2 (p's
@ own stores), after that v2 (line pair p - 1's stores) or v0 on line pair
@ 0.
@ Screens: A 0x20E800, B 0x234000 (rows 0x41D, 0x468); scratch row 0xB4
@ (0x25A000) for the copies.
	.align 4
ez_code:
	ldr	r3, =EZ_LR
	str	lr, [r3]
	@ The VDL as the OS lays a screen out: entry 0 at 0x2FC000, 16 lines
	@ without video DMA (the lines before the picture), then entry 1 at
	@ 0x2FC100: ENVIDDMA, LDCURR, LDPREV, 240 lines of A shown, B the
	@ previous frame buffer, next entry 0. Entry 1 then ends in the vertical
	@ blanking, where its refetch (and the hint fills of the next frame's
	@ first half-rows) have time; from line 5 it ended on a shown line, and
	@ the two hint fills (current and previous frame buffer, ~6-8 us each)
	@ cannot both end before that line's video transfer request.
	ldr	r10, =0x002FC000
	ldr	r6, =0x00000010
	str	r6, [r10]
	ldr	r6, =0x002FC100
	str	r6, [r10, #12]
	ldr	r10, =0x002FC100
	ldr	r6, =0x002180F0
	str	r6, [r10]
	ldr	r6, =0x0020E800
	str	r6, [r10, #4]
	ldr	r6, =0x00234000
	str	r6, [r10, #8]
	ldr	r6, =0x002FC000
	str	r6, [r10, #12]
	ldr	r10, =0x03300000
	ldr	r6, =0x002FC000
	str	r6, [r10, #0x580]
	ldr	r6, [r10, #8]
	ldr	r3, =EZ_MCTL
	str	r6, [r3]
	orr	r6, r6, #0x6000		@ MCTL CLUTXEN, VSCTXEN
	str	r6, [r10, #8]
	bl	ez_frame
	@ picture 1 into B, not shown
	mov	r4, #1
	ldr	r0, =0x00234000
	bl	ez_picture
	@ B shown, A previous; picture 2 into A
	ldr	r1, =0x00234000
	ldr	r2, =0x0020E800
	bl	ez_show
	mov	r4, #2
	ldr	r0, =0x0020E800
	bl	ez_picture
	@ A shown, B previous; picture 3 into A, the shown screen
	ldr	r1, =0x0020E800
	ldr	r2, =0x00234000
	bl	ez_show
	mov	r4, #3
	ldr	r0, =0x0020E800
	bl	ez_picture
	@ video DMA off again
	ldr	r10, =0x03300000
	ldr	r3, =EZ_MCTL
	ldr	r6, [r3]
	str	r6, [r10, #8]
	ldr	r3, =EZ_LR
	ldr	pc, [r3]

@ the VDL's current (r1) and previous (r2) frame buffers (entry 1), taken at
@ the next frame start
ez_show:
	ldr	r10, =0x002FC100
	str	r1, [r10, #4]
	str	r2, [r10, #8]
@ wait for the next frame start: CLIO's line count (0x03400034, bits 8-0)
@ goes back to the top
ez_frame:
	ldr	r8, =0x03400000
	ldr	r4, =0x1FF
	ldr	r5, [r8, #0x34]
	and	r5, r5, r4
81:	ldr	r6, [r8, #0x34]
	and	r6, r6, r4
	cmp	r6, r5
	mov	r5, r6
	bcs	81b
	mov	pc, lr

@ v0, v1, v2 of the word at r1 -> r3 (r10 used)
ez_v0:
	ldr	r10, =0xA5A5A5A5
	eor	r3, r1, r10
	ldr	r10, =EZ_SEED
	ldr	r10, [r10]
	eor	r3, r3, r10, lsl #24
	mov	pc, lr
ez_v1:
	ldr	r10, =0x9E3779B1
	mul	r3, r1, r10
	ldr	r10, =0x1E221E22
	eor	r3, r3, r10
	ldr	r10, =EZ_SEED
	ldr	r10, [r10]
	eor	r3, r3, r10, lsl #24
	mov	pc, lr
ez_v2:
	ldr	r10, =0x2545F491
	mul	r3, r1, r10
	ldr	r10, =0x7FFF7FFF
	eor	r3, r3, r10
	ldr	r10, =EZ_SEED
	ldr	r10, [r10]
	eor	r3, r3, r10, lsl #24
	mov	pc, lr

@ EZ_TMP = v1 of the 8 words at r2 (r1, r3, r6, r7, r10 used; the return
@ address in EZ_LR2)
ez_vals8:
	ldr	r3, =EZ_LR2
	str	lr, [r3]
	ldr	r6, =EZ_TMP
	mov	r7, #8
	mov	r1, r2
82:	bl	ez_v1
	str	r3, [r6], #4
	add	r1, r1, #4
	subs	r7, r7, #1
	bne	82b
	ldr	r3, =EZ_LR2
	ldr	pc, [r3]

@ EZ_TMP = v2 of the 4 words at r2 (r1, r3, r6, r7, r10 used)
ez_vals4:
	ldr	r3, =EZ_LR2
	str	lr, [r3]
	ldr	r6, =EZ_TMP
	mov	r7, #4
	mov	r1, r2
83:	bl	ez_v2
	str	r3, [r6], #4
	add	r1, r1, #4
	subs	r7, r7, #1
	bne	83b
	ldr	r3, =EZ_LR2
	ldr	pc, [r3]

@ the final content of column r1 (16-143) of line pair r9, word address r2
@ -> r3 (r1, r4, r5, r10 used)
ez_rule:
	ldr	r3, =EZ_LR2
	str	lr, [r3]
	sub	r4, r1, #16
	and	r5, r4, #7		@ w
	mov	r4, r4, lsr #3		@ g
	eor	r4, r4, r9
	mov	r1, r2
	tst	r4, #1
	bne	84f			@ not a group of p's samples
	cmp	r5, #2
	bcc	ez_v1x			@ the samples' first two words
	b	ez_v2x
84:	cmp	r5, #2
	bcc	ez_v2x			@ p's own stores
	cmp	r9, #0
	bne	ez_v2x			@ line pair p - 1's stores
	bl	ez_v0
	b	ez_ret
ez_v1x:
	bl	ez_v1
	b	ez_ret
ez_v2x:
	bl	ez_v2
ez_ret:
	ldr	r10, =EZ_LR2
	ldr	pc, [r10]

@ one picture (number r4) into the screen at r0: pre-fill, pass 1, pass 2,
@ every word read back, two rows copied through the CPU's read transfer and
@ compared. r11 += 5. (~80 ms of 3DO time: ~10k accesses outside the FPGA
@ and four frame waits)
ez_picture:
	mov	r13, lr
	ldr	r3, =EZ_SEED
	str	r4, [r3]
	@ v0 into line pairs 0-16, columns 16-145
	mov	r9, #0
85:	mov	r8, #16
86:	mov	r3, #1280
	mul	r2, r9, r3
	add	r2, r2, r0
	add	r2, r2, r8, lsl #2
	mov	r1, r2
	bl	ez_v0
	str	r3, [r2]
	add	r8, r8, #1
	cmp	r8, #146
	bcc	86b
	add	r9, r9, #1
	cmp	r9, #17
	bcc	85b
	@ pass 1
	mov	r9, #0			@ q
87:	mov	r8, #0			@ g
88:	mov	r3, #1280
	mul	r2, r9, r3
	tst	r8, #1
	addne	r2, r2, #1280
	add	r2, r2, r0
	add	r2, r2, #64
	add	r2, r2, r8, lsl #5
	bl	ez_vals8
	ldr	r3, =EZ_TMP
	ldmia	r3, {r1, r3, r4, r5, r6, r7, r10, r14}
	stmia	r2, {r1, r3, r4, r5, r6, r7, r10, r14}
	cmp	r8, #2
	bcc	89f
	sub	r1, r2, #64		@ the first word of group g - 2, this line pair
	ldr	r6, [r1]
	bl	ez_v1
	cmp	r6, r3
	movne	r2, r1
	ldrne	pc, =ROM_BASE + fail
89:	add	r8, r8, #1
	cmp	r8, #16
	bcc	88b
	add	r9, r9, #2
	cmp	r9, #16
	bcc	87b
	add	r11, r11, #1
	@ pass 2
	mov	r9, #0			@ p
90:	mov	r8, #0			@ s
91:	mov	r4, r8, lsr #1
	eor	r4, r4, r9
	tst	r4, #1
	bne	95f			@ no samples in this subgroup
	mov	r3, #1280
	mul	r2, r9, r3
	add	r2, r2, r0
	add	r2, r2, #64
	add	r2, r2, r8, lsl #4
	ldmia	r2, {r4, r5, r6, r7}
	@ expected: the first two words v2 in a group's second subgroup
	@ (stored over after the first was loaded), v1 otherwise; the last two v1
	mov	r1, r2
	tst	r8, #1
	beq	92f
	bl	ez_v2
	b	93f
92:	bl	ez_v1
93:	cmp	r4, r3
	movne	r2, r1
	ldrne	pc, =ROM_BASE + fail
	add	r1, r1, #4
	tst	r8, #1
	beq	94f
	bl	ez_v2
	b	96f
94:	bl	ez_v1
96:	cmp	r5, r3
	movne	r2, r1
	ldrne	pc, =ROM_BASE + fail
	add	r1, r1, #4
	bl	ez_v1
	cmp	r6, r3
	movne	r2, r1
	ldrne	pc, =ROM_BASE + fail
	add	r1, r1, #4
	bl	ez_v1
	cmp	r7, r3
	movne	r2, r1
	ldrne	pc, =ROM_BASE + fail
	@ the pixels: 4 words into line pair p + 1 at C, 4 into p at C + 2
	add	r2, r2, #1280
	bl	ez_vals4
	ldr	r3, =EZ_TMP
	ldmia	r3, {r4, r5, r6, r7}
	stmia	r2, {r4, r5, r6, r7}
	sub	r2, r2, #1280
	add	r2, r2, #8
	bl	ez_vals4
	ldr	r3, =EZ_TMP
	ldmia	r3, {r4, r5, r6, r7}
	stmia	r2, {r4, r5, r6, r7}
95:	add	r8, r8, #1
	cmp	r8, #32
	bcc	91b
	add	r9, r9, #1
	cmp	r9, #16
	bcc	90b
	add	r11, r11, #1
	@ every word of the picture read back
	mov	r9, #0
97:	mov	r8, #16
98:	mov	r3, #1280
	mul	r2, r9, r3
	add	r2, r2, r0
	add	r2, r2, r8, lsl #2
	ldr	r6, [r2]
	mov	r1, r8
	bl	ez_rule
	cmp	r6, r3
	bne	ez_fail
	add	r8, r8, #1
	cmp	r8, #144
	bcc	98b
	add	r9, r9, #1
	cmp	r9, #16
	bcc	97b
	add	r11, r11, #1
	@ rows 0 (line pairs 0 and 1) and 5 (8 and 9) of the screen copied
	@ through the CPU's read transfer into the scratch row, then compared
	mov	r8, #0
99:	sub	r4, r0, #0x00200000
	mov	r4, r4, lsr #9
	add	r4, r4, #0x03200000
	add	r4, r4, r8, lsl #2
	ldr	r6, [r4]		@ read transfer of the row
	ldr	r4, =0x03200000 + 4 * 0xB4
	mvn	r6, #0
	str	r6, [r4]		@ write transfer into the scratch row, all bits
	cmp	r8, #0
	moveq	r9, #0			@ the row's first line pair, kept in
	movne	r9, #8			@ EZ_TMP + 8 (the helpers use r14)
	ldr	r4, =EZ_TMP
	str	r9, [r4, #8]
	mov	r6, #0			@ word of the row
100:	mov	r1, r6
	ldr	r9, =EZ_TMP
	ldr	r9, [r9, #8]
	cmp	r1, #320
	subcs	r1, r1, #320
	addcs	r9, r9, #1
	cmp	r1, #16
	bcc	101f
	cmp	r1, #144
	bcs	101f
	ldr	r2, =0x0025A000
	add	r2, r2, r6, lsl #2
	ldr	r7, [r2]
	mov	r3, #1280		@ the word's address in the screen (the rule's)
	mul	r2, r9, r3
	add	r2, r2, r0
	add	r2, r2, r1, lsl #2
	bl	ez_rule
	cmp	r7, r3
	movne	r6, r7
	bne	ez_fail
101:	add	r6, r6, #1
	cmp	r6, #512
	bcc	100b
	add	r11, r11, #1
	cmp	r8, #0
	moveq	r8, #5
	beq	99b
	mov	pc, r13

@ the value found (r6) and the one expected (r3) into EZ_TMP for the
@ result record, then fail with the address in r2
ez_fail:
	ldr	r1, =EZ_TMP
	str	r6, [r1]
	str	r3, [r1, #4]
	ldr	pc, =ROM_BASE + fail

	.ltorg
ez_code_end:
