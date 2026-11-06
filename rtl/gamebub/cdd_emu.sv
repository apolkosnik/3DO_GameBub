// CD drive back end for the 3DO core on Game Bub.
//
// On MiSTer the 3DO CD-ROM controller (3DO_CDROM.sv) talks to the ARM HPS
// (Main_MiSTer support/3do/3docdd.cpp), which reads sectors from the SD card
// and downloads them through ioctl. Game Bub cannot stream files from the
// microSD card, so the whole ISO image (2048-byte sectors) is preloaded into
// SDRAM by the host, and this module does what the HPS code did:
//
//  * on disc insertion, send the 2 KiB disc-info block (CDD_DIEN): disc type,
//    track list in binary MSF, and the first 128 bytes of sector 0;
//  * READ (0x10) / NEXT (0x20) requests from the controller: send one sector
//    per request (CDD_DTEN), 1024 data words + 1 checksum word, LBA = cmd-150,
//    one sector every SECTOR_DELAY system clocks (MiSTer: one per 3 ms poll).
//
// Clock domains: the command / ioctl side runs on clk_sys, the SDRAM fetch on
// clk_mem. A dual-clock sector buffer and toggle handshakes connect them.
//
// Copyright (c) 2026 Adam Polkosnik. Protocol from the MiSTer 3DO core and
// Main_MiSTer (srg320, sorgelig), GPL-3.0.
// SPDX-License-Identifier: GPL-3.0-or-later

