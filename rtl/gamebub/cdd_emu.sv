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
//    per request (CDD_DTEN), blk_len bytes as words + 1 checksum word, LBA =
//    cmd-150, one sector every SECTOR_DELAY system clocks (MiSTer: one per
//    3 ms poll).
//
// CD-DA (streaming mode): the BIOS's audio CD player sets the block length
// to 2352 (Set Mode, P3DO_CDROM) and reads audio sectors through the data
// path, as from a real drive (SataTo3DO's drive emulation). A block is taken
// from the raw 2352-byte sector: 2048 bytes are the MODE1 user data (bytes
// 16..), a shorter raw block ends with the sector (2340: bytes 12..), 2352 is
// the whole sector, and the 2353/2448/2449-byte formats (error flags,
// subcode) end in zeros. Audio sectors come at the drive's real rate, 75 per
// second (150 at double speed), as a real drive streams them: a sector clock
// runs at that rate and each audio sector takes one of its ticks. A READ that
// continues the stream (the player reads 8 blocks at a time) keeps the clock,
// so neither the time between two READs nor the 3DO's time to read a block
// slows playback down, and up to 8 ticks are kept, so a sector the firmware
// sends late is made up by the next ones. A READ elsewhere (a seek) restarts
// the clock: its first sector comes one sector time later (or, if later, when
// it has arrived: the clock waits for it).
//
// Read-ahead (streaming): sectors come from a ring of 13 raw sectors in block
// RAM, which DISC_READ requests fill one at a time, back to back: to the end
// of the READ, and while audio streams, as far ahead as the ring has room
// (173 ms at 1x). The firmware's latency (an SD read, a file opened at a
// track boundary) then overlaps playback instead of delaying a sector. A READ
// of a sector that is not next in the ring (a seek) restarts it there. The
// track
// table taken from the TOC gives each sector's track, index and audio flag,
// and the Sub-Q position the controller reports (Read Sub-Q, 87).
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
	input      [12: 0] sb_wa,            // word in the sector ring (0x4000_0000..0x4000_7FFF)
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
	input      [11: 0] blk_len,          // bytes per block (Set Mode density)
	input              speed2x,          // double speed (Set Mode speed)
	output reg [71: 0] subq,             // {ctrl, track, index, abs M S F, rel M S F}, binary
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
		C_STR_POS,
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
	reg        str_cancel;       // streaming: a new command came while waiting
	reg        sec_audio;        // the sector being read is CD-DA
	reg [10:0] sec_words;        // words in the block being sent
	reg [11:0] sec_off;          // raw sector byte of its first word
	reg [11:0] sec_b;            // raw sector byte of the word being sent
	// Audio sector clock: clocks until its next tick, at 50 MHz / 75 (or /
	// 150) with the fraction spread over three ticks; acredit counts the
	// ticks not yet taken by a sector (at most ACREDIT_MAX); astream: the
	// last sector sent was audio, so a READ of the next sector continues
	// the stream
	localparam bit [3:0] ACREDIT_MAX = 4'd8;
	reg [19:0] apace;
	reg [ 1:0] apace_ph;
	reg [ 3:0] acredit;
	reg        astream;
	// Read-ahead ring (streaming): rb_cnt sectors from absolute LBA rb_lba,
	// in slots rb_head, rb_head + 1, ... (mod RB_SLOTS). One DISC_READ at a
	// time (pf_busy) fills the next slot (pf_slot); pf_discard: a flush made
	// the one in flight stale. Sectors are fetched up to pf_end (the end of
	// the READ), and, while audio streams, as far ahead as the ring has room.
	reg        rb_on;
	reg [23:0] rb_lba;
	reg [ 3:0] rb_head, rb_cnt;
	reg [15:0] rb_fail;          // slot s: its DISC_READ failed (reads as zeros)
	reg        pf_busy, pf_discard;
	reg [ 3:0] pf_slot;
	reg [23:0] pf_end;
	reg [12:0] rd_base;          // first word of the slot being sent
	reg [23:0] snd_lba;          // absolute LBA of the sector being sent
	wire        a_tick_ok = astream || rb_cnt != 0;
	wire [19:0] apace_period = speed2x ? ((apace_ph == 2'd2) ? 20'd333_334 : 20'd333_333)
	                                   : ((apace_ph == 2'd2) ? 20'd666_666 : 20'd666_667);

	// ------------------------------------------------------------------
	// Streaming mode: table of contents, sector buffer, DISC_READ requests
	// ------------------------------------------------------------------
	localparam [31:0] CMD_DISC_READ   = 32'h0000_0400;
	localparam [31:0] SECTOR_BUF_ADDR = 32'h4000_0000;   // host address of sbr, slot 0
	// Read-ahead: RB_SLOTS raw sectors, slot s at word 588 s of sbr (host
	// address SECTOR_BUF_ADDR + 2352 s)
	localparam int    RB_SLOTS = 13;
	localparam [9:0]  SLOT_WORDS = 10'd588;

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

	// Track table (streaming): first LBA, index 1 LBA and audio flag of each
	// track, from TOC words 4+4n, 6+4n and 7+4n (absolute LBAs)
	reg [23:0] trk_first [0:127];
	reg [23:0] trk_idx1  [0:127];
	reg        trk_audio [0:127];
	wire [8:0] toc_wa_t = toc_wa - 9'd4;
	always @(posedge clk_sys) begin
		if (toc_we && toc_wa >= 9'd4)
			case (toc_wa_t[1:0])
				2'd0: trk_first[toc_wa_t[8:2]] <= toc_wd[23:0];
				2'd2: trk_idx1 [toc_wa_t[8:2]] <= toc_wd[23:0];
				2'd3: trk_audio[toc_wa_t[8:2]] <= toc_wd[31];
				default: ;
			endcase
	end

	// Position lookup: track, index, audio flag and Sub-Q times of absolute
	// LBA pl_lba (pl_start: start, pl_done: subq and pl_audio valid). The
	// tracks are scanned one per cycle, the times converted to MSF by
	// subtraction (at most 99 + 59 steps). A preloaded ISO is one data track.
	reg        pl_start, pl_done, pl_audio;
	reg [23:0] pl_lba;
	typedef enum bit [1:0] { P_IDLE, P_SCAN, P_TIME, P_MSF } pstate_t;
	pstate_t   pst;
	reg [ 6:0] pl_t, pl_hit;
	reg [ 7:0] pl_idx;
	reg [23:0] pa_v, pr_v;               // abs / rel time left to convert
	reg [ 7:0] pa_m, pa_s, pr_m, pr_s;
	wire [6:0] pl_ntr = disc_stream ? toc_tracks[6:0] : 7'd1;
	wire [23:0] pl_first = disc_stream ? trk_first[pl_t] : 24'd150;
	wire [23:0] pl_i1    = disc_stream ? trk_idx1[pl_hit] : 24'd150;
	wire        pl_aud   = disc_stream ? trk_audio[pl_hit] : 1'b0;
	always @(posedge clk_sys) begin
		pl_done <= 0;
		if (rst_sys) begin
			pst  <= P_IDLE;
			subq <= {8'h04, 8'd1, 8'd1, 8'd0, 8'd2, 8'd0, 24'd0};
		end else case (pst)
			P_IDLE: if (pl_start) begin
				pl_t   <= 7'd0;
				pl_hit <= 7'd0;
				pst <= P_SCAN;
			end
			P_SCAN: begin
				// the last track that starts at or before the LBA
				if (pl_first <= pl_lba) pl_hit <= pl_t;
				if (pl_t + 7'd1 >= pl_ntr || pl_first > pl_lba) pst <= P_TIME;
				else pl_t <= pl_t + 7'd1;
			end
			P_TIME: begin
				// relative time: from index 1, counted down in the pregap
				// (index 0)
				pl_idx <= (pl_lba >= pl_i1) ? 8'd1 : 8'd0;
				pr_v   <= (pl_lba >= pl_i1) ? pl_lba - pl_i1 : pl_i1 - pl_lba;
				pa_v   <= pl_lba;
				{pa_m, pa_s, pr_m, pr_s} <= '0;
				pl_audio <= pl_aud;
				pst <= P_MSF;
			end
			P_MSF: begin
				bit a_done, r_done;
				a_done = pa_v < 24'd75;
				r_done = pr_v < 24'd75;
				if (pa_v >= 24'd4500) begin pa_v <= pa_v - 24'd4500; pa_m <= pa_m + 8'd1; end
				else if (!a_done)     begin pa_v <= pa_v - 24'd75;   pa_s <= pa_s + 8'd1; end
				if (pr_v >= 24'd4500) begin pr_v <= pr_v - 24'd4500; pr_m <= pr_m + 8'd1; end
				else if (!r_done)     begin pr_v <= pr_v - 24'd75;   pr_s <= pr_s + 8'd1; end
				if (a_done && r_done) begin
					subq <= {pl_audio ? 8'h00 : 8'h04, 8'(pl_hit) + 8'd1, pl_idx,
					         pa_m, pa_s, pa_v[7:0], pr_m, pr_s, pr_v[7:0]};
					pl_done <= 1;
					pst <= P_IDLE;
				end
			end
		endcase
	end

	// Raw sector ring (RB_SLOTS x 588 words), written by the host
	(* ram_style = "block" *) reg [31:0] sbr [0:8191];
	reg [31:0] sbr_q;
	reg [12:0] sbr_ra;
	always @(posedge clk_sys) begin
		if (sb_we) sbr[sb_wa] <= sb_wd;
		sbr_q <= sbr[sbr_ra];
	end
	// word k ({byte 2k+1, byte 2k}) of a sector's 2048 user data bytes
	// (raw bytes 16.., little-endian host words as the fork firmware sends)
	function automatic [9:0] user_addr(input [9:0] k);
		user_addr = 10'd4 + {1'b0, k[9:1]};
	endfunction
	// first word of a ring slot
	function automatic [12:0] slot_base(input [3:0] slot);
		slot_base = 13'(slot) * 13'(SLOT_WORDS);
	endfunction
	function automatic [15:0] user_word(input [31:0] q, input bit hi);
		user_word = hi ? q[31:16] : q[15:0];
	endfunction
	// Block word k is raw sector bytes sec_off + 2k, sec_off + 2k + 1 (bytes
	// past the 2352 of the sector are zeros)
	function automatic [11:0] raw_byte_addr(input [11:0] off, input [10:0] k);
		raw_byte_addr = off + {k, 1'b0};
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
	reg [31:0] q_addr;           // host address of the slot it fills
	assign core_cmd_words[0] = CMD_DISC_READ;
	assign core_cmd_words[1] = 32'd0;            // disc file id
	assign core_cmd_words[2] = q_lba;            // absolute LBA (track 1 at 150)
	assign core_cmd_words[3] = q_addr;

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
		bit a_send, a_seek, r_flush, r_pop;
		bit [23:0] r_flush_lba;
		a_send = 0;
		a_seek = 0;
		r_flush = 0;
		r_pop = 0;
		r_flush_lba = '0;
		dtgl_s <= {dtgl_s[1:0], done_tgl_mem};
		CDD_WR <= 0;
		cmd_new <= 0;

		q_start <= 0;
		pl_start <= 0;
		// the sector clock ticks at apace == 0; the first tick after a seek
		// waits for the sector to be in the ring
		if (apace != 0) apace <= apace - 1'd1;
		else if (a_tick_ok) begin
			apace    <= apace_period - 20'd1;
			apace_ph <= (apace_ph == 2'd2) ? 2'd0 : apace_ph + 1'd1;
		end
		if (rst_sys) begin
			cst          <= C_IDLE;
			apace        <= '0;
			apace_ph     <= '0;
			acredit      <= '0;
			astream      <= 0;
			rb_on        <= 0;
			rb_head      <= '0;
			rb_cnt       <= '0;
			pf_busy      <= 0;
			pf_discard   <= 0;
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
						// a seek: the first sector after one sector time
						if (!astream || l - 24'd150 != cur_lba) a_seek = 1;
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
							r_flush     = 1;              // sector 0 of track 1
							r_flush_lba = 24'd150;
							pf_end     <= 24'd151;
						end else begin
							fetch_lba_sys <= '0;
							fetch_tgl_sys <= ~fetch_tgl_sys;
						end
						cst <= C_INFO_WAIT;
					end else if (read_pend && info_sent) begin
						delay_cnt <= sector_delay;
						// block geometry (Set Mode is not sent during a read)
						sec_words <= 11'((blk_len + 12'd1) >> 1);
						sec_off   <= (blk_len == 12'd2048) ? 12'd16 :
						             (blk_len >= 12'd2352) ? 12'd0  : ((12'd2352 - blk_len) & 12'hFFE);
						if (disc_stream) begin
							// the sector's track (audio or data); the sector comes
							// from the ring. Not there (a seek): the ring restarts
							// at it, so the firmware's latency overlaps the drive's
							// seek time. The ring reads ahead to the end of the READ.
							bit [23:0] l;
							l = (cur_lba[23] ? 24'd0 : cur_lba) + 24'd150;  // pregap reads sector 0 (3docdd.cpp)
							if (!rb_on || rb_lba != l) begin
								r_flush     = 1;
								r_flush_lba = l;
							end
							pf_end     <= l + ((blocks_left == 0) ? 24'd1 : 24'(blocks_left));
							pl_lba     <= l;
							pl_start   <= 1;
							str_cancel <= 0;
							read_pend  <= 0;
							cst <= C_STR_POS;
						end else begin
							cst <= C_SEC_DELAY;
						end
					end
				end

				// ---- disc-info block ----
				C_INFO_WAIT: if (disc_stream ? rb_cnt != 0 : fetch_done) begin
					// MiSTer hack-table key and MSF, as 3DO.sv extracts them
					disc_msf <= disc_stream ? {bcd2bin(toc_leadout_bcd[23:16]), bcd2bin(toc_leadout_bcd[15:8]),
					                           bcd2bin(toc_leadout_bcd[7:0]), 8'h00} : {leadout_msf, 8'h00};
					zero_sector <= disc_stream && rb_fail[rb_head];
					rd_base  <= slot_base(rb_head);
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
						sbr_ra  <= rd_base + 13'(user_addr(10'(widx - 11'h200)));
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
					pl_lba    <= 24'd150;              // Sub-Q before the first read: track 1
					pl_start  <= 1;
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
						pl_lba        <= l + 24'd150;   // Sub-Q position
						pl_start      <= 1;
						fetch_lba_sys <= l[14:0];
						fetch_tgl_sys <= ~fetch_tgl_sys;
						read_pend     <= 0;
						cst <= C_SEC_WAIT;
					end
				end

				// streaming: sector time and the sector in the ring, whichever
				// comes last. A command in between (a new READ, a stop) drops
				// the send, as MiSTer's next poll would (the sector stays in
				// the ring).
				C_STR_POS: begin
					if (delay_cnt) delay_cnt <= delay_cnt - 1'd1;
					if (cmd_new && comm[0] != 8'h00) str_cancel <= 1;
					if (pl_done) begin
						sec_audio <= pl_audio;
						cst <= C_STR_WAIT;
					end
				end

				C_STR_WAIT: begin
					if (delay_cnt) delay_cnt <= delay_cnt - 1'd1;
					if (cmd_new && comm[0] != 8'h00) str_cancel <= 1;
					// data: the drive's sector time from the NEXT or READ; audio:
					// a tick of the sector clock
					if (rb_cnt != 0 && (sec_audio ? acredit != 0 : delay_cnt == 0)) begin
						if (str_cancel || disc_change) cst <= C_IDLE;
						else begin
							a_send = sec_audio;
							astream  <= sec_audio;
							zero_sector <= rb_fail[rb_head];      // a failed read reads as zeros
							rd_base  <= slot_base(rb_head);
							snd_lba  <= rb_lba;
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
						bit [11:0] b;
						b = raw_byte_addr(sec_off, widx);
						sec_b   <= b;
						sbuf_ra <= cdda(widx[9:0], host_le);
						sbr_ra  <= rd_base + 13'(b[11:2]);
					end else if (rd_phase == 2'd2) begin
						bit [15:0] w;
						// streaming: the raw sector; preloaded ISO: its 2048 bytes
						// of user data, zeros after them in a longer block
						if (zero_sector) w = 16'h0000;
						else if (disc_stream) w = (sec_b < 12'd2352) ? user_word(sbr_q, sec_b[1]) : 16'h0000;
						else w = widx[10] ? 16'h0000 : cddw(sbuf_q, host_le);
						CDD_DATA <= w;                     // ioctl order: low byte first
						CDD_WR   <= 1;
						crc  <= crc + w[15:8] + w[7:0];
						widx <= widx + 1'd1;
						if (widx == sec_words - 11'd1) cst <= C_SEC_CRC;
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
					if (disc_stream) r_pop = 1;           // the sector leaves the ring
					CDD_DTEN    <= 0;
					cur_lba     <= cur_lba + 1'd1;
					blocks_left <= blocks_left - 1'd1;
					cst <= C_IDLE;
				end

				default: cst <= C_IDLE;
			endcase

			// the audio sector clock: a tick adds a credit, a sector takes one.
			// After a seek it waits at its first tick until the sector is in
			// the ring, so a sector the seek delayed does not let the next
			// ones through at once.
			if (a_seek) begin
				apace    <= apace_period - 20'd1;
				apace_ph <= '0;
				acredit  <= '0;
				astream  <= 0;
			end else
				acredit <= acredit + 4'(apace == 0 && a_tick_ok && acredit != ACREDIT_MAX) - 4'(a_send);

			// the read-ahead ring: a flush restarts it at r_flush_lba (a
			// DISC_READ in flight is then dropped when it is answered); an
			// answer fills a slot, a sent sector frees one; the next sector is
			// requested when the last request was answered
			begin
				bit fill;
				fill = q_finished && pf_busy && !pf_discard;
				if (q_finished) begin
					pf_busy    <= 0;
					pf_discard <= 0;
				end
				if (fill) rb_fail[pf_slot] <= q_failed;
				if (r_flush || disc_change) begin
					rb_on  <= r_flush;           // a disc change alone stops it
					rb_lba <= r_flush_lba;
					rb_cnt <= '0;
					if (pf_busy && !q_finished) pf_discard <= 1;
				end else begin
					if (r_pop) begin
						rb_head <= (rb_head == 4'(RB_SLOTS - 1)) ? 4'd0 : rb_head + 4'd1;
						rb_lba  <= rb_lba + 24'd1;
					end
					rb_cnt <= rb_cnt + 4'(fill) - 4'(r_pop);
					if (disc_stream && rb_on && !pf_busy && !r_pop && rb_cnt < 4'(RB_SLOTS) &&
					    (rb_lba + 24'(rb_cnt) < pf_end || astream)) begin
						bit [4:0] sl;
						sl = 5'(rb_head) + 5'(rb_cnt);
						if (sl >= 5'(RB_SLOTS)) sl = sl - 5'(RB_SLOTS);
						pf_slot <= sl[3:0];
						q_lba   <= {8'd0, rb_lba + 24'(rb_cnt)};
						q_addr  <= SECTOR_BUF_ADDR + 32'(sl) * 32'd2352;
						q_start <= 1;
						pf_busy <= 1;
					end
				end
			end
		end
	end
endmodule
