`include "gb3do_pkg.svh"
// Game Bub host (MCU) interface for the 3DO core.
//
//  * HostV0 command channel: GetStatus, CoreRun/Halt, SetupComplete,
//    NotifyFocus, FileWriteStart/End, FileReadStart/End.
//  * HostV0 memory interface, address map:
//      0x0000_1000..0x0000_10FF  core settings (settings.json)
//      0x1000_0000 + o           CD image (ISO), o < 22 MiB          (file 0)
//      0x2000_0000 + o           BIOS ROM, 1 MiB                     (file 1)
//      0x2100_0000 + o           Kanji ROM, 1 MiB, optional          (file 2)
//      0x3000_0000 + o           NVRAM, 32 KiB, saved on exit        (file 3)
//      0xF000_0000..0xF000_000F  host->core command parameters/results
//    File data are stored in SDRAM exactly as received ("host order"):
//    SDRAM word 2k = dataWrite[31:16], 2k+1 = dataWrite[15:0]. Consumers
//    undo the host byte order (see HOST_LE below).
//  * HOST_LE: whether host words carry file byte o in bits [7:0]
//    (SPI byte-swap mode) instead of [31:24]. Defaults to 1 and is detected
//    from the first word of the ISO (Opera volume header 01 5A 5A 5A ...).
//  * After SetupComplete, a blank 3DO NVRAM is formatted if the save file was
//    missing (never written or still 0xFF-filled), like Main_MiSTer does.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module gb_host (
	input              clk,              // clk_sys (framework system clock)
	input              reset,

	// HostV0
	input      [31: 0] mem_address,
	input              mem_enable,
	input              mem_write,
	output reg [31: 0] mem_dataRead,
	input      [31: 0] mem_dataWrite,
	output reg         mem_done,
	input              cmd_request,
	output             cmd_busy,
	output             cmd_done,
	output             cmd_error,

	// core control / status
	output reg         core_halt,        // 1 = hold the 3DO in reset
	output reg         core_reset_pulse, // "Reset" setting action
	output reg         focus,
	output reg         HOST_LE,
	output reg         disc_present,
	output reg [24: 0] disc_bytes,
	output reg         bios_loaded,
	output reg         kanji_loaded,
	output reg [ 1: 0] cd_speed,

	// SDRAM secondary port client (clk_mem)
	input              clk_mem,
	input              rst_mem,
	output reg         sec_req,
	output reg         sec_we,
	output reg [23: 0] sec_addr,
	output     [ 9: 0] sec_len,
	output     [15: 0] sec_wdata,
	output     [ 1: 0] sec_wbe,
	input              sec_wnext,
	input      [15: 0] sec_rdata,
	input              sec_rvalid,
	input              sec_done
);
	import gb3do_pkg::*;

	localparam CMD_GET_STATUS      = 16'h0000;
	localparam CMD_CORE_RUN        = 16'h0100;
	localparam CMD_CORE_HALT       = 16'h0101;
	localparam CMD_SETUP_COMPLETE  = 16'h0102;
	localparam CMD_NOTIFY_FOCUS    = 16'h0200;
	localparam CMD_FILE_WRITE_START= 16'h0300;
	localparam CMD_FILE_WRITE_END  = 16'h0301;
	localparam CMD_FILE_READ_START = 16'h0302;
	localparam CMD_FILE_READ_END   = 16'h0303;

	localparam STATUS_SETUP     = 32'd2;
	localparam STATUS_CORE_HALT = 32'd3;
	localparam STATUS_CORE_RUN  = 32'd4;

	localparam FILE_ISO   = 32'd0;
	localparam FILE_BIOS  = 32'd1;
	localparam FILE_KANJI = 32'd2;
	localparam FILE_NVRAM = 32'd3;

	localparam NVRAM_BYTES = 32'h8000;

	// NVRAM formatting (blank 3DO NVRAM, from Main_MiSTer support/3do/3do.cpp)
	function automatic [7:0] blank_byte(input [7:0] i);
		case (i)
			8'h00: blank_byte = 8'h01; 8'h01: blank_byte = 8'h5A; 8'h02: blank_byte = 8'h5A; 8'h03: blank_byte = 8'h5A;
			8'h04: blank_byte = 8'h5A; 8'h05: blank_byte = 8'h5A; 8'h06: blank_byte = 8'h02;
			8'h28: blank_byte = 8'h4E; 8'h29: blank_byte = 8'h56; 8'h2A: blank_byte = 8'h52; 8'h2B: blank_byte = 8'h41; 8'h2C: blank_byte = 8'h4D;
			8'h48: blank_byte = 8'hFF; 8'h49: blank_byte = 8'hFF; 8'h4A: blank_byte = 8'hFF; 8'h4B: blank_byte = 8'hFF;
			8'h4F: blank_byte = 8'h01;
			8'h52: blank_byte = 8'h80;
			8'h54: blank_byte = 8'hFF; 8'h55: blank_byte = 8'hFF; 8'h56: blank_byte = 8'hFF; 8'h57: blank_byte = 8'hFE;
			8'h5F: blank_byte = 8'h01;
			8'h67: blank_byte = 8'h84;
			8'h84: blank_byte = 8'h85; 8'h85: blank_byte = 8'h5A; 8'h86: blank_byte = 8'h02; 8'h87: blank_byte = 8'hB6;
			8'h8B: blank_byte = 8'h98;
			8'h8F: blank_byte = 8'h98;
			8'h93: blank_byte = 8'h14;
			8'h97: blank_byte = 8'h14;
			8'h98: blank_byte = 8'h7A; 8'h99: blank_byte = 8'hA5; 8'h9A: blank_byte = 8'h65; 8'h9B: blank_byte = 8'hBD;
			8'h9F: blank_byte = 8'h84;
			8'hA3: blank_byte = 8'h84;
			8'hA6: blank_byte = 8'h7F; 8'hA7: blank_byte = 8'h68;
			8'hAB: blank_byte = 8'h14;
			default: blank_byte = 8'h00;
		endcase
	endfunction

	// Blank-NVRAM word w (SDRAM word index from the NVRAM base) in host
	// storage order (see the header): little-endian host words put file
	// bytes {2w+3,2w+2} in even and {2w-1,2w-2} in odd SDRAM words.
	function automatic [15:0] fmt_word(input [13:0] w, input le);
		bit [14:0] n;
		n = {w, 1'b0};
		if (n >= 15'h100)       fmt_word = 16'h0000;
		else if (!le)           fmt_word = {blank_byte(n[7:0]), blank_byte(n[7:0] + 8'd1)};
		else if (!w[0])         fmt_word = {blank_byte(n[7:0] + 8'd3), blank_byte(n[7:0] + 8'd2)};
		else                    fmt_word = {blank_byte(n[7:0] - 8'd1), blank_byte(n[7:0] - 8'd2)};
	endfunction

	// ------------------------------------------------------------------
	// SDRAM access engine (clk_sys request, clk_mem execution)
	//   normal: one host word = 2 SDRAM words
	//   format: one SDRAM row (512 words) of the blank NVRAM image
	// ------------------------------------------------------------------
	reg         xreq_tgl;        // clk_sys -> clk_mem
	reg         xdone_tgl;       // clk_mem -> clk_sys
	reg         x_we;
	reg         x_fmt;
	reg  [23:0] x_addr;          // SDRAM word address of the first word
	reg  [31:0] x_wdata;
	reg  [31:0] x_rdata;         // written in clk_mem, read after xdone
	reg  [ 4:0] x_row;           // NVRAM row (format mode)

	reg  [2:0]  xreq_s;
	reg  [ 8:0] x_widx;          // word index within the transfer
	assign sec_len   = x_fmt ? 10'd512 : 10'd2;
	assign sec_wdata = x_fmt ? fmt_word({x_row, x_widx}, HOST_LE) :
	                   x_widx[0] ? x_wdata[15:0] : x_wdata[31:16];
	assign sec_wbe   = 2'b11;

	always @(posedge clk_mem) begin
		xreq_s <= {xreq_s[1:0], xreq_tgl};
		if (rst_mem) begin
			sec_req   <= 0;
			xdone_tgl <= 0;
			xreq_s    <= '0;
		end else begin
			if (!sec_req && (xreq_s[2] != xreq_s[1])) begin
				sec_we   <= x_we;
				sec_addr <= x_addr;
				x_widx   <= '0;
				sec_req  <= 1;
			end
			if (sec_req) begin
				if (sec_wnext) x_widx <= x_widx + 1'd1;
				if (sec_rvalid) begin
					x_widx <= x_widx + 1'd1;
					if (!x_widx[0]) x_rdata[31:16] <= sec_rdata;
					else            x_rdata[15: 0] <= sec_rdata;
				end
				if (sec_done) begin
					sec_req   <= 0;
					xdone_tgl <= ~xdone_tgl;
				end
			end
		end
	end

	reg  [2:0] xdone_s;
	wire       x_finished = xdone_s[2] != xdone_s[1];
	reg        x_busy;

	// ------------------------------------------------------------------
	// Host memory interface / command handling (clk_sys)
	// ------------------------------------------------------------------
	reg  [31:0] cmd_reg [4];
	reg  [ 1:0] cmd_state;       // 0 idle, 1 busy, 2 done, 3 error
	reg         setup_done;
	reg         finalize_busy;
	reg         nvram_written;
	reg         iso_first_seen;
	reg  [31:0] cur_file;

	assign cmd_busy  = (cmd_state == 2'd1);
	assign cmd_done  = (cmd_state == 2'd2);
	assign cmd_error = (cmd_state == 2'd3);

	// Pending host memory access waiting for SDRAM
	reg         mem_pend;
	reg         mem_pend_rd;

	typedef enum bit [2:0] { F_IDLE, F_CHECK, F_CHECK_WAIT, F_WRITE, F_WRITE_WAIT, F_DONE } fstate_t;
	fstate_t fst;


	// Map a host address to an SDRAM word address; bit 24 = backed by SDRAM
	function automatic [24:0] map_addr(input [31:0] a);
		map_addr = '0;
		if (a[31:28] == 4'h1) begin
			if (a[27:0] < 28'(ISO_MAX_BYTES))  map_addr = {1'b1, iso_word_addr(a[24:1])};
		end else if (a[31:20] == 12'h200) begin
			map_addr = {1'b1, ddr_word_addr(DDR_BIOS_BASE  + {3'd0, a[19:0]})};
		end else if (a[31:20] == 12'h210) begin
			map_addr = {1'b1, ddr_word_addr(DDR_KANJI_BASE + {3'd0, a[19:0]})};
		end else if (a[31:15] == 17'h06000) begin   // 0x3000_0000..0x3000_7FFF
			map_addr = {1'b1, ddr_word_addr(DDR_NVRAM_BASE + {8'd0, a[14:0]})};
		end
	endfunction

	wire [24:0] mapped = map_addr(mem_address);

	always @(posedge clk) begin
		xdone_s <= {xdone_s[1:0], xdone_tgl};
		mem_done <= 0;
		core_reset_pulse <= 0;

		if (reset) begin
			cmd_state     <= 2'd0;
			core_halt     <= 1;
			setup_done    <= 0;
			finalize_busy <= 0;
			focus         <= 0;
			HOST_LE       <= 1;
			disc_present  <= 0;
			disc_bytes    <= '0;
			bios_loaded   <= 0;
			kanji_loaded  <= 0;
			nvram_written <= 0;
			iso_first_seen<= 0;
			cd_speed      <= 2'd1;
			mem_pend      <= 0;
			x_busy        <= 0;
			fst           <= F_IDLE;
			xreq_tgl      <= 0;
			xdone_s       <= '0;
			cur_file      <= '1;
		end else begin
			if (x_finished) x_busy <= 0;

			// ---------------- memory interface ----------------
			if (mem_pend) begin
				if (x_finished) begin
					mem_pend <= 0;
					mem_done <= 1;
					if (mem_pend_rd) mem_dataRead <= x_rdata;
				end
			end else if (mem_enable && !mem_done && (fst == F_IDLE || !mapped[24])) begin
				if (mem_address[31:28] == 4'hF) begin
					// command parameter / result words
					if (mem_address[27:4] == 24'h0) begin
						if (mem_write) cmd_reg[mem_address[3:2]] <= mem_dataWrite;
						else           mem_dataRead <= cmd_reg[mem_address[3:2]];
					end else begin
						mem_dataRead <= 32'h0;
					end
					mem_done <= 1;
				end else if (mem_address[31:8] == 24'h000010) begin
					// settings
					if (mem_write) begin
						case (mem_address[7:0])
							8'h00: cd_speed <= mem_dataWrite[1:0];
							8'h04: if (mem_dataWrite[0]) core_reset_pulse <= 1;
							default: ;
						endcase
						mem_dataRead <= 32'h0;
					end else begin
						case (mem_address[7:0])
							8'h00: mem_dataRead <= {30'd0, cd_speed};
							default: mem_dataRead <= 32'h0;
						endcase
					end
					mem_done <= 1;
				end else if (mapped[24]) begin
					// SDRAM-backed file data
					if (mem_write) begin
						if (mem_address == 32'h1000_0000 && !iso_first_seen) begin
							iso_first_seen <= 1;
							if (mem_dataWrite == 32'h015A5A5A) HOST_LE <= 0;
							if (mem_dataWrite == 32'h5A5A5A01) HOST_LE <= 1;
						end
						if (mem_address[31:24] == 8'h30) nvram_written <= 1;
					end
					x_we     <= mem_write;
					x_fmt    <= 0;
					x_addr   <= mapped[23:0];
					x_wdata  <= mem_dataWrite;
					xreq_tgl <= ~xreq_tgl;
					x_busy   <= 1;
					mem_pend <= 1;
					mem_pend_rd <= !mem_write;
				end else begin
					mem_dataRead <= 32'h0;
					mem_done <= 1;
				end
			end

			// ---------------- NVRAM blank formatting ----------------
			case (fst)
				F_IDLE: ;
				F_CHECK: if (!mem_pend && !x_busy) begin
					x_we     <= 0;
					x_fmt    <= 0;
					x_addr   <= ddr_word_addr(DDR_NVRAM_BASE);
					xreq_tgl <= ~xreq_tgl;
					x_busy   <= 1;
					fst <= F_CHECK_WAIT;
				end
				F_CHECK_WAIT: if (x_finished) begin
					if (!nvram_written || x_rdata == 32'hFFFFFFFF) begin
						x_row <= '0;
						fst <= F_WRITE;
					end else begin
						fst <= F_DONE;
					end
				end
				F_WRITE: if (!mem_pend && !x_busy) begin
					// one 1 KiB SDRAM row of the blank image per request
					x_we     <= 1;
					x_fmt    <= 1;
					x_addr   <= ddr_word_addr(DDR_NVRAM_BASE + {8'd0, x_row, 10'd0});
					xreq_tgl <= ~xreq_tgl;
					x_busy   <= 1;
					fst <= F_WRITE_WAIT;
				end
				F_WRITE_WAIT: if (x_finished) begin
					x_row <= x_row + 1'd1;
					fst <= (x_row == 5'd31) ? F_DONE : F_WRITE;
				end
				F_DONE: begin
					finalize_busy <= 0;
					setup_done    <= 1;
					fst <= F_IDLE;
				end
				default: fst <= F_IDLE;
			endcase

			// ---------------- host -> core commands ----------------
			if (cmd_request) begin
				if (cmd_state == 2'd0) begin
					cmd_state <= 2'd2;
					cmd_reg[0] <= 32'h0;
					case (cmd_reg[0][15:0])
						CMD_GET_STATUS: cmd_reg[0] <= !setup_done ? STATUS_SETUP :
						                              core_halt   ? STATUS_CORE_HALT : STATUS_CORE_RUN;
						CMD_SETUP_COMPLETE: begin
							if (!setup_done && !finalize_busy) begin
								finalize_busy <= 1;
								fst <= F_CHECK;
							end
						end
						CMD_CORE_RUN:  core_halt <= 0;
						CMD_CORE_HALT: core_halt <= 1;
						CMD_NOTIFY_FOCUS: focus <= cmd_reg[1][0];
						CMD_FILE_WRITE_START: cur_file <= cmd_reg[1];
						CMD_FILE_WRITE_END: begin
							case (cmd_reg[1])
								FILE_ISO: begin
									disc_present <= (cmd_reg[2] != 0);
									disc_bytes   <= (cmd_reg[2] > ISO_MAX_BYTES) ? 25'(ISO_MAX_BYTES) : cmd_reg[2][24:0];
								end
								FILE_BIOS:  bios_loaded  <= 1;
								FILE_KANJI: kanji_loaded <= 1;
								FILE_NVRAM: nvram_written <= 1;
								default: ;
							endcase
							cur_file <= '1;
						end
						CMD_FILE_READ_START: begin
							case (cmd_reg[1])
								FILE_NVRAM: cmd_reg[0] <= NVRAM_BYTES;
								default:    cmd_state <= 2'd3;
							endcase
						end
						CMD_FILE_READ_END: ;
						default: cmd_state <= 2'd3;
					endcase
				end
			end else begin
				cmd_state <= 2'd0;
			end
		end
	end
endmodule
