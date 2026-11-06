// Testbench: madam_div (sequential replacement for Altera LPM_DIVIDE,
// 64/32 signed, LPM_REMAINDERPOSITIVE=TRUE) against a reference model:
//   numer = quotient * denom + remain,  0 <= remain < |denom|
// Random operands plus edge cases (signs, +-1, min values, exact divisions).
// Division by zero is reported only (LPM leaves it undefined).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_div;
	reg clk = 0;
	always #10 clk = ~clk;

	reg         start = 0;
	reg  [31:0] denom;
	reg  [63:0] numer;
	wire [63:0] quotient;
	wire [31:0] remain;
	wire        busy;

	madam_div dut (.CLK(clk), .START(start), .denom(denom), .numer(numer),
	               .quotient(quotient), .remain(remain), .BUSY(busy));

	int errors = 0, checks = 0;

	// Reference: floor-style division with non-negative remainder
	task automatic ref_div(input [63:0] n, input [31:0] d, output [63:0] q, output [31:0] r);
		longint sn, sd, qt, rt;
		sn = $signed(n);
		sd = $signed({{32{d[31]}}, d});
		qt = sn / sd;          // truncating
		rt = sn % sd;          // sign of numerator
		if (rt < 0) begin
			if (sd > 0) begin qt = qt - 1; rt = rt + sd; end
			else        begin qt = qt + 1; rt = rt - sd; end
		end
		q = qt;
		r = rt[31:0];
	endtask

	task automatic run(input [63:0] n, input [31:0] d);
		bit [63:0] qe;
		bit [31:0] re;
		@(posedge clk);
		numer <= n; denom <= d; start <= 1;
		@(posedge clk);
		start <= 0;
		@(posedge clk);
		while (busy) @(posedge clk);
		checks++;
		if (d == 0) return;
		// -2^63 / -1 overflows in the reference (C semantics); skip
		if (n == 64'h8000_0000_0000_0000 && d == 32'hFFFF_FFFF) return;
		ref_div(n, d, qe, re);
		if (quotient !== qe || remain !== re) begin
			errors++;
			if (errors < 20)
				$display("ERROR: %0d / %0d: got q=%0d r=%0d expected q=%0d r=%0d",
				         $signed(n), $signed(d), $signed(quotient), remain, $signed(qe), re);
		end
	endtask

	initial begin
		bit [63:0] edge_n [] = '{64'd0, 64'd1, -64'd1, 64'd7, -64'd7, 64'h7FFF_FFFF_FFFF_FFFF,
		                          64'h8000_0000_0000_0000, 64'h0000_0001_0000_0000, -64'h0000_0001_0000_0000,
		                          64'h0000_7FFF_FFFF_0000, 64'd100, -64'd100};
		bit [31:0] edge_d [] = '{32'd1, -32'd1, 32'd2, -32'd2, 32'd3, -32'd3, 32'd7, -32'd7,
		                          32'h7FFF_FFFF, 32'h8000_0000, 32'h0001_0000, -32'h0001_0000, 32'd100};
		foreach (edge_n[i]) foreach (edge_d[j]) run(edge_n[i], edge_d[j]);
		// exact multiples
		for (int i = 0; i < 200; i++) begin
			bit [31:0] d;
			bit [31:0] q;
			d = $urandom(); if (d == 0) d = 1;
			q = $urandom();
			run($signed(d) * $signed({{32{q[31]}}, q}), d);
		end
		// random, including the 3DO use (16.16 fixed point, numerator scaled)
		for (int i = 0; i < 20000; i++) begin
			bit [63:0] n;
			bit [31:0] d;
			n = {$urandom(), $urandom()};
			d = $urandom();
			case (i % 4)
				0: ;
				1: n = {{16{n[47]}}, n[47:0]};
				2: d = {{16{d[15]}}, d[15:0]};
				3: begin n = {{32{n[31]}}, n[31:0]}; d = {{24{d[7]}}, d[7:0]}; end
			endcase
			if (d == 0) d = 32'd5;
			run(n, d);
		end
		$display("tb_div: %0d divisions, %0d errors", checks, errors);
		if (errors == 0) $display("tb_div: PASS");
		else             $display("tb_div: FAIL");
		$finish;
	end
endmodule
