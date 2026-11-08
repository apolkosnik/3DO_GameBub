// System testbench for the Game Bub 3DO core (p3do_gamebub).
//
// The complete core runs: ARM60 CPU, MADAM, CLIO, VRAM, ddram.sv, the DDR
// bridge, the SDRAM controller (against the timing-checking SDRAM model),
// the CD back end and the host interface. A host BFM implements the Game
// Bub framework's host protocol exactly as SpiReceiverFifo drives it
// (enable held until done, done ignored in the first cycle) and the HostV0
// command sequence the MCU uses: file transfers, SetupComplete, CoreRun.
//
// The BIOS is sim/tb/testrom.S (see there for the checks it performs). Its
// verdict is written to NVRAM and read back here through FileReadStart(3)
// while the core is running (host SDRAM access with the 3DO paused).
// Video timing towards the framework is checked as well (320 pixels per
// line, 240 lines per frame).
//
// Plusargs: +rom=<file> (default build/sim/testrom.bin), +be (host sends
//           big-endian words; detected by the core from the ISO header),
//           +frames=<n> video frames to check, +trace (CPU bus), +state
//           (core control state), +sdram_verbose (SDRAM commands)
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_top;
	// clk_sys 50 MHz and clk_mem 100 MHz are phase aligned (same MMCM)
	reg clk_mem = 0;
	reg clk_sys = 0;
	reg clk_vid = 0;
	// independent generators with coincident edges (no delta-cycle skew
	// between the two domains, as with a real MMCM)
	always #5  clk_mem = ~clk_mem;
	always #10 clk_sys = ~clk_sys;
	always #10.191 clk_vid = ~clk_vid;     // 49.0625 MHz

	reg reset = 1;

	// host interface
	reg         h_enable = 0, h_write = 0;
	reg  [31:0] h_addr = 0, h_wdata = 0;
	wire [31:0] h_rdata;
	wire        h_done;
	reg         h_req = 0;
	wire        h_busy, h_cdone, h_err;
	wire        c_req;                      // core -> host request (disc sectors)
	reg         c_done = 0, c_err = 0;

	// video / audio
	wire [5:0]  vr, vg, vb;
	wire        vde, vvbl, vhbl;
	wire [15:0] al, ar;

	// SDRAM
	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;

	reg  [11:0] buttons = 0;
	wire        sr_ce_n, sr_we_n, sr_oe_n, sr_dir;
	wire [ 1:0] sr_mask_n;
	wire [17:0] sr_a;
	wire [15:0] sr_din, sr_dout;
	int         sram_mode = 0;
	initial void'($value$plusargs("sram_mode=%d", sram_mode));

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
		.input_buttons_a(buttons[0]), .input_buttons_b(buttons[1]), .input_buttons_x(buttons[2]),
		.input_buttons_y(buttons[3]), .input_buttons_up(buttons[4]), .input_buttons_down(buttons[5]),
		.input_buttons_left(buttons[6]), .input_buttons_right(buttons[7]), .input_buttons_l(buttons[8]),
		.input_buttons_r(buttons[9]), .input_buttons_start(buttons[10]), .input_buttons_select(buttons[11]),
		.sdram_clock(s_clk), .sdram_cke(s_cke), .sdram_cs(s_cs), .sdram_ras(s_ras), .sdram_cas(s_cas),
		.sdram_we(s_we), .sdram_dqm(s_dqm), .sdram_bank(s_ba), .sdram_address(s_a),
		.sdram_dataIn(s_dq_in), .sdram_dataOut(s_dq_out), .sdram_dataDir(s_oe),
		.sram_ceN(sr_ce_n), .sram_weN(sr_we_n), .sram_oeN(sr_oe_n), .sram_writeMaskN(sr_mask_n),
		.sram_address(sr_a), .sram_dataIn(sr_din), .sram_dataOut(sr_dout), .sram_dataDir(sr_dir)
	);

	// the SRAM ("VRAM memory" setting, +sram_mode=0 SRAM (default), 1 SRAM
	// with three cycles per word, 2 SDRAM only)
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
	task automatic fail(input string m);
		errors++;
		$display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	// ------------------------------------------------------------------
	// Host BFM (framework SpiReceiverFifo behaviour)
	// ------------------------------------------------------------------
	// The MCU does one SPI transaction at a time: serialise the BFM's users
	// (main sequence and the disc-read handler).
	bit host_lock = 0;
	task automatic host_access(input bit wr, input [31:0] a, input [31:0] d, output [31:0] q);
		int to;
		while (host_lock) @(posedge clk_sys);
		host_lock = 1;
		@(posedge clk_sys);
		h_enable <= 1; h_write <= wr; h_addr <= a; h_wdata <= d;
		@(posedge clk_sys);              // first cycle: done is not looked at
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

	// ------------------------------------------------------------------
	// Files
	// ------------------------------------------------------------------
	bit        host_be;
	bit [7:0]  rom [int];
	int        rom_len;
	bit [7:0]  iso [int];
	int        iso_len;

	function automatic [31:0] host_word(input [7:0] b0, input [7:0] b1, input [7:0] b2, input [7:0] b3);
		host_word = host_be ? {b0, b1, b2, b3} : {b3, b2, b1, b0};
	endfunction

	task automatic send_file(input int id, input [31:0] base, ref bit [7:0] data [int], input int len);
		bit [31:0] r;
		bit e;
		host_cmd(16'h0300, id, 0, 0, r, e);
		if (e) fail($sformatf("FileWriteStart(%0d) error", id));
		for (int o = 0; o < len; o += 4)
			host_wr(base + o, host_word(data.exists(o) ? data[o] : 8'h00, data.exists(o+1) ? data[o+1] : 8'h00,
			                            data.exists(o+2) ? data[o+2] : 8'h00, data.exists(o+3) ? data[o+3] : 8'h00));
		host_cmd(16'h0301, id, len, 0, r, e);
		if (e) fail($sformatf("FileWriteEnd(%0d) error", id));
	endtask

	// ------------------------------------------------------------------
	// Disc-streaming firmware model (+stream): the fork firmware's
	// send_disc (table of contents to the disc file's address) and
	// disc_read (raw 2352-byte sectors on DISC_READ requests).
	// ------------------------------------------------------------------
	bit stream_mode;
	int sectors_served = 0;
	int disc_latency_us = 300;

	function automatic [7:0] bcd(input int x); return 8'(((x / 10) << 4) | (x % 10)); endfunction
	function automatic [31:0] msf_bcd(input int lba);
		return {8'h00, bcd(lba / 75 / 60), bcd((lba / 75) % 60), bcd(lba % 75)};
	endfunction

	// The streamed disc: track 1 data (the ISO, abs LBA 150-153), track 2
	// CD-DA (AUDIO_SECTORS sectors from 154; byte i of the sector at abs LBA
	// L is (3i + L + (i >> 8)) & 0xFF, as test 14 of the test ROM expects).
	localparam int AUDIO_SECTORS = 6;
	function automatic bit is_audio(input int lba);
		return lba >= 150 + iso_len / 2048 && lba < 150 + iso_len / 2048 + AUDIO_SECTORS;
	endfunction
	// raw sector at absolute LBA: sync, header (BCD MSF, mode 1), user data
	function automatic [7:0] raw_byte(input int lba, input int i);
		int l;
		if (is_audio(lba)) return 8'((3 * i + lba + (i >> 8)) & 8'hFF);
		l = lba - 150;
		if (l < 0 || l * 2048 >= iso_len) return 8'h00;
		if (i == 0 || i == 11) return 8'h00;
		if (i < 11) return 8'hFF;
		if (i == 12) return msf_bcd(lba)[23:16];
		if (i == 13) return msf_bcd(lba)[15:8];
		if (i == 14) return msf_bcd(lba)[7:0];
		if (i == 15) return 8'h01;
		if (i < 16 + 2048) return iso[l * 2048 + i - 16];
		return 8'h00;   // EDC/ECC not modelled
	endfunction

	task automatic send_toc();
		bit [31:0] r, toc [12];
		bit e;
		int sectors, a0;
		sectors = iso_len / 2048;
		a0 = 150 + sectors;                  // track 2 (audio)
		toc[0] = {16'h0, bcd(2), 8'd2};
		toc[1] = a0 + AUDIO_SECTORS;
		toc[2] = msf_bcd(a0 + AUDIO_SECTORS);
		toc[3] = 0;
		toc[4] = 150; toc[5] = a0 - 1; toc[6] = 150; toc[7] = msf_bcd(150);
		toc[8] = a0; toc[9] = a0 + AUDIO_SECTORS - 1; toc[10] = a0; toc[11] = msf_bcd(a0) | 32'h8000_0000;
		host_cmd(16'h0300, 0, 0, 0, r, e);
		for (int i = 0; i < 12; i++) host_wr(32'h1000_0000 + 4 * i, toc[i]);
		host_cmd(16'h0301, 0, 48, 0, r, e);
	endtask

	// Every command the test ROM writes to the CD controller and the status
	// bytes it reads back, as seen on the controller's port.
	bit [7:0] ctl_cmd [8];
	int       ctl_cmd_n = 0, ctl_cmd_len = 7;
	bit [7:0] ctl_st [16];
	int       ctl_st_n = 0;
	reg       ctl_sten_d = 0;
	always @(posedge clk_sys) begin
		ctl_sten_d <= dut.cdrom.ST_EN;
		if (dut.cdrom.IO_ST == dut.cdrom.IO_CMD_WRITE) begin
			if (ctl_cmd_n == 0) ctl_cmd_len = (dut.cdrom.CDDI == 8'h04 || dut.cdrom.CDDI == 8'h05) ? 1 : 7;
			ctl_cmd[ctl_cmd_n] = dut.cdrom.CDDI;
			ctl_cmd_n++;
			if (ctl_cmd_n == ctl_cmd_len) begin
				string t;
				t = "";
				for (int i = 0; i < ctl_cmd_len; i++) t = {t, $sformatf(" %02h", ctl_cmd[i])};
				$display("[%0t] CD ctl cmd%s", $realtime, t);
				ctl_cmd_n = 0;
			end
		end
		if (dut.cdrom.IO_ST == dut.cdrom.IO_CMD_READ && ctl_st_n < 16) begin
			ctl_st[ctl_st_n] = dut.cdrom.STAT_DATA[dut.cdrom.STAT_FIFO_RPOS];
			ctl_st_n++;
		end
		if (!dut.cdrom.ST_EN && ctl_sten_d) begin
			string t;
			t = "";
			for (int i = 0; i < ctl_st_n; i++) t = {t, $sformatf(" %02h", ctl_st[i])};
			$display("[%0t] CD ctl status%s", $realtime, t);
			ctl_st_n = 0;
		end
	end

	// CD-DA pacing: audio sectors must reach the controller at the drive's
	// rate, 75 per second at single speed and 150 at double speed, timed
	// from one to the next (test 14 reads two pairs: 1x, then 2x). The
	// first sector after a READ comes one sector time after it.
	// The sector after a NEXT that came within one sector time of the
	// previous one must come exactly one sector time after it; after a later
	// NEXT (the CPU took longer to read the block), as soon as the firmware
	// has answered.
	realtime audio_last = -1s, read_cmd_t = -1s, next_cmd_t = -1s;
	int      audio_secs = 0, audio_gaps_1x = 0, audio_gaps_2x = 0;
	reg      dten_d = 0;
	always @(posedge clk_sys) begin
		dten_d <= dut.cdd_dten;
		if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h10) begin read_cmd_t = $realtime; audio_last = -1s; end
		if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h20) next_cmd_t = $realtime;
		if (dut.cdd_dten && !dten_d && dut.cdd.disc_stream && is_audio(int'(dut.cdd.q_lba))) begin
			realtime g, per;
			per = dut.cdrom.CDD_SPEED2X ? 1s / 150 : 1s / 75;
			audio_secs++;
			if (audio_last >= 0) begin
				realtime nx;
				g = $realtime - audio_last;
				nx = next_cmd_t - audio_last;
				$display("[%0t] CD-DA sector abs LBA %0d (%0d bytes): %0.4f ms after the previous one (%0dx), NEXT after %0.4f ms", $realtime,
				         dut.cdd.q_lba, dut.cdrom.CDD_BLK_LEN, g / 1ms, dut.cdrom.CDD_SPEED2X ? 2 : 1, nx / 1ms);
				if (nx + disc_latency_us * 1us + 100us < per) begin
					// one sector time to the clock (50 MHz: the fraction is spread over three sectors)
					if (g < per - 15ns || g > per + 15ns) fail($sformatf("CD-DA sector %0.4f ms after the previous one, expected %0.4f", g / 1ms, per / 1ms));
					if (dut.cdrom.CDD_SPEED2X) audio_gaps_2x++; else audio_gaps_1x++;
				end else begin
					if (g < per - 30ns) fail($sformatf("CD-DA sector %0.4f ms after the previous one, sooner than %0.4f", g / 1ms, per / 1ms));
					if (g > nx + disc_latency_us * 1us + 1ms) fail($sformatf("CD-DA sector %0.4f ms after its NEXT", (g - nx) / 1ms));
					$display("tb_top: the CPU read the block in more than a sector time: exact pacing not checked for this sector");
				end
			end else begin
				g = $realtime - read_cmd_t;
				$display("[%0t] CD-DA sector abs LBA %0d (%0d bytes): %0.4f ms after the READ", $realtime,
				         dut.cdd.q_lba, dut.cdrom.CDD_BLK_LEN, g / 1ms);
				if (g < per - 30ns) fail($sformatf("first CD-DA sector %0.4f ms after the READ, expected at least %0.4f", g / 1ms, per / 1ms));
			end
			audio_last = $realtime;
		end
	end

	initial forever begin
		bit [31:0] w [4];
		@(posedge clk_sys);
		if (stream_mode && c_req && !c_done && !c_err) begin
			for (int i = 0; i < 4; i++) host_rd(32'hF000_1000 + 4 * i, w[i]);
			#(disc_latency_us * 1us);
			if (w[0] != 32'h0400 || w[1] != 0) begin
				fail($sformatf("unexpected core request %08h %08h", w[0], w[1]));
				c_err <= 1;
			end else begin
				for (int i = 0; i < 2352; i += 4)
					host_wr(w[3] + i, {raw_byte(w[2], i + 3), raw_byte(w[2], i + 2), raw_byte(w[2], i + 1), raw_byte(w[2], i)});
				sectors_served++;
				c_done <= 1;
			end
			while (c_req) @(posedge clk_sys);
			c_done <= 0; c_err <= 0;
		end
	end

	// Read the NVRAM file back as the MCU does on exit
	bit [7:0] nvram [32768];
	bit [31:0] nvram_size;       // FileReadStart's answer: 0x8000, or 0 when unchanged
	task automatic read_nvram(input int bytes);
		bit [31:0] r, w;
		bit e;
		host_cmd(16'h0302, 3, 0, 0, r, e);
		if (e) fail("FileReadStart(3) error");
		if (r != 32'h8000 && r != 0) fail($sformatf("FileReadStart(3) size %08h", r));
		nvram_size = r;
		// the testbench reads the memory either way (the firmware would skip it on 0)
		for (int o = 0; o < bytes; o += 4) begin
			host_rd(32'h3000_0000 + o, w);
			if (host_be) {nvram[o], nvram[o+1], nvram[o+2], nvram[o+3]} = w;
			else         {nvram[o+3], nvram[o+2], nvram[o+1], nvram[o]} = w;
		end
		host_cmd(16'h0303, 3, 0, 0, r, e);
	endtask

	// "Buttons" setting (0x100C): each Game Bub button held alone gives one
	// 3DO button in the control pad word the player bus sends (HPS2PAD:
	// 1 0 0 Down Up Right Left A B C P X R L 0 0, a pressed button is 1).
	// Layout 0: Y B A -> A B C, X -> X; layout 1: A B X -> A B C, Y -> X;
	// both: Select -> X, Start -> P, L/R, directions.
	localparam int PD_DOWN = 12, PD_UP = 11, PD_RIGHT = 10, PD_LEFT = 9, PD_A = 8, PD_B = 7,
	               PD_C = 6, PD_P = 5, PD_X = 4, PD_R = 3, PD_L = 2;
	int pad_checks = 0;
	task automatic check_buttons(input bit layout);
		// in the order of `buttons`: A B X Y Up Down Left Right L R Start Select
		int map0 [12] = '{PD_C, PD_B, PD_X, PD_A, PD_UP, PD_DOWN, PD_LEFT, PD_RIGHT, PD_L, PD_R, PD_P, PD_X};
		int map1 [12] = '{PD_A, PD_B, PD_C, PD_X, PD_UP, PD_DOWN, PD_LEFT, PD_RIGHT, PD_L, PD_R, PD_P, PD_X};
		string names [12] = '{"A", "B", "X", "Y", "Up", "Down", "Left", "Right", "L", "R", "Start", "Select"};
		bit [31:0] q;
		bit [15:0] got, exp;
		host_rd(32'h0000_100C, q);
		if (q != {31'd0, layout}) fail($sformatf("Buttons setting reads %08h, written %0d", q, layout));
		for (int i = 0; i <= 12; i++) begin
			buttons = (i < 12) ? 12'(1) << i : 12'd0;
			repeat (4) @(posedge clk_sys);
			exp = 16'h8000 | ((i < 12) ? 16'(1) << (layout ? map1[i] : map0[i]) : 16'h0);
			got = dut.pad.IN_DATA[255:240];
			pad_checks++;
			if (got !== exp)
				fail($sformatf("Buttons setting %0d: %s held gives pad word %04h, expected %04h",
				               layout, (i < 12) ? names[i] : "nothing", got, exp));
		end
	endtask

	// ------------------------------------------------------------------
	// Video timing monitor (framework side)
	// ------------------------------------------------------------------
	// A CLIO software reset also resets the video encoder (VE), as on MiSTer,
	// so the line and frame it interrupts are counted separately; every
	// other line and frame must be exact.
	int px_in_line = 0, lines_in_frame = 0, frames = 0, bad_lines = 0, bad_frames = 0;
	int srst_lines = 0, srst_frames = 0, soft_resets = 0;
	realtime last_soft_reset = -1s;
	reg vhbl_d = 0, vvbl_d = 0, clio_reset_n_d = 1;
	always @(posedge clk_sys) begin
		bit near_srst;
		vhbl_d <= vhbl; vvbl_d <= vvbl;
		clio_reset_n_d <= dut.p3do.RESET_N;
		if (!dut.p3do.RESET_N && clio_reset_n_d && !dut.reset_3do) begin
			soft_resets++;
			last_soft_reset = $realtime;
			$display("[%0t] CLIO software reset", $realtime);
		end
		near_srst = last_soft_reset >= 0 && $realtime - last_soft_reset < 20ms;
		if (vde) px_in_line++;
		if (vhbl && !vhbl_d) begin
			if (px_in_line != 320) begin
				if (near_srst) begin
					srst_lines++;
					$display("[%0t] video: line %0d has %0d pixels (software reset)", $realtime, lines_in_frame, px_in_line);
				end else begin
					bad_lines++;
					if (bad_lines < 5) $display("[%0t] video: line %0d has %0d pixels", $realtime, lines_in_frame, px_in_line);
				end
			end
			px_in_line = 0;
			lines_in_frame++;
		end
		if (vvbl && !vvbl_d) begin
			if (frames > 0 && lines_in_frame != 240) begin
				if (near_srst) srst_frames++;
				else bad_frames++;
				$display("[%0t] video: frame %0d has %0d lines%s", $realtime, frames, lines_in_frame, near_srst ? " (software reset)" : "");
			end
			frames++;
			lines_in_frame = 0;
			px_in_line = 0;
		end
	end

	// ------------------------------------------------------------------
	// Debug trace (+trace): CPU bus activity and pause state
	// ------------------------------------------------------------------
	bit trace;
	initial trace = $test$plusargs("trace");
	always @(posedge clk_sys) begin
		if (trace && dut.p3do.MCLK_PH2)
			$display("[%0t] CPU %s %08h %08h %s nMREQ=%b SEQ=%b nRES=%b CLIO_RESET_N=%b BOOT_ROM=%b", $realtime, dut.p3do.CPU_nRW ? "W" : "R", dut.p3do.CPU_A,
			         dut.p3do.CPU_nRW ? dut.p3do.CPU_DO : dut.p3do.CPU_DI, dut.p3do.CPU_nOPC ? "  " : "op",
			         dut.p3do.CPU_nMREQ, dut.p3do.CPU_SEQ, dut.p3do.CPU_nRES, dut.p3do.RESET_N, dut.p3do.madam.BOOT_ROM);
	end

	initial if ($test$plusargs("state")) forever begin
		#20us;
		$display("[%0t] state: reset_3do=%b halt=%b bios=%b pause=%b sec_hold=%b sec_paused=%b core_rst_lock=%b PH1=%b sst=%0d nMREQ=%b CPU_A=%08h ioBusy=%b ddrBusy=%b LRDY=%b RRDY=%b",
		         $realtime, dut.reset_3do, dut.core_halt, dut.bios_loaded, dut.pause, dut.sec_hold, dut.sec_paused,
		         dut.core_rst_lock, dut.MCLK_CE, dut.sdram.sst, dut.p3do.CPU_nMREQ, dut.p3do.CPU_A,
		         dut.ddr_io_busy, dut.ddr_busy, dut.VRAM_LRDY, dut.VRAM_RRDY);
		$display("          ddram.state=%0d io_read_busy=%b bridge.st=%0d DDRAM_BUSY=%b ddr_sec_req=%b arb.busy=%b arb.sel=%0d m_req=%b",
		         dut.ddram.state, dut.ddram.io_read_busy, dut.ddr_bridge.st, dut.DDRAM_BUSY, dut.ddr_sec_req,
		         dut.arb.busy, dut.arb.sel, dut.m_req);
	end

	// ------------------------------------------------------------------
	initial begin
		string romfile;
		int fd, c, n_frames;
		bit [31:0] r;
		bit e;
		bit done;
		bit nvram_changed;

		if (!$value$plusargs("rom=%s", romfile)) romfile = "build/sim/testrom.bin";
		if (!$value$plusargs("frames=%d", n_frames)) n_frames = 2;
		host_be = $test$plusargs("be");
		stream_mode = $test$plusargs("stream");
		void'($value$plusargs("disc_latency_us=%d", disc_latency_us));
		if (stream_mode && host_be) $fatal(1, "tb_top: +stream uses little-endian host words");

		fd = $fopen(romfile, "rb");
		if (fd == 0) $fatal(1, "tb_top: cannot open %s", romfile);
		rom_len = 0;
		while ((c = $fgetc(fd)) != -1) rom[rom_len++] = c[7:0];
		$fclose(fd);
		rom_len = (rom_len + 3) & ~3;
		$display("tb_top: BIOS %s, %0d bytes, host %s-endian", romfile, rom_len, host_be ? "big" : "little");

		// A small ISO: sector 0 starts with the Opera volume header so the
		// core can detect the host byte order, plus a recognisable pattern.
		iso_len = 4 * 2048;
		for (int i = 0; i < iso_len; i++) iso[i] = 8'((i * 7 + (i >> 11)) & 8'hFF);
		iso[0] = 8'h01; iso[1] = 8'h5A; iso[2] = 8'h5A; iso[3] = 8'h5A; iso[4] = 8'h5A; iso[5] = 8'h5A; iso[6] = 8'h01;

		repeat (20) @(posedge clk_sys);
		reset <= 0;

		// GetStatus until the core is ready for setup
		do begin
			host_cmd(16'h0000, 0, 0, 0, r, e);
		end while (r != 2);
		$display("[%0t] core status: setup", $realtime);

		// files in files.json order
		if (stream_mode) send_toc();
		else             send_file(0, 32'h1000_0000, iso, iso_len);
		send_file(1, 32'h2000_0000, rom, rom_len);

		host_cmd(16'h0102, 0, 0, 0, r, e);   // SetupComplete
		do begin
			host_cmd(16'h0000, 0, 0, 0, r, e);
		end while (r != 3);
		$display("[%0t] core status: halted (setup complete)", $realtime);

		// The blank NVRAM must have been formatted (save file not supplied),
		// and reported as changed (a new save file is due); afterwards it is
		// unchanged until the 3DO writes it.
		read_nvram(16);
		if (nvram_size != 32'h8000) fail("freshly formatted NVRAM not reported as changed");
		read_nvram(16);
		if (nvram_size != 0) fail("unchanged NVRAM reported as changed");
		if ({nvram[0], nvram[1], nvram[2], nvram[3]} != 32'h015A5A5A || nvram[6] != 8'h02)
			fail($sformatf("NVRAM not formatted: %02h %02h %02h %02h .. %02h", nvram[0], nvram[1], nvram[2], nvram[3], nvram[6]));

		host_wr(32'h0000_1000, 32'h2);       // setting: CD speed "Fast (0.5 ms)"
		check_buttons(0);                    // "Buttons": the default, then the other layout and back
		host_wr(32'h0000_100C, 32'h1);
		check_buttons(1);
		host_wr(32'h0000_100C, 32'h0);
		check_buttons(0);
		$display("[%0t] Buttons setting: %0d pad words checked", $realtime, pad_checks);
		host_wr(32'h0000_1010, 32'(sram_mode));   // "VRAM memory", taken while the 3DO is in reset
		begin
			bit [31:0] q;
			host_rd(32'h0000_1010, q);
			if (q != 32'(sram_mode)) fail($sformatf("VRAM memory setting reads %0d, written %0d", q, sram_mode));
		end
		$display("[%0t] VRAM memory setting %0d (%s)", $realtime, sram_mode,
		         sram_mode == 0 ? "SRAM, 2 cycles per word" : sram_mode == 1 ? "SRAM, 3 cycles per word" : "SDRAM only");
		host_cmd(16'h0200, 1, 0, 0, r, e);   // NotifyFocus(1)
		host_cmd(16'h0100, 0, 0, 0, r, e);   // CoreRun
		$display("[%0t] core running", $realtime);
		if ($test$plusargs("short")) begin #300us; $display("tb_top: +short: stopped at 300 us, nothing checked (no PASS/FAIL)"); $finish; end

		// Poll the verdict in NVRAM bytes 0x100..0x10F
		done = 0;
		nvram_changed = 0;
		// (about 250 ms: test 14 reads CD-DA sectors in real time)
		for (int t = 0; t < 2500 && !done; t++) begin
			#100us;
			read_nvram(16'h110);
			if (nvram_size != 0) nvram_changed = 1;
			if ({nvram[256], nvram[257], nvram[258], nvram[259]} == "PASS" ||
			    {nvram[256], nvram[257], nvram[258], nvram[259]} == "FAIL") done = 1;
		end
		if (!done) fail("test ROM did not report a result");
		if (!nvram_changed) fail("NVRAM written by the 3DO was never reported as changed");
		else begin
			bit [31:0] test, addr, checks;
			test   = {nvram[260], nvram[261], nvram[262], nvram[263]};
			addr   = {nvram[264], nvram[265], nvram[266], nvram[267]};
			checks = {nvram[268], nvram[269], nvram[270], nvram[271]};
			$display("[%0t] test ROM: %s test=%0d addr=%08h checks=%0d", $realtime,
			         {nvram[256], nvram[257], nvram[258], nvram[259]}, test, addr, checks);
			if ({nvram[256], nvram[257], nvram[258], nvram[259]} != "PASS") fail("test ROM reported FAIL");
			// tests 1-8, test 9 (SPORT write masks): 3 regions x (13 checks of a
			// row), test 10 (CLIO timers and interrupt summary): 10, test 11
			// (matrix engine): 3
			// test 7's final status: 1; test 14: 22 checks with the streamed
			// disc (audio track), 1 with a preloaded ISO (disc info only)
			if (checks != 64*4 + 1 + 64*5 + 2 + 16 + 1 + 2 + 4 + 1 + (stream_mode ? 22 : 1) + 3 * 13 * 512 + 10 + 3 + 64 + 16)
				fail($sformatf("unexpected number of checks %0d", checks));
			for (int i = 0; i < 16; i++)
				if (nvram[8'h80 + i] != 8'(8'hA5 + 8'h13 * i)) fail($sformatf("NVRAM byte %02h = %02h", 8'h80 + i, nvram[8'h80 + i]));
		end

		// video timing towards the framework
		while (frames < n_frames + 1) @(posedge clk_sys);
		$display("[%0t] video: %0d frames, bad lines %0d, bad frames %0d; at the %0d software reset(s): %0d lines, %0d frames",
		         $realtime, frames, bad_lines, bad_frames, soft_resets, srst_lines, srst_frames);
		if (bad_lines || bad_frames) fail("video timing");
		// one from CLIO's power-on state (CSTAT = 0x11), one by the test ROM
		if (soft_resets != 2) fail($sformatf("%0d CLIO software resets, expected 2 (power-on and the test ROM's)", soft_resets));

		if (stream_mode) begin
			$display("tb_top: %0d disc sectors served by the firmware model", sectors_served);
			if (sectors_served < 3) fail("streaming mode: the core did not request the sectors");
			$display("tb_top: %0d CD-DA sectors, %0d gaps checked at 1x, %0d at 2x", audio_secs, audio_gaps_1x, audio_gaps_2x);
			if (audio_secs != 4 || audio_gaps_1x != 1 || audio_gaps_2x != 1) fail("CD-DA: expected 4 audio sectors in two pairs (1x, 2x)");
		end
		// test ROM test 4 writes VRAM 0x2A0400 (block A: in the SRAM unless it is off)
		if (sram_mode != 2 && sram.writes == 0) fail("no VRAM write reached the SRAM");
		if (sram_mode == 2 && sram.writes != 0) fail("VRAM writes reached the SRAM with it off");
		$display("tb_top: TB errors=%0d, SDRAM model errors=%0d, SRAM model errors=%0d (%0d SRAM writes)",
		         errors, sdram.errors, sram.errors, sram.writes);
		// a failure ends with a non-zero exit status ($fatal), so scripts see it
		if (errors == 0 && sdram.errors == 0 && sram.errors == 0) begin $display("tb_top: PASS"); $finish; end
		else $fatal(1, "tb_top: FAIL");
	end

	initial begin
		#400ms;
		$display("tb_top: TIMEOUT");
		$fatal(1, "tb_top: FAIL");
	end
endmodule
