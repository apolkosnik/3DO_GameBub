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
// Plusargs: +rom=<file> (default build/sim/testrom.bin); the disc (see the
//           firmware model): stock firmware with an on-demand ISO (default),
//           +stream (the fork's raw image with a CD-DA track), +preload (the
//           ISO loaded at setup; +be: the host sends big-endian words,
//           detected by the core from the ISO header),
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
	// the dock's gamepads: connected, buttons {l2 r2 l3 r3 a b x y up down
	// left right l1 r1 start select}, sticks
	reg  [ 3:0] gp_on = '0;
	reg  [15:0] gp_bt [4] = '{default: '0};
	reg  [ 7:0] gp_lx [4] = '{default: '0}, gp_ly [4] = '{default: '0}, gp_rx [4] = '{default: '0}, gp_ry [4] = '{default: '0};
	// InputExtendedV0 slots as the framework (HandheldInput) drives them:
	// docked (a dock controller in slot 0) the dock's, else slot 0 is the
	// handheld (`buttons`: A B X Y Up Down Left Right L R Start Select) and
	// the other slots are empty.
	wire        docked = gp_on[0];
	wire [15:0] hh_bt = {4'b0000, buttons[0], buttons[1], buttons[2], buttons[3], buttons[4], buttons[5],
	                     buttons[6], buttons[7], buttons[8], buttons[9], buttons[10], buttons[11]};
	wire [ 3:0] sl_on = docked ? gp_on : 4'b0001;
	wire [15:0] sl_bt [4] = '{docked ? gp_bt[0] : hh_bt, docked ? gp_bt[1] : '0, docked ? gp_bt[2] : '0, docked ? gp_bt[3] : '0};
	wire [ 3:0] sl_type [4] = '{docked ? 4'd3 : 4'd1, sl_on[1] ? 4'd3 : 4'd0, sl_on[2] ? 4'd3 : 4'd0, sl_on[3] ? 4'd3 : 4'd0};
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
		.input_slots_0_active(sl_on[0]), .input_slots_0_deviceType(sl_type[0]), .input_slots_0_buttons_l2(sl_bt[0][15]), .input_slots_0_buttons_r2(sl_bt[0][14]), .input_slots_0_buttons_l3(sl_bt[0][13]), .input_slots_0_buttons_r3(sl_bt[0][12]), .input_slots_0_buttons_a(sl_bt[0][11]), .input_slots_0_buttons_b(sl_bt[0][10]), .input_slots_0_buttons_x(sl_bt[0][9]), .input_slots_0_buttons_y(sl_bt[0][8]), .input_slots_0_buttons_up(sl_bt[0][7]), .input_slots_0_buttons_down(sl_bt[0][6]), .input_slots_0_buttons_left(sl_bt[0][5]), .input_slots_0_buttons_right(sl_bt[0][4]), .input_slots_0_buttons_l1(sl_bt[0][3]), .input_slots_0_buttons_r1(sl_bt[0][2]), .input_slots_0_buttons_start(sl_bt[0][1]), .input_slots_0_buttons_select(sl_bt[0][0]), .input_slots_0_analog_leftX(gp_lx[0]), .input_slots_0_analog_leftY(gp_ly[0]), .input_slots_0_analog_rightX(gp_rx[0]), .input_slots_0_analog_rightY(gp_ry[0]), .input_slots_0_analog_leftTrigger(8'd0), .input_slots_0_analog_rightTrigger(8'd0),
		.input_slots_1_active(sl_on[1]), .input_slots_1_deviceType(sl_type[1]), .input_slots_1_buttons_l2(sl_bt[1][15]), .input_slots_1_buttons_r2(sl_bt[1][14]), .input_slots_1_buttons_l3(sl_bt[1][13]), .input_slots_1_buttons_r3(sl_bt[1][12]), .input_slots_1_buttons_a(sl_bt[1][11]), .input_slots_1_buttons_b(sl_bt[1][10]), .input_slots_1_buttons_x(sl_bt[1][9]), .input_slots_1_buttons_y(sl_bt[1][8]), .input_slots_1_buttons_up(sl_bt[1][7]), .input_slots_1_buttons_down(sl_bt[1][6]), .input_slots_1_buttons_left(sl_bt[1][5]), .input_slots_1_buttons_right(sl_bt[1][4]), .input_slots_1_buttons_l1(sl_bt[1][3]), .input_slots_1_buttons_r1(sl_bt[1][2]), .input_slots_1_buttons_start(sl_bt[1][1]), .input_slots_1_buttons_select(sl_bt[1][0]), .input_slots_1_analog_leftX(gp_lx[1]), .input_slots_1_analog_leftY(gp_ly[1]), .input_slots_1_analog_rightX(gp_rx[1]), .input_slots_1_analog_rightY(gp_ry[1]), .input_slots_1_analog_leftTrigger(8'd0), .input_slots_1_analog_rightTrigger(8'd0),
		.input_slots_2_active(sl_on[2]), .input_slots_2_deviceType(sl_type[2]), .input_slots_2_buttons_l2(sl_bt[2][15]), .input_slots_2_buttons_r2(sl_bt[2][14]), .input_slots_2_buttons_l3(sl_bt[2][13]), .input_slots_2_buttons_r3(sl_bt[2][12]), .input_slots_2_buttons_a(sl_bt[2][11]), .input_slots_2_buttons_b(sl_bt[2][10]), .input_slots_2_buttons_x(sl_bt[2][9]), .input_slots_2_buttons_y(sl_bt[2][8]), .input_slots_2_buttons_up(sl_bt[2][7]), .input_slots_2_buttons_down(sl_bt[2][6]), .input_slots_2_buttons_left(sl_bt[2][5]), .input_slots_2_buttons_right(sl_bt[2][4]), .input_slots_2_buttons_l1(sl_bt[2][3]), .input_slots_2_buttons_r1(sl_bt[2][2]), .input_slots_2_buttons_start(sl_bt[2][1]), .input_slots_2_buttons_select(sl_bt[2][0]), .input_slots_2_analog_leftX(gp_lx[2]), .input_slots_2_analog_leftY(gp_ly[2]), .input_slots_2_analog_rightX(gp_rx[2]), .input_slots_2_analog_rightY(gp_ry[2]), .input_slots_2_analog_leftTrigger(8'd0), .input_slots_2_analog_rightTrigger(8'd0),
		.input_slots_3_active(sl_on[3]), .input_slots_3_deviceType(sl_type[3]), .input_slots_3_buttons_l2(sl_bt[3][15]), .input_slots_3_buttons_r2(sl_bt[3][14]), .input_slots_3_buttons_l3(sl_bt[3][13]), .input_slots_3_buttons_r3(sl_bt[3][12]), .input_slots_3_buttons_a(sl_bt[3][11]), .input_slots_3_buttons_b(sl_bt[3][10]), .input_slots_3_buttons_x(sl_bt[3][9]), .input_slots_3_buttons_y(sl_bt[3][8]), .input_slots_3_buttons_up(sl_bt[3][7]), .input_slots_3_buttons_down(sl_bt[3][6]), .input_slots_3_buttons_left(sl_bt[3][5]), .input_slots_3_buttons_right(sl_bt[3][4]), .input_slots_3_buttons_l1(sl_bt[3][3]), .input_slots_3_buttons_r1(sl_bt[3][2]), .input_slots_3_buttons_start(sl_bt[3][1]), .input_slots_3_buttons_select(sl_bt[3][0]), .input_slots_3_analog_leftX(gp_lx[3]), .input_slots_3_analog_leftY(gp_ly[3]), .input_slots_3_analog_rightX(gp_rx[3]), .input_slots_3_analog_rightY(gp_ry[3]), .input_slots_3_analog_leftTrigger(8'd0), .input_slots_3_analog_rightTrigger(8'd0),
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
	bit [31:0] disc_id_arg;                 // +disc_id: the ISO's volume unique identifier
	bit        disc_id_set = 0;

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
	// Disc firmware model. The disc file is on demand (files.json
	// "on_demand", framework v1.1.0-beta4): the core asks for it through
	// HostV0 core -> host requests (opcode and 5 parameters at 0xF000_1000,
	// results written back there before done; an error is done and error):
	// FileGetSize 0x0400, FileRead 0x0402 (file, address, offset lo, hi,
	// count; short at the end of the file) and the fork's DiscGetToc 0x8400
	// (file, address).
	//   default:  stock firmware: the ISO; DiscGetToc is unknown (error)
	//   +stream:  the fork firmware: the disc as a raw image (data track and
	//             a CD-DA track), its table of contents on DiscGetToc
	//   +preload: no requests: the ISO loaded at setup (FileWrite, before
	//             on-demand files; +be: big-endian host words)
	// ------------------------------------------------------------------
	bit stream_mode, preload_mode;
	int disc_reqs = 0;
	int sectors_served = 0;
	int disc_latency_us = 300;
	// A firmware hiccup (a slow SD read, a file opened at a track boundary):
	// the requests for the 4th audio sector (abs LBA 157) are answered
	// disc_spike_us late. The first is the core's read-ahead for the READ
	// that continues the stream: the sector must still come exactly one
	// sector time after the previous one. The second is for the READ at 2x,
	// a seek: its sector comes late, and the next one exactly one sector
	// time after it (the clock waits; no burst).
	int disc_spike_us = 20000;
	int disc_spikes = 0;

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

	task automatic send_toc(input bit [31:0] addr);
		bit [31:0] toc [12];
		int sectors, a0;
		sectors = iso_len / 2048;
		a0 = 150 + sectors;                  // track 2 (audio)
		toc[0] = {16'h0, bcd(2), 8'd2};
		toc[1] = a0 + AUDIO_SECTORS;
		toc[2] = msf_bcd(a0 + AUDIO_SECTORS);
		toc[3] = 0;
		toc[4] = 150; toc[5] = a0 - 1; toc[6] = 150; toc[7] = msf_bcd(150);
		toc[8] = a0; toc[9] = a0 + AUDIO_SECTORS - 1; toc[10] = a0; toc[11] = msf_bcd(a0) | 32'h8000_0000;
		for (int i = 0; i < 12; i++) host_wr(addr + 4 * i, toc[i]);
	endtask
	// the disc file's byte o: the raw image (+stream) or the ISO
	function automatic [7:0] file_byte(input longint o);
		if (stream_mode) return raw_byte(int'(o / 2352) + 150, int'(o % 2352));
		return iso.exists(int'(o)) ? iso[int'(o)] : 8'h00;
	endfunction
	function automatic longint file_size();
		return stream_mode ? longint'(iso_len / 2048 + AUDIO_SECTORS) * 2352 : longint'(iso_len);
	endfunction

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
	// from one to the next (test 14 reads at 1x a pair and then, with a new
	// READ that continues the stream, one more; then a pair at 2x). The
	// first sector after a READ elsewhere (a seek) comes one sector time
	// after it. A READ of the sector after the last audio one continues the
	// stream, as a NEXT does: the sector asked for (by a NEXT or such a
	// READ) within one sector time of the previous one must come exactly
	// one sector time after it, so the time between two READs does not slow
	// playback down; asked for later (the CPU took longer to read the
	// block), as soon as the firmware has answered.
	realtime audio_last = -1s, read_cmd_t = -1s, next_cmd_t = -1s;
	int      audio_last_lba = -1;
	int      audio_secs = 0, audio_gaps_1x = 0, audio_gaps_2x = 0;
	reg      dten_d = 0;
	always @(posedge clk_sys) begin
		dten_d <= dut.cdd_dten;
		if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h10) begin
			int l;   // absolute LBA, as cdd_emu.sv decodes the READ
			l = dut.cdd.comm[4] != 0 ? {dut.cdd.comm[1], dut.cdd.comm[2], dut.cdd.comm[3]}
			                         : dut.cdd.comm[1] * 4500 + dut.cdd.comm[2] * 75 + dut.cdd.comm[3];
			read_cmd_t = $realtime;
			if (audio_last >= 0 && l == audio_last_lba + 1) begin
				next_cmd_t = $realtime;
				$display("[%0t] CD-DA: READ of abs LBA %0d continues the stream", $realtime, l);
			end else audio_last = -1s;
		end
		if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h20) next_cmd_t = $realtime;
		if (dut.cdd_dten && !dten_d && dut.cdd.ds_eff && is_audio(int'(dut.cdd.snd_lba))) begin
			realtime g, per;
			per = dut.cdrom.CDD_SPEED2X ? 1s / 150 : 1s / 75;
			audio_secs++;
			if (audio_last >= 0) begin
				realtime nx;
				g = $realtime - audio_last;
				nx = next_cmd_t - audio_last;
				$display("[%0t] CD-DA sector abs LBA %0d (%0d bytes): %0.4f ms after the previous one (%0dx), asked for (NEXT or READ) after %0.4f ms", $realtime,
				         dut.cdd.snd_lba, dut.cdrom.CDD_BLK_LEN, g / 1ms, dut.cdrom.CDD_SPEED2X ? 2 : 1, nx / 1ms);
				if (nx + disc_latency_us * 1us + 100us < per) begin
					// one sector time to the clock (50 MHz: the fraction is spread over three sectors)
					if (g < per - 15ns || g > per + 15ns) fail($sformatf("CD-DA sector %0.4f ms after the previous one, expected %0.4f", g / 1ms, per / 1ms));
					if (dut.cdrom.CDD_SPEED2X) audio_gaps_2x++; else audio_gaps_1x++;
				end else begin
					if (g < per - 30ns) fail($sformatf("CD-DA sector %0.4f ms after the previous one, sooner than %0.4f", g / 1ms, per / 1ms));
					if (g > nx + disc_latency_us * 1us + 1ms) fail($sformatf("CD-DA sector %0.4f ms after its NEXT or READ", (g - nx) / 1ms));
					$display("tb_top: the CPU read the block in more than a sector time: exact pacing not checked for this sector");
				end
			end else begin
				g = $realtime - read_cmd_t;
				$display("[%0t] CD-DA sector abs LBA %0d (%0d bytes): %0.4f ms after the READ", $realtime,
				         dut.cdd.snd_lba, dut.cdrom.CDD_BLK_LEN, g / 1ms);
				if (g < per - 30ns) fail($sformatf("first CD-DA sector %0.4f ms after the READ, expected at least %0.4f", g / 1ms, per / 1ms));
			end
			audio_last = $realtime;
			audio_last_lba = int'(dut.cdd.snd_lba);
		end
	end

	// The disc-info block (cdd_emu -> 3DO_CDROM while CDD_DIEN): bytes
	// 0x400-0x47F are the first 128 bytes of the RAW sector 0 (MiSTer's
	// GetDiscInfo copies them from the raw sector, and 3DO.sv takes the
	// per-game table key from 0x458-0x45B = raw bytes 0x58-0x5B, the volume
	// unique identifier at user bytes 0x48-0x4B). Streamed: the sector's sync
	// and header, then the user data; preloaded ISO: 16 zero bytes, then the
	// user data. The port put the user data at 0x400, so the key came out 16
	// bytes off (Killing Time's 0A9B739E read 00000001 and its DSP-pause
	// entry never applied).
	bit [15:0] info_words [int];
	int        info_n = 0, info_blocks = 0;
	bit        cdd_dien_d = 0;
	function automatic [7:0] info_raw_byte(input int i);   // raw sector 0 byte i as the block carries it
		if (stream_mode) return raw_byte(150, i);
		return i < 16 ? 8'h00 : iso[i - 16];
	endfunction
	always @(posedge clk_sys) begin
		cdd_dien_d <= dut.cdd_dien;
		if (dut.cdd_dien && !cdd_dien_d) info_n = 0;
		if (dut.cdd_dien && dut.cdd_wr) info_words[info_n++] = dut.cdd_data;
		if (!dut.cdd_dien && cdd_dien_d) begin
			info_blocks++;
			if (info_n != 1024) fail($sformatf("disc-info block of %0d words, expected 1024", info_n));
			for (int k = 0; k < 64; k++)
				if (info_words[512 + k] != {info_raw_byte(2 * k + 1), info_raw_byte(2 * k)})
					fail($sformatf("disc-info bytes 0x%03x-0x%03x: %02h %02h, expected raw sector 0 bytes %0d,%0d = %02h %02h",
					               16'h400 + 2 * k, 16'h401 + 2 * k, info_words[512 + k][7:0], info_words[512 + k][15:8],
					               2 * k, 2 * k + 1, info_raw_byte(2 * k), info_raw_byte(2 * k + 1)));
			if (dut.disc_id != {iso[72], iso[73], iso[74], iso[75]})
				fail($sformatf("disc id %08h, expected %02h%02h%02h%02h (user bytes 0x48-0x4B)", dut.disc_id, iso[72], iso[73], iso[74], iso[75]));
			$display("[%0t] disc-info block %0d: id %08h", $realtime, info_blocks, dut.disc_id);
		end
	end

	initial forever begin
		bit [31:0] w [6];
		bit [31:0] res [3];
		bit        ok, unknown;
		@(posedge clk_sys);
		if (!preload_mode && c_req && !c_done && !c_err) begin
			for (int i = 0; i < 6; i++) host_rd(32'hF000_1000 + 4 * i, w[i]);
			disc_reqs++;
			res = '{default: '0};
			ok = 1;
			unknown = 0;
			if (w[1] != 0) fail($sformatf("core request %08h for file %0d, not the disc", w[0], w[1]));
			case (w[0])
				32'h0000_0400: begin res[1] = file_size()[31:0]; res[2] = file_size()[63:32]; end
				32'h0000_0402: begin
					longint off;
					int n;
					off = {w[4], w[3]};
					n = (off >= file_size()) ? 0 : (file_size() - off < longint'(w[5])) ? int'(file_size() - off) : int'(w[5]);
					#(disc_latency_us * 1us);
					// a sector read (not the core's first look at the file)
					if (off != 0 || w[2] != 32'h4000_0000) begin
						bit [31:0] slot;
						slot = w[2] - (stream_mode ? 32'd0 : 32'd16);
						if (slot < 32'h4000_0000 || slot > 32'h4000_7FFF - 2352 + 1 || (slot - 32'h4000_0000) % 2352 != 0)
							fail($sformatf("FileRead: destination %08h is not a sector slot (+%0d)", w[2], stream_mode ? 0 : 16));
						if (w[5] != (stream_mode ? 2352 : 2048) || off % w[5] != 0)
							fail($sformatf("FileRead of %0d bytes at %0d: not one %0d-byte sector", w[5], off, stream_mode ? 2352 : 2048));
						if (stream_mode && disc_spikes < 2 && off == longint'(iso_len / 2048 + 3) * 2352) begin
							disc_spikes++;
							$display("[%0t] firmware model: abs LBA %0d answered %0d us late", $realtime, 150 + iso_len / 2048 + 3, disc_spike_us);
							#(disc_spike_us * 1us);
						end
						sectors_served++;
					end
					for (int i = 0; i < n; i += 4)
						host_wr(w[2] + i, {file_byte(off + i + 3), file_byte(off + i + 2), file_byte(off + i + 1), file_byte(off + i)});
					res[1] = n;
				end
				32'h0000_8400: begin
					if (stream_mode) send_toc(w[2]);
					else unknown = 1;      // stock firmware: an unknown request
				end
				default: begin
					fail($sformatf("unexpected core request %08h", w[0]));
					unknown = 1;
				end
			endcase
			if (!unknown) for (int i = 0; i < 3; i++) host_wr(32'hF000_1000 + 4 * i, res[i]);
			c_done <= 1;
			c_err  <= unknown || !ok;
			while (c_req) @(posedge clk_sys);
			c_done <= 0; c_err <= 0;
		end
	end

	// Read the NVRAM file back as the MCU does on exit, and on pause while the
	// game runs (save_on_pause). The MCU reads it over SPI, which cannot wait
	// (framework SpiReceiverFifo): the read request for word j is queued one
	// SPI word time after the one for word j-1, the first at the end of the
	// command, and word j is shifted out SAVE_LEAD words after its request
	// (the 8 dummy bytes); the core answers the requests in order. A word not
	// there in time is sent as FFFFFFFF and the rest of the save shifts. The
	// default 5000 KB/s (10 MHz quad SPI) makes a word SAVE_WORD long. Each
	// save is checked against that schedule with the host reads' own times.
	// gb_host holds the 3DO paused for a save (save_hold); without it the
	// reads waited for the SDRAM behind the running 3DO and the saves on the
	// card came out shifted and FF-filled.
	localparam realtime SAVE_WORD = 800ns;
	localparam int      SAVE_LEAD = 2;
	int       nvram_saves = 0, nvram_save_words = 0, nvram_underflows = 0;
	realtime  nvram_worst_slack = 1s;
	bit [7:0] nvram [32768];
	bit [31:0] nvram_size;       // FileReadStart's answer: always 0x8000 (the firmware truncates the file to it)
	task automatic read_nvram(input int bytes);
		bit [31:0] r, w;
		bit e;
		host_cmd(16'h0302, 3, 0, 0, r, e);
		if (e) fail("FileReadStart(3) error");
		// the whole NVRAM every time: v1.1.0-beta4 firmware truncates the
		// save file and writes what this says (a 0 would empty it)
		if (r != 32'h8000) fail($sformatf("FileReadStart(3) size %08h, expected 00008000", r));
		nvram_size = r;
		begin
		realtime t0, done_at;
		int under;
		t0 = $realtime;
		done_at = t0;
		under = 0;
		nvram_saves++;
		for (int o = 0; o < bytes; o += 4) begin
			realtime req, need, start, dt, slack;
			int j;
			j = o / 4;
			req  = t0 + j * SAVE_WORD;
			need = t0 + (j + SAVE_LEAD) * SAVE_WORD;
			// the core takes request j when it is queued and the one before is answered
			start = req > done_at ? req : done_at;
			if ($realtime < start) #(start - $realtime);
			start = $realtime;
			host_rd(32'h3000_0000 + o, w);
			dt = $realtime - start;
			done_at = $realtime;
			slack = need - done_at;
			if (slack < nvram_worst_slack) nvram_worst_slack = slack;
			nvram_save_words++;
			if (done_at > need) begin
				under++;
				nvram_underflows++;
				if (nvram_underflows <= 5)
					$display("[%0t] NVRAM save %0d: byte %04h answered %0.0f ns after the SPI sent it (the read took %0.0f ns)",
					         $realtime, nvram_saves, o, (done_at - need) / 1ns, dt / 1ns);
			end
			if (host_be) {nvram[o], nvram[o+1], nvram[o+2], nvram[o+3]} = w;
			else         {nvram[o+3], nvram[o+2], nvram[o+1], nvram[o]} = w;
		end
		end
		host_cmd(16'h0303, 3, 0, 0, r, e);
	endtask

	// The test ROM's verdict, read without a save (the firmware never polls the
	// NVRAM; a save pauses the 3DO)
	task automatic peek_nvram(input int from, input int bytes);
		bit [31:0] w;
		for (int o = from; o < from + bytes; o += 4) begin
			host_rd(32'h3000_0000 + o, w);
			if (host_be) {nvram[o], nvram[o+1], nvram[o+2], nvram[o+3]} = w;
			else         {nvram[o+3], nvram[o+2], nvram[o+1], nvram[o]} = w;
		end
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

		if (!$value$plusargs("rom=%s", romfile)) romfile = "build/sim/testrom.bin";
		if (!$value$plusargs("frames=%d", n_frames)) n_frames = 2;
		host_be = $test$plusargs("be");
		stream_mode = $test$plusargs("stream");
		preload_mode = $test$plusargs("preload");
		if (stream_mode && preload_mode) $fatal(1, "tb_top: +stream and +preload exclude each other");
		if (host_be && !preload_mode) $fatal(1, "tb_top: +be needs +preload (the firmware's FileRead writes little-endian words)");
		void'($value$plusargs("disc_latency_us=%d", disc_latency_us));
		void'($value$plusargs("disc_spike_us=%d", disc_spike_us));

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
		// +disc_id=<hex>: the volume unique identifier (user bytes 0x48-0x4B,
		// MiSTer's per-game table key); 0A9B739E is Killing Time's
		if ($value$plusargs("disc_id=%h", disc_id_arg)) begin
			{iso[72], iso[73], iso[74], iso[75]} = disc_id_arg;
			disc_id_set = 1;
		end

		repeat (20) @(posedge clk_sys);
		reset <= 0;

		// GetStatus until the core is ready for setup
		do begin
			host_cmd(16'h0000, 0, 0, 0, r, e);
		end while (r != 2);
		$display("[%0t] core status: setup", $realtime);

		// files in files.json order
		// (the disc file is on demand: not sent, unless +preload)
		if (preload_mode) send_file(0, 32'h1000_0000, iso, iso_len);
		send_file(1, 32'h2000_0000, rom, rom_len);

		host_cmd(16'h0102, 0, 0, 0, r, e);   // SetupComplete
		do begin
			host_cmd(16'h0000, 0, 0, 0, r, e);
		end while (r != 3);
		$display("[%0t] core status: halted (setup complete)", $realtime);

		// The blank NVRAM must have been formatted (save file not supplied),
		// and every save gives all of it, also unchanged (read_nvram).
		read_nvram(16);
		read_nvram(16);
		if ({nvram[0], nvram[1], nvram[2], nvram[3]} != 32'h015A5A5A || nvram[6] != 8'h02)
			fail($sformatf("NVRAM not formatted: %02h %02h %02h %02h .. %02h", nvram[0], nvram[1], nvram[2], nvram[3], nvram[6]));

		host_wr(32'h0000_1020, 32'h2);       // setting: CD speed "Fast (0.5 ms)"
		check_buttons(0);                    // "Buttons": the default, then the other layout and back
		host_wr(32'h0000_100C, 32'h1);
		check_buttons(1);
		host_wr(32'h0000_100C, 32'h0);
		check_buttons(0);
		$display("[%0t] Buttons setting: %0d pad words checked", $realtime, pad_checks);
		host_wr(32'h0000_1010, 32'(sram_mode));   // "VRAM memory", taken while the 3DO is in reset
		// light gun before the pad (test ROM test 19): aim x 0x4000, y 0x8000,
		// trigger held
		host_wr(32'h0000_1014, 32'h1);
		host_wr(32'h0000_1018, 32'h8000_4000);
		host_wr(32'h0000_101C, 32'h1);
		begin
			bit [31:0] q0, q1, q2;
			host_rd(32'h0000_1014, q0); host_rd(32'h0000_1018, q1); host_rd(32'h0000_101C, q2);
			if (q0 != 32'h1 || q1 != 32'h8000_4000 || q2 != 32'h1)
				fail($sformatf("light gun registers read %08h %08h %08h", q0, q1, q2));
		end
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
		// (up to about 900 ms: test 14 reads CD-DA sectors in real time; test
		// 15 copies with the video DMA on, one transfer per shown line with the
		// SRAM safe timing; tests 15-17 wait for frame starts)
		for (int t = 0; t < 9000 && !done; t++) begin
			#100us;
			peek_nvram(16'h100, 16'h18);
			if ({nvram[256], nvram[257], nvram[258], nvram[259]} == "PASS" ||
			    {nvram[256], nvram[257], nvram[258], nvram[259]} == "FAIL") done = 1;
		end
		if (!done) fail("test ROM did not report a result");
		// the save that follows: the 3DO's writes reported as a change, and
		// the whole NVRAM read with the 3DO running, as on pause
		begin
			int late0, late_blank0;
			late0 = vl_late; late_blank0 = vl_late_blank;
			read_nvram(32768);
			$display("[%0t] NVRAM saves: %0d (%0d words), %0d words late for the SPI, least slack %0.0f ns; video lines late during the running save %0d shown, %0d blanking",
			         $realtime, nvram_saves, nvram_save_words, nvram_underflows, nvram_worst_slack / 1ns,
			         vl_late - late0, vl_late_blank - late_blank0);
			if (nvram_underflows != 0) fail($sformatf("%0d NVRAM save words late for the SPI", nvram_underflows));
			// lines late while the 3DO is held for the save are its pause, not a fault
			vl_late = late0; vl_late_blank = late_blank0;
			#20us;
			if (dut.save_hold) fail("the 3DO is still held paused 20 us after the save ended");
		end
		begin
			bit [31:0] test, addr, checks;
			test   = {nvram[260], nvram[261], nvram[262], nvram[263]};
			addr   = {nvram[264], nvram[265], nvram[266], nvram[267]};
			checks = {nvram[268], nvram[269], nvram[270], nvram[271]};
			$display("[%0t] test ROM: %s test=%0d addr=%08h checks=%0d", $realtime,
			         {nvram[256], nvram[257], nvram[258], nvram[259]}, test, addr, checks);
			if ({nvram[256], nvram[257], nvram[258], nvram[259]} != "PASS") begin
				// a test may leave the value it found and the one it expected (test 21)
				$display("[%0t] test ROM: found %08h, expected %08h", $realtime,
				         {nvram[272], nvram[273], nvram[274], nvram[275]}, {nvram[276], nvram[277], nvram[278], nvram[279]});
				fail("test ROM reported FAIL");
			end
			// tests 1-8, test 9 (SPORT write masks): 3 regions x (13 checks of a
			// row), test 10 (CLIO timers and interrupt summary): 10, test 11
			// (matrix engine): 3
			// test 7's final status: 1; test 14: 25 checks with the streamed
			// disc (audio track), 1 with a preloaded ISO (disc info only)
			// test 15 (page copies with the video DMA on): 64 + 32 rows; test 16
			// (relative VDL next pointer): 1; test 17 (cel culling): 5; test 18
			// (cels drawn into a shown frame buffer): 1; test 19 (light gun): 3;
			// test 20 (mouse): 3; test 22 (mouse before the pad): 3; test 23
			// (two mice before the pad): 4; test 24 (the dock's gamepads): 3;
			// test 21 (in-place video decode): 3 pictures x 5
			if (checks != 64*4 + 1 + 64*5 + 2 + 16 + 1 + 2 + 4 + 1 + (stream_mode ? 25 : 1) + 3 * 13 * 512 + 10 + 3 + 64 + 16 + 96 + 1 + 5 + 1 + 3 + 3 + 3 + 4 + 3 + 15)
				fail($sformatf("unexpected number of checks %0d", checks));
			for (int i = 0; i < 16; i++)
				if (nvram[8'h80 + i] != 8'(8'hA5 + 8'h13 * i)) fail($sformatf("NVRAM byte %02h = %02h", 8'h80 + i, nvram[8'h80 + i]));
		end

		// statistics (the Game Bub firmware reads and clears 0x1000 stalls and
		// 0x1004 run cycles when the game pauses): both counted while the 3DO
		// runs, cleared by a write; the settings moved off them (CD speed at
		// 0x1020) read back
		begin
			bit [31:0] st, cy, st2, cy2, sp;
			host_rd(32'h0000_1000, st); host_rd(32'h0000_1004, cy);
			$display("[%0t] statistics: %0d clocks paused, %0d run (%0.1f%% run)", $realtime, st, cy,
			         100.0 * real'(cy) / (real'(cy) + real'(st) + 1.0));
			if (cy == 0 || st == 0) fail($sformatf("statistics counters %0d / %0d", st, cy));
			host_wr(32'h0000_1000, 32'h0); host_wr(32'h0000_1004, 32'h0);
			host_rd(32'h0000_1000, st2); host_rd(32'h0000_1004, cy2);
			if (st2 >= st || cy2 >= cy || cy2 > 32'd1000)
				fail($sformatf("statistics not cleared: %0d / %0d after %0d / %0d", st2, cy2, st, cy));
			host_rd(32'h0000_1020, sp);
			if (sp != 32'h2) fail($sformatf("CD speed setting (0x1020) reads %0d, written 2", sp));
		end


		// video timing towards the framework
		while (frames < n_frames + 1) @(posedge clk_sys);
		$display("[%0t] video: %0d frames, bad lines %0d, bad frames %0d; at the %0d software reset(s): %0d lines, %0d frames",
		         $realtime, frames, bad_lines, bad_frames, soft_resets, srst_lines, srst_frames);
		if (bad_lines || bad_frames) fail("video timing");
		// test ROM test 15: lines shown during the page copies
		$display("tb_top: video DMA lines %0d, %0d of them late (started before a read transfer; shown lines), %0d late in the vertical blanking (not shown); CPU write transfers while it was on %0d",
		         vl_lines, vl_late, vl_late_blank, vl_copies);
		$display("tb_top: longest CPU SPORT transfer: left %0.2f us, right %0.2f us", cx_max[0] / 1us, cx_max[1] / 1us);
		if (vl_lines < 400) fail($sformatf("only %0d video DMA lines: test 15's VDL did not start the video DMA", vl_lines));
		// 2 x 600 copies, each from line 40 of a frame: 385 to 430 of them while
		// lines are shown, about 100 with the SRAM's safe timing (one transfer
		// per line: they wait for the line's transfers)
		if (vl_copies < 80) fail($sformatf("%0d CPU write transfers with the video DMA on, expected at least 80", vl_copies));
		if (vl_late) fail("video lines started before their read transfers (tests 15, 18)");
		// one from CLIO's power-on state (CSTAT = 0x11), one by the test ROM
		if (soft_resets != 2) fail($sformatf("%0d CLIO software resets, expected 2 (power-on and the test ROM's)", soft_resets));

		if (!preload_mode) begin
			// the disc came on demand: the fork's table of contents (raw image)
			// or, from stock firmware, the ISO's size and first sector
			$display("tb_top: on-demand disc (%s firmware): %0d requests, %0d sectors served, %s", stream_mode ? "fork" : "stock",
			         disc_reqs, sectors_served, dut.cdd.od_iso ? "ISO" : "raw image");
			if (!dut.cdd.od_present) fail("on-demand disc: the core did not set it up");
			if (dut.cdd.od_iso != !stream_mode) fail($sformatf("on-demand disc read as %s", dut.cdd.od_iso ? "an ISO" : "a raw image"));
			if (dut.cdd.toc_tracks != (stream_mode ? 2 : 1)) fail($sformatf("on-demand disc: %0d tracks", dut.cdd.toc_tracks));
			if (sectors_served < 2) fail("on-demand disc: the core did not request the sectors");
		end else if (disc_reqs != 0) fail("preloaded ISO: the core sent requests");
		if (stream_mode) begin
			$display("tb_top: %0d disc sectors served by the firmware model", sectors_served);
			if (sectors_served < 3) fail("streaming mode: the core did not request the sectors");
			if (disc_spikes != 2) fail($sformatf("streaming mode: %0d requests for the 4th audio sector answered late, expected 2", disc_spikes));
			$display("tb_top: %0d CD-DA sectors, %0d gaps checked at 1x, %0d at 2x", audio_secs, audio_gaps_1x, audio_gaps_2x);
			if (audio_secs != 5 || audio_gaps_1x != 2 || audio_gaps_2x != 1)
				fail("CD-DA: expected 5 audio sectors, 2 gaps at 1x (the second across a READ that continues the stream), 1 at 2x");
		end
		// the disc-info block and the id the per-game table (p3do_gamebub) is keyed on
		if (info_blocks == 0) fail("no disc-info block was sent");
		if (disc_id_set && dut.disc_id != disc_id_arg)
			fail($sformatf("disc id %08h, expected the +disc_id %08h", dut.disc_id, disc_id_arg));
		$display("tb_top: disc id %08h", dut.disc_id);
		// test ROM test 4 writes VRAM 0x2A0400 (block A: in the SRAM unless it is off)
		if (sram_mode != 2 && sram.writes == 0) fail("no VRAM write reached the SRAM");
		if (sram_mode == 2 && sram.writes != 0) fail("VRAM writes reached the SRAM with it off");
		$display("tb_top: TB errors=%0d, SDRAM model errors=%0d, SRAM model errors=%0d (%0d SRAM writes)",
		         errors, sdram.errors, sram.errors, sram.writes);
		// a failure ends with a non-zero exit status ($fatal), so scripts see it
		if (errors == 0 && sdram.errors == 0 && sram.errors == 0) begin $display("tb_top: PASS"); $finish; end
		else $fatal(1, "tb_top: FAIL");
	end

	// Video lines with the video DMA on (test ROM test 15): from the point a
	// +vdl_trace: MADAM's VDL DMA register writes (group 0x60: 0x580 VDL
	// address, 0x584 next VDL, 0x590/0x594 previous/current line address)
	bit vdl_trace = 0;
	initial vdl_trace = $test$plusargs("vdl_trace");
	always @(posedge clk_mem)
		if (vdl_trace && dut.p3do.madam.AG.EN && dut.p3do.madam.AG.CE_R && dut.p3do.madam.AG.DMA_STACK_WE &&
		    dut.p3do.madam.AG.DMA_STACK_WADDR[6:3] == 4'hC)
			$display("[%0t] VDL reg %02h <= %06h (%s, line %0d)", $realtime, dut.p3do.madam.AG.DMA_STACK_WADDR,
			         {dut.p3do.madam.AG.DMA_STACK_IN, 2'b00}, dut.p3do.madam.AG.BUS_STATE_FF.name(), dut.p3do.madam.SPORT.VCOUNT);

	// Test ROM test 20: after the first control port transfer (test 19, the
	// light gun) the Controller setting goes to the mouse (2) with the left
	// button held; when the ROM enables its next transfer (MCTL bit 15 set
	// again, at a line in the first half of a field) one motion packet
	// (dx +5, dy -3) is written: the port is latched every field, which
	// takes the motion, so it must come in the field before the DMA reads.
	// After test 20's transfer, the same for test 22 with the Controller
	// setting 3 (the mouse before the pad); after test 22's, for test 23
	// with the setting 4 (two mice before the pad), the second mouse's right
	// button, and a packet for each mouse.
	bit pb_mctl_q = 0, pb_mouse_set = 0, pb_motion_set = 0, pb_first_set = 0, pb_first_motion_set = 0;
	bit pb_two_set = 0, pb_two_motion_set = 0, pb_pads_set = 0;
	// After test 23's transfer: the Controller setting back to 0 and three
	// dock gamepads connected (test 24): the first with B, the second with
	// Start, the third with its left stick held left.
	always @(posedge clk_sys) begin
		if (!dut.p3do.madam.MCTL[15] && pb_mctl_q && !pb_mouse_set) begin
			pb_mouse_set <= 1;
			fork
				begin
					host_wr(32'h0000_1014, 32'h2);
					host_wr(32'h0000_1034, 32'h1);
					$display("[%0t] mouse: Controller 2, left button written", $realtime);
				end
			join_none
		end
		if (dut.p3do.madam.MCTL[15] && !pb_mctl_q && pb_mouse_set && !pb_motion_set) begin
			pb_motion_set <= 1;
			fork
				begin
					host_wr(32'h0000_1030, {16'hFFFD, 16'h0005});
					$display("[%0t] mouse: motion dx +5 dy -3 written (line %0d)", $realtime, dut.p3do.madam.SPORT.VCOUNT);
				end
			join_none
		end
		if (!dut.p3do.madam.MCTL[15] && pb_mctl_q && pb_motion_set && !pb_first_set) begin
			pb_first_set <= 1;
			fork
				begin
					host_wr(32'h0000_1014, 32'h3);
					$display("[%0t] mouse: Controller 3 (mouse before the pad)", $realtime);
				end
			join_none
		end
		if (!dut.p3do.madam.MCTL[15] && pb_mctl_q && pb_first_motion_set && !pb_two_set) begin
			pb_two_set <= 1;
			fork
				begin
					host_wr(32'h0000_1014, 32'h4);
					host_wr(32'h0000_103C, 32'h1_0002);
					$display("[%0t] mouse: Controller 4 (two mice before the pad), mouse 2 connected, right button", $realtime);
				end
			join_none
		end
		if (!dut.p3do.madam.MCTL[15] && pb_mctl_q && pb_two_motion_set && !pb_pads_set) begin
			pb_pads_set <= 1;
			fork
				begin
					host_wr(32'h0000_1014, 32'h0);
					gp_bt[0] = 16'h0400;   // B
					gp_bt[1] = 16'h0002;   // Start
					gp_lx[2] = -8'sd100;   // left stick left
					gp_on = 4'b0111;
					$display("[%0t] gamepads: Controller 0, three dock gamepads (B, Start, stick left)", $realtime);
				end
			join_none
		end
		if (dut.p3do.madam.MCTL[15] && !pb_mctl_q && pb_two_set && !pb_two_motion_set) begin
			pb_two_motion_set <= 1;
			fork
				begin
					host_wr(32'h0000_1030, {16'hFFFD, 16'h0005});
					host_wr(32'h0000_1038, {16'h0002, 16'hFFF9});
					$display("[%0t] mice: mouse 1 dx +5 dy -3, mouse 2 dx -7 dy +2 written (line %0d)", $realtime, dut.p3do.madam.SPORT.VCOUNT);
				end
			join_none
		end
		if (dut.p3do.madam.MCTL[15] && !pb_mctl_q && pb_first_set && !pb_first_motion_set) begin
			pb_first_motion_set <= 1;
			fork
				begin
					host_wr(32'h0000_1030, {16'hFFFD, 16'h0005});
					$display("[%0t] mouse: motion dx +5 dy -3 written (line %0d)", $realtime, dut.p3do.madam.SPORT.VCOUNT);
				end
			join_none
		end
		pb_mctl_q <= dut.p3do.madam.MCTL[15];
	end

	// +pbus_trace: the control port DMA (ControlPort registers 0x570-0x57C,
	// MADAM register stack 0x5C-0x5F; the player's bus states; MCTL bit 15)
	bit pbus_trace = 0;
	initial pbus_trace = $test$plusargs("pbus_trace");
	bit pb_mctl_d = 0;
	always @(posedge clk_mem) if (pbus_trace) begin
		if (dut.p3do.madam.AG.EN && dut.p3do.madam.AG.CE_R && dut.p3do.madam.AG.DMA_STACK_WE &&
		    dut.p3do.madam.AG.DMA_STACK_WADDR[6:2] == 5'h17)
			$display("[%0t] PBUS reg %02h <= %06h (%s)", $realtime, dut.p3do.madam.AG.DMA_STACK_WADDR,
			         {dut.p3do.madam.AG.DMA_STACK_IN, 2'b00}, dut.p3do.madam.AG.BUS_STATE_FF.name());
		if (dut.p3do.madam.PLAYER.DATA_WR && dut.p3do.madam.AG.EN && dut.p3do.madam.AG.CE_R)
			$display("[%0t] PBUS DMA write %08h at %06h", $realtime, dut.p3do.madam.PLAYER.MDTO, {dut.p3do.madam.AG.ADDR_FF_1, 2'b00});
		if (dut.p3do.madam.MCTL[15] != pb_mctl_d)
			$display("[%0t] PBUS MCTL[15] = %b (line %0d)", $realtime, dut.p3do.madam.MCTL[15], dut.p3do.madam.SPORT.VCOUNT);
		pb_mctl_d <= dut.p3do.madam.MCTL[15];
	end

	// line's transfers are scheduled (MADAM_SPORT VIDEO_TRANS_PEND) to its
	// scanout (VIDEO_TRANS_EXEC) both VRAM halves must have had a read
	// transfer that is not the CPU's (as tb_boot). A late line shows the
	// serial registers' old contents.
	int vl_lines = 0, vl_late = 0, vl_copies = 0, vl_late_blank = 0;
	// Lines the video encoder shows (VE.sv: 240 from line 22, PAL 45; it
	// starts CLIO's line count, so MADAM's is within a line of it): one more
	// at each end, so a late line that might be shown counts as shown.
	function automatic bit vl_shown(input [9:0] vc);
		int s;
		s = dut.p3do.ve.PAL_SYNC[1] ? 45 : 22;
		return int'(vc) >= s - 1 && int'(vc) <= s + 240;
	endfunction
	realtime vl_t0;
	real vl_t_ack;
	int vl_np;
	bit vl_hold0;
	string vl_st0, vl_st_max, vl_st_last, vl_why;
	string cx_last = "none";   // the last CPU SPORT transfer's start (see cx_max below)
	bit cx_log = 0;            // +cx_log: every CPU SPORT transfer's start
	initial cx_log = $test$plusargs("cx_log");

	// +fill_log=<from_ms>: from that time, on lines 243-247 of each field, the
	// read-transfer cache's fills (issue and end, kind), the VDL frame buffer
	// hints, the video transfer requests, ddram.sv's random VRAM accesses as
	// they are latched and served, and the 3DO's pause edges, with the line
	// and dot (the late lines of test 21: a hint fill while the CPU writes VRAM)
	int fl_ms = -1;
	initial void'($value$plusargs("fill_log=%d", fl_ms));
	function automatic bit fl_on();
		return fl_ms >= 0 && $realtime >= fl_ms * 1ms && dut.p3do.madam.SPORT.VCOUNT >= 10'd243 && dut.p3do.madam.SPORT.VCOUNT <= 10'd247;
	endfunction
	function automatic string fl_pos();
		return $sformatf("line %0d dot %0d", dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT);
	endfunction
	bit fl_fill_d = 0, fl_pause_d = 0, fl_wl_d = 0, fl_wr_d = 0, fl_rl_d = 0, fl_rr_d = 0, fl_hint_d = 0;
	always @(posedge clk_mem) begin
		if (fl_on()) begin
			if (dut.rtcache.fill_issue)
				$display("[%0t] fill_log: fill of half-row %03h issued (%s) into entry %0d, %s", $realtime, dut.rtcache.fill_h,
				         !dut.rtcache.fill_yield ? "demand" : dut.rtcache.fill_plain ? "prefetch" : "hint", dut.rtcache.fill_e, fl_pos());
			if (fl_fill_d && !dut.rtcache.fill_busy)
				$display("[%0t] fill_log: fill ended, %s", $realtime, fl_pos());
			if (dut.rtcache.hint && !fl_hint_d)
				$display("[%0t] fill_log: VDL hint curr %05h (v %b) prev %05h (v %b), %s", $realtime, dut.rtcache.hint_curr, dut.rtcache.hint_curr_v,
				         dut.rtcache.hint_prev, dut.rtcache.hint_prev_v, fl_pos());
			if (dut.rtcache.l_esrd) $display("[%0t] fill_log: L read transfer request %05h%s, %s", $realtime, dut.rtcache.l_esaddr, dut.rtcache.l_esnp ? " (not display)" : "", fl_pos());
			if (dut.rtcache.r_esrd) $display("[%0t] fill_log: R read transfer request %05h%s, %s", $realtime, dut.rtcache.r_esaddr, dut.rtcache.r_esnp ? " (not display)" : "", fl_pos());
			if (dut.ddram.write_lpend && !fl_wl_d) $display("[%0t] fill_log: L random write latched %05h (ddram state %0d), %s", $realtime, dut.ddram.write_laddr, dut.ddram.state, fl_pos());
			if (!dut.ddram.write_lpend && fl_wl_d) $display("[%0t] fill_log: L random write issued, %s", $realtime, fl_pos());
			if (dut.ddram.read_lbusy && !fl_rl_d) $display("[%0t] fill_log: L random read miss %05h (ddram state %0d), %s", $realtime, dut.ddram.read_laddr, dut.ddram.state, fl_pos());
			if (!dut.ddram.read_lbusy && fl_rl_d) $display("[%0t] fill_log: L random read served, %s", $realtime, fl_pos());
			if (dut.pause != fl_pause_d) $display("[%0t] fill_log: 3DO %s, %s", $realtime, dut.pause ? "paused" : "running", fl_pos());
		end
		fl_fill_d = dut.rtcache.fill_busy; fl_pause_d = dut.pause; fl_hint_d = dut.rtcache.hint;
		fl_wl_d = dut.ddram.write_lpend; fl_wr_d = dut.ddram.write_rpend; fl_rl_d = dut.ddram.read_lbusy; fl_rr_d = dut.ddram.read_rbusy;
	end
	bit vl_armed = 0, vl_l = 0, vl_r = 0, vl_pend_d = 0, vl_exec_d = 0, vl_rtl_d = 0, vl_rtr_d = 0, vl_mwt_d = 0;
	always @(posedge clk_mem) begin
		if (dut.reset_3do) vl_armed = 0;
		else begin
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_PEND && !vl_pend_d) begin
				vl_armed = 1; vl_l = 0; vl_r = 0;
				vl_t0 = $realtime; vl_t_ack = -1.0; vl_np = 0; vl_hold0 = dut.p3do.madam.SE_HOLD;
				vl_st0 = dut.p3do.madam.ARB.BUS_ST.name(); vl_st_max = "";
				vl_why = $sformatf("ddr_busy %b io %b LRDY %b RRDY %b sec_hold %b | ddram state %0d rd L/R %b%b wr L/R %b%b burst rd %b%b wr %b%b | bridge %s | sdram sec %s | fill %b h %03h e %0d yield %b/%b chunk %b part %b | delivery L %b e %0d R %b e %0d | VRAM L row %03h R row %03h",
				                   dut.ddr_busy, dut.ddr_io_busy, dut.VRAM_LRDY, dut.VRAM_RRDY, dut.sec_hold_s,
				                   dut.ddram.state, dut.ddram.read_lbusy, dut.ddram.read_rbusy, dut.ddram.write_lpend, dut.ddram.write_rpend,
				                   dut.ddram.burst_read_lbusy, dut.ddram.burst_read_rbusy, dut.ddram.burst_write_lbusy, dut.ddram.burst_write_rbusy,
				                   dut.ddr_bridge.st.name(), dut.sdram.sst.name(), dut.rtcache.fill_busy, dut.rtcache.fill_h, dut.rtcache.fill_e,
				                   dut.rtcache.fill_yield, dut.rtcache.d_byield, dut.ddram.brd_chunk, dut.ddram.brd_part,
				                   dut.rtcache.dl_act[0], dut.rtcache.dl_e[0], dut.rtcache.dl_act[1], dut.rtcache.dl_e[1],
				                   dut.vram_l.MEM_ROW, dut.vram_r.MEM_ROW);
			end
			if (vl_armed) begin
				if (dut.pause) vl_np++;
				if (dut.p3do.madam.ARB.VIDOUT_ACK && vl_t_ack < 0) vl_t_ack = ($realtime - vl_t0) / 1000.0;
				if (vl_t_ack < 0 && dut.p3do.madam.ARB.BUS_ST.name() != vl_st_last) vl_st_max = {vl_st_max, " ", dut.p3do.madam.ARB.BUS_ST.name()};
				vl_st_last = dut.p3do.madam.ARB.BUS_ST.name();
			end
			if (dut.vram_l.RT_REQ && !vl_rtl_d && !dut.vram_l.XFER_CPU) vl_l = 1;
			if (dut.vram_r.RT_REQ && !vl_rtr_d && !dut.vram_r.XFER_CPU) vl_r = 1;
			if (dut.vram_l.MWT_EXEC && !vl_mwt_d && dut.vram_l.XFER_CPU && dut.p3do.madam.SPORT.ENVIDDMA) vl_copies++;
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !vl_exec_d && vl_armed) begin
				vl_armed = 0;
				vl_lines++;
				if ((!vl_l || !vl_r) && !vl_shown(dut.p3do.madam.SPORT.VCOUNT)) begin
					vl_late_blank++;
					if (vl_late_blank <= 5)
						$display("[%0t] tb_top: video line %0d (vertical blanking, not shown) started before its read transfer", $realtime, dut.p3do.madam.SPORT.VCOUNT);
				end else if (!vl_l || !vl_r) begin
					vl_late++;
					if (vl_late <= 10)
						$display("[%0t] TB ERROR: video line %0d started before its read transfer (left %b right %b); grant %0.2f us after scheduling, 3DO paused %0.2f us, SE_HOLD at scheduling %b, bus at scheduling %s, then:%s",
						         $realtime, dut.p3do.madam.SPORT.VCOUNT, vl_l, vl_r, vl_t_ack, vl_np * 0.01, vl_hold0, vl_st0,
						         vl_st_max.len() > 300 ? vl_st_max.substr(0, 299) : vl_st_max);
						$display("            at scheduling: %s", vl_why);
						$display("            last CPU SPORT transfer: %s", cx_last);
				end
			end
		end
		vl_pend_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_PEND;
		vl_exec_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;
		vl_rtl_d  <= dut.vram_l.RT_REQ;
		vl_rtr_d  <= dut.vram_r.RT_REQ;
		vl_mwt_d  <= dut.vram_l.MWT_EXEC;
	end

	// the longest CPU SPORT transfer (page copy read or write transfer, flash
	// write) per VRAM half: the time its half was busy
	realtime cx_t [2], cx_max [2] = '{0, 0};
	bit cx_busy [2] = '{0, 0};
	always @(posedge clk_mem) begin
		bit b [2];
		b[0] = (dut.vram_l.RT_EXEC || dut.vram_l.MWT_EXEC || dut.vram_l.FW_EXEC || dut.vram_l.MRD_EXEC) && dut.vram_l.XFER_CPU;
		b[1] = (dut.vram_r.RT_EXEC || dut.vram_r.MWT_EXEC || dut.vram_r.FW_EXEC || dut.vram_r.MRD_EXEC) && dut.vram_r.XFER_CPU;
		for (int i = 0; i < 2; i++) begin
			if (b[i] && !cx_busy[i]) begin
				cx_t[i] = $realtime;
				cx_last = $sformatf("%s %s at line %0d dot %0d (SPORT_HOLD %b, start %0d)", i ? "R" : "L",
				                    (i ? dut.vram_r.MWT_EXEC : dut.vram_l.MWT_EXEC) ? "write" : "read",
				                    dut.p3do.madam.SPORT.VCOUNT, dut.p3do.madam.SPORT.HCOUNT,
				                    dut.p3do.madam.SPORT.SPORT_HOLD, dut.p3do.madam.SPORT.SPORT_HOLD_START);
				if (cx_log) $display("[%0t] CPU SPORT transfer: %s", $realtime, cx_last);
			end
			if (!b[i] && cx_busy[i] && $realtime - cx_t[i] > cx_max[i]) cx_max[i] = $realtime - cx_t[i];
			cx_busy[i] = b[i];
		end
	end

	initial begin
		#1500ms;   // the test ROM takes ~870 ms (~1 s in the SRAM safe timing mode)
		$display("tb_top: TIMEOUT: cpu A=%08h, MADAM stretch %b, SPORT hold %b, line %0d, video DMA lines %0d, CPU write transfers %0d",
		         dut.p3do.CPU_A, dut.p3do.madam.CPUIF.STRETCH, dut.p3do.madam.SPORT.SPORT_HOLD, dut.p3do.madam.SPORT.VCOUNT,
		         vl_lines, vl_copies);
		$fatal(1, "tb_top: FAIL");
	end
endmodule
