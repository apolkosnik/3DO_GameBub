`include "gb3do_pkg.svh"
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

	// Streaming mode (fork firmware "disc" file, docs/disc_streaming.md):
	// the host wrote the image's table of contents instead of the data, and
	// raw 2352-byte sectors are read on request (DISC_READ).
	input              disc_stream,
	input              disc_change,      // pulse: a disc was loaded (or swapped while running)
	input              toc_we,
	input      [ 8: 0] toc_wa,
	input      [31: 0] toc_wd,
	input              sb_we,
	input      [ 9: 0] sb_wa,
	input      [31: 0] sb_wd,
	output     [31: 0] core_cmd_words [4],
	output reg         core_req,         // HostV0 commandCore
	input              core_done,
	input              core_error,
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
		C_SEC_END,
		C_STR_WAIT
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
	reg        q_got;            // streaming: the requested sector has arrived
	reg        str_cancel;       // streaming: a new command came while waiting

	// ------------------------------------------------------------------
	// Streaming mode: table of contents, sector buffer, DISC_READ requests
	// ------------------------------------------------------------------
	localparam [31:0] CMD_DISC_READ   = 32'h0000_0400;
	localparam [31:0] SECTOR_BUF_ADDR = 32'h4000_0000;   // host address of sbr

	// Table of contents (fork firmware DiscImage::toc, little-endian words):
	//   0: track count (7:0); 1: lead-out LBA; 2: lead-out position BCD 00MMSSFF
	//   4+4n: first LBA, 5+4n: last LBA, 6+4n: index 1 LBA,
	//   7+4n: index 1 position BCD 00MMSSFF, bit 31 = audio track
	reg [31:0] tocr [0:511];
	reg [31:0] toc_q;
	reg [ 8:0] toc_ra;
	reg [ 7:0] toc_tracks;
	reg [23:0] toc_leadout_bcd;
	always @(posedge clk_sys) begin
		if (toc_we) tocr[toc_wa] <= toc_wd;
		toc_q <= tocr[toc_ra];
	end
	// A real table of contents has 1..99 tracks, also given in BCD. (With
	// firmware that does not know "disc" files, a .cue would arrive as text.)
	reg        toc_valid;
	always @(posedge clk_sys) begin
		if (toc_we && toc_wa == 9'd0) begin
			toc_tracks <= toc_wd[7:0];
			toc_valid  <= toc_wd[7:0] >= 8'd1 && toc_wd[7:0] <= 8'd99 &&
			              toc_wd[15:8] == {4'(toc_wd[7:0] / 10), 4'(toc_wd[7:0] % 10)};
		end
		if (toc_we && toc_wa == 9'd2) toc_leadout_bcd <= toc_wd[23:0];
	end

	// Raw sector buffer (588 words used), written by the host
	(* ram_style = "block" *) reg [31:0] sbr [0:1023];
	reg [31:0] sbr_q;
	reg [ 9:0] sbr_ra;
	always @(posedge clk_sys) begin
		if (sb_we) sbr[sb_wa] <= sb_wd;
		sbr_q <= sbr[sbr_ra];
	end
	// word k ({byte 2k+1, byte 2k}) of a sector's 2048 user data bytes
	// (raw bytes 16.., little-endian host words as the fork firmware sends)
	function automatic [9:0] user_addr(input [9:0] k);
		user_addr = 10'd4 + {1'b0, k[9:1]};
	endfunction
	function automatic [15:0] user_word(input [31:0] q, input bit hi);
		user_word = hi ? q[31:16] : q[15:0];
	endfunction

	// Core -> host request (the same handshake as the fork's PSX core):
	// raise request with the words set, wait for done or error, drop the
	// request, wait for done and error to clear.
	typedef enum bit [1:0] { Q_IDLE, Q_WAIT, Q_CLEAR } qstate_t;
	qstate_t   qst;
	reg [31:0] q_lba;
	reg        q_start;          // pulse from the main FSM (latched in q_pend)
	reg        q_pend;
	reg        q_finished;       // pulse: answered (q_failed says how)
	reg        q_failed;
	reg [27:0] q_timer;
	assign core_cmd_words[0] = CMD_DISC_READ;
	assign core_cmd_words[1] = 32'd0;            // disc file id
	assign core_cmd_words[2] = q_lba;            // absolute LBA (track 1 at 150)
	assign core_cmd_words[3] = SECTOR_BUF_ADDR;

	always @(posedge clk_sys) begin
		q_finished <= 0;
		if (rst_sys) begin
			// a request may still be answered after a reset: start by
			// waiting for the answer to clear
			core_req <= 0;
			q_pend   <= 0;
			qst <= Q_CLEAR;
		end else begin
			if (q_start) q_pend <= 1;
			case (qst)
				Q_IDLE: if (q_pend) begin
					q_pend   <= 0;
					core_req <= 1;
					q_timer  <= '0;
					qst <= Q_WAIT;
				end
				Q_WAIT: begin
					q_timer <= q_timer + 1'd1;
					if (core_done || core_error || &q_timer) begin
						// no answer in ~5 s (e.g. stock firmware): fail
						q_failed   <= !core_done;
						q_finished <= 1;
						core_req   <= 0;
						qst <= Q_CLEAR;
					end
				end
				Q_CLEAR: if (!core_done && !core_error) qst <= Q_IDLE;
				default: qst <= Q_IDLE;
			endcase
		end
	end

	function automatic [7:0] bcd2bin(input [7:0] x);
		bcd2bin = x[7:4] * 8'd10 + x[3:0];
	endfunction

	// Disc-info word k ({byte 2k+1, byte 2k}) from the table of contents
	// (GetDiscInfo in 3docdd.cpp; positions in binary MSF). For track
	// entries `t` is TOC word 7+4i (or the lead-out position word).
	function automatic [15:0] info_word_toc(input [9:0] k, input [7:0] ntr, input [23:0] lo_bcd,
	                                        input [31:0] t, input [15:0] sw);
		bit [7:0] m, sec, f, e;
		info_word_toc = 16'h0000;
		if (k == 10'd1) info_word_toc = {ntr, 8'h01};                          // first, last track
		else if (k == 10'd2) info_word_toc = {bcd2bin(lo_bcd[15:8]), bcd2bin(lo_bcd[23:16])};
		else if (k == 10'd3) info_word_toc = {8'h00, bcd2bin(lo_bcd[7:0])};
		else if (k >= 10'd8 && k < 10'd512) begin
			e = 8'(k[9:3]) - 8'd1;                                             // entry: track e+1
			if (e <= ntr) begin
				m = bcd2bin(t[23:16]); sec = bcd2bin(t[15:8]); f = bcd2bin(t[7:0]);
				case (k[2:0])
					3'd1: info_word_toc = {8'(e + 8'd1), (e == ntr || t[31]) ? 8'h00 : 8'h04};
					3'd2: info_word_toc = {m, 8'h00};
					3'd3: info_word_toc = {f, sec};
					default: ;
				endcase
			end
		end
		else if (k >= 10'd512 && k < 10'd576) info_word_toc = sw;              // sector 0, bytes 0..127
	endfunction

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

		q_start <= 0;
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

			// a disc was loaded or swapped: send its info block again (the
			// controller then reports a media change, as on MiSTer)
			if (disc_change) begin
				info_sent <= 0;
				read_pend <= 0;
			end

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
					if (disc_present && !info_sent && (!disc_stream || toc_valid)) begin
						if (disc_stream) begin
							q_lba   <= 32'd150;          // sector 0 of track 1
							q_start <= 1;
						end else begin
							fetch_lba_sys <= '0;
							fetch_tgl_sys <= ~fetch_tgl_sys;
						end
						cst <= C_INFO_WAIT;
					end else if (read_pend && info_sent) begin
						delay_cnt <= sector_delay;
						if (disc_stream) begin
							// request now, so the firmware's latency overlaps the
							// drive's sector time
							bit [23:0] l;
							l = cur_lba[23] ? 24'd0 : cur_lba;  // pregap reads sector 0 (3docdd.cpp)
							q_lba      <= {8'd0, l} + 32'd150;   // absolute LBA
							q_start    <= 1;
							q_got      <= 0;
							str_cancel <= 0;
							read_pend  <= 0;
							cst <= C_STR_WAIT;
						end else begin
							cst <= C_SEC_DELAY;
						end
					end
				end

				// ---- disc-info block ----
				C_INFO_WAIT: if (disc_stream ? q_finished : fetch_done) begin
					// MiSTer hack-table key and MSF, as 3DO.sv extracts them
					disc_msf <= disc_stream ? {bcd2bin(toc_leadout_bcd[23:16]), bcd2bin(toc_leadout_bcd[15:8]),
					                           bcd2bin(toc_leadout_bcd[7:0]), 8'h00} : {leadout_msf, 8'h00};
					zero_sector <= disc_stream && q_failed;
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
						sbr_ra  <= user_addr(10'(widx - 11'h200));
						// TOC word of the track entry this info word belongs to
						toc_ra  <= (8'(widx[9:3]) - 8'd1 >= toc_tracks) ? 9'd2 : 9'(7 + 4 * (widx[9:3] - 1));
					end else if (rd_phase == 2'd2) begin
						bit [15:0] cw;
						cw = disc_stream ? (zero_sector ? 16'h0000 : user_word(sbr_q, widx[0])) : cddw(sbuf_q, host_le);
						if (disc_stream)
							CDD_DATA <= info_word_toc(widx[9:0], toc_tracks, toc_leadout_bcd,
							                          (8'(widx[9:3]) - 8'd1 >= toc_tracks) ? {8'h00, toc_leadout_bcd} : toc_q, cw);
						else
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

				// streaming: sector time and the firmware's answer, whichever
				// comes last. A command in between (a new READ, a stop) drops
				// the sector, as MiSTer's next poll would.
				C_STR_WAIT: begin
					if (delay_cnt) delay_cnt <= delay_cnt - 1'd1;
					if (cmd_new && comm[0] != 8'h00) str_cancel <= 1;
					if (q_finished) begin
						q_got       <= 1;
						zero_sector <= q_failed;              // a failed read reads as zeros
					end
					if (q_got && delay_cnt == 0) begin
						if (str_cancel || disc_change) cst <= C_IDLE;
						else begin
							CDD_DTEN <= 1;
							widx     <= '0;
							crc      <= '0;
							rd_phase <= '0;
							cst <= C_SEC_SEND;
						end
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
						sbr_ra  <= user_addr(widx[9:0]);
					end else if (rd_phase == 2'd2) begin
						bit [15:0] w;
						w = zero_sector ? 16'h0000 : disc_stream ? user_word(sbr_q, widx[0]) : cddw(sbuf_q, host_le);
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
