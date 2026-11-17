// Light gun crosshair on the Game Bub video stream.
//
// Sits between video_capture and the framework: the same 320 x 240 pixel
// stream (VideoV0: dataEnable per pixel, an hblank pulse after each line, a
// vblank pulse after each frame), one clock later, with a plus drawn at the
// framebuffer pixel the light gun aims at (HPS2PAD GUN_X, GUN_Y: 0..319 x
// 0..239). The plus is white with a black border one pixel wide, so it shows
// on any picture; ARM is the length of each arm in pixels, not counting the
// centre (4, or 8 with big_en), and it is clipped at the picture's edges.
// The pixels are counted here as the framework counts them for its
// framebuffer's address (HandheldTop): vblank (held a few clocks by
// video_capture) clears x and y, the rising edge of hblank starts the next
// line, each dataEnable outside them is the next pixel. The aim and EN are
// taken at the vblank, so a frame shows one whole plus, or none.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module gun_cross #(
	parameter int CDEPTH = 6
)(
	input                   clk,
	input                   rst,

	input                   en,
	input                   big_en,
	input             [8:0] gun_x,
	input             [8:0] gun_y,

	input      [CDEPTH-1:0] in_r,
	input      [CDEPTH-1:0] in_g,
	input      [CDEPTH-1:0] in_b,
	input                   in_de,
	input                   in_hblank,
	input                   in_vblank,

	output reg [CDEPTH-1:0] video_r,
	output reg [CDEPTH-1:0] video_g,
	output reg [CDEPTH-1:0] video_b,
	output reg              video_de,
	output reg              video_hblank,
	output reg              video_vblank
);
	reg  [8:0] x, y;
	reg        hblank_d;
	reg  [8:0] cx, cy;
	reg        show, big;

	// distance from the centre in pixels
	wire [9:0] adx = x >= cx ? 10'(x - cx) : 10'(cx - x);
	wire [9:0] ady = y >= cy ? 10'(y - cy) : 10'(cy - y);
	wire [9:0] arm = big ? 10'd8 : 10'd4;
	wire       white  = (ady == 0 && adx <= arm) || (adx == 0 && ady <= arm);
	wire       border = (ady <= 1 && adx <= arm + 10'd1) || (adx <= 1 && ady <= arm + 10'd1);
	wire       draw   = show && border;

	always @(posedge clk) begin
		video_de     <= in_de;
		video_hblank <= in_hblank;
		video_vblank <= in_vblank;
		if (in_de) begin
			if (draw) {video_r, video_g, video_b} <= {3*CDEPTH{white}};
			else      {video_r, video_g, video_b} <= {in_r, in_g, in_b};
		end
		hblank_d <= in_hblank;
		if (rst) begin
			x <= '0;
			y <= '0;
			show <= 0;
		end else begin
			if (in_hblank) begin
				if (!hblank_d) begin
					x <= '0;
					y <= y + 9'd1;
				end
			end else if (in_de)
				x <= x + 9'd1;
			if (in_vblank) begin
				x <= '0;
				y <= '0;
				show <= en;
				big <= big_en;
				cx <= gun_x;
				cy <= gun_y;
			end
		end
	end
endmodule
