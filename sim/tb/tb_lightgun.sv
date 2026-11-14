// Testbench: the 3DO light gun and mouse on the control port (HPS2PAD and
// host_mouse, Game Bub core).
//
// The real HPS2PAD, driven as MADAM_PLAYER drives the control port: PBCLK
// high and low long enough to latch, then one clock per bit; the data the
// pad side puts on PBDIN after each falling edge is collected. With LG_EN the
// stream is the first pad's 16 bits, then the light gun's 40 bits
// (Portfolio LightGunRom.c / Opera opera_pbus.c):
//   0x4D | trigger 0 0 0 option 0 0 count[19] | count[18:11] | count[10:3] |
//   count[2:0] hits[4:0]
// with count = ceil((y * YSCANTIME + x * XSCANTIME * 10 / WIDTH) / 10) - TIMEOFFSET
// for the pixel (x, y) aimed at (NTSC 1030 / 12707 / -12835 / 320 x 240, PAL
// 1051 / 12796 / -58995 / 388 x 288), hits 0x1F; off screen: count 0, hits 0,
// trigger set. After them the bus reads 1s (no more devices).
// For every aim (corners, edges, a grid, random) and both standards the
// count must match, and Portfolio's lightgun.c decoding of it must give the
// pixel back (within one pixel: the integer divisions).
// Then the mouse (ID 0x49, 32 bits after the pad): host_mouse turns the Game
// Bub's motion packets ({dy, dx} signed, down / right positive) and buttons
// into HPS2PAD's PS/2 packets; HPS2PAD moves one count per unit, at most 511
// counts per read (the 10-bit field's range; MiSTer took 96), and keeps the
// rest, up to 1023, for the next reads: a packet (+5, -3) with the left
// button reads dx +5, dy -3; (+300, 0) is clamped to +255 and read whole;
// four packets of +255 and -255 in one field (a fast mouse) read 511 and
// -511, then 509 and -509; six (1530) are kept as -1024 / +1023: -511,
// -511, -2 and 511, 511, 1; two
// packets add; a button written alone (no packet) is read, also one held
// from before the mouse was switched on; dy -32768 is clamped up (-255
// reads), not wrapped down; with the mouse off the pad is followed by 1s.
// Then the Game Bub chain (GB_CHAIN, CHAIN): the control port as a daisy
// chain of up to 7 devices in any order, as on the console. Each transfer
// must read exactly the chain's devices in its order, each with its own data
// (pads 16 bits, mice 32, the light gun 40), then 1s: a pad alone; the light
// gun then a pad; two mice then four pads (each pad with its own button);
// four pads then two mice; mice with motion (each its own packets, the
// second's 511-count reads); a chain changed after the latch is taken at the
// next transfer, not in the middle of one; no device at all reads 1s.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
module tb_lightgun;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;
	reg pbclk = 0;
	wire pbdin;
	reg  [12:0] joy = '0;
	reg  lg_en = 1, lg_pal = 0, trig = 0, opt = 0, off = 0;
	reg  [15:0] ax = 0, ay = 0;
	reg  mouse_en = 0, mouse2_en = 0, m_pkt = 0, m2_pkt = 0, gb_chain = 0;
	reg  [27:0] chain = '0;
	reg  [12:0] joy1 = '0, joy2 = '0, joy3 = '0;
	reg  [15:0] m_dx = 0, m_dy = 0;
	reg  [ 2:0] m_btn = 0;
	wire [24:0] ps2;
	host_mouse hm (.clk(clk), .rst(rst), .pkt(m_pkt), .dx(m_dx), .dy(m_dy), .buttons(m_btn), .ps2_mouse(ps2));
	reg  [15:0] m2_dx = 0, m2_dy = 0;
	reg  [ 2:0] m2_btn = 0;
	wire [24:0] ps2b;
	host_mouse hm2 (.clk(clk), .rst(rst), .pkt(m2_pkt), .dx(m2_dx), .dy(m2_dy), .buttons(m2_btn), .ps2_mouse(ps2b));

	HPS2PAD dut (
		.CLK(clk), .RST(rst), .CE(1'b1),
		.PBDIN(pbdin), .PBDOUT(1'b1), .PBCLK(pbclk), .EXPBDIN(1'b1), .EXPBDOUT(),
		.PAD_SEL(3'd1), .ARCADE_SEL(2'd0), .STICK_EN(1'b0), .MOUSE_EN(mouse_en), .MOUSE2_EN(mouse2_en), .GB_CHAIN(gb_chain), .CHAIN(chain), .ARCADE_SERVICE(1'b0),
		.joystick_0(joy), .joystick_1(joy1), .joystick_2(joy2), .joystick_3(joy3),
		.joy0_x0('0), .joy0_y0('0), .joy0_x1('0), .joy0_y1('0),
		.joy1_x0('0), .joy1_y0('0), .joy1_x1('0), .joy1_y1('0), .ps2_mouse(ps2), .ps2_mouse2(ps2b),
		.LG_EN(lg_en), .LG_PAL(lg_pal), .lg_x(ax), .lg_y(ay),
		.lg_trigger(trig), .lg_option(opt), .lg_offscreen(off)
	);

	int errors = 0, checks = 0;
	task automatic fail(input string m);
		errors++;
		if (errors <= 20) $display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	// one control port transfer of n bits, as MADAM_PLAYER makes it
	task automatic pbus_read(input int n, output bit [255:0] q);
		pbclk = 1; repeat (9000) @(posedge clk);
		pbclk = 0; repeat (9000) @(posedge clk);
		q = '0;
		for (int i = 0; i < n; i++) begin
			pbclk = 1; repeat (100) @(posedge clk);
			pbclk = 0; repeat (100) @(posedge clk);
			q = {q[254:0], pbdin};
		end
		pbclk = 0; repeat (20000) @(posedge clk);   // the pad side goes idle
	endtask

	// the expected count (Opera's formula with the division by 10 rounded up,
	// so that the driver's decoding gives the pixel back; plain integers)
	function automatic int exp_count(input int px, input int py, input bit pal);
		int xs, ys, toff, w, c;
		xs = pal ? 1051 : 1030; ys = pal ? 12796 : 12707; toff = pal ? -58995 : -12835; w = pal ? 388 : 320;
		c = (py * ys + (px * xs * 10) / w + 9) / 10;
		return (c - toff) & 32'hFFFFF;
	endfunction

	task automatic check(input bit [15:0] x, input bit [15:0] y, input bit pal, input bit t, input bit o, input bit offs);
		bit [255:0] q;
		bit [15:0] pad;
		bit [39:0] g;
		bit [7:0] rest;
		int px, py, w, h, ec, c, dx, dy;
		ax = x; ay = y; lg_pal = pal; trig = t; opt = o; off = offs;
		repeat (200) @(posedge clk);                // a whole count computation
		pbus_read(16 + 40 + 8, q);
		pad = q[63:48]; g = q[47:8]; rest = q[7:0];
		w = pal ? 388 : 320; h = pal ? 288 : 240;
		px = (int'(x) * w) >> 16; py = (int'(y) * h) >> 16;
		ec = offs ? 0 : exp_count(px, py, pal);
		checks++;
		if (pad !== 16'h8000) fail($sformatf("pad word %04h, expected 8000", pad));
		if (rest !== 8'hFF) fail($sformatf("after the gun %02h, expected FF (no more devices)", rest));
		if (g[39:32] !== 8'h4D) fail($sformatf("gun ID %02h, expected 4D", g[39:32]));
		if (g[31] !== (t | offs) || g[27] !== o || g[30:28] !== 3'b000 || g[26:25] !== 2'b00)
			fail($sformatf("gun buttons %02h (trigger %b option %b off-screen %b)", g[31:24], t, o, offs));
		c = {g[24], g[23:16], g[15:8], g[7:5]};
		if (c !== ec) fail($sformatf("%s aim %04h,%04h (pixel %0d,%0d): count %05h, expected %05h",
		                             pal ? "PAL" : "NTSC", x, y, px, py, c, ec));
		if (g[4:0] !== (offs ? 5'd0 : 5'h1F)) fail($sformatf("hit count %0d", g[4:0]));
		// Portfolio's decoding (lightgun.c, with the same standard's constants)
		if (!offs) begin
			int cp, rx, ry, xs, ys, toff;
			xs = pal ? 1051 : 1030; ys = pal ? 12796 : 12707; toff = pal ? -58995 : -12835;
			cp = c + toff;
			ry = (10 * cp) / ys;
			rx = (((10 * cp) % ys) * w) / (xs * 10);
			dx = rx - px; dy = ry - py;
			if (dx < -1 || dx > 1 || dy != 0)
				fail($sformatf("%s pixel %0d,%0d: the driver decodes the count as %0d,%0d", pal ? "PAL" : "NTSC", px, py, rx, ry));
		end
	endtask

	task automatic mouse_packet(input [15:0] dx, input [15:0] dy, input [2:0] btn);
		@(posedge clk); m_dx <= dx; m_dy <= dy; m_btn <= btn; m_pkt <= 1;
		@(posedge clk); m_pkt <= 0;
		repeat (10) @(posedge clk);
	endtask
	task automatic mouse_check(input [9:0] ex, input [9:0] ey, input [2:0] btn, input string what);
		bit [255:0] q;
		bit [31:0] m;
		pbus_read(16 + 32 + 8, q);
		m = q[39:8];
		checks++;
		if (q[55:40] !== 16'h8000) fail($sformatf("%s: pad word %04h", what, q[55:40]));
		if (m[31:24] !== 8'h49) fail($sformatf("%s: mouse ID %02h", what, m[31:24]));
		if (m[23] !== btn[0] || m[22] !== btn[2] || m[21] !== btn[1] || m[20] !== 1'b0)
			fail($sformatf("%s: buttons L%b M%b R%b, expected L%b M%b R%b", what, m[23], m[22], m[21], btn[0], btn[2], btn[1]));
		if (m[19:10] !== ey || m[9:0] !== ex)
			fail($sformatf("%s: dy %0d dx %0d, expected %0d %0d", what, $signed(m[19:10]), $signed(m[9:0]), $signed(ey), $signed(ex)));
		if (q[7:0] !== 8'hFF) fail($sformatf("%s: after the mouse %02h", what, q[7:0]));
	endtask
	task automatic mouse2_packet(input [15:0] dx, input [15:0] dy, input [2:0] btn);
		@(posedge clk); m2_dx <= dx; m2_dy <= dy; m2_btn <= btn; m2_pkt <= 1;
		@(posedge clk); m2_pkt <= 0;
		repeat (10) @(posedge clk);
	endtask
	// one mouse word: ID, buttons {left, middle, right} as btn {middle, right, left}, dy, dx
	task automatic mouse_word(input [31:0] m, input [9:0] ex, input [9:0] ey, input [2:0] btn, input string what);
		if (m[31:24] !== 8'h49) fail($sformatf("%s: ID %02h, expected the mouse 49", what, m[31:24]));
		if (m[23] !== btn[0] || m[22] !== btn[2] || m[21] !== btn[1] || m[20] !== 1'b0)
			fail($sformatf("%s: buttons L%b M%b R%b, expected L%b M%b R%b", what, m[23], m[22], m[21], btn[0], btn[2], btn[1]));
		if (m[19:10] !== ey || m[9:0] !== ex)
			fail($sformatf("%s: dy %0d dx %0d, expected %0d %0d", what, $signed(m[19:10]), $signed(m[9:0]), $signed(ey), $signed(ex)));
	endtask
	// the chain: device codes (slot 0 first) and the words expected for
	// them; reads the whole transfer and compares it bit for bit, then 1s
	function automatic [27:0] chain_of(input int n, input int d0, d1 = 0, d2 = 0, d3 = 0, d4 = 0, d5 = 0, d6 = 0);
		int d [7] = '{d0, d1, d2, d3, d4, d5, d6};
		chain_of = '0;
		for (int i = 0; i < n; i++) chain_of[i*4 +: 4] = 4'(8 | d[i]);
	endfunction
	task automatic chain_check(input [27:0] ch, input bit [39:0] exp_word [7], input string what);
		bit [255:0] q;
		int n, len, pos;
		bit [255:0] e;
		n = 0;
		for (int i = 0; i < 7; i++) if (ch[i*4+3]) n = i + 1;
		len = 0;
		for (int i = 0; i < n; i++) len += ch[i*4 +: 3] < 4 ? 16 : ch[i*4 +: 3] < 6 ? 32 : 40;
		pbus_read(len + 16, q);
		checks++;
		e = '1;
		pos = len + 16;
		for (int i = 0; i < n; i++) begin
			int l = ch[i*4 +: 3] < 4 ? 16 : ch[i*4 +: 3] < 6 ? 32 : 40;
			for (int k = 0; k < l; k++) e[pos - 1 - k] = exp_word[i][39 - k];
			pos -= l;
		end
		for (int b = 0; b < len + 16; b++)
			if (q[b] !== e[b]) begin
				fail($sformatf("%s: bit %0d of %0d read %b, expected %b (got %h, expected %h)", what,
				               len + 16 - 1 - b, len + 16, q[b], e[b], q[len + 15 -: 128], e[len + 15 -: 128]));
				break;
			end
	endtask
	// a pad's word (left-aligned in 40 bits), a mouse's, the light gun's
	function automatic [39:0] w16(input [15:0] v); w16 = {v, 24'h0}; endfunction
	function automatic [39:0] w32(input [31:0] v); w32 = {v, 8'h0}; endfunction
	function automatic [31:0] mword(input [2:0] btn, input [9:0] dy, input [9:0] dx);
		// btn {middle, right, left}: the word's buttons are left, middle, right
		mword = {8'h49, btn[0], btn[2], btn[1], 1'b0, dy, dx};
	endfunction

	initial begin
		bit [15:0] edges [6] = '{16'h0000, 16'h0001, 16'h00CC, 16'h8000, 16'hFF00, 16'hFFFF};
		repeat (10) @(posedge clk); rst = 0;
		for (int pal = 0; pal < 2; pal++) begin
			foreach (edges[i]) foreach (edges[j]) check(edges[i], edges[j], 1'(pal), 0, 0, 0);
			for (int gx = 0; gx < 16; gx++) for (int gy = 0; gy < 12; gy++)
				check(16'(gx * 4369), 16'(gy * 5957), 1'(pal), 0, 0, 0);
			repeat (40) check(16'($urandom()), 16'($urandom()), 1'(pal), 0, 0, 0);
		end
		check(16'h4000, 16'h4000, 0, 1, 0, 0);   // trigger
		check(16'h4000, 16'h4000, 0, 0, 1, 0);   // option
		check(16'h4000, 16'h4000, 0, 1, 1, 0);
		check(16'h4000, 16'h4000, 0, 0, 0, 1);   // off screen: reload
		check(16'h4000, 16'h4000, 1, 0, 1, 1);
		// the mouse
		lg_en = 0; mouse_en = 1;
		repeat (20) @(posedge clk);
		mouse_packet(16'd5, -16'd3, 3'b001);
		mouse_check(10'd5, -10'd3, 3'b001, "a packet (+5, -3), left button");
		mouse_check(10'd0, 10'd0, 3'b001, "nothing more");
		mouse_packet(16'd300, 16'd0, 3'b000);               // clamped to +255 counts
		mouse_check(10'd255, 10'd0, 3'b000, "+300 clamped to 255, read whole");
		mouse_check(10'd0, 10'd0, 3'b000, "+300 clamped, after");
		// a fast mouse: four packets in one field, 1020 counts each way
		repeat (4) mouse_packet(16'd255, -16'd255, 3'b000);
		mouse_check(10'd511, -10'd511, 3'b000, "4 x (+255, -255): 1st read, the field's range");
		mouse_check(10'd509, -10'd509, 3'b000, "4 x (+255, -255): the rest");
		mouse_check(10'd0, 10'd0, 3'b000, "4 x (+255, -255): after");
		// six packets, 1530 counts: kept as -1024 / +1023
		repeat (6) mouse_packet(-16'd255, 16'd255, 3'b000);
		mouse_check(-10'd511, 10'd511, 3'b000, "6 x (-255, +255): 1st read");
		mouse_check(-10'd511, 10'd511, 3'b000, "6 x (-255, +255): 2nd read");
		mouse_check(-10'd2, 10'd1, 3'b000, "6 x (-255, +255): the rest of -1024 (dx) / +1023 (dy)");
		mouse_check(10'd0, 10'd0, 3'b000, "6 x (-255, +255): after");
		mouse_packet(-16'd2, 16'd40, 3'b110);
		mouse_packet(-16'd2, 16'd40, 3'b110);               // two packets add
		mouse_check(-10'd4, 10'd80, 3'b110, "two packets (-2, +40), right and middle");
		mouse_check(10'd0, 10'd0, 3'b110, "their rest");
		mouse_packet(16'd1, -16'd1, 3'b110);                // one count moves one count
		mouse_check(10'd1, -10'd1, 3'b110, "a packet (+1, -1)");
		// a button alone, no motion packet (the firmware writes the buttons
		// register by itself when a button changes with the mouse still)
		@(posedge clk); m_btn <= 3'b010; repeat (10) @(posedge clk);
		mouse_check(10'd0, 10'd0, 3'b010, "right button alone, no packet");
		@(posedge clk); m_btn <= 3'b000; repeat (10) @(posedge clk);
		mouse_check(10'd0, 10'd0, 3'b000, "released alone, no packet");
		// a button held from before the mouse was switched on
		mouse_en = 0; repeat (20) @(posedge clk);
		@(posedge clk); m_btn <= 3'b001; repeat (10) @(posedge clk);
		mouse_en = 1; repeat (20) @(posedge clk);
		mouse_check(10'd0, 10'd0, 3'b001, "left button held from before the mouse was switched on");
		// dy -32768 (the most up a packet can say): +255 PS/2 counts up, not
		// -256 down (a 16-bit negation wraps), read as -255
		mouse_packet(16'd0, 16'h8000, 3'b001);
		mouse_check(10'd0, -10'd255, 3'b001, "dy -32768 clamped to -255");
		@(posedge clk); m_btn <= 3'b000; repeat (10) @(posedge clk);
		mouse_check(10'd0, 10'd0, 3'b000, "dy -32768 clamped, after");
		// the Game Bub chain
		mouse_en = 0; mouse2_en = 0; lg_en = 0; gb_chain = 1;
		joy = 13'h0010; joy1 = 13'h0001; joy2 = 13'h0040; joy3 = 13'h0400;   // pad words 8100 8400 8040 8004
		repeat (20) @(posedge clk);
		begin
			bit [39:0] w [7];
			// a pad alone
			chain = chain_of(1, 0);
			w = '{w16(16'h8100), 0, 0, 0, 0, 0, 0};
			chain_check(chain, w, "chain: pad 1");
			// the light gun, off screen (count 0, no hits, trigger set), then a pad
			off = 1; trig = 0; opt = 0;
			chain = chain_of(2, 6, 0);
			repeat (200) @(posedge clk);
			w = '{40'h4D80000000, w16(16'h8100), 0, 0, 0, 0, 0};
			chain_check(chain, w, "chain: light gun, pad 1");
			off = 0;
			// two mice, then four pads, each with its own button
			mouse_en = 1; mouse2_en = 1;
			@(posedge clk); m_btn <= 3'b001; m2_btn <= 3'b010; repeat (10) @(posedge clk);
			chain = chain_of(6, 4, 5, 0, 1, 2, 3);
			w = '{w32(mword(3'b001, 0, 0)), w32(mword(3'b010, 0, 0)), w16(16'h8100), w16(16'h8400), w16(16'h8040), w16(16'h8004), 0};
			chain_check(chain, w, "chain: mouse 1, mouse 2, pads 1-4");
			// four pads, then two mice
			chain = chain_of(6, 0, 1, 2, 3, 4, 5);
			w = '{w16(16'h8100), w16(16'h8400), w16(16'h8040), w16(16'h8004), w32(mword(3'b001, 0, 0)), w32(mword(3'b010, 0, 0)), 0};
			chain_check(chain, w, "chain: pads 1-4, mouse 1, mouse 2");
			// pads in another order (pad 3 before pad 1), a mouse between them
			chain = chain_of(3, 2, 4, 0);
			w = '{w16(16'h8040), w32(mword(3'b001, 0, 0)), w16(16'h8100), 0, 0, 0, 0};
			chain_check(chain, w, "chain: pad 3, mouse 1, pad 1");
			// motion: each mouse its own packets; the second fast (511-count reads)
			chain = chain_of(3, 4, 5, 0);
			mouse_packet(16'd5, -16'd3, 3'b001);
			mouse2_packet(-16'd7, 16'd2, 3'b010);
			w = '{w32(mword(3'b001, -10'd3, 10'd5)), w32(mword(3'b010, 10'd2, -10'd7)), w16(16'h8100), 0, 0, 0, 0};
			chain_check(chain, w, "chain: a packet each mouse");
			w = '{w32(mword(3'b001, 0, 0)), w32(mword(3'b010, 0, 0)), w16(16'h8100), 0, 0, 0, 0};
			chain_check(chain, w, "chain: nothing more");
			repeat (3) mouse2_packet(16'd0, 16'd200, 3'b100);
			w = '{w32(mword(3'b001, 0, 0)), w32(mword(3'b100, 10'd511, 0)), w16(16'h8100), 0, 0, 0, 0};
			chain_check(chain, w, "chain: mouse 2 fast, 1st read");
			w = '{w32(mword(3'b001, 0, 0)), w32(mword(3'b100, 10'd89, 0)), w16(16'h8100), 0, 0, 0, 0};
			chain_check(chain, w, "chain: mouse 2's rest");
			// the chain changed after the latch: the transfer under way keeps
			// the chain it latched, the next one takes the new one
			begin
				bit [255:0] q;
				fork
					pbus_read(32 + 32 + 16 + 16, q);
					begin repeat (18000 + 300) @(posedge clk); chain = chain_of(1, 1); end
				join
				checks++;
				if (q[95:64] !== mword(3'b001, 0, 0) || q[63:32] !== mword(3'b100, 0, 0) || q[31:16] !== 16'h8100 || q[15:0] !== 16'hFFFF)
					fail($sformatf("chain changed after the latch: read %h, expected the latched chain", q[95:0]));
			end
			w = '{w16(16'h8400), 0, 0, 0, 0, 0, 0};
			chain_check(chain, w, "chain: the new chain at the next transfer");
			// the second mouse unplugged (MOUSE2_EN off): its packets meanwhile
			// are dropped, it reads still when it is back
			mouse2_en = 0;
			mouse2_packet(16'd9, 16'd9, 3'b001);
			repeat (20) @(posedge clk);
			mouse2_en = 1;
			repeat (20) @(posedge clk);
			chain = chain_of(2, 4, 5);
			w = '{w32(mword(3'b001, 0, 0)), w32(mword(3'b001, 0, 0)), 0, 0, 0, 0, 0};
			chain_check(chain, w, "chain: second mouse back, its motion while away dropped");
			// no device: 1s
			chain = '0;
			w = '{0, 0, 0, 0, 0, 0, 0};
			chain_check(chain, w, "chain: empty");
		end
		gb_chain = 0; chain = '0; joy = '0; joy1 = '0; joy2 = '0; joy3 = '0;
		@(posedge clk); m_btn <= 3'b000; m2_btn <= 3'b000; repeat (10) @(posedge clk);
		mouse2_en = 0;
		mouse_en = 0;
		repeat (20) @(posedge clk);
		begin
			bit [255:0] q;
			pbus_read(16 + 8, q);
			checks++;
			if (q[23:8] !== 16'h8000 || q[7:0] !== 8'hFF) fail($sformatf("mouse off: %04h %02h, expected 8000 FF", q[23:8], q[7:0]));
		end
		$display("tb_lightgun: %0d transfers checked, errors=%0d", checks, errors);
		if (errors == 0) begin $display("tb_lightgun: PASS"); $finish; end
		else $fatal(1, "tb_lightgun: FAIL");
	end
	initial begin #20s; $fatal(1, "tb_lightgun: timeout"); end
endmodule
