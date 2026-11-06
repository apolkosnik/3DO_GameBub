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
//   * streamed discs: every sector sent to the CD controller is checked
//     against the image at the LBA the BIOS asked for
//   * every video line must have had its VRAM read transfers (both halves)
//     before it starts shifting out (counted as TB errors)
//   * random VRAM writes to the SDRAM tier (CPU, CEL engine): none may be
//     lost in ddram.sv's posted write port or completed with another
//     address's flash-write state (counted as TB errors)
//   * <out>/cpu_trace.txt: the last 32768 CPU bus cycles (or, with
//     +trace_from_ms=<n>, all from n ms on) before the CPU first runs outside
//     the 3DO memory map (a crash), with CLIO's interrupt state at each FIQ
//
// Plusargs: +bios=<file> (required), +iso=<file> or +disc_bin=<file>,
//           +disc_latency_us=<n> (default 800), +trace_from_ms=<n>, +run_ms=<n> (default 1000),
//           +frame_every=<n> (default 10), +out=<dir> (default build/sim)
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

	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;

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
		.input_buttons_a(1'b0), .input_buttons_b(1'b0), .input_buttons_x(1'b0),
		.input_buttons_y(1'b0), .input_buttons_up(1'b0), .input_buttons_down(1'b0),
		.input_buttons_left(1'b0), .input_buttons_right(1'b0), .input_buttons_l(1'b0),
		.input_buttons_r(1'b0), .input_buttons_start(1'b0), .input_buttons_select(1'b0),
		.sdram_clock(s_clk), .sdram_cke(s_cke), .sdram_cs(s_cs), .sdram_ras(s_ras), .sdram_cas(s_cas),
		.sdram_we(s_we), .sdram_dqm(s_dqm), .sdram_bank(s_ba), .sdram_address(s_a),
		.sdram_dataIn(s_dq_in), .sdram_dataOut(s_dq_out), .sdram_dataDir(s_oe)
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
		if (fd == 0) begin $display("cannot open %s", fname); $finish; end
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
	// ---------------- CD data check (streaming) ----------------
	// Every sector the drive back end sends to the CD controller is compared
	// with the image's user data (raw bytes 16..2063) at the LBA the BIOS
	// asked for. The expected LBA is computed here from the READ commands
	// (one sector per READ or NEXT), not taken from the core.
	int       chk_fd = 0;
	int       cd_exp_lba = 150;     // absolute LBA of the next sector to arrive
	int       cd_ref_lba = 0;       // LBA of the sector being received
	int       cd_widx = 0;
	int       cd_sec_errs = 0;
	int       cd_good = 0, cd_bad = 0;
	bit [7:0] cd_ref [2352];
	bit [15:0] cd_ref_sum;
	always @(posedge clk_sys) begin
		if (chk_fd != 0) begin
			if (dut.cdd.cmd_new && dut.cdd.comm[0] == 8'h10) begin
				int l;
				l = (dut.cdd.comm[4] != 0) ? int'({dut.cdd.comm[1], dut.cdd.comm[2], dut.cdd.comm[3]})
				                           : int'(dut.cdd.comm[1]) * 4500 + int'(dut.cdd.comm[2]) * 75 + int'(dut.cdd.comm[3]);
				cd_exp_lba = (l < 150) ? 150 : l;
			end
			if (dut.cdd_dten && !cdd_dten_d) begin
				cd_ref_lba = cd_exp_lba;
				cd_exp_lba++;
				foreach (cd_ref[i]) cd_ref[i] = 8'h00;
				if (cd_ref_lba < 150 + bin_sectors) begin
					int n;
					void'($fseek(chk_fd, longint'(cd_ref_lba - 150) * 2352, 0));
					n = $fread(cd_ref, chk_fd);
				end
				cd_widx = 0;
				cd_sec_errs = 0;
				cd_ref_sum = 16'h0000;
			end
			if (dut.cdd_dten && dut.cdd.CDD_WR) begin
				if (cd_widx < 1024) begin
					bit [15:0] e;
					e = {cd_ref[16 + 2 * cd_widx + 1], cd_ref[16 + 2 * cd_widx]};
					cd_ref_sum = cd_ref_sum + e[15:8] + e[7:0];
					if (dut.cdd.CDD_DATA !== e) begin
						if (cd_sec_errs < 4)
							$display("[%0t] CD DATA MISMATCH abs lba %0d word %0d: got %04h, expected %04h",
							         $realtime, cd_ref_lba, cd_widx, dut.cdd.CDD_DATA, e);
						cd_sec_errs++;
					end
				end else if (cd_widx == 1024) begin
					if (dut.cdd.CDD_DATA !== cd_ref_sum) begin
						$display("[%0t] CD CHECKSUM MISMATCH abs lba %0d: got %04h, expected %04h",
						         $realtime, cd_ref_lba, dut.cdd.CDD_DATA, cd_ref_sum);
						cd_sec_errs++;
					end
				end
				cd_widx++;
			end
			if (!dut.cdd_dten && cdd_dten_d) begin
				if (cd_widx != 1025) begin
					$display("[%0t] CD sector abs lba %0d: %0d words sent, expected 1025", $realtime, cd_ref_lba, cd_widx);
					cd_sec_errs++;
				end
				if (cd_sec_errs) begin cd_bad++; errors++; end
				else cd_good++;
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
	// register word the transfer has not written yet.
	bit sr_filled [512];
	int stale_reads = 0, stale_rts = 0, good_reads = 0, stale_kind_clut = 0, stale_kind_vid = 0;
	bit stale_this_rt, fill_half;
	reg sc_old2 = 0;
	always @(posedge clk_mem) begin
		sc_old2 <= dut.vram_l.SC;
		if (dut.vram_l.RT_EXEC && !rt_exec_d) begin
			foreach (sr_filled[i]) sr_filled[i] = 0;
			stale_this_rt = 0;
			fill_half = dut.vram_l.SREG_POS[8];
		end
		if (dut.vram_l.SR_WE) begin
			sr_filled[dut.vram_l.SR_WA] = 1;
			sr_filled[9'(dut.vram_l.SR_WA + 1)] = 1;
		end
		if (!dut.vram_l.SC && sc_old2 && dut.vram_l.SOM && dut.vram_l.RT_EXEC && !dut.vram_l.ISTE &&
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

	// Random VRAM writes to the SDRAM tier (ddram.sv's posted write port,
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
	final $display("tb_boot: SDRAM-tier VRAM writes %0d (%0d latched while ddram.sv was busy), %0d lost, %0d issued with another address's flash-write lookup (%0d with a different flag)",
	               vw_writes, vw_deferred, vw_lost, vw_fw_wrong, vw_fw_wrong_effect);
	// where CLUT/VDL and video transfers point (64 KiB VRAM blocks)
	int blk_clut [16], blk_vid [16];
	reg clut_d = 0, vid_d = 0;
	bit [3:0] last_rt_blk;
	always @(posedge clk_mem) begin
		if (dut.vram_l.RT_EXEC && !rt_exec_d) last_rt_blk = dut.vram_l.MEM_ROW[8:5];
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
	// e.g. the VDL words of the CLUT transfer (counted as TB errors).
	bit lt_req_d = 0, lt_exec_d = 0, lt_rtl_d = 0, lt_rtr_d = 0, lt_l = 0, lt_r = 0, lt_armed = 0;
	int late_lines = 0, video_lines = 0;
	always @(posedge clk_mem) begin
		if (dut.reset_3do) lt_armed = 0;
		else begin
			if (dut.p3do.madam.SPORT.VIDOUT_REQ && !lt_req_d) begin lt_l = 0; lt_r = 0; lt_armed = 1; end
			if (dut.vram_l.RT_REQ && !lt_rtl_d) lt_l = 1;
			if (dut.vram_r.RT_REQ && !lt_rtr_d) lt_r = 1;
			if (dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC && !lt_exec_d && lt_armed) begin
				video_lines++;
				if (!lt_l || !lt_r) begin
					late_lines++;
					errors++;
					if (late_lines <= 10)
						$display("[%0t] TB ERROR: video line %0d started before its read transfer (left %b right %b)",
						         $realtime, dut.p3do.madam.SPORT.VCOUNT, lt_l, lt_r);
				end
			end
		end
		lt_req_d <= dut.p3do.madam.SPORT.VIDOUT_REQ;
		lt_exec_d <= dut.p3do.madam.SPORT.VIDEO_TRANS_EXEC;
		lt_rtl_d <= dut.vram_l.RT_REQ;
		lt_rtr_d <= dut.vram_r.RT_REQ;
	end
	final $display("tb_boot: video lines %0d, %0d started before their read transfer", video_lines, late_lines);

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
			if (frames % frame_every == 0) save_frame(frames);
			frames++;
			px = 0; ln = 0;
		end
	end
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
		bit [3:0] b1;
		b1 = dut.BRAM1_OFFS;
		if ((w >= {b1, 14'h0} >> 2 << 2 && w < (({b1, 16'h0} + 32'hC000) >> 2)) || w >= (20'hFC000 >> 2))
			return 32'hDEADBEEF;   // on-chip block: not dumped
		return {sdram.peek({2'd2, 22'(w * 2)}), sdram.peek({2'd2, 22'(w * 2 + 1)})};
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
		if (!$value$plusargs("bios=%s", bios)) begin $display("+bios=<file> required"); $finish; end
		if (!$value$plusargs("run_ms=%d", run_ms)) run_ms = 1000;
		if (!$value$plusargs("frame_every=%d", frame_every)) frame_every = 10;

		place_file(bios, 0, 23'h400000, bios_len);
		$display("tb_boot: BIOS %s (%0d bytes) placed", bios, bios_len);
		iso_len = 0;
		void'($value$plusargs("disc_latency_us=%d", disc_latency_us));
		void'($value$plusargs("trace_from_ms=%d", trace_from_ms));
		if ($value$plusargs("disc_bin=%s", iso)) begin
			bin_fd = $fopen(iso, "rb");
			if (bin_fd == 0) begin $display("cannot open %s", iso); $finish; end
			void'($fseek(bin_fd, 0, 2));
			bin_sectors = $ftell(bin_fd) / 2352;
			chk_fd = $fopen(iso, "rb");
			$display("tb_boot: streaming %s (%0d raw sectors), firmware latency %0d us", iso, bin_sectors, disc_latency_us);
		end else if ($value$plusargs("iso=%s", iso)) begin
			place_file(iso, 1, 23'h0, iso_len);
			$display("tb_boot: ISO %s (%0d bytes, %0d sectors) placed", iso, iso_len, iso_len / 2048);
		end

		repeat (20) @(posedge clk_sys);
		reset <= 0;
		do host_cmd(16'h0000, 0, 0, 0, r, e); while (r != 2);
		if (iso_len) begin
			host_cmd(16'h0300, 0, 0, 0, r, e);
			host_cmd(16'h0301, 0, iso_len, 0, r, e);
		end
		if (bin_fd != 0) begin
			bit [31:0] toc [8];
			toc[0] = {16'h0, bcd(1), 8'd1};
			toc[1] = 150 + bin_sectors; toc[2] = msf_bcd(150 + bin_sectors); toc[3] = 0;
			toc[4] = 150; toc[5] = 150 + bin_sectors - 1; toc[6] = 150; toc[7] = msf_bcd(150);
			host_cmd(16'h0300, 0, 0, 0, r, e);
			for (int i = 0; i < 8; i++) host_wr(32'h1000_0000 + 4 * i, toc[i]);
			host_cmd(16'h0301, 0, 32, 0, r, e);
		end
		host_cmd(16'h0300, 1, 0, 0, r, e);
		host_cmd(16'h0301, 1, bios_len, 0, r, e);
		host_cmd(16'h0102, 0, 0, 0, r, e);
		do host_cmd(16'h0000, 0, 0, 0, r, e); while (r != 3);
		host_cmd(16'h0200, 1, 0, 0, r, e);
		host_cmd(16'h0100, 0, 0, 0, r, e);
		$display("[%0t] core running", $realtime);

		#(run_ms * 1ms);
		dump_vram_fb(32'h000000, 1638, {outdir, "/frames/vram_all.ppm"});
		$display("tb_boot: %0d frames, %0d CD sectors (%0d served by the firmware model), SDRAM model errors %0d, TB errors %0d",
		         frames, sectors_sent, served, sdram.errors, errors);
		if (chk_fd != 0)
			$display("tb_boot: CD data check: %0d sectors match the image, %0d differ", cd_good, cd_bad);
		$display("tb_boot: RT cache hits %0d, misses %0d, prefetches %0d, invalidations %0d, VDL frame buffer hints %0d",
		         dut.rtc_hits, dut.rtc_misses, dut.rtc_prefetches, dut.rtc_invalidations, dut.rtc_hints);
		$finish;
	end
endmodule
