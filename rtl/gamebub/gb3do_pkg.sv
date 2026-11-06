// Shared definitions for the Game Bub 3DO core.
//
// SDRAM map (32 MiB, 4 banks x 8 MiB, 8192 rows x 512 x 16-bit words):
//   bank 0 rows    0..1023 : 3DO DRAM, left half  (TDM part of sdram_3do)
//   bank 1 rows    0..1023 : 3DO DRAM, right half (TDM part of sdram_3do)
//   bank 2                 : MiSTer "DDR3" image, 64-bit beat address [19:0]
//                            0x000000-0x0FFFFF VRAM overflow
//                            0x400000-0x4FFFFF BIOS ROM
//                            0x500000-0x5FFFFF Kanji ROM
//                            0x600000-0x607FFF NVRAM (32 KiB)
//   bank 3 rows 0..8191, then bank 0 rows 1024..8191, then bank 1 rows
//   1024..8191            : CD image (2048-byte sectors, ISO), up to 22 MiB
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

package gb3do_pkg;

	// Byte offsets inside the bank-2 "DDR" image (as seen by ddram.sv)
	localparam bit [22:0] DDR_BIOS_BASE  = 23'h400000;
	localparam bit [22:0] DDR_KANJI_BASE = 23'h500000;
	localparam bit [22:0] DDR_NVRAM_BASE = 23'h600000;

	localparam int ISO_MAX_ROWS    = 8192 + 7168 + 7168;      // 1 KiB rows
	localparam int ISO_MAX_BYTES   = ISO_MAX_ROWS * 1024;     // 23,068,672
	localparam int ISO_MAX_SECTORS = ISO_MAX_ROWS / 2;        // 11,264

	// SDRAM word address {bank, row, col} of a bank-2 DDR byte offset.
	function automatic [23:0] ddr_word_addr(input [22:0] byte_off);
		ddr_word_addr = {2'd2, byte_off[22:1]};
	endfunction

	// SDRAM word address of ISO word index w (byte offset / 2).
	function automatic [23:0] iso_word_addr(input [23:0] w);
		bit [14:0] r;
		bit [ 8:0] c;
		r = w[23:9];
		c = w[8:0];
		if (r < 15'd8192)
			iso_word_addr = {2'd3, r[12:0], c};
		else if (r < 15'd15360)
			iso_word_addr = {2'd0, 13'(r - 15'd8192 + 15'd1024), c};
		else
			iso_word_addr = {2'd1, 13'(r - 15'd15360 + 15'd1024), c};
	endfunction

endpackage
