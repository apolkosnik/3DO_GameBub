// Small utility modules for the Game Bub 3DO core.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

// Fractional clock-enable generator (SystemVerilog port of MiSTer CEGen.vhd).
module ce_gen #(
	parameter longint IN_CLK  = 50_000_000,
	parameter longint OUT_CLK = 24_545_400
)(
	input      CLK,
	input      RST_N,
	output reg CE
);
	localparam int W = $clog2(IN_CLK + OUT_CLK + 1);
	reg [W-1:0] sum;
	always @(posedge CLK or negedge RST_N) begin
		if (!RST_N) begin
			sum <= '0;
			CE  <= 0;
		end else begin
			CE <= 0;
			if (sum + W'(OUT_CLK) >= W'(IN_CLK)) begin
				sum <= sum + W'(OUT_CLK) - W'(IN_CLK);
				CE  <= 1;
			end else begin
				sum <= sum + W'(OUT_CLK);
			end
		end
	end
endmodule

// Asynchronous FIFO with Gray-coded pointers (power-of-two depth).
module async_fifo #(
	parameter int WIDTH = 8,
	parameter int AW    = 4
)(
	input              wclk,
	input              wrst,
	input              wr,
	input  [WIDTH-1:0] wdata,
	output             wfull,

	input              rclk,
	input              rrst,
	input              rd,
	output [WIDTH-1:0] rdata,
	output             rempty
);
	(* ram_style = "distributed" *) reg [WIDTH-1:0] mem [0:(1<<AW)-1];

	reg  [AW:0] wbin, wgray, rbin, rgray;
	(* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1, rgray_w2;
	(* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1, wgray_r2;

	wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, (wr & ~wfull)};
	wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
	wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, (rd & ~rempty)};
	wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

	always @(posedge wclk) begin
		if (wr && !wfull) mem[wbin[AW-1:0]] <= wdata;
	end
	always @(posedge wclk or posedge wrst) begin
		if (wrst) begin
			wbin <= '0; wgray <= '0; rgray_w1 <= '0; rgray_w2 <= '0;
		end else begin
			wbin <= wbin_n; wgray <= wgray_n;
			rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
		end
	end
	always @(posedge rclk or posedge rrst) begin
		if (rrst) begin
			rbin <= '0; rgray <= '0; wgray_r1 <= '0; wgray_r2 <= '0;
		end else begin
			rbin <= rbin_n; rgray <= rgray_n;
			wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
		end
	end

	assign wfull  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
	assign rempty = (rgray == wgray_r2);
	assign rdata  = mem[rbin[AW-1:0]];
endmodule

// Video capture: 3DO video encoder output (640 dots x 240 lines, VCLK
// domain, DCLK pixel enable) -> 320 x 240 pixel stream on the system clock
// for the Game Bub framework (VideoV0: dataEnable per pixel, hblank pulse
// after each line, vblank pulse after each frame).
module video_capture #(
	parameter int CDEPTH = 6
)(
	input                   vclk,
	input                   vrst,
	input            [23:0] RGB,
	input                   DCLK,
	input                   HBLK_N,
	input                   VBLK_N,

	input                   clk,
	input                   rst,
	output reg [CDEPTH-1:0] video_r,
	output reg [CDEPTH-1:0] video_g,
	output reg [CDEPTH-1:0] video_b,
	output reg              video_de,
	output reg              video_hblank,
	output reg              video_vblank
);
	// token: {kind[1:0], rgb}, kind 0 = pixel, 1 = end of line, 2 = end of frame
	localparam TW = 2 + 3*CDEPTH;

	reg  [ 9:0] x;
	reg  [ 8:0] y;
	reg         hblk_n_d, vblk_n_d;
	reg         fifo_wr;
	reg [TW-1:0] fifo_wd;
	wire        fifo_full;

	always @(posedge vclk) begin
		fifo_wr <= 0;
		if (vrst) begin
			x <= '0;
			y <= '0;
			hblk_n_d <= 0;
			vblk_n_d <= 0;
		end else if (DCLK) begin
			hblk_n_d <= HBLK_N;
			vblk_n_d <= VBLK_N;
			if (HBLK_N && VBLK_N) begin
				// 640 dots per line: every source pixel is output twice
				if (x[0] && x < 10'd640 && y < 9'd240) begin
					fifo_wr <= 1;
					fifo_wd <= {2'd0, RGB[23 -: CDEPTH], RGB[15 -: CDEPTH], RGB[7 -: CDEPTH]};
				end
				x <= x + 1'd1;
			end
			if (hblk_n_d && !HBLK_N && VBLK_N) begin
				x <= '0;
				if (y < 9'd240) begin
					fifo_wr <= 1;
					fifo_wd <= {2'd1, {3*CDEPTH{1'b0}}};
				end
				y <= y + 1'd1;
			end
			if (vblk_n_d && !VBLK_N) begin
				x <= '0;
				y <= '0;
				fifo_wr <= 1;
				fifo_wd <= {2'd2, {3*CDEPTH{1'b0}}};
			end
		end
	end

	wire [TW-1:0] fifo_rd_data;
	wire          fifo_empty;
	reg           fifo_rd;

	async_fifo #(.WIDTH(TW), .AW(4)) fifo (
		.wclk(vclk), .wrst(vrst), .wr(fifo_wr), .wdata(fifo_wd), .wfull(fifo_full),
		.rclk(clk),  .rrst(rst),  .rd(fifo_rd), .rdata(fifo_rd_data), .rempty(fifo_empty)
	);

	// System clock side: one token every 4 cycles keeps hblank/vblank pulses
	// clearly separated for the framework's edge detectors.
	reg [1:0] phase;
	always @(posedge clk) begin
		fifo_rd  <= 0;
		video_de <= 0;
		if (rst) begin
			phase <= '0;
			video_hblank <= 0;
			video_vblank <= 0;
		end else begin
			phase <= phase + 1'd1;
			if (phase == 2'd3) begin
				video_hblank <= 0;
				video_vblank <= 0;
			end
			if (phase == 2'd0 && !fifo_empty) begin
				fifo_rd <= 1;
				case (fifo_rd_data[TW-1 -: 2])
					2'd0: begin
						video_de <= 1;
						{video_r, video_g, video_b} <= fifo_rd_data[3*CDEPTH-1:0];
					end
					2'd1: video_hblank <= 1;
					default: video_vblank <= 1;
				endcase
			end
		end
	end
endmodule
