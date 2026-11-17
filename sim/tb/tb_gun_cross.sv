// Testbench: the light gun crosshair on the Game Bub video stream
// (rtl/gamebub/gun_cross.sv).
//
// The real HPS2PAD turns the aim (0..65535, as the firmware writes it) into
// the gun pixel on the system clock; the real VE makes the video timing on
// the video clock; the real video_capture turns VE's 640 dots x 240 lines
// into the framework's 320 x 240 pixel stream; gun_cross draws the plus on
// that stream. The testbench puts a picture on video_capture's RGB from its
// own count of VE's active window (DCLK, HBLK_N, VBLK_N): every pixel (x, y)
// has its own colour, never white or black. It captures whole frames of the
// stream gun_cross gives the framework (dataEnable, hblank, vblank) and
// checks each frame has 240 lines of 320 pixels, and every pixel: white on
// the plus at the pixel the aim maps to ((aim * 320) >> 16, (aim * 240) >>
// 16), black on its one pixel border, the picture's own colour everywhere
// else (so the plus is where the picture's pixel is, not shifted). Arms of 4
// (small) and 8 (lg) pixels, clipped at the edges. Cases, NTSC and PAL:
// the corners, the edges, the centre and elsewhere, small and lg; off
// (the picture untouched); an aim and a size changed in the middle of a
// frame only show from the next frame (the plus is taken at the vblank).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
module tb_gun_cross;
	reg clk_sys = 0;
	reg clk_vid = 0;
	always #10 clk_sys = ~clk_sys;
	always #10.191 clk_vid = ~clk_vid;     // 49.0625 MHz, as tb_top

	reg         rst = 1;
	reg         pal = 0;
	reg  [15:0] ax = 16'h8000, ay = 16'h8000;
	reg         en = 0, big = 0;

	wire [ 8:0] gun_x, gun_y;
	HPS2PAD pad (
		.CLK(clk_sys), .RST(rst), .CE(1'b1),
		.PBDIN(), .PBDOUT(1'b1), .PBCLK(1'b0), .EXPBDIN(1'b1), .EXPBDOUT(),
		.PAD_SEL(3'd1), .ARCADE_SEL(2'd0), .STICK_EN(1'b0), .MOUSE_EN(1'b0), .MOUSE2_EN(1'b0),
		.GB_CHAIN(1'b1), .CHAIN(28'h0), .ARCADE_SERVICE(1'b0),
		.joystick_0('0), .joystick_1('0), .joystick_2('0), .joystick_3('0),
		.joy0_x0('0), .joy0_y0('0), .joy0_x1('0), .joy0_y1('0),
		.joy1_x0('0), .joy1_y0('0), .joy1_x1('0), .joy1_y1('0), .ps2_mouse('0), .ps2_mouse2('0),
		.LG_EN(1'b1), .LG_PAL(pal), .lg_x(ax), .lg_y(ay),
		.lg_trigger(1'b0), .lg_option(1'b0), .lg_offscreen(1'b0),
		.GUN_X(gun_x), .GUN_Y(gun_y)
	);

	wire [23:0] ve_rgb;
	wire        HS_N, VS_N, HBLK_N, VBLK_N, DCLK;
	VE ve (
		.MCLK(clk_sys), .VCLK(clk_vid), .RST_N(~rst), .EN(1'b1), .PAL(pal),
		.VCE(1'b0), .AD(24'd0), .DE(1'b0), .HSYNC_N(), .VSYNC_N(),
		.RGB(ve_rgb), .HS_N(HS_N), .VS_N(VS_N), .HBLK_N(HBLK_N), .VBLK_N(VBLK_N), .DCLK(DCLK),
		.DBG_EXT(8'hFF), .DBG_BORD_DIS(1'b1), .DBG_HS_START(), .DBG_HS_END()
	);

	// the picture: pixel (x, y) of the active window; never white or black
	// (b's low bit is 1, b's top three bits are x[8:6] <= 4)
	function automatic [17:0] pattern(input int x, input int y);
		pattern = {6'(x), 6'(y), 3'(x >> 6), 2'(y >> 6), 1'b1};
	endfunction
	int  vdot = 0, vline = 0;
	bit  vline_act = 0;
	always @(posedge clk_vid) begin
		if (DCLK) begin
			if (!VBLK_N) begin
				vdot <= 0; vline <= 0; vline_act <= 0;
			end else if (HBLK_N) begin
				vdot <= vdot + 1; vline_act <= 1;
			end else if (vline_act) begin
				vdot <= 0; vline <= vline + 1; vline_act <= 0;
			end
		end
	end
	wire [17:0] pat = pattern(vdot >> 1, vline);
	wire [23:0] rgb = {pat[17:12], 2'b00, pat[11:6], 2'b00, pat[5:0], 2'b00};

	wire [5:0] cap_r, cap_g, cap_b;
	wire       cap_de, cap_hblank, cap_vblank;
	reg  vrst = 1;
	always @(posedge clk_vid) vrst <= rst;
	video_capture #(.CDEPTH(6)) vcap (
		.vclk(clk_vid), .vrst(vrst), .RGB(rgb), .DCLK(DCLK), .HBLK_N(HBLK_N), .VBLK_N(VBLK_N),
		.clk(clk_sys), .rst(rst),
		.video_r(cap_r), .video_g(cap_g), .video_b(cap_b),
		.video_de(cap_de), .video_hblank(cap_hblank), .video_vblank(cap_vblank)
	);

	wire [5:0] vr, vg, vb;
	wire       vde, vhblank, vvblank;
	gun_cross #(.CDEPTH(6)) dut (
		.clk(clk_sys), .rst(rst), .en(en), .big_en(big), .gun_x(gun_x), .gun_y(gun_y),
		.in_r(cap_r), .in_g(cap_g), .in_b(cap_b), .in_de(cap_de), .in_hblank(cap_hblank), .in_vblank(cap_vblank),
		.video_r(vr), .video_g(vg), .video_b(vb), .video_de(vde), .video_hblank(vhblank), .video_vblank(vvblank)
	);

	int errors = 0, checks = 0;
	task automatic fail(input string m);
		errors++;
		if (errors <= 30) $display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	// the stream to the framework, captured frame by frame, addressed as the
	// framework addresses its framebuffer (HandheldTop): vblank (a level)
	// clears x and y, the rising edge of hblank starts the next line, each
	// dataEnable outside them is the next pixel; a frame ends at the rising
	// edge of vblank. Each line must have had 320 pixels at its hblank edge.
	bit [17:0] cap  [240][320];
	bit [17:0] done [240][320];
	int  sx = 0, sy = 0, frame_lines, frames = 0, line_errs = 0, oob = 0;
	bit  lcheck = 0;   // count the pixels of each line (not while the standard changes)
	bit  hb_d = 0, vb_d = 0;
	event frame_end;
	always @(posedge clk_sys) begin
		if (vvblank) begin
			if (!vb_d) begin
				frame_lines = sy;
				done = cap;
				frames++;
				-> frame_end;
			end
			sx = 0; sy = 0;
		end else if (vhblank) begin
			if (!hb_d) begin
				if (sx != 320 && lcheck) begin
					line_errs++;
					if (line_errs <= 5) $display("[%0t] TB ERROR: line %0d has %0d pixels", $realtime, sy, sx);
				end
				sx = 0; sy++;
			end
		end else if (vde) begin
			if (sy < 240 && sx < 320) cap[sy][sx] = {vr, vg, vb};
			else if (lcheck) oob++;
			sx++;
		end
		hb_d = vhblank; vb_d = vvblank;
	end

	// one whole frame against the plus at the aim's pixel (draw 0: no plus)
	task automatic check_frame(input bit draw, input bit lg, input bit [15:0] x, input bit [15:0] y, input string what);
		int px, py, arm, bad;
		px = (int'(x) * 320) >> 16; py = (int'(y) * 240) >> 16;
		arm = lg ? 4 + 4 : 4;
		bad = 0;
		checks++;
		if (frame_lines != 240) fail($sformatf("%s: %0d lines, expected 240", what, frame_lines));
		for (int j = 0; j < 240; j++) for (int i = 0; i < 320; i++) begin
			int dx, dy;
			bit [17:0] e;
			dx = i > px ? i - px : px - i;
			dy = j > py ? j - py : py - j;
			if (draw && ((dy == 0 && dx <= arm) || (dx == 0 && dy <= arm)))           e = '1;
			else if (draw && ((dy <= 1 && dx <= arm + 1) || (dx <= 1 && dy <= arm + 1))) e = '0;
			else                                                                       e = pattern(i, j);
			if (done[j][i] !== e) begin
				bad++;
				if (bad <= 3) fail($sformatf("%s %s: pixel %0d,%0d is %05h, expected %05h (plus at %0d,%0d)",
				                             pal ? "PAL" : "NTSC", what, i, j, done[j][i], e, px, py));
			end
		end
		if (bad > 3) fail($sformatf("%s %s: %0d pixels wrong", pal ? "PAL" : "NTSC", what, bad));
	endtask

	// set the aim, size and enable, let a vblank take them, check the next frame
	task automatic case_check(input bit draw, input bit lg, input bit [15:0] x, input bit [15:0] y, input string what);
		ax = x; ay = y; en = draw; big = lg;
		@(frame_end); @(frame_end);
		@(frame_end);
		check_frame(draw, lg, x, y, what);
	endtask

	initial begin
		bit [15:0] xs [5] = '{16'h0000, 16'h0100, 16'h8000, 16'hF000, 16'hFFFF};
		bit [15:0] ys [5] = '{16'h0000, 16'h0200, 16'h8000, 16'hF800, 16'hFFFF};
		repeat (20) @(posedge clk_sys); rst = 0;
		for (int p = 0; p < 2; p++) begin
			lcheck = 0;
			pal = 1'(p);
			@(frame_end); @(frame_end);
			lcheck = 1;
			case_check(0, 0, 16'h8000, 16'h8000, "off");
			foreach (xs[i]) foreach (ys[j]) for (int l = 0; l < 2; l++)
				case_check(1, 1'(l), xs[i], ys[j], $sformatf("%s aim %04h,%04h", l ? "lg" : "small", xs[i], ys[j]));
			repeat (4) case_check(1, 1'($urandom()), 16'($urandom()), 16'($urandom()), "random aim");
			// a change in the middle of a frame shows from the next frame
			case_check(1, 0, 16'h2000, 16'h3000, "before the change");
			wait (sy == 120);
			ax = 16'hC000; ay = 16'hA000; big = 1;
			@(frame_end);
			check_frame(1, 0, 16'h2000, 16'h3000, "aim changed mid-frame: that frame");
			@(frame_end);
			check_frame(1, 1, 16'hC000, 16'hA000, "aim changed mid-frame: the next frame");
			// switched off in the middle of a frame
			wait (sy == 60);
			en = 0;
			@(frame_end);
			check_frame(1, 1, 16'hC000, 16'hA000, "off mid-frame: that frame");
			@(frame_end);
			check_frame(0, 0, 16'h0000, 16'h0000, "off mid-frame: the next frame");
		end
		if (line_errs) fail($sformatf("%0d lines without 320 pixels", line_errs));
		if (oob) fail($sformatf("%0d pixels outside 320 x 240", oob));
		$display("tb_gun_cross: %0d frames checked (%0d pixels each), errors=%0d", checks, 320 * 240, errors);
		if (errors == 0) begin $display("tb_gun_cross: PASS"); $finish; end
		else $fatal(1, "tb_gun_cross: FAIL");
	end
	initial begin #20s; $fatal(1, "tb_gun_cross: timeout"); end
endmodule