module cdd_emu (
	input              clk_sys,
	input              rst_sys,          // core reset (clk_sys)
	input      [31: 0] sector_delay,     // clk_sys cycles between sectors
	input              host_le,          // host file byte order (see gb_host.sv)

	// disc image description (clk_sys, static while disc_present)
	input              disc_present,
	input      [24: 0] disc_bytes,       // ISO size in bytes (multiple of 2048)
	output reg [31: 0] disc_id,          // bytes 0x58..0x5B of sector 0 (MiSTer hack table key)
	output reg [31: 0] disc_msf,         // bytes 4..7 of the info block
	output reg         disc_info_valid,

	// P3DO_CDROM side (clk_sys)
	input      [64: 0] cd_comm,          // {toggle, HOST_COMM[7..0]}
	output reg [15: 0] CDD_DATA,
	output reg         CDD_WR,
	output reg         CDD_DTEN,
	output reg         CDD_DIEN,

	// SDRAM secondary port client (clk_mem)
	input              clk_mem,
	input              rst_mem,
	output reg         sec_req,
	output             sec_we,
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

	assign sec_we    = 1'b0;
	assign sec_len   = 10'd512;
	assign sec_wdata = '0;
	assign sec_wbe   = '0;

	// ------------------------------------------------------------------
	// Sector buffer: 1024 x 16, written in clk_mem, read in clk_sys.
	// Holds SDRAM words (big-endian byte pairs).
	// ------------------------------------------------------------------
	// Converts a buffer word to the ioctl word format P3DO_CDROM expects
	// ({byte 2k+1, byte 2k}); see gb_host.sv for the storage order.
	//   big-endian host   : word k = bswap(sbuf[k])
	//   little-endian host: word k = sbuf[k ^ 1]
	function automatic [15:0] cddw(input [15:0] q, input le);
		cddw = le ? q : {q[7:0], q[15:8]};
	endfunction
	function automatic [9:0] cdda(input [9:0] k, input le);
		cdda = le ? {k[9:1], ~k[0]} : k;
	endfunction

	(* ram_style = "block" *) reg [15:0] sbuf [0:1023];
	reg  [ 9:0] sbuf_wa;
	reg  [ 9:0] sbuf_ra;
	reg  [15:0] sbuf_q;
	always @(posedge clk_mem) if (sec_rvalid && sec_req) sbuf[sbuf_wa] <= sec_rdata;
	always @(posedge clk_sys) sbuf_q <= sbuf[sbuf_ra];

	// ------------------------------------------------------------------
	// clk_mem: fetch one 2048-byte sector (two SDRAM rows)
	// ------------------------------------------------------------------
	reg        fetch_tgl_sys;           // clk_sys -> clk_mem
	reg [14:0] fetch_lba_sys;           // sector index (0..ISO_MAX_SECTORS-1)
	reg        done_tgl_mem;            // clk_mem -> clk_sys

	reg [2:0]  ftgl_s;
	typedef enum bit [1:0] { M_IDLE, M_ROW0, M_GAP, M_ROW1 } mstate_t;
	mstate_t mst;
	always @(posedge clk_mem) begin
		ftgl_s <= {ftgl_s[1:0], fetch_tgl_sys};
		if (rst_mem) begin
			sec_req      <= 0;
			done_tgl_mem <= 0;
			mst          <= M_IDLE;
		end else begin
			if (sec_req && sec_rvalid) sbuf_wa <= sbuf_wa + 1'd1;
			case (mst)
				M_IDLE: if (ftgl_s[2] != ftgl_s[1]) begin
					// fetch_lba_sys was written well before the toggle: stable
					sec_addr <= iso_word_addr({fetch_lba_sys[13:0], 10'd0});
					sbuf_wa  <= '0;
					sec_req  <= 1;
					mst <= M_ROW0;
				end
				M_ROW0: if (sec_done) begin
					sec_req <= 0;           // let the arbiter release the grant
					mst <= M_GAP;
				end
				M_GAP: begin
					sec_addr <= iso_word_addr({fetch_lba_sys[13:0], 10'd512});
					sec_req  <= 1;
					mst <= M_ROW1;
				end
				M_ROW1: if (sec_done) begin
					sec_req      <= 0;
					done_tgl_mem <= ~done_tgl_mem;
					mst <= M_IDLE;
				end
			endcase
		end
	end

	// ------------------------------------------------------------------
	// clk_sys: command handling and ioctl-style download to P3DO_CDROM
	// ------------------------------------------------------------------
	reg [2:0] dtgl_s;
	wire      fetch_done = dtgl_s[2] != dtgl_s[1];

	typedef enum bit [3:0] {
		C_IDLE,
		C_INFO_FETCH,
		C_INFO_WAIT,
		C_INFO_SEND,
		C_INFO_END,
		C_SEC_DELAY,
		C_SEC_FETCH,
		C_SEC_WAIT,
		C_SEC_SEND,
		C_SEC_CRC,
		C_SEC_END
	} cstate_t;
	cstate_t cst;

	reg        comm_tgl_old;
	reg [ 7:0] comm [8];
	reg        cmd_new;
	reg [23:0] cur_lba;          // signed-ish: may start "negative" (pregap) -> clamp to 0
	reg [15:0] blocks_left;
	reg        read_pend;
	reg [31:0] delay_cnt;
	reg [10:0] widx;             // word index while sending
	reg [15:0] crc;
	reg        info_sent;
	reg [14:0] disc_sectors;
	reg [ 1:0] rd_phase;         // 3-cycle cadence: set address, BRAM latency, use data
	reg        zero_sector;

	// MSF of an absolute LBA (binary, like LBAToMSF in 3docdd.cpp)
	function automatic [23:0] lba2msf(input [23:0] lba);
		bit [23:0] secs;
		secs = lba / 75;
		lba2msf = {8'(secs / 60), 8'(secs % 60), 8'(lba % 75)};
	endfunction

	wire [23:0] leadout_msf = lba2msf({9'd0, disc_sectors} + 24'd150);

	// Disc-info block byte (GetDiscInfo in 3docdd.cpp)
	function automatic [7:0] info_byte(input [10:0] a, input [23:0] lo_msf, input [15:0] s0word);
		info_byte = 8'h00;
		case (a)
			11'h001: info_byte = 8'h00;           // P3DO_DISC_DA_OR_CDROM
			11'h002: info_byte = 8'h01;           // first track
			11'h003: info_byte = 8'h01;           // last track
			11'h004: info_byte = lo_msf[23:16];
			11'h005: info_byte = lo_msf[15: 8];
			11'h006: info_byte = lo_msf[ 7: 0];
			// track 1: data track at 00:02:00
			11'h012: info_byte = 8'h04;
			11'h013: info_byte = 8'h01;
			11'h015: info_byte = 8'h00;
			11'h016: info_byte = 8'h02;
			11'h017: info_byte = 8'h00;
			// "track 2" entry = lead-out (toc.tracks[last])
			11'h022: info_byte = 8'h00;
			11'h023: info_byte = 8'h02;
			11'h025: info_byte = lo_msf[23:16];
			11'h026: info_byte = lo_msf[15: 8];
			11'h027: info_byte = lo_msf[ 7: 0];
			default: begin
				if (a >= 11'h400 && a < 11'h480) info_byte = a[0] ? s0word[15:8] : s0word[7:0];
			end
		endcase
	endfunction

	always @(posedge clk_sys) begin
		dtgl_s <= {dtgl_s[1:0], done_tgl_mem};
		CDD_WR <= 0;
		cmd_new <= 0;

		if (rst_sys) begin
			cst          <= C_IDLE;
			CDD_DTEN     <= 0;
			CDD_DIEN     <= 0;
			read_pend    <= 0;
			blocks_left  <= '0;
			comm_tgl_old <= cd_comm[64];
			info_sent    <= 0;
			disc_info_valid <= 0;
		end else begin
			disc_sectors <= {1'b0, disc_bytes[24:11]};

			// New command from the controller (CD_IN_MSB toggled)
			if (cd_comm[64] != comm_tgl_old) begin
				comm_tgl_old <= cd_comm[64];
				comm[0] <= cd_comm[ 7: 0]; comm[1] <= cd_comm[15: 8];
				comm[2] <= cd_comm[23:16]; comm[3] <= cd_comm[31:24];
				comm[4] <= cd_comm[39:32]; comm[5] <= cd_comm[47:40];
				comm[6] <= cd_comm[55:48]; comm[7] <= cd_comm[63:56];
				cmd_new <= 1;
			end
			if (cmd_new) begin
				case (comm[0])
					8'h00: ; // NOP
					8'h10: begin // READ
						bit [23:0] l;
						if (comm[4] != 0) l = {comm[1], comm[2], comm[3]};
						else              l = comm[1] * 24'd4500 + comm[2] * 24'd75 + comm[3];
						cur_lba     <= l - 24'd150;
						blocks_left <= {comm[5], comm[6]};
						read_pend   <= 1;
					end
					8'h20: begin // NEXT
						if (blocks_left != 0) read_pend <= 1;
					end
					default: read_pend <= 0;
				endcase
			end

			case (cst)
				C_IDLE: begin
					if (disc_present && !info_sent) begin
						fetch_lba_sys <= '0;
						fetch_tgl_sys <= ~fetch_tgl_sys;
						cst <= C_INFO_WAIT;
					end else if (read_pend && info_sent) begin
						delay_cnt <= sector_delay;
						cst <= C_SEC_DELAY;
					end
				end

				// ---- disc-info block ----
				C_INFO_WAIT: if (fetch_done) begin
					// MiSTer hack-table key and MSF, as 3DO.sv extracts them
					disc_msf <= {leadout_msf, 8'h00};
					CDD_DIEN <= 1;
					widx     <= '0;
					sbuf_ra  <= 10'd0;
					rd_phase <= '0;
					cst <= C_INFO_SEND;
				end

				C_INFO_SEND: begin
					// one word every two cycles; sector-0 data comes from sbuf
					rd_phase <= (rd_phase == 2'd2) ? 2'd0 : rd_phase + 1'd1;
					if (rd_phase == 2'd0) begin
						sbuf_ra <= (widx >= 11'h200 && widx < 11'h240) ? cdda(10'(widx - 11'h200), host_le) : 10'd0;
					end else if (rd_phase == 2'd2) begin
						bit [15:0] cw;
						cw = cddw(sbuf_q, host_le);
						CDD_DATA <= {info_byte({widx[9:0], 1'b1}, leadout_msf, cw),
						             info_byte({widx[9:0], 1'b0}, leadout_msf, cw)};
						CDD_WR   <= 1;
						if (widx == 11'h22C) disc_id[31:16] <= {cw[7:0], cw[15:8]};   // sector0 bytes 0x58,0x59
						if (widx == 11'h22D) disc_id[15: 0] <= {cw[7:0], cw[15:8]};   // sector0 bytes 0x5A,0x5B
						widx <= widx + 1'd1;
						if (widx == 11'h3FF) cst <= C_INFO_END;
					end
				end

				C_INFO_END: begin
					CDD_DIEN  <= 0;
					info_sent <= 1;
					disc_info_valid <= 1;
					cst <= C_IDLE;
				end

				// ---- data sectors ----
				C_SEC_DELAY: begin
					if (!read_pend) cst <= C_IDLE;
					else if (delay_cnt) delay_cnt <= delay_cnt - 1'd1;
					else begin
						bit [23:0] l;
						l = cur_lba[23] ? 24'd0 : cur_lba;  // pregap reads sector 0 (3docdd.cpp)
						zero_sector   <= (l >= {9'd0, disc_sectors});
						fetch_lba_sys <= l[14:0];
						fetch_tgl_sys <= ~fetch_tgl_sys;
						read_pend     <= 0;
						cst <= C_SEC_WAIT;
					end
				end

				C_SEC_WAIT: if (fetch_done) begin
					CDD_DTEN <= 1;
					widx     <= '0;
					crc      <= '0;
					sbuf_ra  <= 10'd0;
					rd_phase <= '0;
					cst <= C_SEC_SEND;
				end

				C_SEC_SEND: begin
					rd_phase <= (rd_phase == 2'd2) ? 2'd0 : rd_phase + 1'd1;
					if (rd_phase == 2'd0) begin
						sbuf_ra <= cdda(widx[9:0], host_le);
					end else if (rd_phase == 2'd2) begin
						bit [15:0] w;
						w = zero_sector ? 16'h0000 : cddw(sbuf_q, host_le);
						CDD_DATA <= w;                     // ioctl order: low byte first
						CDD_WR   <= 1;
						crc  <= crc + w[15:8] + w[7:0];
						widx <= widx + 1'd1;
						if (widx == 11'h3FF) cst <= C_SEC_CRC;
					end
				end

				C_SEC_CRC: begin
					rd_phase <= rd_phase + 1'd1;
					if (rd_phase == 2'd1) begin
						CDD_DATA <= crc;
						CDD_WR   <= 1;
						cst <= C_SEC_END;
					end
				end

				C_SEC_END: begin
					CDD_DTEN    <= 0;
					cur_lba     <= cur_lba + 1'd1;
					blocks_left <= blocks_left - 1'd1;
					cst <= C_IDLE;
				end

				default: cst <= C_IDLE;
			endcase
		end
	end
endmodule
