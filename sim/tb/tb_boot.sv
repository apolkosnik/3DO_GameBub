// Boot testbench: runs a real 3DO BIOS (and optionally a disc image) on the
// complete Game Bub 3DO core.
//
// The BIOS and ISO are placed directly into the SDRAM model, in the layout
// the host interface produces for a little-endian MCU (that path is covered
// by tb_top). They are then registered through the real host commands
// (FileWriteEnd, SetupComplete, NotifyFocus, CoreRun), so the core's NVRAM
// formatting, CD drive emulation and byte-order handling run as on hardware.
//
// Output:
//   * framework video frames as PPM files (<out>/frames/frame_NNNN.ppm)
//   * every CD controller command the BIOS sends and every sector delivered
//   * CPU address samples, pause statistics, SDRAM model errors
//   * every sector sent to the CD controller is checked against the image
//     (streamed .bin or preloaded ISO) at the LBA the BIOS asked for
//   * every video line must have had its VRAM read transfers (both halves)
//     before it starts shifting out (TB errors if the 3DO was paused in
//     between; MADAM's own arbitration delays are reported separately)
//   * random VRAM writes to off-chip VRAM (CPU, CEL engine): none may be
//     lost in ddram.sv's posted write port or completed with another
//     address's flash-write state (counted as TB errors)
//   * a shadow of VRAM kept by the VRAM bus semantics (random writes, flash
//     writes, read and write transfers): every read transfer served by the
//     external path must deliver what VRAM held when it started, and at the
//     end off-chip VRAM (SDRAM or SRAM) must hold what the 3DO wrote (TB errors);
//     +vram_watch=<row> logs every event on one 512-word VRAM row
//   * <out>/cpu_trace.txt: the last 32768 CPU bus cycles (or, with
//     +trace_from_ms=<n>, all from n ms on) before the CPU first runs outside
//     the 3DO memory map (a crash), with CLIO's interrupt state at each FIQ
//
// Plusargs: +bios=<file> (required), +iso=<file> or +disc_bin=<file>,
//           +disc_latency_us=<n> (default 800), +trace_from_ms=<n>, +run_ms=<n> (default 1000),
//           +frame_every=<n> (default 10), +out=<dir> (default build/sim),
//           +vram_watch=<row>, +sport_ms=<n>, +rt_log_ms=<n>, +pad_ctl=<file> (buttons
//           pressed while it runs, see pad_btn), +frame_log, +frames_from=<n> +frames_to=<m>
//           (per-frame brightness log, every frame saved in a window; see save_frame)
//           <out>/audio.raw: the audio output (s16le stereo, 44.1 kHz)
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_boot;
	string outdir = "build/sim";   // +out=<dir>: frames/, cpu_trace.txt
	initial void'($value$plusargs("out=%s", outdir));
	reg clk_mem = 0;
	reg clk_sys = 0;
	reg clk_vid = 0;
	always #5  clk_mem = ~clk_mem;
	always #10 clk_sys = ~clk_sys;
	always #10.191 clk_vid = ~clk_vid;

	reg reset = 1;

	reg         h_enable = 0, h_write = 0;
	reg  [31:0] h_addr = 0, h_wdata = 0;
	wire [31:0] h_rdata;
	wire        h_done;
	reg         h_req = 0;
	wire        h_busy, h_cdone, h_err;
	wire        c_req;
	reg         c_done = 0, c_err = 0;

	wire [5:0]  vr, vg, vb;
	wire        vde, vvbl, vhbl;
	wire [15:0] al, ar;

	// <out>/audio.raw: the core's audio output, sampled at 44.1 kHz (16-bit
	// little-endian stereo, left first), for listening to or measuring it
	// (CD-DA the BIOS plays from the disc, for instance)
	int      au_fd = 0;
	longint  au_n = 0, au_nz = 0;
	int      au_peak = 0;
	initial begin
		au_fd = $fopen({outdir, "/audio.raw"}, "wb");
		forever begin
			#(1s / 44100.0);
			if (au_fd != 0) $fwrite(au_fd, "%c%c%c%c", al[7:0], al[15:8], ar[7:0], ar[15:8]);
			au_n++;
			if (al != 0 || ar != 0) au_nz++;
			if ($signed(al) > au_peak) au_peak = $signed(al);
			if (-$signed(al) > au_peak) au_peak = -$signed(al);
			if ($signed(ar) > au_peak) au_peak = $signed(ar);
			if (-$signed(ar) > au_peak) au_peak = -$signed(ar);
		end
	end

	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;

	// Buttons: a, b, x, y, up, down, left, right, l, r, start, select. With
	// +pad_walk one button is held at a time, the next every 50 ms of 3DO
	// time (from 1 s), so that the player bus carries changing pad words.
	reg [11:0] pad_btn = '0;
	// +pad_ctl=<file>: buttons pressed while the simulation runs. Every 50 ms
	// of 3DO time the file is read again and its new lines are carried out
	// in order: "<button>[+<button>...] <hold_ms>" presses the buttons for
	// hold_ms, then releases them for 200 ms; "wait <ms>" waits. Buttons:
	// a b x y up down left right l r start select (core mapping, Buttons
	// setting 0: Y B A = 3DO A B C, X = stop, start = P). Each press is
	// logged with its time.
	string pad_ctl_file = "";
	initial if ($value$plusargs("pad_ctl=%s", pad_ctl_file)) begin
		int done_lines;
		done_lines = 0;
		$display("tb_boot: pad control file %s", pad_ctl_file);
		forever begin
			int fd, n;
			string line;
			#50ms;
			fd = $fopen(pad_ctl_file, "r");
			if (fd == 0) continue;
			n = 0;
			while ($fgets(line, fd)) begin
				string btns, tok;
				int hold, sp;
				bit [11:0] m;
				n++;
				if (n <= done_lines) continue;
				done_lines = n;
				sp = -1;
				for (int i = 0; i < line.len(); i++) if (line[i] == " ") begin sp = i; break; end
				if (sp < 0) continue;
				btns = line.substr(0, sp - 1);
				hold = line.substr(sp + 1, line.len() - 1).atoi();
				if (btns == "wait") begin
					$display("[%0t] pad: wait %0d ms", $realtime, hold);
					#(hold * 1ms);
					continue;
				end
				m = '0;
				tok = "";
				for (int i = 0; i <= btns.len(); i++) begin
					if (i == btns.len() || btns[i] == "+") begin
						case (tok)
							"a": m[0] = 1;  "b": m[1] = 1;  "x": m[2] = 1;  "y": m[3] = 1;
							"up": m[4] = 1; "down": m[5] = 1; "left": m[6] = 1; "right": m[7] = 1;
							"l": m[8] = 1;  "r": m[9] = 1;  "start": m[10] = 1; "select": m[11] = 1;
							default: $display("[%0t] pad: unknown button '%s'", $realtime, tok);
						endcase
						tok = "";
					end else tok = {tok, btns[i]};
				end
				$display("[%0t] pad: %s for %0d ms", $realtime, btns, hold);
				@(posedge clk_sys) pad_btn <= m;
				#(hold * 1ms);
				@(posedge clk_sys) pad_btn <= '0;
				#200ms;
			end
			$fclose(fd);
		end
	end
	initial if ($test$plusargs("pad_walk")) begin
		#1s;
		forever begin
			@(posedge clk_sys) pad_btn <= (pad_btn == 12'd0 || pad_btn == 12'h800) ? 12'h001 : {pad_btn[10:0], 1'b0};
			#50ms;
		end
	end

	p3do_gamebub #(.DISPLAY_DIVIDER(31)) dut (
		.clock(clk_sys), .reset(reset),
		.clocks_clockIn50M(1'b0),
		.clocks_clockOutSystem(), .clocks_clockOutDisplay(), .clocks_clockOutSpi(), .clocks_locked(),
		.video_data_r(vr), .video_data_g(vg), .video_data_b(vb),
		.video_dataEnable(vde), .video_vblank(vvbl), .video_hblank(vhbl),
		.audio_left(al), .audio_right(ar),
		.host_mem_enable(h_enable), .host_mem_write(h_write), .host_mem_done(h_done),
		.host_mem_address(h_addr), .host_mem_dataRead(h_rdata), .host_mem_dataWrite(h_wdata),
		.host_commandHost_request(h_req), .host_commandHost_busy(h_busy),
		.host_commandHost_done(h_cdone), .host_commandHost_error(h_err),
		.host_commandCore_request(c_req), .host_commandCore_busy(1'b0),
		.host_commandCore_done(c_done), .host_commandCore_error(c_err),
		.input_buttons_a(pad_btn[0]), .input_buttons_b(pad_btn[1]), .input_buttons_x(pad_btn[2]),
		.input_buttons_y(pad_btn[3]), .input_buttons_up(pad_btn[4]), .input_buttons_down(pad_btn[5]),
		.input_buttons_left(pad_btn[6]), .input_buttons_right(pad_btn[7]), .input_buttons_l(pad_btn[8]),
		.input_buttons_r(pad_btn[9]), .input_buttons_start(pad_btn[10]), .input_buttons_select(pad_btn[11]),
		.sdram_clock(s_clk), .sdram_cke(s_cke), .sdram_cs(s_cs), .sdram_ras(s_ras), .sdram_cas(s_cas),
		.sdram_we(s_we), .sdram_dqm(s_dqm), .sdram_bank(s_ba), .sdram_address(s_a),
		.sdram_dataIn(s_dq_in), .sdram_dataOut(s_dq_out), .sdram_dataDir(s_oe),
		.sram_ceN(sr_ce_n), .sram_weN(sr_we_n), .sram_oeN(sr_oe_n), .sram_writeMaskN(sr_mask_n),
		.sram_address(sr_a), .sram_dataIn(sr_din), .sram_dataOut(sr_dout), .sram_dataDir(sr_dir)
	);

	// the SRAM ("VRAM memory" setting, +sram_mode=0 SRAM (default), 1 SRAM
	// with three cycles per word, 2 SDRAM only)
	wire        sr_ce_n, sr_we_n, sr_oe_n, sr_dir;
	wire [ 1:0] sr_mask_n;
	wire [17:0] sr_a;
	wire [15:0] sr_din, sr_dout;
	int         sram_mode = 0;
	initial void'($value$plusargs("sram_mode=%d", sram_mode));
	sram_model sram (
		.ce_n(sr_ce_n), .we_n(sr_we_n), .oe_n(sr_oe_n), .mask_n(sr_mask_n), .a(sr_a),
		.dq_from_fpga(sr_dout), .dq_dir(sr_dir), .dq_to_fpga(sr_din)
	);

	sdram_model sdram (
		.clk(s_clk), .cke(s_cke), .cs_n(s_cs), .ras_n(s_ras), .cas_n(s_cas), .we_n(s_we),
		.dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_from_fpga(s_dq_out), .dq_oe_fpga(s_oe),
		.dq_to_fpga(s_dq_in)
	);

	int errors = 0;
	bit sh_cpu [2];   // VRAM side 0/1: the access whose RAS fell last is the CPU's SPORT access (VRAM shadow)
	task automatic fail(input string m);
		errors++;
		$display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	// ---------------- host BFM (as tb_top) ----------------
	bit host_lock = 0;
	task automatic host_access(input bit wr, input [31:0] a, input [31:0] d, output [31:0] q);
		int to;
		while (host_lock) @(posedge clk_sys);
		host_lock = 1;
		@(posedge clk_sys);
		h_enable <= 1; h_write <= wr; h_addr <= a; h_wdata <= d;
		@(posedge clk_sys);
		to = 0;
		while (!h_done) begin
			@(posedge clk_sys);
			if (++to > 2_000_000) begin fail($sformatf("host access %08h timed out", a)); break; end
		end
		q = h_rdata;
		h_enable <= 0;
		host_lock = 0;
	endtask
	task automatic host_wr(input [31:0] a, input [31:0] d);
		bit [31:0] q;
		host_access(1, a, d, q);
	endtask
	task automatic host_rd(input [31:0] a, output [31:0] q);
		host_access(0, a, 32'h0, q);
	endtask
	task automatic host_cmd(input [15:0] op, input [31:0] p1, input [31:0] p2, input [31:0] p3,
	                        output [31:0] result, output bit error);
		int to;
		host_wr(32'hF000_0004, p1);
		host_wr(32'hF000_0008, p2);
		host_wr(32'hF000_000C, p3);
		host_wr(32'hF000_0000, {16'h0, op});
		@(posedge clk_sys);
		h_req <= 1;
		to = 0;
		while (!(h_cdone || h_err)) begin
			@(posedge clk_sys);
			if (++to > 100000) begin fail($sformatf("command %04h timed out", op)); break; end
		end
		error = h_err;
		host_rd(32'hF000_0000, result);
		@(posedge clk_sys);
		h_req <= 0;
		while (h_cdone || h_err) @(posedge clk_sys);
	endtask

	// ---------------- backdoor file placement ----------------
	// Little-endian host storage (gb_host.sv): file bytes b0..b3 of a 32-bit
	// group go to SDRAM words {b3,b2} (even) and {b1,b0} (odd).
	function automatic [23:0] iso_word_addr(input [23:0] w);
		bit [14:0] r;
		r = w[23:9];
		if (r < 15'd8192)       iso_word_addr = {2'd3, r[12:0], w[8:0]};
		else if (r < 15'd15360) iso_word_addr = {2'd0, 13'(r - 15'd8192 + 15'd1024), w[8:0]};
		else                    iso_word_addr = {2'd1, 13'(r - 15'd15360 + 15'd1024), w[8:0]};
	endfunction

	task automatic place_file(input string fname, input bit iso_map, input [22:0] ddr_base, output int len);
		int fd, n;
		bit [7:0] b [4];
		fd = $fopen(fname, "rb");
		if (fd == 0) $fatal(1, "tb_boot: cannot open %s", fname);
		len = 0;
		forever begin
			n = $fread(b, fd);
			if (n <= 0) break;
			for (int i = n; i < 4; i++) b[i] = 8'h00;
			begin
				bit [23:0] w0, a0, a1;
				w0 = len >> 1;
				if (iso_map) begin a0 = iso_word_addr(w0); a1 = iso_word_addr(w0 + 1); end
				else begin a0 = {2'd2, 22'((ddr_base + len) >> 1)}; a1 = a0 + 1; end
				sdram.poke(a0, {b[3], b[2]});
				sdram.poke(a1, {b[1], b[0]});
			end
			len += 4;
			if (n < 4) break;
		end
		$fclose(fd);
	endtask

	// ---------------- disc-streaming firmware model ----------------
	// +disc_bin=<file>: a single-track MODE1/2352 .bin, served like the
	// fork firmware (table of contents, then raw sectors on DISC_READ).
	int  bin_fd = 0;
	int  bin_sectors = 0;
	int  disc_latency_us = 800;
	int  served = 0;
	function automatic [7:0] bcd(input int x); return 8'(((x / 10) << 4) | (x % 10)); endfunction
	function automatic [31:0] msf_bcd(input int lba);
		return {8'h00, bcd(lba / 75 / 60), bcd((lba / 75) % 60), bcd(lba % 75)};
	endfunction
	initial forever begin
		bit [31:0] w [4];
		bit [7:0]  sec [2352];
		@(posedge clk_sys);
		if (bin_fd != 0 && c_req && !c_done && !c_err) begin
			for (int i = 0; i < 4; i++) host_rd(32'hF000_1000 + 4 * i, w[i]);
			foreach (sec[i]) sec[i] = 8'h00;
			if (w[2] >= 150 && w[2] < 150 + bin_sectors) begin
				int n;
				void'($fseek(bin_fd, longint'(w[2] - 150) * 2352, 0));
				n = $fread(sec, bin_fd);
			end
			#(disc_latency_us * 1us);
			for (int i = 0; i < 2352; i += 4) host_wr(w[3] + i, {sec[i+3], sec[i+2], sec[i+1], sec[i]});
			served++;
			c_done <= 1;
			while (c_req) @(posedge clk_sys);
			c_done <= 0;
		end
	end

	// ---------------- monitors ----------------
	// CD controller commands from the BIOS and sector deliveries
	always @(posedge clk_sys) begin
		if (dut.cdd.cmd_new)
			$display("[%0t] CD cmd %02h %02h %02h %02h %02h %02h %02h %02h", $realtime,
			         dut.cdd.comm[0], dut.cdd.comm[1], dut.cdd.comm[2], dut.cdd.comm[3],
			         dut.cdd.comm[4], dut.cdd.comm[5], dut.cdd.comm[6], dut.cdd.comm[7]);
	end
	// Every command the BIOS writes to the CD controller (also those the
	// controller answers itself: 09, 8x), and the status bytes it reads back,
	// as seen on the controller's port (P3DO_CDROM IO_CMD_WRITE / IO_CMD_READ).
	bit [7:0] ctl_cmd [8];
	int       ctl_cmd_n = 0, ctl_cmd_len = 7;
	bit [7:0] ctl_st [16];
	int       ctl_st_n = 0;
	int       ctl_cmds = 0;
	reg       ctl_sten_d = 0;
	always @(posedge clk_sys) begin
		ctl_sten_d <= dut.cdrom.ST_EN;
		if (dut.cdrom.IO_ST == dut.cdrom.IO_CMD_WRITE) begin
			if (ctl_cmd_n == 0)
				case (dut.cdrom.CDDI)
					8'h01:                      ctl_cmd_len = 8;
					8'h04, 8'h05:               ctl_cmd_len = 1;
					default:                    ctl_cmd_len = 7;
				endcase
			ctl_cmd[ctl_cmd_n] = dut.cdrom.CDDI;
			ctl_cmd_n++;
			if (ctl_cmd_n == ctl_cmd_len) begin
				string s;
				s = "";
				for (int i = 0; i < ctl_cmd_len; i++) s = {s, $sformatf(" %02h", ctl_cmd[i])};
				ctl_cmds++;
				if (ctl_cmd[0] != 8'h20 || ctl_cmds < 200)
					$display("[%0t] CD ctl cmd%s", $realtime, s);
				ctl_cmd_n = 0;
			end
		end
		if (dut.cdrom.IO_ST == dut.cdrom.IO_CMD_READ && ctl_st_n < 16) begin
			// IO_CMD_READ loads DOUT from the status FIFO at the end of this cycle
			ctl_st[ctl_st_n] = dut.cdrom.STAT_DATA[dut.cdrom.STAT_FIFO_RPOS];
			ctl_st_n++;
		end
		if (!dut.cdrom.ST_EN && ctl_sten_d) begin
			string s;
			s = "";
			for (int i = 0; i < ctl_st_n; i++) s = {s, $sformatf(" %02h", ctl_st[i])};
			if (ctl_st_n && (ctl_st[0] != 8'h20 || ctl_cmds < 200))
				$display("[%0t] CD ctl status%s", $realtime, s);
			ctl_st_n = 0;
		end
	end

	reg cdd_dten_d = 0, cdd_dien_d = 0;
	int sectors_sent = 0;
	always @(posedge clk_sys) begin
		cdd_dten_d <= dut.cdd_dten;
		cdd_dien_d <= dut.cdd_dien;
		if (dut.cdd_dten && !cdd_dten_d) begin
			sectors_sent++;
			if (sectors_sent <= 40 || sectors_sent % 100 == 0)
				$display("[%0t] CD sector %0d (%s %0d)", $realtime, sectors_sent, dut.cdd.disc_stream ? "abs lba" : "lba", dut.cdd.disc_stream ? dut.cdd.q_lba : 32'(dut.cdd.fetch_lba_sys));
		end
		if (!dut.cdd_dien && cdd_dien_d)
			$display("[%0t] CD disc-info block sent (id %08h, lead-out MSF %06h)", $realtime, dut.cdd.disc_id, dut.cdd.disc_msf[31:8]);
	end
	// ---------------- CD data check (streamed and preloaded discs) ----------
	// Every sector the drive back end sends to the CD controller is compared
	// with the image at the LBA the BIOS asked for. A block of the length the
	// BIOS set (Set Mode, the controller's CDD_BLK_LEN) is, for a raw .bin,
	// 2048: bytes 16..2063 of the 2352-byte sector; 2352: the whole sector;
	// shorter: the end of the sector (2340: bytes 12..); longer: the sector
	// and zeros. For an ISO: its 2048 bytes, zeros after them. The expected
	// LBA is computed here from the READ commands (one sector per READ or
	// NEXT), not taken from the core. The bytes the CPU then reads from the
	// controller's data port are checked against the same block.
	int       chk_fd = 0;
	int       chk_sec_bytes = 2352; // sector size in the image file
	int       chk_sectors = 0;      // sectors in the image
	int       cd_exp_lba = 150;     // absolute LBA of the next sector to arrive
	int       cd_ref_lba = 0;       // LBA of the sector being received
	int       cd_widx = 0;
	int       cd_blk_len = 2048;    // block length of the sector being received
	int       cd_sec_errs = 0;
	int       cd_good = 0, cd_bad = 0;
	int       cd_len_count [int];   // sectors received per block length
	bit [7:0] cd_raw [2352];
	bit [7:0] cd_ref [2449];        // the expected block
	bit [15:0] cd_ref_sum;
	int       cd_rd_idx = 0, cd_rd_errs = 0, cd_rd_bytes = 0;
	reg       cd_dt_en_d = 0;
	// audio sector timing (abs LBAs in audio tracks per the TOC sent)
	realtime  cd_last_audio = -1s;
	realtime  cd_audio_min = 1s, cd_audio_max = 0, cd_audio_sum = 0;
	int       cd_audio_gaps = 0, cd_audio_secs = 0;
	int       trk_audio_from = 1 << 30;   // first audio LBA (all audio after it)
	always @(posedge clk_sys) begin
		if (chk_fd != 0) begin
			if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h10) begin
				int l;
				l = (dut.cdd.comm[4] != 0) ? int'({dut.cdd.comm[1], dut.cdd.comm[2], dut.cdd.comm[3]})
				                           : int'(dut.cdd.comm[1]) * 4500 + int'(dut.cdd.comm[2]) * 75 + int'(dut.cdd.comm[3]);
				cd_exp_lba = (l < 150) ? 150 : l;
				cd_last_audio = -1s;      // a seek: no gap to measure
			end
			if (dut.cdd_dten && !cdd_dten_d) begin
				int off;
				cd_ref_lba = cd_exp_lba;
				cd_exp_lba++;
				cd_blk_len = int'(dut.cdrom.CDD_BLK_LEN);
				if (cd_len_count.exists(cd_blk_len)) cd_len_count[cd_blk_len]++;
				else cd_len_count[cd_blk_len] = 1;
				foreach (cd_raw[i]) cd_raw[i] = 8'h00;
				if (cd_ref_lba < 150 + chk_sectors) begin
					int n;
					void'($fseek(chk_fd, longint'(cd_ref_lba - 150) * chk_sec_bytes, 0));
					n = $fread(cd_raw, chk_fd, 0, chk_sec_bytes);
				end
				if (chk_sec_bytes == 2048) off = 0;
				else if (cd_blk_len == 2048) off = 16;
				else if (cd_blk_len >= 2352) off = 0;
				else off = (2352 - cd_blk_len) & ~1;
				foreach (cd_ref[i])
					cd_ref[i] = (i < cd_blk_len && off + i < chk_sec_bytes) ? cd_raw[off + i] : 8'h00;
				cd_widx = 0;
				cd_sec_errs = 0;
				cd_ref_sum = 16'h0000;
				if (cd_ref_lba >= trk_audio_from) begin
					cd_audio_secs++;
					if (cd_last_audio >= 0) begin
						realtime g;
						g = $realtime - cd_last_audio;
						cd_audio_gaps++;
						cd_audio_sum += g;
						if (g < cd_audio_min) cd_audio_min = g;
						if (g > cd_audio_max) cd_audio_max = g;
					end
					cd_last_audio = $realtime;
				end
			end
			if (dut.cdd_dten && dut.cdd.CDD_WR) begin
				if (cd_widx < (cd_blk_len + 1) / 2) begin
					bit [15:0] e;
					e = {(2 * cd_widx + 1 < 2449) ? cd_ref[2 * cd_widx + 1] : 8'h00, cd_ref[2 * cd_widx]};
					cd_ref_sum = cd_ref_sum + e[15:8] + e[7:0];
					if (dut.cdd.CDD_DATA !== e) begin
						if (cd_sec_errs < 4)
							$display("[%0t] CD DATA MISMATCH abs lba %0d word %0d (block %0d bytes): got %04h, expected %04h",
							         $realtime, cd_ref_lba, cd_widx, cd_blk_len, dut.cdd.CDD_DATA, e);
						cd_sec_errs++;
					end
				end else if (cd_widx == (cd_blk_len + 1) / 2) begin
					if (dut.cdd.CDD_DATA !== cd_ref_sum) begin
						$display("[%0t] CD CHECKSUM MISMATCH abs lba %0d: got %04h, expected %04h",
						         $realtime, cd_ref_lba, dut.cdd.CDD_DATA, cd_ref_sum);
						cd_sec_errs++;
					end
				end
				cd_widx++;
			end
			if (!dut.cdd_dten && cdd_dten_d) begin
				if (cd_widx != (cd_blk_len + 1) / 2 + 1) begin
					$display("[%0t] CD sector abs lba %0d: %0d words sent, expected %0d", $realtime, cd_ref_lba, cd_widx, (cd_blk_len + 1) / 2 + 1);
					cd_sec_errs++;
				end
				if (cd_sec_errs) begin cd_bad++; errors++; end
				else cd_good++;
			end
			// the CPU's reads of the block from the controller's data port
			cd_dt_en_d <= dut.cdrom.DT_EN;
			if (dut.cdrom.DT_EN && !cd_dt_en_d) cd_rd_idx = 0;
			if (dut.cdrom.IO_ST == dut.cdrom.IO_DAT_READ) begin
				// DISC_DATA_Q is the byte at DISC_DATA_RPOS, which counts the
				// bytes read since the block arrived
				if (cd_rd_idx < cd_blk_len && dut.cdrom.DISC_DATA_Q !== cd_ref[cd_rd_idx]) begin
					if (cd_rd_errs < 8)
						$display("[%0t] CD PORT MISMATCH abs lba %0d byte %0d: CPU reads %02h, expected %02h",
						         $realtime, cd_ref_lba, cd_rd_idx, dut.cdrom.DISC_DATA_Q, cd_ref[cd_rd_idx]);
					cd_rd_errs++;
					errors++;
				end
				cd_rd_idx++;
				cd_rd_bytes++;
			end
		end
	end

	// ---------------- system control events ----------------
	// CPU writes to CLIO's CSTAT (software reset) and interrupt enable
	// registers, and the ARM's reset input, over the whole run.
	reg cpu_nres_d = 1;
	bit [31:0] last_fetch = 0;
	always @(posedge clk_sys) begin
		if (dut.p3do.MCLK_PH2 && !dut.p3do.CPU_nOPC && !dut.p3do.CPU_nRW) last_fetch <= dut.p3do.CPU_A;
		if (!dut.reset_3do) begin
			cpu_nres_d <= dut.p3do.CPU_nRES;
			if (dut.p3do.CPU_nRES != cpu_nres_d)
				$display("[%0t] ARM reset input %s", $realtime, dut.p3do.CPU_nRES ? "released" : "asserted");
			if (dut.p3do.MCLK_PH2 && dut.p3do.CPU_nRW)
				case (dut.p3do.CPU_A)
					32'h03400028: $display("[%0t] CLIO CSTAT <= %08h (code near %08h, BOOT_ROM %b)", $realtime, dut.p3do.CPU_DO, last_fetch, dut.p3do.madam.BOOT_ROM);
					32'h03400048: $display("[%0t] CLIO INT0 enable set   %08h", $realtime, dut.p3do.CPU_DO);
					32'h0340004C: $display("[%0t] CLIO INT0 enable clear %08h", $realtime, dut.p3do.CPU_DO);
					32'h03400068: $display("[%0t] CLIO INT1 enable set   %08h", $realtime, dut.p3do.CPU_DO);
					32'h0340006C: $display("[%0t] CLIO INT1 enable clear %08h", $realtime, dut.p3do.CPU_DO);
					default: ;
				endcase
		end
	end

	// ---------------- CPU bus trace on a wild jump ----------------
	// CPU bus cycles are sampled on MCLK_PH2 (the ARM6 core's CE_F, where
	// MiSTer's own debug hooks pair CPU_A with CPU_DI). The last TR_N are kept
	// in a ring buffer; with +trace_from_ms=<n> every cycle from n ms on is
	// written instead. When the CPU has addressed outside the 3DO memory map
	// for TR_WILD samples in a row, the trace goes to <out>/cpu_trace.txt:
	// time (ns), address, data (read: CPU_DI, write: CPU_DO), and the flags
	// nMREQ SEQ nOPC nRW. Each fetch from the FIQ vector is preceded by a
	// comment line with CLIO's pending-and-enabled interrupt bits and the CPSR.
	localparam int TR_N = 32768;
	localparam int TR_WILD = 8;
	bit [31:0] tr_a [TR_N];
	bit [31:0] tr_d [TR_N];
	bit [ 3:0] tr_f [TR_N];
	longint    tr_t [TR_N];
	int        tr_i = 0, tr_wild = 0;
	bit        tr_done = 0;
	int        tr_fd = 0;
	longint    trace_from_ms = -1;
	int        fiq_count = 0;
	function automatic bit cpu_addr_mapped(input [31:0] a);
		return a <= 32'h002FFFFF || (a >= 32'h03000000 && a <= 32'h034FFFFF);
	endfunction
	always @(posedge clk_sys) begin
		if (dut.p3do.MCLK_PH2 && !tr_done && !dut.reset_3do) begin
			bit [31:0] d;
			bit [ 3:0] f;
			d = dut.p3do.CPU_nRW ? dut.p3do.CPU_DO : dut.p3do.CPU_DI;
			f = {dut.p3do.CPU_nMREQ, dut.p3do.CPU_SEQ, dut.p3do.CPU_nOPC, dut.p3do.CPU_nRW};
			if (!dut.p3do.CPU_nOPC && dut.p3do.CPU_A == 32'h0000001C) fiq_count++;
			if (trace_from_ms >= 0 && $time >= trace_from_ms * 1000000 && tr_fd == 0) begin
				tr_fd = $fopen({outdir, "/cpu_trace.txt"}, "w");
				$fdisplay(tr_fd, "# time_ns address data nMREQ SEQ nOPC nRW");
				$display("[%0t] CPU bus trace started (%s/cpu_trace.txt)", $realtime, outdir);
			end
			if (tr_fd != 0) begin
				if (!dut.p3do.CPU_nOPC && dut.p3do.CPU_A == 32'h0000001C)
					$fdisplay(tr_fd, "# FIQ %0d: INT0 pend&en %08h  INT1 pend&en %08h  CPSR %08h",
					          fiq_count, dut.p3do.clio.INT0_PEND & dut.p3do.clio.INT0_EN,
					          dut.p3do.clio.INT1_PEND & dut.p3do.clio.INT1_EN, 32'(dut.p3do.cpu.CPSR));
				$fdisplay(tr_fd, "%0d %08h %08h %b %b %b %b", $time, dut.p3do.CPU_A, d, f[3], f[2], f[1], f[0]);
			end else begin
				tr_a[tr_i] = dut.p3do.CPU_A;
				tr_d[tr_i] = d;
				tr_f[tr_i] = f;
				tr_t[tr_i] = longint'($time);
				tr_i = (tr_i + 1) % TR_N;
			end
			tr_wild = cpu_addr_mapped(dut.p3do.CPU_A) ? 0 : tr_wild + 1;
			if (tr_wild == TR_WILD) begin
				tr_done = 1;
				if (tr_fd == 0) begin
					tr_fd = $fopen({outdir, "/cpu_trace.txt"}, "w");
					$fdisplay(tr_fd, "# time_ns address data nMREQ SEQ nOPC nRW");
					for (int k = 0; k < TR_N; k++) begin
						int j;
						j = (tr_i + k) % TR_N;
						if (tr_t[j] != 0)
							$fdisplay(tr_fd, "%0d %08h %08h %b %b %b %b", tr_t[j], tr_a[j], tr_d[j],
							          tr_f[j][3], tr_f[j][2], tr_f[j][1], tr_f[j][0]);
					end
				end
				$fclose(tr_fd);
				$display("[%0t] CPU addressed outside the memory map (A=%08h) after %0d FIQs: trace in %s/cpu_trace.txt",
				         $realtime, dut.p3do.CPU_A, fiq_count, outdir);
			end
		end
	end

	// command bytes the BIOS writes to the drive (CD bus write strobes)
	reg cdhwr_d = 1;
	always @(posedge clk_sys) begin
		cdhwr_d <= dut.CDHWR_N;
		if (!dut.CDHWR_N && cdhwr_d && !dut.CDCMD_N && !dut.CDEN_N)
			$display("[%0t] BIOS -> drive byte %02h", $realtime, dut.CDDO);
	end
	// VRAM read transfers (video/SPORT) from +rt_log_ms on, for one frame
	int rt_log_ms = -1;
	initial void'($value$plusargs("rt_log_ms=%d", rt_log_ms));
	reg rt_exec_d = 0, sc_d = 0;
	realtime rt_t0;
	int sc_during_rt;
	bit rt_win;
	always @(posedge clk_mem) begin
		rt_win = rt_log_ms >= 0 && $realtime >= rt_log_ms * 1ms && $realtime < rt_log_ms * 1ms + 17ms;
		rt_exec_d <= dut.vram_l.RT_EXEC;
		sc_d <= dut.vram_l.SC;
		if (dut.vram_l.RT_EXEC && !rt_exec_d) begin
			rt_t0 = $realtime;
			sc_during_rt = 0;
		end
		if (dut.vram_l.RT_EXEC && dut.vram_l.SC && !sc_d) sc_during_rt++;
		if (!dut.vram_l.RT_EXEC && rt_exec_d && rt_win)
			$display("[%0t] RT row %03h split=%b internal=%b took %0.2f us, %0d serial shifts during the transfer",
			         $realtime, dut.vram_l.MEM_ROW, dut.vram_l.SPLIT, dut.vram_l.ISTE,
			         ($realtime - rt_t0) / 1000.0, sc_during_rt);
	end

	// Stale serial reads: a shift during a read transfer that reads a shift
	// register word the transfer has not written yet. The CPU's SPORT
	// transfers fill a shift register of their own (vram.sv) and are skipped.
	bit sr_filled [512];
	int stale_reads = 0, stale_rts = 0, good_reads = 0, stale_kind_clut = 0, stale_kind_vid = 0;
	bit stale_this_rt, fill_half, stale_cpu_rt = 0;
	reg sc_old2 = 0;
	always @(posedge clk_mem) begin
		sc_old2 <= dut.vram_l.SC;
		if (dut.vram_l.RT_EXEC && !rt_exec_d) begin
			stale_cpu_rt = sh_cpu[0];
			if (!stale_cpu_rt) begin
				foreach (sr_filled[i]) sr_filled[i] = 0;
				stale_this_rt = 0;
				fill_half = dut.vram_l.SREG_POS[8];
			end
		end
		if (dut.vram_l.SR_WE && !stale_cpu_rt) begin
			sr_filled[dut.vram_l.SR_WA] = 1;
			sr_filled[9'(dut.vram_l.SR_WA + 1)] = 1;
		end
		if (!dut.vram_l.SC && sc_old2 && dut.vram_l.SOM && dut.vram_l.RT_EXEC && !dut.vram_l.ISTE && !stale_cpu_rt &&
		    (!dut.vram_l.SPLIT || dut.vram_l.SR_RA[8] == fill_half)) begin
			if (dut.p3do.madam.SPORT.CLUT_TRANS_EXEC) stale_kind_clut += !sr_filled[dut.vram_l.SR_RA];
			else if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC) stale_kind_vid += !sr_filled[dut.vram_l.SR_RA];
			if (!sr_filled[dut.vram_l.SR_RA]) begin
				if (stale_reads < 0)
					$display("[%0t] stale read: RA=%03h fill pos=%03h split=%b (%0.2f us into the transfer)",
					         $realtime, dut.vram_l.SR_RA, dut.vram_l.SREG_POS, dut.vram_l.SPLIT, ($realtime - rt_t0) / 1000.0);
				stale_reads++;
				if (!stale_this_rt) stale_rts++;
				stale_this_rt = 1;
			end else good_reads++;
		end
	end
	final $display("tb_boot: serial reads during transfers: %0d ok, %0d stale (in %0d transfers): %0d CLUT/VDL, %0d video",
	               good_reads, stale_reads, stale_rts, stale_kind_clut, stale_kind_vid);

	// Random VRAM writes to off-chip VRAM (ddram.sv's posted write port,
	// one entry per half). Two hazards are counted:
	//  * lost write: a new write is latched while the previous write of the
	//    same half has not been issued yet (it overwrites it);
	//  * flash-write lookup for the wrong address: when a write is issued,
	//    the flash-write flag and row colour used to complete the 64-bit
	//    word must be the ones of the written address.
	// Both count as TB errors (the summary line).
	function automatic bit fw_flag(input [17:1] a);
		case (a[4:1])
			4'h0: return dut.ddram.vram_fw.g_lane[ 0].mem[a[17:5]];
			4'h1: return dut.ddram.vram_fw.g_lane[ 1].mem[a[17:5]];
			4'h2: return dut.ddram.vram_fw.g_lane[ 2].mem[a[17:5]];
			4'h3: return dut.ddram.vram_fw.g_lane[ 3].mem[a[17:5]];
			4'h4: return dut.ddram.vram_fw.g_lane[ 4].mem[a[17:5]];
			4'h5: return dut.ddram.vram_fw.g_lane[ 5].mem[a[17:5]];
			4'h6: return dut.ddram.vram_fw.g_lane[ 6].mem[a[17:5]];
			4'h7: return dut.ddram.vram_fw.g_lane[ 7].mem[a[17:5]];
			4'h8: return dut.ddram.vram_fw.g_lane[ 8].mem[a[17:5]];
			4'h9: return dut.ddram.vram_fw.g_lane[ 9].mem[a[17:5]];
			4'hA: return dut.ddram.vram_fw.g_lane[10].mem[a[17:5]];
			4'hB: return dut.ddram.vram_fw.g_lane[11].mem[a[17:5]];
			4'hC: return dut.ddram.vram_fw.g_lane[12].mem[a[17:5]];
			4'hD: return dut.ddram.vram_fw.g_lane[13].mem[a[17:5]];
			4'hE: return dut.ddram.vram_fw.g_lane[14].mem[a[17:5]];
			default: return dut.ddram.vram_fw.g_lane[15].mem[a[17:5]];
		endcase
	endfunction
	bit        vw_old_lwe = 0, vw_old_rwe = 0, vw_old_lras = 0, vw_old_rras = 0, vw_issued_d = 0;
	bit [17:1] vw_fw_a1 = '0, vw_fw_a1_d = '0;
	int        vw_writes = 0, vw_deferred = 0, vw_lost = 0, vw_fw_wrong = 0, vw_fw_wrong_effect = 0;
	always @(posedge clk_mem) begin
		bit lw, rw, issued;
		bit [19:3] wa;
		lw = |dut.ddram.lwe && !vw_old_lwe && dut.ddram.lras && vw_old_lras;
		rw = |dut.ddram.rwe && !vw_old_rwe && dut.ddram.rras && vw_old_rras;
		vw_writes += int'(lw) + int'(rw);
		if ((lw && dut.ddram.write_lpend) || (rw && dut.ddram.write_rpend)) begin
			vw_lost++;
			errors++;
			if (vw_lost <= 20)
				$display("[%0t] VRAM write lost: %s write to %05h (data %04h) overwritten by a write to %05h, ddram state %0d busy %b bursts %b%b%b%b",
				         $realtime, lw && dut.ddram.write_lpend ? "L" : "R",
				         lw && dut.ddram.write_lpend ? dut.ddram.write_laddr : dut.ddram.write_raddr,
				         lw && dut.ddram.write_lpend ? dut.ddram.write_ldata : dut.ddram.write_rdata,
				         lw && dut.ddram.write_lpend ? dut.ddram.laddr : dut.ddram.raddr,
				         dut.ddram.state, dut.ddram.DDRAM_BUSY, dut.ddram.burst_write_lbusy, dut.ddram.burst_write_rbusy,
				         dut.ddram.burst_read_lbusy, dut.ddram.burst_read_rbusy);
		end
		// A random VRAM write was issued at the previous edge (ddram.sv then
		// sits in state 6 with the DDRAM write command up). It completed the
		// 64-bit word with the flag/colour read for the port-1 address of
		// the edge before that.
		issued = dut.ddram.state == 6 && dut.ddram.ram_write;
		if (issued && !vw_issued_d) begin
			wa = dut.ddram.ram_address[19:3];   // ram_address is [27:1]: {8'b0, addr[19:3], 2'b00}
			if (vw_fw_a1_d != wa) begin
				vw_fw_wrong++;
				errors++;
				// the flag used differs from the written word's own
				if (fw_flag(vw_fw_a1_d) != fw_flag(wa)) vw_fw_wrong_effect++;
				if (vw_fw_wrong <= 20)
					$display("[%0t] VRAM write to %05h issued with the flash-write lookup of %05h (flags %b/%b)",
					         $realtime, {wa, 1'b0}, {vw_fw_a1_d, 1'b0}, fw_flag(wa), fw_flag(vw_fw_a1_d));
			end
		end
		vw_issued_d <= issued;
		vw_fw_a1_d <= vw_fw_a1;
		if ((lw && (dut.ddram.state != 0 || dut.ddram.DDRAM_BUSY)) || (rw && (dut.ddram.state != 0 || dut.ddram.DDRAM_BUSY)))
			vw_deferred++;
		vw_old_lwe <= |dut.ddram.lwe;  vw_old_lras <= dut.ddram.lras;
		vw_old_rwe <= |dut.ddram.rwe;  vw_old_rras <= dut.ddram.rras;
		vw_fw_a1 <= dut.ddram.vram_fw.ADDR1;
	end
	final $display("tb_boot: off-chip VRAM writes %0d (%0d latched while ddram.sv was busy), %0d lost, %0d issued with another address's flash-write lookup (%0d with a different flag)",
	               vw_writes, vw_deferred, vw_lost, vw_fw_wrong, vw_fw_wrong_effect);

	// ---------------- VRAM shadow model ----------------
	// What the 3DO's VRAM holds by the VRAM bus semantics, per side (0 = L,
	// bits 31..16; 1 = R, bits 15..0; 16-bit entries at word address
	// A[17:0], rows of 512), updated from the VRAM modules' own command
	// decode (vram.sv):
	//  * random writes: RAS low, WE newly low, byte lanes ~WE_N;
	//  * flash writes: the whole row <- the side's COLOR register, under the
	//    write mask;
	//  * read transfers: shift register <- row, from the start column to
	//    the end of the half (split) or of the row;
	//  * write transfers: row <- shift register, under the write mask.
	// The write mask is the CPU's write data to SPORT space (MADAM), on the
	// side's data bus once CAS falls (PHASE2: the core registers the CPU's
	// write data at PHASE1, after RAS has fallen): 1 bits are written, 0
	// bits keep the row's.
	// A partial mask outside the FPGA makes vram.sv read the destination row
	// first (MRD_EXEC): its beats are checked against the shadow row, and
	// the command's mask and source are those of the RAS fall it began at.
	// The CPU's SPORT transfers (MADAM CPU_SPORT_SEL when RAS falls) have a
	// shift register of their own, the others (video, CLUT/VDL) share one:
	// a page copy stores the row its read transfer loaded, as on hardware,
	// where the OS copies during vertical blanking.
	// BRAM and the SDRAM model both start at zero, and so does the shadow.
	// Checks (TB errors):
	//  * every shift-register beat a read transfer gets from the external
	//    path (vram_rtcache.sv / ddram.sv) equals the shadow row as it was
	//    when the transfer started;
	//  * at the end, every off-chip word as ddram.sv returns it (lazy
	//    flash fill applied) equals the shadow.
	// +vram_watch=<row> (hex) logs every event on one VRAM row.
	bit [15:0] shv [2][1<<18];
	bit [15:0] shs [2][512];               // video/CLUT shift register
	bit [15:0] shc [2][512];               // CPU (SPORT) shift register
	bit        sh_ras_m [2] = '{1, 1};     // RAS_N at the previous clk_mem edge
	bit        sh_xfer_cpu [2];            // the transfer in progress is the CPU's
	bit        sh_copy_open [2], sh_copy_hit [2];
	int        sh_copies = 0, sh_copies_crossed = 0, sh_legacy_mwts = 0;
	int        sh_rts = 0, sh_mwts = 0, sh_fws = 0, sh_split_mwts = 0;
	int        sh_rt_bad = 0, sh_beats = 0, sh_beats_bad = 0, sh_mem_bad = 0, sh_mem_checked = 0;
	int        sh_watch = -1, sh_watch_n = 0;
	bit [ 8:0] sh_rt_row [2];
	bit        sh_rt_bad_this [2];
	realtime   sh_rt_t [2];
	bit        sh_ras_old [2] = '{1, 1}, sh_we_old [2] = '{1, 1};
	bit        sh_rt_d [2], sh_mwt_d [2], sh_fw_d [2], sh_mrd_d [2];
	bit [15:0] sh_mask [2];                // data bus at the last CAS fall
	bit        sh_cas_m [2] = '{1, 1};
	bit [15:0] sh_cmd_mask [2];            // mask and source of a write after its row read
	bit        sh_cmd_cpu [2], sh_mrd_open [2];
	int        sh_masked = 0, sh_mrds = 0, sh_mrd_beats = 0, sh_mrd_bad = 0;
	// +vram_watch_from=<ms>: log the row's events from then on (the log
	// stops after 100000 lines); +vram_watch_col=<col> (hex): also log every
	// write to that column pair (one 64-bit SDRAM beat) of the row from the
	// start, with the hardware side (ddram.sv, vram_rtcache.sv) of each.
	realtime   sh_watch_from = 0;
	int        sh_watch_col = -1, sh_watch_wn = 0;
	initial begin
		int ms;
		if ($value$plusargs("vram_watch=%h", sh_watch))
			$display("tb_boot: logging VRAM row %03h (VRAM +%05h)", sh_watch, sh_watch * 2048);
		if ($value$plusargs("vram_watch_from=%d", ms)) begin
			sh_watch_from = ms * 1ms;
			$display("tb_boot: logging the row from %0d ms", ms);
		end
		if ($value$plusargs("vram_watch_col=%h", sh_watch_col))
			$display("tb_boot: logging writes to columns %03h-%03h of the row from the start",
			         sh_watch_col & 'h1fe, sh_watch_col | 1);
	end

	function automatic bit sh_watched(input [8:0] row);
		if (sh_watch < 0 || row != 9'(sh_watch) || $realtime < sh_watch_from || sh_watch_n >= 100000) return 0;
		sh_watch_n++;
		return 1;
	endfunction

	// a write to the watched column pair (logged whatever the time)
	function automatic bit sh_watched_word(input [8:0] row, input [8:0] col);
		if (sh_watch < 0 || sh_watch_col < 0 || row != 9'(sh_watch) || col[8:1] != 8'(sh_watch_col >> 1)) return 0;
		if ($realtime >= sh_watch_from) return sh_watched(row);
		if (sh_watch_wn >= 100000) return 0;
		sh_watch_wn++;
		return 1;
	endfunction

	task automatic sh_write(input int s, input [17:0] a, input [15:0] d, input [1:0] we_n);
		if (!we_n[1]) shv[s][a][15:8] = d[15:8];
		if (!we_n[0]) shv[s][a][ 7:0] = d[ 7:0];
		if (sh_watched_word(a[17:9], a[8:0]) || sh_watched(a[17:9]))
			$display("[%0t] VRAM row %03h: %s write %05h <= %04h (lanes %b)", $realtime, a[17:9], s ? "R" : "L", a, d, ~we_n);
	endtask

	task automatic sh_rt_start(input int s, input [8:0] row, input [8:0] pos, input bit split);
		bit [8:0] last;
		last = split ? {pos[8], 8'hFF} : 9'h1FF;
		sh_xfer_cpu[s] = sh_cpu[s];
		if (sh_cpu[s]) begin
			for (int i = pos; i <= last; i++) shc[s][i] = shv[s][{row, 9'(i)}];
			sh_copy_open[s] = 1;
			sh_copy_hit[s] = 0;
		end else begin
			for (int i = pos; i <= last; i++) shs[s][i] = shv[s][{row, 9'(i)}];
			if (sh_copy_open[s]) sh_copy_hit[s] = 1;   // inside a copy
		end
		sh_rts++;
		sh_rt_row[s] = row;
		sh_rt_bad_this[s] = 0;
		sh_rt_t[s] = $realtime;
		if (sh_watched(row))
			$display("[%0t] VRAM row %03h: %s %s read transfer from column %03h, split %b (first words %04h %04h)",
			         $realtime, row, s ? "R" : "L", sh_cpu[s] ? "CPU" : "video", pos, split,
			         shv[s][{row, pos}], shv[s][{row, 9'(pos + 1)}]);
	endtask

	task automatic sh_rt_beat(input int s, input [8:0] wa, input [31:0] wd);
		bit [31:0] e;
		e = sh_xfer_cpu[s] ? {shc[s][wa], shc[s][9'(wa + 1)]} : {shs[s][wa], shs[s][9'(wa + 1)]};
		sh_beats++;
		if (sh_watch_col >= 0 && wa[8:1] == 8'(sh_watch_col >> 1) && sh_watched(sh_rt_row[s]))
			$display("[%0t] VRAM row %03h: %s beat at column %03h: %08h (shadow %08h)", $realtime, sh_rt_row[s], s ? "R" : "L", wa, wd, e);
		if (wd == e) return;
		sh_beats_bad++;
		if (sh_rt_bad_this[s]) return;
		sh_rt_bad_this[s] = 1;
		sh_rt_bad++;
		errors++;
		if (sh_rt_bad <= 20 || sh_watched(sh_rt_row[s]))
			$display("[%0t] TB ERROR: %s read transfer of VRAM row %03h delivered %08h at column %03h, VRAM holds %08h (%0.2f us after the transfer started)",
			         $realtime, s ? "R" : "L", sh_rt_row[s], wd, wa, e, ($realtime - sh_rt_t[s]) / 1000.0);
	endtask

	// CPU write transfers whose source row (the CPU shift register) holds one
	// value in all 512 words of that VRAM half, as a frame buffer clear's
	// does, per half. +copy_log_ms=<n>: each CPU write transfer from n ms on
	// for 50 ms, with the video line it starts in.
	int        sh_copies_unif [2] = '{0, 0}, sh_copy_log_ms = -1, sh_copy_log_n = 0;
	initial void'($value$plusargs("copy_log_ms=%d", sh_copy_log_ms));
	task automatic sh_mwt_start(input int s, input [8:0] row, input bit split, input [15:0] mask, input bit cpu);
		if (mask != 16'hFFFF) sh_masked++;
		if (cpu) begin
			bit unif;
			unif = 1;
			for (int i = 0; i < 512; i++) begin
				shv[s][{row, 9'(i)}] = (shc[s][i] & mask) | (shv[s][{row, 9'(i)}] & ~mask);
				if (shc[s][i] != shc[s][0]) unif = 0;
			end
			if (unif) sh_copies_unif[s]++;
			if (sh_copy_log_ms >= 0 && $realtime >= sh_copy_log_ms * 1ms && $realtime < (sh_copy_log_ms + 50) * 1ms &&
			    sh_copy_log_n < 20000) begin
				sh_copy_log_n++;
				$display("[%0t] copy: %s CPU write transfer into row %03h at video line %0d, source row %03h %s",
				         $realtime, s ? "R" : "L", row, dut.p3do.madam.SPORT.VCOUNT, sh_rt_row[s],
				         unif ? $sformatf("uniform %04h", shc[s][0]) : "not uniform");
			end
			if (s == 0) begin
				sh_copies++;
				if (sh_copy_hit[0]) sh_copies_crossed++;
			end
			sh_copy_hit[s] = 0;
		end else begin
			for (int i = 0; i < 512; i++) shv[s][{row, 9'(i)}] = (shs[s][i] & mask) | (shv[s][{row, 9'(i)}] & ~mask);
			sh_legacy_mwts++;
		end
		sh_mwts++;
		if (split) sh_split_mwts++;
		if (sh_watched_word(row, 9'(sh_watch_col)) || sh_watched(row))
			$display("[%0t] VRAM row %03h: %s %s write transfer (last read transfer: row %03h), split %b, mask %04h (first words %04h %04h)",
			         $realtime, row, s ? "R" : "L", cpu ? "CPU" : "video", sh_rt_row[s], split, mask,
			         shv[s][{row, 9'h000}], shv[s][{row, 9'h001}]);
	endtask

	task automatic sh_fw_start(input int s, input [8:0] row, input [15:0] color, input [15:0] mask);
		for (int i = 0; i < 512; i++) shv[s][{row, 9'(i)}] = (color & mask) | (shv[s][{row, 9'(i)}] & ~mask);
		sh_fws++;
		if (mask != 16'hFFFF) sh_masked++;
		if (sh_watched_word(row, 9'(sh_watch_col)) || sh_watched(row))
			$display("[%0t] VRAM row %03h: %s flash write %04h, mask %04h", $realtime, row, s ? "R" : "L", color, mask);
	endtask

	// a beat of the destination row's read before a masked write: the row as it is
	task automatic sh_mrd_beat(input int s, input [8:0] row, input [8:0] wa, input [31:0] wd);
		bit [31:0] e;
		e = {shv[s][{row, wa}], shv[s][{row, 9'(wa + 1)}]};
		sh_mrd_beats++;
		if (wd == e) return;
		sh_mrd_bad++;
		errors++;
		if (sh_mrd_bad <= 20)
			$display("[%0t] TB ERROR: %s read of VRAM row %03h for a masked write delivered %08h at column %03h, VRAM holds %08h",
			         $realtime, s ? "R" : "L", row, wd, wa, e);
	endtask

	`define SH_SIDE(S, M) \
	always @(posedge clk_sys) begin \
		if (!dut.M.RAS_N && !sh_ras_old[S] && sh_we_old[S] && dut.M.WE_N != 2'b11) \
			sh_write(S, dut.M.A, dut.M.D, dut.M.WE_N); \
		sh_ras_old[S] <= dut.M.RAS_N; \
		sh_we_old[S]  <= &dut.M.WE_N; \
	end \
	always @(posedge clk_mem) begin \
		if (!dut.M.RAS_N && sh_ras_m[S]) sh_cpu[S] = dut.p3do.madam.CPU_SPORT_SEL; \
		if (!dut.M.RAS_N && !dut.M.CAS_N && sh_cas_m[S]) sh_mask[S] = dut.M.D; \
		sh_ras_m[S] <= dut.M.RAS_N; \
		sh_cas_m[S] <= dut.M.CAS_N; \
		if (dut.M.RT_EXEC && !sh_rt_d[S]) sh_rt_start(S, dut.M.MEM_ROW, dut.M.SREG_POS, dut.M.SPLIT); \
		if (dut.M.MRD_EXEC && !sh_mrd_d[S]) begin \
			sh_cmd_mask[S] = sh_mask[S]; sh_cmd_cpu[S] = sh_cpu[S]; sh_mrd_open[S] = 1; sh_mrds++; \
		end \
		if (dut.M.MWT_EXEC && !sh_mwt_d[S]) begin \
			if (!sh_mrd_open[S]) begin sh_cmd_mask[S] = sh_mask[S]; sh_cmd_cpu[S] = sh_cpu[S]; end \
			sh_mrd_open[S] = 0; \
			if (dut.M.FWM) sh_fw_start(S, dut.M.MEM_ROW, dut.M.COLOR, sh_cmd_mask[S]); \
			else sh_mwt_start(S, dut.M.MEM_ROW, dut.M.SPLIT, sh_cmd_mask[S], sh_cmd_cpu[S]); \
		end \
		if (dut.M.FW_EXEC && !sh_fw_d[S]) sh_fw_start(S, dut.M.MEM_ROW, dut.M.COLOR, sh_mask[S]); \
		if (dut.M.SR_WE && !dut.M.ISTE_DELAYED) begin \
			if (dut.M.SR_WSCR) sh_mrd_beat(S, dut.M.MEM_ROW, dut.M.SR_WA, dut.M.SR_WD); \
			else sh_rt_beat(S, dut.M.SR_WA, dut.M.SR_WD); \
		end \
		sh_rt_d[S]  <= dut.M.RT_EXEC; \
		sh_mwt_d[S] <= dut.M.MWT_EXEC; \
		sh_fw_d[S]  <= dut.M.FW_EXEC; \
		sh_mrd_d[S] <= dut.M.MRD_EXEC; \
	end
	`SH_SIDE(0, vram_l)
	`SH_SIDE(1, vram_r)
	`undef SH_SIDE

	// vram.sv skips a split read transfer of the half-row the video shift
	// register holds (MiSTer core; real VRAM always reloads). Counted, with
	// those where the half-row has changed since it was loaded, so the
	// serial output differs from real VRAM's, and the reloads forced by a
	// CPU copy into the held row (Game Bub port).
	int        sk_skips = 0, sk_stale = 0, sk_copy_inv = 0;
	bit        sk_ras_m = 1, sk_rdy_m = 1, sk_vsrv_d = 0;
	always @(posedge clk_mem) begin
		// vram.sv decodes a command when RAS falls, or when RDY rises for one
		// that came during a transfer
		if (((!dut.vram_l.RAS_N && sk_ras_m) || (dut.vram_l.RDY && !sk_rdy_m)) &&
		    !(dut.vram_l.RT_EXEC || dut.vram_l.MWT_EXEC || dut.vram_l.FW_EXEC) &&
		    !dut.vram_l.OE_N && dut.vram_l.WE_N != 2'b00 && dut.vram_l.DSF1 && !dut.p3do.madam.CPU_SPORT_SEL &&
		    dut.vram_l.VSR_V && dut.vram_l.VSR_TAG == dut.vram_l.A[17:8]) begin
			bit d;
			d = 0;
			for (int i = 0; i < 256; i++)
				if (shs[0][{dut.vram_l.A[8], 8'(i)}] != shv[0][{dut.vram_l.A[17:8], 8'(i)}] ||
				    shs[1][{dut.vram_r.A[8], 8'(i)}] != shv[1][{dut.vram_r.A[17:8], 8'(i)}]) d = 1;
			sk_skips++;
			if (d) sk_stale++;
		end
		if (sk_vsrv_d && !dut.vram_l.VSR_V) sk_copy_inv++;
		sk_ras_m  <= dut.vram_l.RAS_N;
		sk_rdy_m  <= dut.vram_l.RDY;
		sk_vsrv_d <= dut.vram_l.VSR_V;
	end
	final $display("tb_boot: split read transfers skipped (half-row already in the video shift register): %0d, %0d of them after it changed in VRAM; reloads forced by a CPU copy into that row: %0d",
	               sk_skips, sk_stale, sk_copy_inv);

	// +vram_watch with +vram_watch_col: the watched column pair as stored,
	// i.e. its 64-bit beat in SDRAM bank 2 (L(w) at halfword 2w, R(w) at
	// 2w+1), its lazy flash-fill flag and its row's colour. Every change is
	// logged with what the SDRAM's secondary port and ddram.sv are doing, so
	// a write from any path shows up, whatever address it was meant for.
	bit [15:0] st_hw [4];
	bit        st_flag;
	bit [31:0] st_color;
	bit        st_init = 0;
	always @(posedge clk_mem) if (sh_watch >= 0 && sh_watch_col >= 0) begin
		bit [17:0] w;
		bit [15:0] v;
		w = {9'(sh_watch), 9'(sh_watch_col & 'h1fe)};
		for (int i = 0; i < 4; i++) begin
			v = vram_hw(19'(w * 2 + i));
			if (st_init && v != st_hw[i])
				$display("[%0t]   %s: %s(%05h) %04h -> %04h; SDRAM port: req %b we %b client %0d addr %06h; bridge state %0d; ddram.sv state %0d ram_address %06h write %b burst %0d",
				         $realtime, dut.vsram_map_v[w[17:14]] ? "SRAM" : "SDRAM", i[0] ? "R" : "L", w + (i >> 1), st_hw[i], v,
				         dut.m_req, dut.m_we, dut.arb.sel, dut.m_addr,
				         dut.ddr_bridge.st, dut.ddram.state, {dut.ddram.ram_address[27:1], 1'b0}, dut.ddram.ram_write, dut.ddram.ram_burst);
			st_hw[i] = v;
		end
		if (st_init && fw_flag(w[17:1]) != st_flag)
			$display("[%0t]   flash-fill flag of %05h %b -> %b; bfw %b bladdr %05h, fill issue %b, vram_fw ADDR1 %05h WREN1 %b",
			         $realtime, w, st_flag, fw_flag(w[17:1]), dut.ddram.bfw, dut.ddram.bladdr, dut.rtcache.fill_issue,
			         {dut.ddram.vram_fw.ADDR1, 1'b0}, dut.ddram.vram_fw.WREN1);
		st_flag = fw_flag(w[17:1]);
		if (st_init && dut.ddram.vram_color.mem[w[17:9]] != st_color)
			$display("[%0t]   colour of row %03h %08h -> %08h; bfw %b bladdr %05h, fill issue %b",
			         $realtime, w[17:9], st_color, dut.ddram.vram_color.mem[w[17:9]], dut.ddram.bfw, dut.ddram.bladdr, dut.rtcache.fill_issue);
		st_color = dut.ddram.vram_color.mem[w[17:9]];
		st_init = 1;
	end

	// +vram_watch, hardware side: what ddram.sv and vram_rtcache.sv do with
	// the watched row (random writes taken and issued, flash writes, cache
	// requests, fills and invalidations)
	bit        hw_old_lwe, hw_old_rwe, hw_old_lras, hw_old_rras, hw_issued_d, hw_fill_busy_d;
	bit        hw_req_d [2];
	bit [ 9:0] hw_req_h [2];
	always @(posedge clk_mem) if (sh_watch >= 0) begin
		bit lw, rw, issued;
		bit [8:0] row;
		row = 9'(sh_watch);
		lw = |dut.ddram.lwe && !hw_old_lwe && dut.ddram.lras && hw_old_lras;
		rw = |dut.ddram.rwe && !hw_old_rwe && dut.ddram.rras && hw_old_rras;
		if (lw && (sh_watched_word(dut.ddram.laddr[19:11], dut.ddram.laddr[10:2]) || sh_watched(dut.ddram.laddr[19:11])))
			$display("[%0t]   ddram.sv takes L write %05h <= %04h (lanes %b), state %0d, DDRAM busy %b, writes pending %b%b",
			         $realtime, dut.ddram.laddr, dut.ddram.ldin, dut.ddram.lwe, dut.ddram.state, dut.ddram.DDRAM_BUSY,
			         dut.ddram.write_lpend, dut.ddram.write_rpend);
		if (rw && (sh_watched_word(dut.ddram.raddr[19:11], dut.ddram.raddr[10:2]) || sh_watched(dut.ddram.raddr[19:11])))
			$display("[%0t]   ddram.sv takes R write %05h <= %04h (lanes %b), state %0d, DDRAM busy %b, writes pending %b%b",
			         $realtime, dut.ddram.raddr, dut.ddram.rdin, dut.ddram.rwe, dut.ddram.state, dut.ddram.DDRAM_BUSY,
			         dut.ddram.write_lpend, dut.ddram.write_rpend);
		issued = dut.ddram.state == 6 && dut.ddram.ram_write;
		if (issued && !hw_issued_d && dut.ddram.ram_address[27:20] == '0 &&
		    (sh_watched_word(dut.ddram.ram_address[19:11], {dut.ddram.ram_address[10:3], 1'b0}) || sh_watched(dut.ddram.ram_address[19:11])))
			$display("[%0t]   ddram.sv issues the write of %05h: data %016h, byte enables %08b, flash flag was %b",
			         $realtime, {dut.ddram.ram_address[19:3], 1'b0}, dut.ddram.ram_din, dut.ddram.ram_ba, dut.ddram.vram_fw_bwr);
		if (dut.ddram.bfw && dut.ddram.bladdr[19:11] == row && sh_watched(row))
			$display("[%0t]   ddram.sv flash write %05h, colour %08h", $realtime, dut.ddram.bladdr, dut.ddram.bin[31:0]);
		// cache requests (registered), and whether they hit (next cycle)
		for (int s = 0; s < 2; s++) begin
			if (hw_req_d[s] && sh_watched(row))
				$display("[%0t]   RT cache: %s request for half-row %03h %s", $realtime, s ? "R" : "L", hw_req_h[s],
				         dut.rtcache.dem_pend[s] ? "missed" : $sformatf("hit entry %0d (dirty %b)", dut.rtcache.dl_e[s], dut.rtcache.dirty[dut.rtcache.dl_e[s]]));
			hw_req_d[s] = dut.rtcache.req_v[s] && dut.rtcache.req_a[s][17:9] == row;
			hw_req_h[s] = dut.rtcache.req_a[s][17:8];
		end
		if (dut.rtcache.fill_issue && dut.rtcache.fill_h[9:1] == row && sh_watched(row))
			$display("[%0t]   RT cache: fill of half-row %03h into entry %0d", $realtime, dut.rtcache.fill_h, dut.rtcache.fill_e);
		if (hw_fill_busy_d && !dut.rtcache.fill_busy && dut.rtcache.fill_h[9:1] == row && sh_watched(row))
			$display("[%0t]   RT cache: fill of half-row %03h done, dirty %b", $realtime, dut.rtcache.fill_h, dut.rtcache.dirty[dut.rtcache.fill_e]);
		for (int i = 0; i < 16; i++)
			if (dut.rtcache.snoop_hit[i] && dut.rtcache.tag[i][9:1] == row && sh_watched(row))
				$display("[%0t]   RT cache: entry %0d (half-row %03h) %s by a %s, %s", $realtime, i, dut.rtcache.tag[i],
				         dut.rtcache.fill_busy && dut.rtcache.fill_e == 4'(i) ? "marked dirty" : "invalidated",
				         dut.rtcache.sn_fw ? "flash write" : $sformatf("DDRAM write to half-row %03h", dut.rtcache.sn_h),
				         dut.rtcache.fill_busy && dut.rtcache.fill_e == 4'(i) ? "while filling" : "idle");
		hw_issued_d    <= issued;
		hw_fill_busy_d <= dut.rtcache.fill_busy;
		hw_old_lwe <= |dut.ddram.lwe;  hw_old_lras <= dut.ddram.lras;
		hw_old_rwe <= |dut.ddram.rwe;  hw_old_rras <= dut.ddram.rras;
	end

	// on-chip VRAM (vram.sv USE_INT_RAM1; this port has no BRAM4/BRAM2)
	function automatic bit vram_internal(input [17:0] w);
		bit [3:0] b1;
		b1 = dut.BRAM1_OFFS;
		return (w >= ({b1, 16'h0000} >> 2) && w <= ({b1, 16'hBFFF} >> 2)) || w >= (20'hFC000 >> 2);
	endfunction

	// Off-chip VRAM halfword h (VRAM byte offset 2h; ddram.sv layout: VRAM
	// word w is L at 2w, R at 2w+1) as stored: in the SRAM if its 64 KiB
	// block is mapped there (vram_sram.sv), else in SDRAM bank 2.
	function automatic [15:0] vram_hw(input [18:0] h);
		bit [3:0] b;
		b = h[18:15];
		if (dut.vsram_map_v[b]) return sram.mem[{dut.vsram_map_slot[b], h[14:0]}];
		return sdram.peek({2'd2, 22'(h)});
	endfunction

	// Off-chip VRAM word w as ddram.sv returns it: a beat whose lazy
	// flash-fill flag is set reads as its row's colour {L, R}.
	function automatic [31:0] vram_visible(input [17:0] w);
		if (fw_flag(w[17:1])) return dut.ddram.vram_color.mem[w[17:9]];
		return {vram_hw(19'(w * 2)), vram_hw(19'(w * 2 + 1))};
	endfunction

	task automatic sh_check_memory();
		int rows_bad [512];
		string r = "";
		int nrows = 0;
		for (int w = 0; w < (1 << 18); w++) begin
			bit [31:0] v, e;
			if (vram_internal(18'(w))) continue;
			v = vram_visible(18'(w));
			e = {shv[0][w], shv[1][w]};
			sh_mem_checked++;
			if (v == e) continue;
			if (sh_mem_bad < 10)
				$display("tb_boot: VRAM +%05h (row %03h) holds %08h, the 3DO wrote %08h", w * 4, w >> 9, v, e);
			sh_mem_bad++;
			rows_bad[w >> 9]++;
		end
		foreach (rows_bad[i]) if (rows_bad[i] != 0) begin
			nrows++;
			if (nrows <= 16) r = {r, $sformatf(" %03h:%0d", i, rows_bad[i])};
		end
		if (sh_mem_bad != 0) begin
			errors++;
			$display("tb_boot: TB ERROR: %0d off-chip VRAM words differ from what the 3DO wrote, in %0d rows (row:words)%s",
			         sh_mem_bad, nrows, r);
		end
		$display("tb_boot: VRAM shadow: %0d read transfers, %0d external beats checked (%0d transfers delivered wrong data, %0d beats), %0d write transfers (%0d split, %0d not the CPU's), %0d flash writes; off-chip VRAM words differing at the end: %0d of %0d",
		         sh_rts, sh_beats, sh_rt_bad, sh_beats_bad, sh_mwts, sh_split_mwts, sh_legacy_mwts, sh_fws, sh_mem_bad, sh_mem_checked);
		$display("tb_boot: write masks: %0d write transfers and flash writes with a mask other than FFFF; %0d destination-row reads (%0d beats, %0d wrong)",
		         sh_masked, sh_mrds, sh_mrd_beats, sh_mrd_bad);
		$display("tb_boot: SPORT page copies (CPU write transfers) %0d, %0d of them with a video/CLUT transfer between their read and write transfer",
		         sh_copies, sh_copies_crossed);
		$display("tb_boot: CPU write transfers from a uniform source row: left %0d, right %0d",
		         sh_copies_unif[0], sh_copies_unif[1]);
	endtask
	// where CLUT/VDL and video transfers point (64 KiB VRAM blocks)
	int blk_clut [16], blk_vid [16];
	reg clut_d = 0, vid_d = 0;
	bit [3:0] last_rt_blk;
	always @(posedge clk_mem) begin
		if (dut.vram_l.RT_EXEC && !rt_exec_d && !sh_cpu[0]) last_rt_blk = dut.vram_l.MEM_ROW[8:5];
		clut_d <= dut.p3do.madam.SPORT.CLUT_TRANS_EXEC;
		vid_d  <= dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;
		if (dut.p3do.madam.SPORT.CLUT_TRANS_EXEC && !clut_d) blk_clut[last_rt_blk]++;
		if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !vid_d) blk_vid[last_rt_blk]++;
	end
	final begin
		string a = "", b = "";
		for (int i = 0; i < 16; i++) begin
			a = {a, $sformatf(" %0h:%0d", i, blk_clut[i])};
			b = {b, $sformatf(" %0h:%0d", i, blk_vid[i])};
		end
		$display("tb_boot: CLUT/VDL transfers per 64 KiB VRAM block:%s", a);
		$display("tb_boot: video transfers per 64 KiB VRAM block:%s", b);
	end

	// First-data latency of external VRAM read transfers, by what the DDR
	// path was doing when the request came in.
	reg esrd_d = 0, blte_d = 0;
	realtime esrd_t;
	bit esrd_wait;
	int lat_hist [8];          // <0.2, <0.4, <0.8, <1.6, <3.2, <6.4, <12.8, >=12.8 us
	int lat_cause_busy = 0, lat_n = 0;
	real lat_sum = 0, lat_busy_sum = 0;
	bit req_while_busy;
	always @(posedge clk_mem) begin
		esrd_d <= dut.vram_l.ESRD;
		if (dut.vram_l.ESRD && !esrd_d) begin
			esrd_t = $realtime;
			esrd_wait = 1;
			req_while_busy = (dut.ddram.state != 0) || (dut.ddr_bridge.st != 0);
		end
		if (esrd_wait && dut.ddr_blte) begin
			real l;
			int b;
			l = ($realtime - esrd_t) / 1000.0;
			esrd_wait = 0;
			b = l < 0.2 ? 0 : l < 0.4 ? 1 : l < 0.8 ? 2 : l < 1.6 ? 3 : l < 3.2 ? 4 : l < 6.4 ? 5 : l < 12.8 ? 6 : 7;
			lat_hist[b]++;
			lat_n++; lat_sum += l;
			if (req_while_busy) begin lat_cause_busy++; lat_busy_sum += l; end
		end
	end
	final begin
		$display("tb_boot: VRAM read transfers: %0d, mean first-data latency %0.2f us", lat_n, lat_n ? lat_sum / lat_n : 0.0);
		$display("tb_boot:   requested while the DDR path was busy: %0d (mean %0.2f us)", lat_cause_busy,
		         lat_cause_busy ? lat_busy_sum / lat_cause_busy : 0.0);
		$display("tb_boot:   latency histogram <0.2/<0.4/<0.8/<1.6/<3.2/<6.4/<12.8/more us: %0d %0d %0d %0d %0d %0d %0d %0d",
		         lat_hist[0], lat_hist[1], lat_hist[2], lat_hist[3], lat_hist[4], lat_hist[5], lat_hist[6], lat_hist[7]);
	end

	// Video lines must not start shifting before both VRAM halves have had
	// their read transfer for the line (requested since the line's video DMA
	// request). Otherwise the line shows the serial register's old contents,
	// e.g. the VDL words of the CLUT transfer. A late line during which the
	// 3DO was paused comes from the port's memory system (SDRAM, RT cache) and
	// counts as a TB error. Without a pause it is MADAM's own arbitration
	// (upstream logic: a CPU access to CLIO, e.g. an LDM from the XBUS data
	// port while the BIOS reads the CD, goes before the video DMA): counted
	// and reported separately.
	bit lt_req_d = 0, lt_exec_d = 0, lt_rtl_d = 0, lt_rtr_d = 0, lt_l = 0, lt_r = 0, lt_armed = 0, lt_paused = 0;
	int late_lines = 0, late_arb = 0, video_lines = 0;
	int late_per_s [64];   // late lines with the 3DO paused, per second of 3DO time
	bit draining = 0;      // the run is over: the TB holds the pause itself
	always @(posedge clk_mem) begin
		if (dut.reset_3do) lt_armed = 0;
		else begin
			if (dut.p3do.madam.SPORT.VIDOUT_REQ && !lt_req_d) begin lt_l = 0; lt_r = 0; lt_armed = 1; lt_paused = 0; end
			if (dut.pause) lt_paused = 1;
			// the CPU's SPORT transfers (page copies) have their own shift
			// register and do not load the line
			if (dut.vram_l.RT_REQ && !lt_rtl_d && !dut.vram_l.XFER_CPU) lt_l = 1;
			if (dut.vram_r.RT_REQ && !lt_rtr_d && !dut.vram_r.XFER_CPU) lt_r = 1;
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !lt_exec_d && lt_armed) begin
				video_lines++;
				if (draining) ;
				else if ((!lt_l || !lt_r) && lt_paused) begin
					late_lines++;
					errors++;
					// int'() of a real rounds: truncate to the second the line is in
					late_per_s[$realtime < 63s ? int'($floor($realtime / 1s)) : 63]++;
					if (late_lines <= 10)
						$display("[%0t] TB ERROR: video line %0d started before its read transfer (left %b right %b), 3DO paused",
						         $realtime, dut.p3do.madam.SPORT.VCOUNT, lt_l, lt_r);
				end else if (!lt_l || !lt_r) begin
					late_arb++;
					if (late_arb <= 3)
						$display("[%0t] video line %0d started before its read transfer (left %b right %b): MADAM bus arbitration, no pause",
						         $realtime, dut.p3do.madam.SPORT.VCOUNT, lt_l, lt_r);
				end
			end
		end
		lt_req_d <= dut.p3do.madam.SPORT.VIDOUT_REQ;
		lt_exec_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;
		lt_rtl_d <= dut.vram_l.RT_REQ;
		lt_rtr_d <= dut.vram_r.RT_REQ;
	end
	final begin
		string t = "";
		$display("tb_boot: video lines %0d, started before their read transfer: %0d with the 3DO paused (errors), %0d by MADAM's bus arbitration",
		         video_lines, late_lines, late_arb);
		foreach (late_per_s[i]) if (late_per_s[i] != 0) t = {t, $sformatf(" %0d:%0d", i, late_per_s[i])};
		if (late_lines != 0) $display("tb_boot:   late lines with the 3DO paused, per second of 3DO time (s:lines, s = s to s+1 s):%s", t);
	end

	// Player bus. MADAM_PLAYER drives PBCLK from the video clock and takes a
	// bit per falling edge (SHIFT_PEND), but shifts it in on its bus clock,
	// which a pause stops; a second falling edge before it has done so loses
	// a bit, and the pad words after it arrive misaligned. Per frame (from
	// the pad's latch): the falling edges in the shifting window against the
	// shifts done, and the first 32-bit word received against the one the
	// pad latched (an error).
	int pb_frames = 0, pb_lost_frames = 0, pb_lost_bits = 0, pb_words = 0, pb_bad_words = 0, pb_falls = 0, pb_strobes = 0;
	bit pb_clk_d = 0, pb_latch_d = 0, pb_active = 0, pb_checked = 0, pb_check_next = 0;
	bit [31:0] pb_expect;
	always @(posedge clk_sys) begin
		if (dut.reset_3do) pb_active = 0;
		else begin
			if (dut.pad.LATCH && !pb_latch_d) begin
				if (pb_active) begin
					pb_frames++;
					if (pb_falls != pb_strobes) begin
						pb_lost_frames++;
						pb_lost_bits += pb_falls - pb_strobes;
						if (pb_lost_frames <= 10)
							$display("[%0t] player bus: %0d falling PBCLK edges, %0d bits shifted in during the last frame", $realtime, pb_falls, pb_strobes);
					end
				end
				pb_active = 1; pb_falls = 0; pb_strobes = 0; pb_checked = 0; pb_check_next = 0;
				pb_expect = dut.pad.IN_DATA[255:224];
			end
			if (pb_active) begin
				// a data bit's falling edge: every 200 video clocks in the line, the
				// last at 1558 (not the one MADAM forces when the DMA has ended and
				// it drops ENABLE with PBCLK high, which carries no bit)
				if (!dut.p3do.madam.PLAYER.PBCLK && pb_clk_d && dut.p3do.madam.V_CNT >= 10'd16 && dut.p3do.madam.V_CNT <= 10'd239 &&
				    ((dut.p3do.madam.H_CNT <= 11'd1402 && (dut.p3do.madam.H_CNT % 200 >= 198 || dut.p3do.madam.H_CNT % 200 <= 2)) ||
				     (dut.p3do.madam.H_CNT >= 11'd1557 && dut.p3do.madam.H_CNT <= 11'd1561)))
					pb_falls++;
				// the first word is in SHF_REG one cycle after its 32nd shift
				if (pb_check_next) begin
					pb_check_next = 0;
					pb_words++;
					if (dut.p3do.madam.PLAYER.SHF_REG != pb_expect) begin
						pb_bad_words++;
						errors++;
						if (pb_bad_words <= 10)
							$display("[%0t] TB ERROR: player bus word %08h, the pad latched %08h", $realtime, dut.p3do.madam.PLAYER.SHF_REG, pb_expect);
					end
				end
				// a shift: a MADAM bus clock (stopped by PAUSE) with the strobe set
				if (dut.p3do.madam.CE_R && dut.p3do.madam.PLAYER.SHIFT_STROBE) begin
					pb_strobes++;
					if (dut.p3do.madam.PLAYER.SHIFT_LAST && !pb_checked) begin
						pb_checked = 1;
						pb_check_next = 1;
					end
				end
			end
		end
		pb_clk_d    = dut.p3do.madam.PLAYER.PBCLK;
		pb_latch_d  = dut.pad.LATCH;
	end
	final $display("tb_boot: player bus: %0d frames, %0d with bits lost (%0d bits); first words checked %0d, wrong %0d",
	               pb_frames, pb_lost_frames, pb_lost_bits, pb_words, pb_bad_words);

	// Cycle trace of MADAM's arbitration (+clio_trace=<start us>, for
	// +clio_trace_us=<us>, default 6): per MADAM bus clock (CE_F), the bus
	// state, the CPU's grant and its CPU interface wait/stretch, the CPU's
	// CLIO access handshake (EXTPIF CPU_REQ, CLIO's ready and I/O state), the
	// video request and grant, and the CPU address.
	longint ct_start = -1;
	int ct_us = 6;
	initial begin
		void'($value$plusargs("clio_trace=%d", ct_start));
		void'($value$plusargs("clio_trace_us=%d", ct_us));
	end
	always @(posedge clk_sys)
		if (ct_start >= 0 && $realtime >= ct_start * 1us && $realtime < ct_start * 1us + ct_us * 1us && dut.p3do.madam.CE_F)
			$display("[%0t] ct: %-14s ph%0d%0d grant %b req %b ccode %0d cready_n %b io_st %0d cpuif pause %b stretch %b | vid req %b ack %b | hi %b | A %08h nMREQ %b",
			         $realtime, dut.p3do.madam.ARB.BUS_ST.name(), dut.p3do.madam.ARB.PHASE1, dut.p3do.madam.ARB.PHASE2,
			         dut.p3do.madam.CPU_GRANT, dut.p3do.madam.EXTPIF.CPU_REQ, dut.p3do.madam.EXTPIF.CPU_CCODE,
			         dut.p3do.madam.CREADY_N, dut.p3do.clio.IO_ST, dut.p3do.madam.CPUIF.PAUSE, dut.p3do.madam.CPUIF.STRETCH,
			         dut.p3do.madam.SPORT.VIDOUT_REQ, dut.p3do.madam.ARB.VIDOUT_ACK, dut.p3do.madam.ARB.HI_PRIO_REQ,
			         dut.p3do.madam.A, dut.p3do.madam.CPUIF.nMREQ);

	// Late-line diagnosis (+late_diag[=<n>], details of the first n late or
	// nearly late lines, default 40). For every video line: the time from
	// MADAM's video DMA request to its bus grant (VIDOUT_ACK), to each VRAM
	// half's read transfer request and to the line start, and how long the
	// 3DO was paused in between, by cause (ddram.sv I/O or burst busy, a
	// VRAM half not ready, the SDRAM's second port holding the 3DO, by
	// client). The slack of every line (line start minus the later of the
	// two transfer requests) goes into a histogram.
	bit ld_on = 0;
	int ld_max = 40, ld_shown = 0;
	initial if ($value$plusargs("late_diag=%d", ld_max) || $test$plusargs("late_diag")) ld_on = 1;
	realtime ld_t_req, ld_t_ack, ld_t_rl, ld_t_rr;
	int ld_hc_req, ld_n_pause, ld_n_ddrio, ld_n_ddr, ld_n_lrdy, ld_n_rrdy, ld_n_sec, ld_max_len;
	// MADAM's bus while the request waits for its grant: external port
	// (DSP/audio and XBUS DMA), CEL engine, CLUT/VDL, player, refresh, idle;
	// and the external port's grants
	int ld_b_extp, ld_b_se, ld_b_clut, ld_b_play, ld_b_ref, ld_b_idle, ld_extp_acks;
	bit ld_extp_ack_d = 0;
	int ld_late_extp = 0;   // late lines with an external-port grant in their window
	// SDRAM work started in the window (clk_mem): RT cache fills by source
	// (demand miss, prefetch, VDL hint or frame start), the CPU's SPORT read
	// transfers (page copy sources) and write transfers (page copy stores)
	int ld_f_dem, ld_f_pf, ld_f_hint, ld_cpu_rt, ld_mwt;
	bit ld_fi_d = 0, ld_m_req_d = 0, ld_cpurt_d = 0, ld_mwt_d = 0, ld_m_armed = 0;
	int ld_pf_prev = 0;
	int ld_late_src [5];   // late lines whose window had: demand fill, prefetch, hint fill, CPU RT, MWT
	always @(posedge clk_mem) if (ld_on) begin
		if (dut.p3do.madam.SPORT.VIDOUT_REQ && !ld_m_req_d) begin
			ld_m_armed = 1; ld_f_dem = 0; ld_f_pf = 0; ld_f_hint = 0; ld_cpu_rt = 0; ld_mwt = 0;
		end
		if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC) ld_m_armed = 0;
		if (ld_m_armed) begin
			if (dut.rtcache.fill_issue && !ld_fi_d) begin
				if (dut.rtcache.stat_prefetches != ld_pf_prev) begin
					if (dut.rtcache.used[dut.rtcache.fill_e]) ld_f_hint++; else ld_f_pf++;
				end else ld_f_dem++;
			end
			if (dut.vram_l.RT_REQ && dut.vram_l.XFER_CPU && !ld_cpurt_d) ld_cpu_rt++;
			if (dut.vram_l.MWT_EXEC && !ld_mwt_d) ld_mwt++;
		end
		ld_m_req_d = dut.p3do.madam.SPORT.VIDOUT_REQ;
		ld_fi_d    = dut.rtcache.fill_issue;
		ld_pf_prev = dut.rtcache.stat_prefetches;
		ld_cpurt_d = dut.vram_l.RT_REQ && dut.vram_l.XFER_CPU;
		ld_mwt_d   = dut.vram_l.MWT_EXEC;
	end
	int ld_n_cl [3];
	bit ld_armed = 0, ld_req_d = 0, ld_ack_d = 0, ld_rl_d = 0, ld_rr_d = 0, ld_exec_d = 0, ld_we;
	int ld_slack_hist [9];   // <0 (late), <0.25, <0.5, <1, <1.5, <2, <3, <4, >=4 us
	int ld_lines = 0;
	real ld_pause_late = 0, ld_pause_all = 0;
	int ld_cause_late [6];   // late lines in which each cause paused: ddr io, ddr burst, lrdy, rrdy, sec, none
	always @(posedge clk_sys) if (ld_on) begin
		if (dut.reset_3do) ld_armed = 0;
		else begin
			if (dut.p3do.madam.SPORT.VIDOUT_REQ && !ld_req_d) begin
				ld_armed = 1; ld_t_req = $realtime; ld_hc_req = dut.p3do.madam.SPORT.HCOUNT;
				ld_t_ack = -1; ld_t_rl = -1; ld_t_rr = -1;
				ld_n_pause = 0; ld_n_ddrio = 0; ld_n_ddr = 0; ld_n_lrdy = 0; ld_n_rrdy = 0; ld_n_sec = 0; ld_max_len = 0;
				ld_n_cl = '{0, 0, 0}; ld_we = 0;
				ld_b_extp = 0; ld_b_se = 0; ld_b_clut = 0; ld_b_play = 0; ld_b_ref = 0; ld_b_idle = 0; ld_extp_acks = 0;
			end
			if (ld_armed) begin
				if (dut.pause)          ld_n_pause++;
				if (dut.ddr_io_busy)    ld_n_ddrio++;
				if (dut.ddr_busy)       ld_n_ddr++;
				if (!dut.VRAM_LRDY)     ld_n_lrdy++;
				if (!dut.VRAM_RRDY)     ld_n_rrdy++;
				if (dut.sec_hold_s) begin
					ld_n_sec++;
					if (dut.arb.busy) ld_n_cl[dut.arb.sel]++;
				end
				if (dut.sdram.sec_req && dut.sdram.sec_len > ld_max_len) ld_max_len = dut.sdram.sec_len;
				if (dut.sdram.sec_req && dut.sdram.sec_we) ld_we = 1;
				if (dut.p3do.madam.ARB.VIDOUT_ACK && !ld_ack_d && ld_t_ack < 0) ld_t_ack = $realtime;
				if (ld_t_ack < 0) begin
					P3DO_PKG::BusState_t st;
					st = dut.p3do.madam.ARB.BUS_ST;
					if      (st == P3DO_PKG::BUS_IDLE) ld_b_idle++;
					else if (st >= P3DO_PKG::EXTP_PREINIT1 && st <= P3DO_PKG::EXTP_REINIT1) ld_b_extp++;
					else if (st >= P3DO_PKG::PLAY_PREINIT1 && st <= P3DO_PKG::PLAY_WRITE1) ld_b_play++;
					else if (st >= P3DO_PKG::REF_PREINIT1  && st <= P3DO_PKG::REF_WRITE3)  ld_b_ref++;
					else if (st >= P3DO_PKG::SCOB_PREINIT1 && st <= P3DO_PKG::CFB_WRITE1)  ld_b_se++;
					else if (st >= P3DO_PKG::CLUT_PREINIT1 && st <= P3DO_PKG::CLUT_MIDTRANS1) ld_b_clut++;
				end
				if (dut.p3do.madam.ARB.EXTP_ACK && !ld_extp_ack_d) ld_extp_acks++;
				if (dut.vram_l.RT_REQ && !ld_rl_d && !dut.vram_l.XFER_CPU && ld_t_rl < 0) ld_t_rl = $realtime;
				if (dut.vram_r.RT_REQ && !ld_rr_d && !dut.vram_r.XFER_CPU && ld_t_rr < 0) ld_t_rr = $realtime;
				if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !ld_exec_d) begin
					real slack, rel;
					int b;
					bit late;
					late = ld_t_rl < 0 || ld_t_rr < 0;
					slack = late ? -1.0 : ($realtime - (ld_t_rl > ld_t_rr ? ld_t_rl : ld_t_rr)) / 1000.0;
					b = late ? 0 : slack < 0.25 ? 1 : slack < 0.5 ? 2 : slack < 1.0 ? 3 : slack < 1.5 ? 4 :
					    slack < 2.0 ? 5 : slack < 3.0 ? 6 : slack < 4.0 ? 7 : 8;
					ld_slack_hist[b]++;
					ld_lines++;
					ld_pause_all += ld_n_pause * 20.0;
					if (late) begin
						ld_pause_late += ld_n_pause * 20.0;
						if (ld_n_ddrio) ld_cause_late[0]++;
						if (ld_n_ddr)   ld_cause_late[1]++;
						if (ld_n_lrdy)  ld_cause_late[2]++;
						if (ld_n_rrdy)  ld_cause_late[3]++;
						if (ld_n_sec)   ld_cause_late[4]++;
						if (!ld_n_pause) ld_cause_late[5]++;
						if (ld_extp_acks) ld_late_extp++;
						if (ld_f_dem)  ld_late_src[0]++;
						if (ld_f_pf)   ld_late_src[1]++;
						if (ld_f_hint) ld_late_src[2]++;
						if (ld_cpu_rt) ld_late_src[3]++;
						if (ld_mwt)    ld_late_src[4]++;
					end
					if ((late || slack < 0.25) && ld_shown < ld_max) begin
						ld_shown++;
						rel = $realtime - ld_t_req;
						$display("[%0t] late_diag: line %0d %s: req at HCOUNT %0d; ack +%0.2f, RT L +%0.2f R +%0.2f, start +%0.2f us; paused %0.2f us (ddr io %0.2f, ddr burst %0.2f, L not rdy %0.2f, R not rdy %0.2f, SDRAM port %0.2f: bridge %0.2f cdd %0.2f host %0.2f; longest port transfer %0d words%s)",
						         $realtime, dut.p3do.madam.SPORT.VCOUNT, late ? "LATE" : $sformatf("slack %0.2f us", slack), ld_hc_req,
						         ld_t_ack < 0 ? -1.0 : (ld_t_ack - ld_t_req) / 1000.0, ld_t_rl < 0 ? -1.0 : (ld_t_rl - ld_t_req) / 1000.0,
						         ld_t_rr < 0 ? -1.0 : (ld_t_rr - ld_t_req) / 1000.0, rel / 1000.0,
						         ld_n_pause * 0.02, ld_n_ddrio * 0.02, ld_n_ddr * 0.02, ld_n_lrdy * 0.02, ld_n_rrdy * 0.02,
						         ld_n_sec * 0.02, ld_n_cl[0] * 0.02, ld_n_cl[1] * 0.02, ld_n_cl[2] * 0.02, ld_max_len, ld_we ? ", writes" : "");
						$display("            bus until the grant: ext port (DSP/audio, XBUS) %0.2f us in %0d grants, CEL engine %0.2f, CLUT/VDL %0.2f, player %0.2f, refresh %0.2f, idle %0.2f us",
						         ld_b_extp * 0.02, ld_extp_acks, ld_b_se * 0.02, ld_b_clut * 0.02, ld_b_play * 0.02, ld_b_ref * 0.02, ld_b_idle * 0.02);
						$display("            SDRAM work started in the window: RT cache fills demand %0d, prefetch %0d, VDL hint/frame start %0d; CPU read transfers %0d, write transfers %0d",
						         ld_f_dem, ld_f_pf, ld_f_hint, ld_cpu_rt, ld_mwt);
					end
					ld_armed = 0;
				end
			end
		end
		ld_req_d  = dut.p3do.madam.SPORT.VIDOUT_REQ;
		ld_ack_d  = dut.p3do.madam.ARB.VIDOUT_ACK;
		ld_extp_ack_d = dut.p3do.madam.ARB.EXTP_ACK;
		ld_rl_d   = dut.vram_l.RT_REQ;
		ld_rr_d   = dut.vram_r.RT_REQ;
		ld_exec_d = dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;
	end
	final if (ld_on) begin
		$display("tb_boot: late_diag: %0d lines; slack (line start - later RT request) <0(late)/<0.25/<0.5/<1/<1.5/<2/<3/<4/more us: %0d %0d %0d %0d %0d %0d %0d %0d %0d",
		         ld_lines, ld_slack_hist[0], ld_slack_hist[1], ld_slack_hist[2], ld_slack_hist[3], ld_slack_hist[4],
		         ld_slack_hist[5], ld_slack_hist[6], ld_slack_hist[7], ld_slack_hist[8]);
		$display("tb_boot: late_diag: late lines paused by: ddr io %0d, ddr burst %0d, L not ready %0d, R not ready %0d, SDRAM port %0d, no pause %0d; mean pause in the window %0.2f us (late lines), %0.3f us (all)",
		         ld_cause_late[0], ld_cause_late[1], ld_cause_late[2], ld_cause_late[3], ld_cause_late[4], ld_cause_late[5],
		         ld_slack_hist[0] ? ld_pause_late / 1000.0 / ld_slack_hist[0] : 0.0, ld_lines ? ld_pause_all / 1000.0 / ld_lines : 0.0);
		$display("tb_boot: late_diag: late lines with an external-port (DSP/audio, XBUS) DMA grant before their video grant: %0d", ld_late_extp);
		$display("tb_boot: late_diag: late lines whose window had an RT cache demand fill %0d, prefetch %0d, VDL hint/frame-start fill %0d, CPU read transfer %0d, write transfer %0d",
		         ld_late_src[0], ld_late_src[1], ld_late_src[2], ld_late_src[3], ld_late_src[4]);
	end

	// Video DMA sequence (+sport_ms=<start>, one frame): MADAM_SPORT's VDL
	// (CLUT) and video transfer requests, their bus grants, the VRAM read
	// transfers they cause, PAUSE, and the first serial words of each line.
	int sport_ms = -1;
	initial void'($value$plusargs("sport_ms=%d", sport_ms));
	bit sp_vz_d, sp_clutreq_d, sp_clutexec_d, sp_vpend_d, sp_vexec_d, sp_vreq_d, sp_vack_d, sp_upd_d, sp_env_d,
	    sp_pause_d, sp_rtl_d, sp_rtr_d, sp_rtexl_d, sp_lsc_d;
	int sp_shifts = 0;
	always @(posedge clk_sys) begin
		bit win;
		string bs;
		win = sport_ms >= 0 && $realtime >= sport_ms * 1ms && $realtime < sport_ms * 1ms + 17ms;
		bs = dut.p3do.madam.ARB.BUS_ST.name();
		if (win) begin
			if (dut.p3do.madam.SPORT.VZ != sp_vz_d)
				$display("[%0t] SP v%0d h%0d VZ=%b FC=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT,
				         dut.p3do.madam.SPORT.VZ, dut.p3do.madam.SPORT.FC);
			if (dut.p3do.madam.SPORT.CLUTWR_REQ != sp_clutreq_d)
				$display("[%0t] SP v%0d h%0d CLUTWR_REQ=%b LINE=%0d bus=%s pause=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.p3do.madam.SPORT.CLUTWR_REQ, dut.p3do.madam.SPORT.LINE, bs, dut.pause);
			if (dut.p3do.madam.SPORT.CLUT_DMACTL_UPDATED && !sp_upd_d)
				$display("[%0t] SP v%0d h%0d VDL control word %08h (ENVIDDMA %b, LEN %0d, LINE %0d)", $realtime,
				         dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT, 32'(dut.p3do.madam.SPORT.CLUT_DMACTL),
				         dut.p3do.madam.SPORT.CLUT_DMACTL.ENVIDDMA, dut.p3do.madam.SPORT.CLUT_DMACTL.LEN,
				         dut.p3do.madam.SPORT.CLUT_DMACTL.LINE);
			if (dut.p3do.madam.SPORT.ENVIDDMA != sp_env_d)
				$display("[%0t] SP v%0d h%0d ENVIDDMA=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT,
				         dut.p3do.madam.SPORT.ENVIDDMA);
			if (dut.p3do.madam.SPORT.CLUT_TRANS_EXEC != sp_clutexec_d)
				$display("[%0t] SP v%0d h%0d CLUT_TRANS_EXEC=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.p3do.madam.SPORT.CLUT_TRANS_EXEC);
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_PEND != sp_vpend_d)
				$display("[%0t] SP v%0d h%0d VIDEO_TRANS_PEND=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.p3do.madam.SPORT.VIDEO_TRANS_PEND);
			if (dut.p3do.madam.SPORT.VIDOUT_REQ != sp_vreq_d)
				$display("[%0t] SP v%0d h%0d VIDOUT_REQ=%b bus=%s pause=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.p3do.madam.SPORT.VIDOUT_REQ, bs, dut.pause);
			if (dut.p3do.madam.SPORT.VIDOUT_ACK && !sp_vack_d)
				$display("[%0t] SP v%0d h%0d VIDOUT_ACK bus=%s", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, bs);
			if (dut.pause != sp_pause_d)
				$display("[%0t] SP v%0d h%0d pause=%b bus=%s", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.pause, bs);
			// why: the core's PAUSE sources, and what ddram.sv, the RT cache,
			// the SDRAM secondary-port clients and the VRAM modules are doing
			if (dut.pause && !sp_pause_d)
				$display("[%0t] SP   cause: io_busy %b ddr_busy %b LRDY %b RRDY %b sec_hold %b | ddram state %0d wpend %b%b rbusy %b%b bursts %b%b%b%b io %b%b | rtc fill %b h=%03h dem %b%b pf %b%b | sec req host %b cdd %b ddr %b | L rt/mwt/fw %b%b%b R rt/mwt %b%b | cpu %08h",
				         $realtime, dut.ddr_io_busy, dut.ddr_busy, dut.VRAM_LRDY, dut.VRAM_RRDY, dut.sec_hold_s,
				         dut.ddram.state, dut.ddram.write_lpend, dut.ddram.write_rpend, dut.ddram.read_lbusy, dut.ddram.read_rbusy,
				         dut.ddram.burst_read_lbusy, dut.ddram.burst_read_rbusy, dut.ddram.burst_write_lbusy, dut.ddram.burst_write_rbusy,
				         dut.ddram.io_read_busy, dut.ddram.io_write_busy,
				         dut.rtcache.fill_busy, dut.rtcache.fill_h, dut.rtcache.dem_pend[0], dut.rtcache.dem_pend[1],
				         dut.rtcache.pf_v[0], dut.rtcache.pf_v[1],
				         dut.host_sec_req, dut.cdd_sec_req, dut.ddr_sec_req,
				         dut.vram_l.RT_EXEC, dut.vram_l.MWT_EXEC, dut.vram_l.FW_EXEC, dut.vram_r.RT_EXEC, dut.vram_r.MWT_EXEC,
				         dut.p3do.CPU_A);
			if (dut.rtcache.fill_issue)
				$display("[%0t] SP v%0d h%0d   RT cache fill h=%03h (demand %b%b, prefetch queue %b%b)", $realtime,
				         dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT, dut.rtcache.fill_h,
				         dut.rtcache.dem_pend[0], dut.rtcache.dem_pend[1], dut.rtcache.pf_v[0], dut.rtcache.pf_v[1]);
			if (dut.vram_r.RT_REQ && !sp_rtr_d)
				$display("[%0t] SP v%0d h%0d RT R A=%05h split=%b int=%b bus=%s", $realtime,
				         dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT, {dut.vram_r.MEM_ROW, dut.vram_r.MEM_COL},
				         dut.vram_r.SPLIT, dut.vram_r.ISTE, bs);
			if (dut.vram_l.RT_REQ && !sp_rtl_d)
				$display("[%0t] SP v%0d h%0d RT L A=%05h split=%b int=%b SR_RA=%03h bus=%s", $realtime,
				         dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT, {dut.vram_l.MEM_ROW, dut.vram_l.MEM_COL},
				         dut.vram_l.SPLIT, dut.vram_l.ISTE, dut.vram_l.SR_RA, bs);
			if (dut.vram_l.RT_EXEC != sp_rtexl_d)
				$display("[%0t] SP v%0d h%0d RT_EXEC L=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.vram_l.RT_EXEC);
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !sp_vexec_d) begin
				$display("[%0t] SP v%0d h%0d VIDEO_TRANS_EXEC (L SR_RA=%03h RT_EXEC=%b)", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, dut.vram_l.SR_RA, dut.vram_l.RT_EXEC);
				sp_shifts = 0;
			end
			// first serial words of a line (left chip), as CLIO receives them
			if (sp_lsc_d && !dut.vram_l.SC && dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && sp_shifts < 8) begin
				$display("[%0t] SP v%0d h%0d   L shift %0d: SR_RA=%03h SQ=%04h RT_EXEC=%b", $realtime, dut.p3do.madam.SPORT.VCOUNT,
				         dut.p3do.madam.SPORT.HCOUNT, sp_shifts, dut.vram_l.SR_RA, dut.vram_l.SQ, dut.vram_l.RT_EXEC);
				sp_shifts++;
			end
		end
		sp_vz_d <= dut.p3do.madam.SPORT.VZ;               sp_clutreq_d <= dut.p3do.madam.SPORT.CLUTWR_REQ;
		sp_clutexec_d <= dut.p3do.madam.SPORT.CLUT_TRANS_EXEC; sp_vpend_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_PEND;
		sp_vexec_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;  sp_vreq_d <= dut.p3do.madam.SPORT.VIDOUT_REQ;
		sp_vack_d <= dut.p3do.madam.SPORT.VIDOUT_ACK;     sp_upd_d <= dut.p3do.madam.SPORT.CLUT_DMACTL_UPDATED;
		sp_env_d <= dut.p3do.madam.SPORT.ENVIDDMA;        sp_pause_d <= dut.pause;
		sp_rtl_d <= dut.vram_l.RT_REQ;                    sp_rtexl_d <= dut.vram_l.RT_EXEC;
		sp_rtr_d <= dut.vram_r.RT_REQ;
		sp_lsc_d <= dut.vram_l.SC;
	end

	// Address sequence of VRAM read transfers (+rtseq_ms=<start>, one frame)
	int rtseq_ms = -1;
	initial void'($value$plusargs("rtseq_ms=%d", rtseq_ms));
	reg rtl_d = 0, rtr_d = 0;
	always @(posedge clk_mem) begin
		rtl_d <= dut.vram_l.RT_REQ;
		rtr_d <= dut.vram_r.RT_REQ;
		if (rtseq_ms >= 0 && $realtime >= rtseq_ms * 1ms && $realtime < rtseq_ms * 1ms + 17ms) begin
			if (dut.vram_l.RT_REQ && !rtl_d)
				$display("[%0t] RTSEQ L A=%05h split=%b int=%b bus=%s", $realtime, {dut.vram_l.MEM_ROW, dut.vram_l.MEM_COL},
				         dut.vram_l.SPLIT, dut.vram_l.ISTE, dut.p3do.madam.ARB.BUS_ST.name());
			if (dut.vram_r.RT_REQ && !rtr_d)
				$display("[%0t] RTSEQ R A=%05h split=%b int=%b bus=%s", $realtime, {dut.vram_r.MEM_ROW, dut.vram_r.MEM_COL},
				         dut.vram_r.SPLIT, dut.vram_r.ISTE, dut.p3do.madam.ARB.BUS_ST.name());
		end
	end

	// pause statistics and CPU sampling
	longint pause_cycles = 0, cycles = 0;
	always @(posedge clk_sys) if (!dut.reset_3do) begin
		cycles++;
		if (dut.pause) pause_cycles++;
	end
	initial forever begin
		#1ms;
		$display("[%0t] cpu A=%08h  pause %0d%%  frames %0d  CD sectors %0d  SDRAM errors %0d  VRAM writes lost %0d, bad FW lookups %0d",
		         $realtime, dut.p3do.CPU_A, cycles ? int'(pause_cycles * 100 / cycles) : 0, frames, sectors_sent, sdram.errors,
		         vw_lost, vw_fw_wrong_effect);
	end

	// ---------------- memory system hang ----------------
	// The 3DO pause (p3do_gamebub.sv: ddram.sv's VRAM port or slow-bus port
	// busy, a VRAM module not ready, the SDRAM secondary port's hold) lasts
	// microseconds. A pause of HANG_US without a break is a hang: a TB error;
	// the state of every pause source is printed and the run ends there.
	// +hang_trace_from_us=<n> [+hang_trace_us=<n>, default 2000]: from n us on,
	// every clk_mem cycle in which a VRAM transfer, RT cache, ddram.sv, SDRAM
	// secondary port or MADAM bus signal changes goes to <out>/hang_trace.txt.
	localparam int HANG_US = 500;
	int  hang_cnt = 0;       // clk_sys cycles (20 ns) paused without a break
	bit  hung = 0;
	always @(posedge clk_sys) begin
		if (dut.reset_3do || !dut.pause || draining) hang_cnt <= 0;
		else if (hang_cnt < HANG_US * 50) hang_cnt <= hang_cnt + 1;
		else if (!hung) begin
			hung = 1;
			errors++;
			$display("[%0t] TB ERROR: the 3DO has been paused for %0d us without a break: the memory system has hung",
			         $realtime, HANG_US);
			hang_state();
			$fflush();
		end
	end

	task automatic hang_vram_side(input string s, input bit ras_n, cas_n, oe_n, input bit [1:0] we_n, input bit dsf, sp_cpu,
	                              rt, mwt, fw, rdy, xcpu, split, iste, input bit [8:0] row, col, pos,
	                              input bit esrd, eswr, esfw, este, input bit [9:0] vtag, input bit vtag_v);
		$display("tb_boot: hang:   VRAM %s: RAS_N %b CAS_N %b OE_N %b WE_N %b DSF1 %b SP_CPU %b | RT_EXEC %b MWT_EXEC %b FW_EXEC %b RDY %b XFER_CPU %b SPLIT %b ISTE %b row %03h col %03h SREG_POS %03h | ESRD %b ESWR %b ESFW %b ESTE %b | VSR_TAG %03h valid %b",
		         s, ras_n, cas_n, oe_n, we_n, dsf, sp_cpu, rt, mwt, fw, rdy, xcpu, split, iste, row, col, pos,
		         esrd, eswr, esfw, este, vtag, vtag_v);
	endtask

	task automatic hang_state();
		$display("tb_boot: hang: pause %b = ddram.sv VRAM busy %b | slow-bus port busy %b | VRAM L not ready %b | VRAM R not ready %b | SDRAM secondary hold %b",
		         dut.pause, dut.ddr_busy, dut.ddr_io_busy, !dut.VRAM_LRDY, !dut.VRAM_RRDY, dut.sec_hold_s);
		$display("tb_boot: hang:   CPU A=%08h, MADAM bus %s, CPU SPORT select %b", dut.p3do.CPU_A,
		         dut.p3do.madam.ARB.BUS_ST.name(), dut.p3do.madam.CPU_SPORT_SEL);
		hang_vram_side("L", dut.vram_l.RAS_N, dut.vram_l.CAS_N, dut.vram_l.OE_N, dut.vram_l.WE_N, dut.vram_l.DSF1, dut.vram_l.SP_CPU,
		               dut.vram_l.RT_EXEC, dut.vram_l.MWT_EXEC, dut.vram_l.FW_EXEC, dut.vram_l.RDY, dut.vram_l.XFER_CPU,
		               dut.vram_l.SPLIT, dut.vram_l.ISTE, dut.vram_l.MEM_ROW, dut.vram_l.MEM_COL, dut.vram_l.SREG_POS,
		               dut.vram_l.ESRD, dut.vram_l.ESWR, dut.vram_l.ESFW, dut.vram_l.ESTE, dut.vram_l.VSR_TAG, dut.vram_l.VSR_V);
		hang_vram_side("R", dut.vram_r.RAS_N, dut.vram_r.CAS_N, dut.vram_r.OE_N, dut.vram_r.WE_N, dut.vram_r.DSF1, dut.vram_r.SP_CPU,
		               dut.vram_r.RT_EXEC, dut.vram_r.MWT_EXEC, dut.vram_r.FW_EXEC, dut.vram_r.RDY, dut.vram_r.XFER_CPU,
		               dut.vram_r.SPLIT, dut.vram_r.ISTE, dut.vram_r.MEM_ROW, dut.vram_r.MEM_COL, dut.vram_r.SREG_POS,
		               dut.vram_r.ESRD, dut.vram_r.ESWR, dut.vram_r.ESFW, dut.vram_r.ESTE, dut.vram_r.VSR_TAG, dut.vram_r.VSR_V);
		$display("tb_boot: hang:   RT cache: fill busy %b issue %b entry %0d half-row %03h | demand L %b h %03h beat %02h, R %b h %03h beat %02h, age %0d hold %b | delivery L %b entry %0d beat %02h (filled %02h), R %b entry %0d beat %02h (filled %02h) | prefetch %b %03h, %b %03h, quiet %b | victim %0d ok %b | to ddram.sv: blwr %b brwr %b bfw %b blrd %b brrd %b, bbusy %b",
		         dut.rtcache.fill_busy, dut.rtcache.fill_issue, dut.rtcache.fill_e, dut.rtcache.fill_h,
		         dut.rtcache.dem_pend[0], dut.rtcache.dem_h[0], dut.rtcache.dem_beat[0],
		         dut.rtcache.dem_pend[1], dut.rtcache.dem_h[1], dut.rtcache.dem_beat[1], dut.rtcache.dem_age, dut.rtcache.dem_hold,
		         dut.rtcache.dl_act[0], dut.rtcache.dl_e[0], dut.rtcache.dl_beat[0], dut.rtcache.fl0,
		         dut.rtcache.dl_act[1], dut.rtcache.dl_e[1], dut.rtcache.dl_beat[1], dut.rtcache.fl1,
		         dut.rtcache.pf_v[0], dut.rtcache.pf_h[0], dut.rtcache.pf_v[1], dut.rtcache.pf_h[1], dut.rtcache.pf_quiet,
		         dut.rtcache.vptr, dut.rtcache.v_ok,
		         dut.rtcache.d_blwr, dut.rtcache.d_brwr, dut.rtcache.d_bfw, dut.rtcache.d_blrd, dut.rtcache.d_brrd, dut.rtcache.d_bbusy);
		for (int i = 0; i < 16; i++)
			$display("tb_boot: hang:     RT cache entry %2d: valid %b tag %03h filled %02h dirty %b used %b", i,
			         dut.rtcache.valid[i], dut.rtcache.tag[i], dut.rtcache.filled[i], dut.rtcache.dirty[i], dut.rtcache.used[i]);
		$display("tb_boot: hang:   ddram.sv: state %0d DDRAM_BUSY %b | burst write L %b R %b (addr %05h %05h, wpos %02h), burst read L %b R %b (rpos %02h) | random write pend L %b R %b busy L %b R %b (addr %05h %05h, flag lookup at %05h) | read busy L %b R %b | slow bus read %b write %b",
		         dut.ddram.state, dut.ddram.DDRAM_BUSY, dut.ddram.burst_write_lbusy, dut.ddram.burst_write_rbusy,
		         dut.ddram.burst_laddr, dut.ddram.burst_raddr, dut.ddram.wpos, dut.ddram.burst_read_lbusy, dut.ddram.burst_read_rbusy,
		         dut.ddram.rpos, dut.ddram.write_lpend, dut.ddram.write_rpend, dut.ddram.write_lbusy, dut.ddram.write_rbusy,
		         dut.ddram.write_laddr, dut.ddram.write_raddr, {dut.ddram.vram_fw_qaddr, 1'b0},
		         dut.ddram.read_lbusy, dut.ddram.read_rbusy, dut.ddram.io_read_busy, dut.ddram.io_write_busy);
		$display("tb_boot: hang:   DDR bridge %s (collected %0d, read beats %0d), secondary port arbiter busy %b sel %0d, SDRAM secondary %s ref_due %b",
		         dut.ddr_bridge.st.name(), dut.ddr_bridge.wcnt, dut.ddr_bridge.rbeats, dut.arb.busy, dut.arb.sel,
		         dut.sdram.sst.name(), dut.sdram.ref_due);
	endtask

	int     ht_fd = 0;
	longint ht_from_us = -1, ht_us = 2000;
	initial begin
		void'($value$plusargs("hang_trace_from_us=%d", ht_from_us));
		void'($value$plusargs("hang_trace_us=%d", ht_us));
	end
	bit [127:0] ht_mon, ht_mon_d;
	always @(posedge clk_mem) begin
		if (ht_from_us >= 0 && $realtime >= ht_from_us * 1us && $realtime < (ht_from_us + ht_us) * 1us) begin
			ht_mon = {dut.pause, dut.VRAM_LRDY, dut.VRAM_RRDY, dut.ddr_busy, dut.ddr_io_busy, dut.sec_hold_s,
			          dut.vram_l.RAS_N, dut.vram_l.CAS_N, dut.vram_l.OE_N, dut.vram_l.WE_N, dut.vram_l.DSF1, dut.vram_l.SP_CPU,
			          dut.vram_l.RT_EXEC, dut.vram_l.MWT_EXEC, dut.vram_l.FW_EXEC, dut.vram_l.ESRD, dut.vram_l.ESWR, dut.vram_l.ESFW,
			          dut.vram_r.RAS_N, dut.vram_r.CAS_N, dut.vram_r.OE_N, dut.vram_r.WE_N, dut.vram_r.DSF1, dut.vram_r.SP_CPU,
			          dut.vram_r.RT_EXEC, dut.vram_r.MWT_EXEC, dut.vram_r.FW_EXEC, dut.vram_r.ESRD, dut.vram_r.ESWR,
			          dut.rtcache.fill_busy, dut.rtcache.fill_issue, dut.rtcache.dem_pend[0], dut.rtcache.dem_pend[1],
			          dut.rtcache.dl_act[0], dut.rtcache.dl_act[1], dut.rtcache.d_blwr, dut.rtcache.d_brwr,
			          dut.rtcache.d_blrd, dut.rtcache.d_brrd, dut.rtcache.d_bbusy,
			          dut.ddram.state, dut.ddram.DDRAM_BUSY, dut.ddram.write_lpend, dut.ddram.write_rpend,
			          dut.ddram.read_lbusy, dut.ddram.read_rbusy, dut.ddram.io_read_busy, dut.ddram.io_write_busy,
			          3'(dut.ddr_bridge.st), dut.arb.busy, 4'(dut.sdram.sst), dut.sdram.ref_due,
			          8'(dut.p3do.madam.ARB.BUS_ST)};
			if (ht_fd == 0) begin
				ht_fd = $fopen({outdir, "/hang_trace.txt"}, "w");
				$fdisplay(ht_fd, "# time_ps | pause LRDY RRDY ddr_busy io_busy sec_hold | VRAM L/R: RAS CAS OE WE DSF SP_CPU RT MWT FW row col pos ESRD ESWR ESFW ESTE | RT cache: fill busy/issue entry h, demand L/R, delivery L/R beat, blwr brwr bfw blrd brrd bbusy | ddram.sv state DDRAM_BUSY wpend L/R rbusy L/R io r/w | bridge arb sdram ref | MADAM bus CPU_A");
				$display("[%0t] hang trace started (%s/hang_trace.txt)", $realtime, outdir);
				ht_mon_d = ~ht_mon;
			end
			if (ht_mon != ht_mon_d)
				$fdisplay(ht_fd, "%0t | %b %b %b %b %b %b | L %b%b%b%b%b%b %b%b%b %03h %03h %03h %b%b%b%b | R %b%b%b%b%b%b %b%b%b %03h %03h %03h %b%b%b | C %b%b %0d %03h d%b%b dl%b%b %02h %02h %b%b%b%b%b %b | D %0d %b w%b%b r%b%b io%b%b | %s %b %s %b | %s %08h",
				          $realtime, dut.pause, dut.VRAM_LRDY, dut.VRAM_RRDY, dut.ddr_busy, dut.ddr_io_busy, dut.sec_hold_s,
				          dut.vram_l.RAS_N, dut.vram_l.CAS_N, dut.vram_l.OE_N, &dut.vram_l.WE_N, dut.vram_l.DSF1, dut.vram_l.SP_CPU,
				          dut.vram_l.RT_EXEC, dut.vram_l.MWT_EXEC, dut.vram_l.FW_EXEC,
				          dut.vram_l.MEM_ROW, dut.vram_l.MEM_COL, dut.vram_l.SREG_POS,
				          dut.vram_l.ESRD, dut.vram_l.ESWR, dut.vram_l.ESFW, dut.vram_l.ESTE,
				          dut.vram_r.RAS_N, dut.vram_r.CAS_N, dut.vram_r.OE_N, &dut.vram_r.WE_N, dut.vram_r.DSF1, dut.vram_r.SP_CPU,
				          dut.vram_r.RT_EXEC, dut.vram_r.MWT_EXEC, dut.vram_r.FW_EXEC,
				          dut.vram_r.MEM_ROW, dut.vram_r.MEM_COL, dut.vram_r.SREG_POS,
				          dut.vram_r.ESRD, dut.vram_r.ESWR, dut.vram_r.ESTE,
				          dut.rtcache.fill_busy, dut.rtcache.fill_issue, dut.rtcache.fill_e, dut.rtcache.fill_h,
				          dut.rtcache.dem_pend[0], dut.rtcache.dem_pend[1], dut.rtcache.dl_act[0], dut.rtcache.dl_act[1],
				          dut.rtcache.dl_beat[0], dut.rtcache.dl_beat[1],
				          dut.rtcache.d_blwr, dut.rtcache.d_brwr, dut.rtcache.d_bfw, dut.rtcache.d_blrd, dut.rtcache.d_brrd,
				          dut.rtcache.d_bbusy,
				          dut.ddram.state, dut.ddram.DDRAM_BUSY, dut.ddram.write_lpend, dut.ddram.write_rpend,
				          dut.ddram.read_lbusy, dut.ddram.read_rbusy, dut.ddram.io_read_busy, dut.ddram.io_write_busy,
				          dut.ddr_bridge.st.name(), dut.arb.busy, dut.sdram.sst.name(), dut.sdram.ref_due,
				          dut.p3do.madam.ARB.BUS_ST.name(), dut.p3do.CPU_A);
			ht_mon_d = ht_mon;
		end else if (ht_fd != 0) begin
			$fclose(ht_fd);
			ht_fd = 0;
			ht_from_us = -1;
		end
	end

	// framework video -> PPM frames
	bit [17:0] fb [320*240];
	int px = 0, ln = 0, frames = 0, frame_every;
	reg vhbl_d = 0, vvbl_d = 0;
	always @(posedge clk_sys) begin
		vhbl_d <= vhbl; vvbl_d <= vvbl;
		if (vde) begin
			if (px < 320 && ln < 240) fb[ln*320 + px] = {vr, vg, vb};
			px++;
		end
		if (vhbl && !vhbl_d) begin px = 0; ln++; end
		if (vvbl && !vvbl_d) begin
			if (flog_fd != 0) frame_log(frames);
			if (frames % frame_every == 0 || (frames >= frames_from && frames <= frames_to)) save_frame(frames);
			frames++;
			px = 0; ln = 0;
		end
	end

	// +frame_log: <out>/frame_log.txt, one line per frame: its number, the
	// time, the mean red, green and blue (0-63) and the frame buffer the
	// frame's first VDL entry pointed the video DMA at (VRAM byte offset), so
	// a frame out of line in a fade shows, with whether the buffer changed.
	// +frames_from=<n> +frames_to=<m>: every frame from n to m is saved too.
	int flog_fd = 0, frames_from = -1, frames_to = -1;
	bit [19:2] fl_fb = '0;
	bit        fl_fb_seen = 0;
	initial begin
		void'($value$plusargs("frames_from=%d", frames_from));
		void'($value$plusargs("frames_to=%d", frames_to));
		if ($test$plusargs("frame_log")) flog_fd = $fopen({outdir, "/frame_log.txt"}, "w");
	end
	always @(posedge clk_sys) if (dut.VID_FB_HINT && dut.VID_FB_CURR_V && !fl_fb_seen) begin
		fl_fb = dut.VID_FB_CURR;
		fl_fb_seen = 1;
	end
	task automatic frame_log(input int n);
		longint sr, sg, sb;
		sr = 0; sg = 0; sb = 0;
		for (int i = 0; i < 320*240; i++) begin sr += fb[i][17:12]; sg += fb[i][11:6]; sb += fb[i][5:0]; end
		$fdisplay(flog_fd, "%0d %0.3f %0.2f %0.2f %0.2f %s", n, $realtime / 1.0e9, sr / 76800.0, sg / 76800.0, sb / 76800.0,
		          fl_fb_seen ? $sformatf("%05h", {fl_fb, 2'b00}) : "-");
		$fflush(flog_fd);
		fl_fb_seen = 0;
	endtask
	task automatic save_frame(input int n);
		int fd;
		bit any;
		fd = $fopen($sformatf("%s/frames/frame_%04d.ppm", outdir, n), "wb");
		if (fd == 0) return;
		$fwrite(fd, "P6\n320 240\n255\n");
		any = 0;
		for (int i = 0; i < 320*240; i++) begin
			$fwrite(fd, "%c%c%c", {fb[i][17:12], fb[i][17:16]}, {fb[i][11:6], fb[i][11:10]}, {fb[i][5:0], fb[i][5:4]});
			if (fb[i] != 0) any = 1;
		end
		$fclose(fd);
		$display("[%0t] frame %0d saved (%s)", $realtime, n, any ? "has content" : "black");
	endtask

	// VRAM word w (32-bit, VRAM byte offset 4w) as seen by the 3DO. Words in
	// the on-chip BRAM1 block are read from the VRAM_MEM lanes, the rest from
	// the SDRAM bank-2 overflow area (ddram.sv layout: natural word order).
	function automatic [31:0] vram_word(input [17:0] w);
		if (vram_internal(w)) return 32'hDEADBEEF;   // on-chip block: not dumped
		return vram_visible(w);
	endfunction

	// 320x240 16-bit 3DO framebuffer in "LR form": word (x, line pair k) holds
	// pixel (x, 2k) in bits 31..16 and (x, 2k+1) in bits 15..0.
	task automatic dump_vram_fb(input [31:0] byte_off, input int lines, input string fname);
		int fd;
		fd = $fopen(fname, "wb");
		$fwrite(fd, "P6\n320 %0d\n255\n", lines);
		for (int y = 0; y < lines; y++)
			for (int x = 0; x < 320; x++) begin
				bit [31:0] wv;
				bit [15:0] p;
				wv = vram_word(18'((byte_off >> 2) + (y >> 1) * 320 + x));
				p = y[0] ? wv[15:0] : wv[31:16];
				$fwrite(fd, "%c%c%c", {p[14:10], p[14:12]}, {p[9:5], p[9:7]}, {p[4:0], p[4:2]});
			end
		$fclose(fd);
		$display("VRAM framebuffer at +%06h dumped to %s", byte_off, fname);
	endtask

	// ---------------- sequence ----------------
	initial begin
		string bios, iso;
		int bios_len, iso_len, run_ms;
		bit [31:0] r;
		bit e;
		if (!$value$plusargs("bios=%s", bios)) $fatal(1, "tb_boot: +bios=<file> required");
		if (!$value$plusargs("run_ms=%d", run_ms)) run_ms = 1000;
		if (!$value$plusargs("frame_every=%d", frame_every)) frame_every = 10;

		place_file(bios, 0, 23'h400000, bios_len);
		$display("tb_boot: BIOS %s (%0d bytes) placed", bios, bios_len);
		iso_len = 0;
		void'($value$plusargs("disc_latency_us=%d", disc_latency_us));
		void'($value$plusargs("trace_from_ms=%d", trace_from_ms));
		if ($value$plusargs("disc_bin=%s", iso)) begin
			bin_fd = $fopen(iso, "rb");
			if (bin_fd == 0) $fatal(1, "tb_boot: cannot open %s", iso);
			void'($fseek(bin_fd, 0, 2));
			bin_sectors = $ftell(bin_fd) / 2352;
			chk_fd = $fopen(iso, "rb");
			chk_sectors = bin_sectors;
			$display("tb_boot: streaming %s (%0d raw sectors), firmware latency %0d us", iso, bin_sectors, disc_latency_us);
		end else if ($value$plusargs("iso=%s", iso)) begin
			place_file(iso, 1, 23'h0, iso_len);
			$display("tb_boot: ISO %s (%0d bytes, %0d sectors) placed", iso, iso_len, iso_len / 2048);
			chk_fd = $fopen(iso, "rb");
			chk_sec_bytes = 2048;
			chk_sectors = iso_len / 2048;
		end

		repeat (20) @(posedge clk_sys);
		reset <= 0;
		do host_cmd(16'h0000, 0, 0, 0, r, e); while (r != 2);
		if (iso_len) begin
			host_cmd(16'h0300, 0, 0, 0, r, e);
			host_cmd(16'h0301, 0, iso_len, 0, r, e);
		end
		if (bin_fd != 0) begin
			// Table of contents (fork firmware DiscImage::toc). Default: one
			// MODE1 track. +audio_tracks=<n> [+data_sectors=<k>]: the first k
			// sectors are a data track (none with k = 0), the rest of the image
			// is n audio tracks of equal length (the last one takes the rest).
			int ntr, data_secs, atr, first, len;
			bit [31:0] toc [];
			data_secs = bin_sectors;
			atr = 0;
			if ($value$plusargs("audio_tracks=%d", atr)) begin
				data_secs = 0;
				void'($value$plusargs("data_sectors=%d", data_secs));
			end
			ntr = (data_secs > 0) + atr;
			toc = new [4 + 4 * ntr];
			toc[0] = {16'h0, bcd(ntr), 8'(ntr)};
			toc[1] = 150 + bin_sectors; toc[2] = msf_bcd(150 + bin_sectors); toc[3] = 0;
			first = 0;
			for (int t = 0; t < ntr; t++) begin
				bit audio;
				audio = !(t == 0 && data_secs > 0);
				if (!audio) len = data_secs;
				else if (t == ntr - 1) len = bin_sectors - first;
				else len = (bin_sectors - data_secs) / atr;
				toc[4 + 4 * t] = 150 + first;
				toc[5 + 4 * t] = 150 + first + len - 1;
				toc[6 + 4 * t] = 150 + first;
				toc[7 + 4 * t] = msf_bcd(150 + first) | {audio, 31'd0};
				if (audio && 150 + first < trk_audio_from) trk_audio_from = 150 + first;
				$display("tb_boot: track %0d %s, abs LBA %0d..%0d", t + 1, audio ? "audio" : "data", 150 + first, 150 + first + len - 1);
				first += len;
			end
			host_cmd(16'h0300, 0, 0, 0, r, e);
			for (int i = 0; i < 4 + 4 * ntr; i++) host_wr(32'h1000_0000 + 4 * i, toc[i]);
			host_cmd(16'h0301, 0, 16 + 16 * ntr, 0, r, e);
		end
		host_cmd(16'h0300, 1, 0, 0, r, e);
		host_cmd(16'h0301, 1, bios_len, 0, r, e);
		host_cmd(16'h0102, 0, 0, 0, r, e);
		do host_cmd(16'h0000, 0, 0, 0, r, e); while (r != 3);
		host_wr(32'h0000_1010, 32'(sram_mode));   // "VRAM memory", taken while the 3DO is in reset
		$display("tb_boot: VRAM memory setting %0d (%s)", sram_mode,
		         sram_mode == 0 ? "SRAM, 2 cycles per word" : sram_mode == 1 ? "SRAM, 3 cycles per word" : "SDRAM only");
		host_cmd(16'h0200, 1, 0, 0, r, e);
		host_cmd(16'h0100, 0, 0, 0, r, e);
		$display("[%0t] core running", $realtime);

		// the run ends early if the memory system hangs (nothing moves after that)
		fork
			#(run_ms * 1ms);
			wait (hung);
		join_any
		disable fork;
		if (hung) $display("[%0t] tb_boot: run ended early: memory system hang", $realtime);
		if (ht_fd != 0) begin $fclose(ht_fd); ht_fd = 0; end
		$fflush();
		// The shadow takes each write at the VRAM port; ddram.sv stores it in
		// the SRAM or SDRAM some cycles later. Stop the 3DO (its own pause
		// input, as slow memory does) and let the memory system go idle first,
		// so that a write still on its way is not counted as lost.
		if (!hung) begin
			bit idle = 0;
			draining = 1;
			force dut.pause = 1'b1;
			for (int i = 0; i < 2000 && !idle; i++) begin
				repeat (50) @(posedge clk_sys);
				idle = !dut.ddr_busy && !dut.ddr_io_busy && dut.VRAM_LRDY && dut.VRAM_RRDY;
			end
			if (idle) repeat (500) @(posedge clk_sys);
			else begin
				errors++;
				$display("[%0t] TB ERROR: the memory system did not go idle within 2 ms of stopping the 3DO", $realtime);
			end
		end
		dump_vram_fb(32'h000000, 1638, {outdir, "/frames/vram_all.ppm"});
		sh_check_memory();
		if (!hung) release dut.pause;
		$display("tb_boot: %0d frames, %0d CD sectors (%0d served by the firmware model), SDRAM model errors %0d, SRAM model errors %0d (%0d SRAM writes), TB errors %0d",
		         frames, sectors_sent, served, sdram.errors, sram.errors, sram.writes, errors);
		if (au_fd != 0) $fclose(au_fd);
		au_fd = 0;
		$display("tb_boot: audio output: %0d samples at 44.1 kHz in %s/audio.raw, %0d not silent, peak %0d",
		         au_n, outdir, au_nz, au_peak);
		if (chk_fd != 0) begin
			$display("tb_boot: CD data check: %0d sectors match the image, %0d differ; CPU read %0d bytes from the data port, %0d differ",
			         cd_good, cd_bad, cd_rd_bytes, cd_rd_errs);
			foreach (cd_len_count[l]) $display("tb_boot: CD blocks of %0d bytes: %0d", l, cd_len_count[l]);
			if (cd_audio_secs)
				$display("tb_boot: CD audio sectors %0d; between consecutive ones min %0.3f ms, max %0.3f ms, mean %0.3f ms (%0d gaps)",
				         cd_audio_secs, cd_audio_min / 1ms, cd_audio_max / 1ms, cd_audio_gaps ? cd_audio_sum / cd_audio_gaps / 1ms : 0.0, cd_audio_gaps);
		end
		$display("tb_boot: RT cache hits %0d, misses %0d, prefetches %0d, invalidations %0d, VDL frame buffer hints %0d",
		         dut.rtc_hits, dut.rtc_misses, dut.rtc_prefetches, dut.rtc_invalidations, dut.rtc_hints);
		// any TB error (late video lines included) or SDRAM / SRAM model error
		// fails the run, with a non-zero exit status ($fatal) so scripts see it
		if (errors == 0 && sdram.errors == 0 && sram.errors == 0) begin $display("tb_boot: PASS"); $finish; end
		else $fatal(1, "tb_boot: FAIL");
	end
endmodule
