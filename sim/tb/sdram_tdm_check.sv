// Checker for sdram_3do.sv's split TDM command registers (bound into
// p3do_gamebub by the testbenches that list this file in their .deps).
//
// sdram_3do decides the 3DO DRAM command for slots 1, 3, 5 and 7 into
// tdm_slow and lpage_row, which p3do.xdc times as two clk_mem cycles from
// clk_sys, and everything else into tdm_fast. This checks, every clk_mem
// cycle:
//   * the command (tdm_s0) and lpage_row equal what the original single
//     register decided (MiSTer's rules, in its order of precedence), from
//     the same inputs and page state;
//   * tdm_slow and lpage_row load only at clk_mem edges that are also
//     clk_sys rising edges, so their clk_sys inputs had 20 ns (the premise
//     of the multicycle constraint).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module sdram_tdm_check (
	input        clk_sys,
	input        clk,
	input        init_done,
	input        sec_active,
	input [3:0]  slot,
	input        slot_odd,
	input        lpage_opened, rpage_opened, r_pre_slot3,
	input [3:0]  act_cnt0, act_cnt1,
	input [22:2] laddr, raddr,
	input [1:0]  lwe, rwe,
	input        lras, rras,
	input [3:0]  lcode, rcode,
	input [31:0] din,
	input [46:0] tdm_s0_q,         // {CMD, BANK, ROW, COL, DATA, RD, WE, BE, RFS} of sdram_3do's state_t
	input [12:0] lpage_row
);
	// MiSTer's TDM rules as one decision (sdram_3do.sv before the split)
	typedef struct packed {
		bit [ 1:0] cmd;
		bit [ 1:0] bank;
		bit [12:0] row;
		bit [ 8:0] col;
		bit [15:0] data;
		bit        rd, we;
		bit [ 1:0] be;
		bit        rfs;
	} c_t;
	localparam bit [1:0] RAS = 2'd1, CAS = 2'd2, PRE = 2'd3;

	function automatic c_t decide();
		c_t t;
		bit parked;
		t = '0;
		parked = slot == 4'd8;
		if (lras && lcode == 4'h8 && slot == 4'd5) begin t.cmd = RAS; t.row = laddr[22:11]; t.bank = 0; end
		if (rras && rcode == 4'h8 && slot == 4'd6) begin t.cmd = RAS; t.row = raddr[22:11]; t.bank = 1; end
		if (lras && lcode == 4'h1 && slot == 4'd0 && lpage_opened) begin t.cmd = CAS; t.col = laddr[10:2]; t.rd = 1; t.bank = 0; end
		if (rras && rcode == 4'h1 && slot == 4'd1 && rpage_opened) begin t.cmd = CAS; t.col = raddr[10:2]; t.rd = 1; t.bank = 1; end
		if (lras && lcode == 4'h2 && (slot == 4'd2 || slot == 4'd6) && lpage_opened) begin
			t.cmd = CAS; t.col = laddr[10:2]; t.we = 1; t.be = lwe; t.data = din[31:16]; t.bank = 0; end
		if (rras && rcode == 4'h2 && (slot == 4'd3 || slot == 4'd7) && rpage_opened) begin
			t.cmd = CAS; t.col = raddr[10:2]; t.we = 1; t.be = rwe; t.data = din[15:0]; t.bank = 1; end
		if (lras && (lcode == 4'h4 || lcode == 4'hC) && slot == 4'd4 && !r_pre_slot3) begin t.cmd = RAS; t.bank = 0; t.rfs = 1; end
		else if (!lras && !rras && lcode == 4'h2 && slot == 4'd4 && !r_pre_slot3) begin t.cmd = RAS; t.bank = 0; t.rfs = 1; end
		if (!lras && lpage_opened && (((slot == 4'd0 || parked) && act_cnt0 >= 4'd3) || slot == 4'd2)) begin t.cmd = PRE; t.bank = 0; end
		if (!rras && rpage_opened && (((slot == 4'd1 || (parked && !(!lras && lpage_opened))) && act_cnt1 >= 4'd3) || slot == 4'd3)) begin t.cmd = PRE; t.bank = 1; end
		return t;
	endfunction

	bit        exp_v = 0, row_v = 0, slow_d = 0;
	c_t        exp_c;
	bit [12:0] exp_row;
	longint    n_cmp = 0, n_cmd = 0, n_slow = 0, errors = 0;
	always @(posedge clk) begin
		c_t got;
		got = tdm_s0_q;
		if (exp_v) begin
			n_cmp++;
			if (got != exp_c) begin
				errors++;
				if (errors <= 20)
					$display("[%0t] SDRAM TDM CHECK: command %h, MiSTer's decision %h", $realtime, got, exp_c);
			end
		end
		if (row_v && lpage_row != exp_row) begin
			errors++;
			if (errors <= 20) $display("[%0t] SDRAM TDM CHECK: lpage_row %03h, expected %03h", $realtime, lpage_row, exp_row);
		end
		exp_v = init_done && !sec_active;
		row_v = 0;
		if (exp_v) begin
			exp_c = decide();
			if (exp_c.cmd != 0) n_cmd++;
			if (lras && lcode == 4'h8 && slot == 4'd5) begin row_v = 1; exp_row = laddr[22:11]; end
		end
		if (slot_odd) n_slow++;
		slow_d <= slot_odd;
	end
	// A clk_mem edge at which tdm_slow loads must be a clk_sys rising edge:
	// half a clk_mem cycle later, clk_sys is high (in the first half of its
	// high phase), while after the other clk_mem edges it is low.
	always @(negedge clk) if (slow_d && !clk_sys) begin
		errors++;
		if (errors <= 20) $display("[%0t] SDRAM TDM CHECK: tdm_slow loaded at a clk_mem edge that is not a clk_sys edge", $realtime);
	end
	final begin
		$display("sdram_tdm_check: %0d commands compared (%0d TDM commands, %0d slow-register loads), %0d errors",
		         n_cmp, n_cmd, n_slow, errors);
		if (errors != 0) $fatal(1, "sdram_tdm_check: FAIL");
	end
endmodule

bind p3do_gamebub sdram_tdm_check sdram_tdm_chk (
	.clk_sys(clk_sys), .clk(sdram.clk), .init_done(sdram.init_done), .sec_active(sdram.sec_active),
	.slot(sdram.slot), .slot_odd(sdram.slot_odd),
	.lpage_opened(sdram.lpage_opened), .rpage_opened(sdram.rpage_opened), .r_pre_slot3(sdram.r_pre_slot3),
	.act_cnt0(sdram.act_cnt[0]), .act_cnt1(sdram.act_cnt[1]),
	.laddr(sdram.laddr), .raddr(sdram.raddr), .lwe(sdram.lwe), .rwe(sdram.rwe),
	.lras(sdram.lras), .rras(sdram.rras), .lcode(sdram.lcode), .rcode(sdram.rcode), .din(sdram.din),
	.tdm_s0_q({sdram.tdm_s0.CMD, sdram.tdm_s0.BANK, sdram.tdm_s0.ROW, sdram.tdm_s0.COL, sdram.tdm_s0.DATA,
	           sdram.tdm_s0.RD, sdram.tdm_s0.WE, sdram.tdm_s0.BE, sdram.tdm_s0.RFS}),
	.lpage_row(sdram.lpage_row)
);
