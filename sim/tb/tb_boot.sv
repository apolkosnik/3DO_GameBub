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
//   * framework video frames as PPM files (build/sim/frames/frame_NNNN.ppm)
//   * every CD controller command the BIOS sends and every sector delivered
//   * CPU address samples, pause statistics, SDRAM model errors
//
// Plusargs: +bios=<file> (required), +iso=<file>, +run_ms=<n> (default 1000),
//           +frame_every=<n> (default 10)
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_boot;
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
		.host_commandCore_request(), .host_commandCore_busy(1'b0),
		.host_commandCore_done(1'b0), .host_commandCore_error(1'b0),
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
	task automatic host_access(input bit wr, input [31:0] a, input [31:0] d, output [31:0] q);
		int to;
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
				$display("[%0t] CD sector %0d (lba %0d)", $realtime, sectors_sent, dut.cdd.fetch_lba_sys);
		end
		if (!dut.cdd_dien && cdd_dien_d)
			$display("[%0t] CD disc-info block sent (id %08h, lead-out %06h)", $realtime, dut.cdd.disc_id, dut.cdd.leadout_msf);
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
		$display("[%0t] cpu A=%08h  pause %0d%%  frames %0d  CD sectors %0d  SDRAM errors %0d", $realtime,
		         dut.p3do.CPU_A, cycles ? int'(pause_cycles * 100 / cycles) : 0, frames, sectors_sent, sdram.errors);
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
		fd = $fopen($sformatf("build/sim/frames/frame_%04d.ppm", n), "wb");
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
		if ($value$plusargs("iso=%s", iso)) begin
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
		host_cmd(16'h0300, 1, 0, 0, r, e);
		host_cmd(16'h0301, 1, bios_len, 0, r, e);
		host_cmd(16'h0102, 0, 0, 0, r, e);
		do host_cmd(16'h0000, 0, 0, 0, r, e); while (r != 3);
		host_cmd(16'h0200, 1, 0, 0, r, e);
		host_cmd(16'h0100, 0, 0, 0, r, e);
		$display("[%0t] core running", $realtime);

		#(run_ms * 1ms);
		dump_vram_fb(32'h000000, 1638, "build/sim/frames/vram_all.ppm");
		$display("tb_boot: %0d frames, %0d CD sectors, SDRAM model errors %0d, TB errors %0d",
		         frames, sectors_sent, sdram.errors, errors);
		$display("tb_boot: RT cache hits %0d, misses %0d, prefetches %0d, invalidations %0d",
		         dut.rtc_hits, dut.rtc_misses, dut.rtc_prefetches, dut.rtc_invalidations);
		$finish;
	end
endmodule
