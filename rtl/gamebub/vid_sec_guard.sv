// Video transfer guard for the SDRAM secondary port.
//
// Every secondary-port transfer pauses the 3DO (its DRAM shares the SDRAM
// bus), while the scanout goes on. A 512-word transfer (a video cache
// half-row fill, a CD or host block) takes 5.6 us, more than the 4.4 us
// between a line's video transfer request and the start of its scanout, so
// one that begins just before the request leaves the line with the serial
// register's old contents. Short transfers back to back do the same (each
// pause ends before MADAM has run long enough to make its transfers).
// MADAM_SPORT's VID_GUARD is high from 5.7 us before the request until the
// line's transfers are on the bus; while it is, hold tells sec_arb to start
// no transfer.
//
// Not while the 3DO is already stopped for something else (stall: a VRAM
// access waiting in ddram.sv or the cache, which may need the transfer
// held back; the 3DO's own random VRAM reads and writes keep ddram.sv busy
// until they are done, so they are never held) or in reset, and at most
// MAX_CYCLES clk_mem cycles at a time, so no request can wait on the guard
// indefinitely. What waits: video cache fills and prefetches, copy and
// flash bursts, CD and host transfers, at most about 10 us per line.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module vid_sec_guard #(parameter int MAX_CYCLES = 1500) (
	input      clk_sys,
	input      vid_guard,    // MADAM_SPORT VID_GUARD (clk_sys)
	input      reset_3do,    // (clk_sys)
	input      stall,        // the 3DO is paused for a reason other than the secondary port (clk_sys)

	input      clk_mem,
	input      rst_mem,
	output reg hold          // to sec_arb (clk_mem)
);
	reg        defer;
	always @(posedge clk_sys) defer <= vid_guard && !reset_3do && !stall;

	reg [10:0] cnt;
	always @(posedge clk_mem) begin
		if (rst_mem || !defer) cnt <= '0;
		else if (cnt != 11'(MAX_CYCLES)) cnt <= cnt + 1'd1;
		hold <= !rst_mem && defer && cnt != 11'(MAX_CYCLES);
	end
endmodule
