// Avalon-MM style 64-bit burst slave (the MiSTer DDRAM_* interface used by
// ddram.sv) implemented on top of the 16-bit SDRAM secondary port.
//
// One 64-bit beat = four consecutive SDRAM words, most significant first:
//   word 4i+0 = DIN[63:48], 4i+1 = [47:32], 4i+2 = [31:16], 4i+3 = [15:0]
// The beat address space (DDRAM_ADDR[19:0], 8 MiB) maps linearly onto
// SDRAM bank 2. ddram.sv never issues a burst that crosses a 1 KiB boundary
// (128 beats), which is exactly one SDRAM row.
//
// Handshake (as ddram.sv expects from the MiSTer DDR3 bridge):
//  * a command (RD or WE) is accepted on a clock edge where BUSY is low;
//  * write bursts: every further beat is accepted the same way; beats are
//    collected into a buffer and written to SDRAM after the last one, with
//    BUSY high until the SDRAM write is complete;
//  * reads: BUSY stays low while the read beats are returned with
//    DOUT_READY (ddram.sv only looks at DOUT_READY when BUSY is low and
//    never issues a new command while it waits for read data).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module ddr_bridge (
	input              clk,
	input              rst,
	input              host_le,      // host file byte order (see gb_host.sv)

	// MiSTer DDRAM interface (slave side)
	output reg         DDRAM_BUSY,
	input      [ 7: 0] DDRAM_BURSTCNT,
	input      [28: 0] DDRAM_ADDR,
	output reg [63: 0] DDRAM_DOUT,
	output reg         DDRAM_DOUT_READY,
	input              DDRAM_RD,
	input      [63: 0] DDRAM_DIN,
	input      [ 7: 0] DDRAM_BE,
	input              DDRAM_WE,

	// SDRAM secondary port (master side)
	output reg         sec_req,
	output reg         sec_we,
	output reg [23: 0] sec_addr,
	output reg [ 9: 0] sec_len,
	output     [15: 0] sec_wdata,
	output     [ 1: 0] sec_wbe,
	input              sec_wnext,
	input      [15: 0] sec_rdata,
	input              sec_rvalid,
	input              sec_done
);
	typedef enum bit [2:0] {
		B_IDLE,
		B_COLLECT,
		B_WRITE,
		B_READ
	} bstate_t;
	bstate_t st;

	// Write buffer: one SDRAM row (128 beats) of data + byte enables.
	(* ram_style = "distributed" *) reg [71:0] wbuf [0:127];
	reg  [ 6:0] wcnt;          // beats collected
	reg  [ 7:0] burst;         // beats in the current command
	reg  [ 8:0] widx;          // SDRAM word index while writing
	reg  [ 1:0] rword;         // word position inside the beat being read
	reg  [ 7:0] rbeats;        // read beats delivered
	reg  [47:0] racc;

	// Beats at byte offset >= 4 MiB (BIOS, kanji, NVRAM) hold host-written
	// file data in host order. With a little-endian host every 32-bit group
	// is byte-reversed relative to the 3DO's big-endian view; undo that here.
	function automatic [31:0] rev32(input [31:0] x);
		rev32 = {x[7:0], x[15:8], x[23:16], x[31:24]};
	endfunction
	function automatic [3:0] rev4(input [3:0] x);
		rev4 = {x[0], x[1], x[2], x[3]};
	endfunction
	wire        swap_cmd = host_le && DDRAM_ADDR[19];
	reg         swap;
	wire [63:0] din_s = swap_cmd ? {rev32(DDRAM_DIN[63:32]), rev32(DDRAM_DIN[31:0])} : DDRAM_DIN;
	wire [ 7:0] be_s  = swap_cmd ? {rev4(DDRAM_BE[7:4]), rev4(DDRAM_BE[3:0])} : DDRAM_BE;
	wire [63:0] din_c = swap ? {rev32(DDRAM_DIN[63:32]), rev32(DDRAM_DIN[31:0])} : DDRAM_DIN;
	wire [ 7:0] be_c  = swap ? {rev4(DDRAM_BE[7:4]), rev4(DDRAM_BE[3:0])} : DDRAM_BE;

	wire [71:0] wb   = wbuf[widx[8:2]];
	wire [ 1:0] wsel = widx[1:0];
	assign sec_wdata = wsel == 2'd0 ? wb[63:48] : wsel == 2'd1 ? wb[47:32] : wsel == 2'd2 ? wb[31:16] : wb[15:0];
	assign sec_wbe   = wsel == 2'd0 ? wb[71:70] : wsel == 2'd1 ? wb[69:68] : wsel == 2'd2 ? wb[67:66] : wb[65:64];

	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 0;

		if (rst) begin
			st         <= B_IDLE;
			DDRAM_BUSY <= 0;
			sec_req    <= 0;
		end else begin
			case (st)
				B_IDLE: begin
					DDRAM_BUSY <= 0;
					if (DDRAM_WE && !DDRAM_BUSY) begin
						wbuf[0]  <= {be_s, din_s};
						swap     <= swap_cmd;
						wcnt     <= 7'd1;
						burst    <= DDRAM_BURSTCNT;
						sec_addr <= {2'd2, DDRAM_ADDR[19:0], 2'b00};
						sec_len  <= {DDRAM_BURSTCNT, 2'b00};
						sec_we   <= 1;
						widx     <= '0;
						if (DDRAM_BURSTCNT == 8'd1) begin
							DDRAM_BUSY <= 1;
							sec_req    <= 1;
							st <= B_WRITE;
						end else begin
							st <= B_COLLECT;
						end
					end else if (DDRAM_RD && !DDRAM_BUSY) begin
						swap     <= swap_cmd;
						burst    <= DDRAM_BURSTCNT;
						sec_addr <= {2'd2, DDRAM_ADDR[19:0], 2'b00};
						sec_len  <= {DDRAM_BURSTCNT, 2'b00};
						sec_we   <= 0;
						sec_req  <= 1;
						rword    <= '0;
						rbeats   <= '0;
						st <= B_READ;
					end
				end

				B_COLLECT: begin
					if (DDRAM_WE && !DDRAM_BUSY) begin
						wbuf[wcnt] <= {be_c, din_c};
						wcnt <= wcnt + 1'd1;
						if ({1'b0, wcnt} + 8'd1 == burst) begin
							DDRAM_BUSY <= 1;
							sec_req    <= 1;
							st <= B_WRITE;
						end
					end
				end

				B_WRITE: begin
					if (sec_wnext) widx <= widx + 1'd1;
					if (sec_done) begin
						sec_req    <= 0;
						DDRAM_BUSY <= 0;
						st <= B_IDLE;
					end
				end

				B_READ: begin
					// After the last beat has been seen by ddram.sv (BUSY must be
					// low in that cycle, it ignores DOUT_READY otherwise), hold off
					// new commands until the SDRAM transaction has completed.
					// ddram.sv cannot issue one earlier: it is still in its
					// read state when it takes the last beat.
					if (DDRAM_DOUT_READY && rbeats == burst) DDRAM_BUSY <= 1;
					if (sec_rvalid) begin
						rword <= rword + 1'd1;
						case (rword)
							2'd0: racc[47:32] <= sec_rdata;
							2'd1: racc[31:16] <= sec_rdata;
							2'd2: racc[15: 0] <= sec_rdata;
							2'd3: begin
								DDRAM_DOUT       <= swap ? {rev32(racc[47:16]), rev32({racc[15:0], sec_rdata})} : {racc, sec_rdata};
								DDRAM_DOUT_READY <= 1;
								rbeats <= rbeats + 1'd1;
							end
						endcase
					end
					if (sec_done) begin
						sec_req    <= 0;
						DDRAM_BUSY <= 0;
						st <= B_IDLE;
					end
				end

				default: st <= B_IDLE;
			endcase
		end
	end
endmodule
