// Checker for MADAM_CPUIF's START, which takes the CPU's SEQ from a register
// (SEQ_MID, loaded at CE_F) instead of the CPU's decode (bound into
// p3do_gamebub by the testbenches that list this file in their .deps).
//
// START drives MADAM's DRAM RAS and code lines, which the SDRAM controller
// and ddram.sv sample on clk_mem. In the middle of every clk_mem cycle (both
// halves of each clk_sys cycle) this compares it with the original
// expression, (STRETCH | BREAK | (ICYCLE && SEQ)) & PHASE2, using SEQ itself.
// START reaches MADAM_AG's RAS and code lines only in their CPU_GRANT
// branches, when no SE, external-port or player grant takes precedence:
// those cycles must match. The others are counted (the arbiter can hold
// PHASE2 high for a DMA's pre-init after the CPU's last cycle, when the CPU's
// registers have moved on and SEQ_MID still has the earlier SEQ).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module cpu_start_check (
	input clk_mem,
	input reset,        // the 3DO is in reset
	input start,        // MADAM_CPUIF START
	input stretch, brk, icycle, seq, phase2,
	input cpu_grant,
	input other_grant   // SE, external port or player grant (MADAM_AG takes those first)
);
	longint n_cmp = 0, n_start = 0, n_seq_used = 0, n_off_bus = 0, errors = 0;
	always @(negedge clk_mem) if (!reset) begin
		bit exp, used;
		exp = (stretch | brk | (icycle & seq)) & phase2;
		used = cpu_grant && !other_grant;
		if (used) n_cmp++;
		if (start && used) n_start++;
		if (used && icycle && phase2 && !stretch && !brk) n_seq_used++;
		if (!used && start !== exp) n_off_bus++;
		if (used && start !== exp) begin
			errors++;
			if (errors <= 20)
				$display("[%0t] CPU START CHECK: START %b, with the CPU's SEQ %b (STRETCH %b BREAK %b ICYCLE %b SEQ %b PHASE2 %b CPU_GRANT %b)",
				         $realtime, start, exp, stretch, brk, icycle, seq, phase2, cpu_grant);
		end
	end
	final begin
		$display("cpu_start_check: %0d half-cycles with the CPU on the bus compared (START high %0d, decided by SEQ %0d), %0d errors; %0d differing half-cycles off the bus",
		         n_cmp, n_start, n_seq_used, errors, n_off_bus);
		if (errors != 0) $fatal(1, "cpu_start_check: FAIL");
	end
endmodule

bind p3do_gamebub cpu_start_check cpu_start_chk (
	.clk_mem(clk_mem), .reset(reset_3do),
	.start(p3do.madam.CPUIF.START),
	.stretch(p3do.madam.CPUIF.STRETCH), .brk(p3do.madam.CPUIF.BREAK), .icycle(p3do.madam.CPUIF.ICYCLE),
	.seq(p3do.madam.CPUIF.SEQ), .phase2(p3do.madam.CPUIF.PHASE2),
	.cpu_grant(p3do.madam.AG.CPU_GRANT),
	.other_grant(p3do.madam.AG.SE_GRANT || p3do.madam.AG.EXTP_GRANT || p3do.madam.AG.PLAYER_GRANT)
);
