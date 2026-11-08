// Testbench: VRAM read-transfer cache (vram_rtcache) coherence and data path.
//
// Real modules: two P3DO_VRAM (left/right halves, external path only),
// vram_rtcache, ddram.sv, ddr_bridge, sdram_3do and the SDRAM model. A
// bus-functional model drives the VRAM pins the way MADAM does for:
//   * read transfers (RT, full and split) followed by serial read-out (SC/SQ)
//   * random CPU writes (ddram.sv's posted write port)
//   * write transfers (MWT, shift register -> row: SPORT row copy); the
//     CPU's copies (SP_CPU, MADAM's SPORT space) use their own shift
//     register, so video transfers and serial read-out between a copy's
//     read and write transfer must not change what the copy stores, and the
//     copy must not change what the video read-out shows, and a copy into the
//     row the video shift register holds must reach its next split transfer
//     (phase 5)
//   * flash writes (FW, colour register -> whole row)
//   * CEL-engine framebuffer writes (phase 9): one per MCLK, stopped only by
//     the core's PAUSE (ddram.sv busy, registered at CE_F), into flash-filled
//     and plain rows while read-transfer fills keep ddram.sv bursting
//   * VDL frame buffer hints (phase 10), and no prefetch fill right after a
//     transfer request (invariant)
//   * a line's two transfers ~0.15 us apart, as MADAM's video DMA issues
//     them, with the first missing: its fill waits for the second while
//     MADAM is in its video DMA sequence, at most 2 us (phase 11)
//   * write transfers with the halves out of step (phase 12)
//   * write masks on copies and flash writes in on-chip, SRAM and SDRAM
//     rows, and split transfers after writes into the half-row the video
//     shift register holds (phase 13)
// and checks every word shifted out against a reference model of VRAM. The
// important cases write to rows that are already in the cache.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_rtcache;
	reg clk_mem = 0, clk_sys = 0;
	always #5  clk_mem = ~clk_mem;
	// the MMCM's SDRAM clock: clk_mem delayed by 67.5 degrees (gb_clocks.sv)
	reg clk_sdram = 0;
	always @(clk_mem) clk_sdram <= #1.875 clk_mem;
	always #10 clk_sys = ~clk_sys;
	reg rst = 1;

	localparam [3:0] BRAM1_OFFS = 4'hC;   // on-chip block at 0xC0000: test rows below it

	// ---------------- VRAM pins (both halves driven alike) ----------------
	reg  [17:0] A = 0;
	reg  [15:0] DL = 0, DR = 0;
	reg         RAS_N = 1, CAS_N = 1, OE_N = 1, DSF1 = 0, SC = 0;
	reg         SP_CPU = 0;    // the access is the CPU's SPORT access (MADAM CPU_SPORT_SEL)
	reg  [ 1:0] WE_N = 2'b11;
	wire [15:0] SQL, SQR;
	wire        RDYL, RDYR;

	wire [17:0] v_laddr, v_raddr;
	wire        v_lwr, v_rwr, v_lrd, v_rrd, v_lfw;
	wire        v_lte, v_rte;
	wire [31:0] v_lq, v_rq, bldata, brdata;

	// The right VRAM half sees the control signals r_delay clk_mem cycles
	// later (0: in the same cycle, as for CPU transfers). MADAM's video DMA
	// issues a line's two transfers ~0.15 us apart (phase 11).
	int r_delay = 0;
	typedef struct packed { logic [17:0] a; logic ras_n, cas_n, oe_n, dsf1; logic [1:0] we_n; } vctl_t;
	vctl_t vctl_hist [256];
	wire vctl_t vctl_now = '{a: A, ras_n: RAS_N, cas_n: CAS_N, oe_n: OE_N, dsf1: DSF1, we_n: WE_N};
	initial foreach (vctl_hist[i]) vctl_hist[i] = '{a: '0, ras_n: 1, cas_n: 1, oe_n: 1, dsf1: 0, we_n: 2'b11};
	always @(posedge clk_mem) begin
		for (int i = 255; i > 0; i--) vctl_hist[i] <= vctl_hist[i - 1];
		vctl_hist[0] <= vctl_now;
	end
	wire vctl_t vctl_r = (r_delay == 0) ? vctl_now : vctl_hist[r_delay - 1];
	// MADAM's bus is in a video DMA sequence (vram_rtcache.sv)
	reg vid_dma = 0;
	// The video DMA's transfers go to one VRAM half at a time (MADAM's
	// LEFT_TRANS / RIGHT_TRANS): l_off / r_off keep that half's RAS high
	// (phase 12).
	reg l_off = 0, r_off = 0;
	wire v_lbusy, v_rbusy, v_lnp, v_rnp;

	P3DO_VRAM #(0) vram_l (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~rst),
		.A(A), .D(DL), .Q(), .RAS_N(RAS_N | l_off), .CAS_N(CAS_N), .WE_N(WE_N), .OE_N(OE_N), .DSF1(DSF1),
		.SC(SC), .SE_N(1'b0), .SQ(SQL), .QSF(), .RDY(RDYL),
		.EQ(16'h0), .ESADDR(v_laddr), .ESDATA(bldata), .ESWR(v_lwr), .ESRD(v_lrd), .ESNP(v_lnp), .ESFW(v_lfw),
		.ESQ(v_lq), .ESTE(v_lte),
		.BRAM4_OFFS(4'h0), .BRAM2_OFFS(4'h4), .BRAM1_OFFS(BRAM1_OFFS), .SP_CPU(SP_CPU),
		.DP(DR), .PEER_BUSY(v_rbusy), .XBUSY(v_lbusy), .DBG_WAIT_CNT()
	);
	P3DO_VRAM #(0) vram_r (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~rst),
		.A(vctl_r.a), .D(DR), .Q(), .RAS_N(vctl_r.ras_n | r_off), .CAS_N(vctl_r.cas_n), .WE_N(vctl_r.we_n), .OE_N(vctl_r.oe_n), .DSF1(vctl_r.dsf1),
		.SC(SC), .SE_N(1'b0), .SQ(SQR), .QSF(), .RDY(RDYR),
		.EQ(16'h0), .ESADDR(v_raddr), .ESDATA(brdata), .ESWR(v_rwr), .ESRD(v_rrd), .ESNP(v_rnp), .ESFW(),
		.ESQ(v_rq), .ESTE(v_rte),
		.BRAM4_OFFS(4'h0), .BRAM2_OFFS(4'h4), .BRAM1_OFFS(BRAM1_OFFS), .SP_CPU(SP_CPU),
		.DP(DL), .PEER_BUSY(v_lbusy), .XBUSY(v_rbusy), .DBG_WAIT_CNT()
	);

	// ---------------- cache + ddram.sv ----------------
	wire [17:0] ddr_bladdr, ddr_braddr;
	wire        ddr_blwr, ddr_brwr, ddr_blrd, ddr_brrd, ddr_bfw, ddr_blte, ddr_brte, ddr_bbusy;
	wire [63:0] ddr_bout;
	wire [ 9:2] ddr_ba;
	wire [63:0] ddr_bin = {bldata[31:16], brdata[31:16], bldata[15:0], brdata[15:0]};
	wire        DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
	wire [ 7:0] DDRAM_BURSTCNT, DDRAM_BE;
	wire [28:0] DDRAM_ADDR;
	wire [63:0] DDRAM_DOUT, DDRAM_DIN;
	wire [31:0] st_hits, st_misses, st_pf, st_inv, st_hints;
	// VDL frame buffer hint (MADAM_AG.sv in the core)
	reg         frame = 0;   // start of a frame (MADAM SPORT LINE0)
	reg         hint = 0, hint_curr_v = 0, hint_prev_v = 0;
	reg  [17:0] hint_curr = 0, hint_prev = 0;

	vram_rtcache #(.ENTRIES(16)) cache (
		.clk(clk_mem), .rst(rst), .BRAM1_OFFS(BRAM1_OFFS),
		.l_esrd(v_lrd), .l_esnp(v_lnp), .l_esaddr(v_laddr), .l_eswr(v_lwr), .l_esfw(v_lfw), .l_este(v_lte), .l_esq(v_lq),
		.r_esrd(v_rrd), .r_esnp(v_rnp), .r_esaddr(v_raddr), .r_eswr(v_rwr), .r_este(v_rte), .r_esq(v_rq),
		.d_bladdr(ddr_bladdr), .d_blrd(ddr_blrd), .d_blwr(ddr_blwr), .d_bfw(ddr_bfw),
		.d_braddr(ddr_braddr), .d_brrd(ddr_brrd), .d_brwr(ddr_brwr),
		.d_blte(ddr_blte), .d_brte(ddr_brte), .d_bout(ddr_bout), .d_ba(ddr_ba), .d_bbusy(ddr_bbusy),
		.ddr_we(DDRAM_WE && !DDRAM_BUSY), .ddr_addr(DDRAM_ADDR),
		.frame(frame), .vid_dma(vid_dma), .hint(hint), .hint_curr(hint_curr), .hint_curr_v(hint_curr_v), .hint_prev(hint_prev), .hint_prev_v(hint_prev_v),
		.stat_hits(st_hits), .stat_misses(st_misses), .stat_prefetches(st_pf), .stat_invalidations(st_inv),
		.stat_hints(st_hints)
	);

	// CPU random writes go straight into ddram.sv's posted write port
	reg  [17:0] w_addr = 0;
	reg  [15:0] w_ldata = 0, w_rdata = 0;
	reg  [ 1:0] w_lwe = 0, w_rwe = 0;
	reg         w_ras = 0;

	ddram ddram (
		.DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.clk(clk_mem), .rst(rst),
		.io_addr('0), .io_din('0), .io_we('0), .io_rd(1'b0), .io_dout(), .io_busy(),
		.nvram_addr('0), .nvram_din('0), .nvram_wr(1'b0), .nvram_rd(1'b0), .nvram_dout(), .nvram_busy(),
		.sclk(1'b0),
		.laddr(w_addr), .ldin(w_ldata), .lras(w_ras), .lwe(w_lwe), .lrd(1'b0), .ldout(),
		.raddr(w_addr), .rdin(w_rdata), .rras(w_ras), .rwe(w_rwe), .rrd(1'b0), .rdout(),
		.busy(),
		.bladdr(ddr_bladdr), .blwr(ddr_blwr), .blrd(ddr_blrd), .braddr(ddr_braddr), .brwr(ddr_brwr),
		.brrd(ddr_brrd), .bfw(ddr_bfw), .ba(ddr_ba), .bin(ddr_bin), .bout(ddr_bout),
		.blte(ddr_blte), .brte(ddr_brte), .bbusy(ddr_bbusy)
	);

	wire        sec_req, sec_we, sec_wnext, sec_rvalid, sec_done, init_done;
	wire [23:0] sec_addr;
	wire [ 9:0] sec_len;
	wire [15:0] sec_wdata, sec_rdata;
	wire [ 1:0] sec_wbe;

	ddr_bridge bridge (
		.clk(clk_mem), .rst(rst), .host_le(1'b1),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.sec_req(sec_req), .sec_we(sec_we), .sec_addr(sec_addr), .sec_len(sec_len),
		.sec_wdata(sec_wdata), .sec_wbe(sec_wbe), .sec_wnext(sec_wnext),
		.sec_rdata(sec_rdata), .sec_rvalid(sec_rvalid), .sec_done(sec_done)
	);

	// VRAM blocks in the SRAM (vram_sram.sv, as in the core): +sram_mode=0
	// (two cycles per word, the default), 1 (three), 2 (none: all in the
	// SDRAM). With these offsets (BRAM4 0, BRAM2 4, on-chip block at 0xC0000)
	// the SRAM has blocks 0-5, C and F (the highest one left); the test rows
	// are in both memories.
	bit  [ 1:0] sram_mode = 2'd0;
	initial begin
		int m;
		if ($value$plusargs("sram_mode=%d", m)) sram_mode = 2'(m);
		$display("tb_rtcache: VRAM memory mode %0d (%s)", sram_mode,
		         sram_mode == 0 ? "SRAM, 2 cycles per word" : sram_mode == 1 ? "SRAM, 3 cycles per word" : "SDRAM only");
	end
	wire        d_req, d_wnext, d_rvalid, d_done;
	wire [15:0] d_rdata;
	wire        sr_ce_n, sr_we_n, sr_oe_n, sr_dir;
	wire [ 1:0] sr_mask_n;
	wire [17:0] sr_a;
	wire [15:0] sr_dout, sr_din;
	wire [15:0] vs_map_v;
	wire [ 2:0] vs_map_slot [16];
	vram_sram vsram (
		.clk(clk_mem), .rst(rst), .mode(sram_mode),
		.BRAM4_OFFS(4'h0), .BRAM2_OFFS(4'h4), .BRAM1_OFFS(BRAM1_OFFS),
		.c_req(sec_req), .c_we(sec_we), .c_addr(sec_addr), .c_len(sec_len), .c_wdata(sec_wdata), .c_wbe(sec_wbe),
		.c_wnext(sec_wnext), .c_rdata(sec_rdata), .c_rvalid(sec_rvalid), .c_done(sec_done),
		.s_req(d_req), .s_wnext(d_wnext), .s_rdata(d_rdata), .s_rvalid(d_rvalid), .s_done(d_done),
		.sram_ceN(sr_ce_n), .sram_weN(sr_we_n), .sram_oeN(sr_oe_n), .sram_writeMaskN(sr_mask_n),
		.sram_address(sr_a), .sram_dataIn(sr_din), .sram_dataOut(sr_dout), .sram_dataDir(sr_dir),
		.map_v(vs_map_v), .map_slot(vs_map_slot)
	);
	sram_model sram (
		.ce_n(sr_ce_n), .we_n(sr_we_n), .oe_n(sr_oe_n), .mask_n(sr_mask_n), .a(sr_a),
		.dq_from_fpga(sr_dout), .dq_dir(sr_dir), .dq_to_fpga(sr_din)
	);

	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;

	sdram_3do #(.POWERUP_US(2)) sdram (
		.clk_sdram(clk_sdram),
		.clk(clk_mem), .rst(rst),
		.SDRAM_CLK(s_clk), .SDRAM_CKE(s_cke), .SDRAM_nCS(s_cs), .SDRAM_nRAS(s_ras), .SDRAM_nCAS(s_cas),
		.SDRAM_nWE(s_we), .SDRAM_DQM(s_dqm), .SDRAM_BA(s_ba), .SDRAM_A(s_a),
		.SDRAM_DQ_IN(s_dq_in), .SDRAM_DQ_OUT(s_dq_out), .SDRAM_DQ_OE(s_oe), .init_done(init_done),
		.sync(1'b0), .laddr('0), .lwe('0), .lras(1'b0), .lcode('0), .raddr('0), .rwe('0), .rras(1'b0),
		.rcode('0), .din('0), .dout(),
		.CORE_RST(1'b1), .SEC_PAUSED(1'b0), .SEC_HOLD(),
		.sec_req(d_req), .sec_we(sec_we), .sec_addr(sec_addr), .sec_len(sec_len),
		.sec_wdata(sec_wdata), .sec_wbe(sec_wbe), .sec_wnext(d_wnext),
		.sec_rdata(d_rdata), .sec_rvalid(d_rvalid), .sec_done(d_done)
	);

	sdram_model model (
		.clk(s_clk), .cke(s_cke), .cs_n(s_cs), .ras_n(s_ras), .cas_n(s_cas), .we_n(s_we),
		.dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_from_fpga(s_dq_out), .dq_oe_fpga(s_oe), .dq_to_fpga(s_dq_in)
	);

	// VRAM rows in the SRAM (vram_sram.sv map)
	function automatic bit in_sram(input [8:0] row);
		return sram_mode != 2'd2 && vs_map_v[row[8:5]];
	endfunction
	// Every read-transfer fill from the SRAM must keep ahead of a line's
	// serial read-out started with it: at least one 64-bit beat (two columns
	// of each VRAM half) per 160 ns, two video dots; 128 beats in 20.48 us.
	// Fills from the SDRAM pause the 3DO and are timed by phases 10 and 11.
	realtime fr_t0;
	real     fr_max [2] = '{0.0, 0.0};
	int      fr_n [2] = '{0, 0};
	bit      fr_sram;
	always @(posedge clk_mem) begin
		if (cache.fill_issue) begin
			fr_t0 = $realtime;
			fr_sram = in_sram(cache.fill_h[9:1]);
		end
		if (cache.fill_busy && cache.d_blte && cache.d_ba[8:2] == 7'd127) begin
			real us;
			us = ($realtime - fr_t0) / 1000.0;
			fr_n[fr_sram]++;
			if (us > fr_max[fr_sram]) fr_max[fr_sram] = us;
			if (fr_sram && us > 20.48)
				fail($sformatf("SRAM fill of half-row %03h took %0.2f us: slower than a line's serial read-out", cache.fill_h, us));
		end
	end

	// ---------------- reference model ----------------
	bit [15:0] ref_l [bit [17:0]];
	bit [15:0] ref_r [bit [17:0]];
	bit [15:0] sr_l [512], sr_r [512];     // expected shift register contents (video)
	bit [15:0] sc_l [512], sc_r [512];     // expected CPU (SPORT copy) shift register contents
	int        sq_pos;                     // serial read-out position after rt_read/sq_read
	function automatic [15:0] rl(input [17:0] a); return ref_l.exists(a) ? ref_l[a] : 16'h0; endfunction
	function automatic [15:0] rr(input [17:0] a); return ref_r.exists(a) ? ref_r[a] : 16'h0; endfunction

	int errors = 0, checks = 0;
	task automatic fail(input string m);
		errors++;
		if (errors < 30) $display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	task automatic mem_cycles(input int n); repeat (n) @(posedge clk_mem); endtask

	// wait until the VRAM modules, the cache and ddram.sv are idle
	task automatic wait_idle();
		int to;
		to = 0;
		do begin
			mem_cycles(8);
			to++;
		end while ((vram_l.XBUSY || vram_r.XBUSY ||
		            cache.fill_busy || cache.dl_act[0] || cache.dl_act[1] || ddr_bbusy ||
		            ddram.state != 0 || ddram.write_lpend || ddram.write_rpend || sec_req) && to < 20000);
		if (to >= 20000) fail("timeout waiting for idle");
		mem_cycles(16);
	endtask

	// RAS cycle with the given control lines (as MADAM's SPORT/transfer cycles)
	task automatic ras_cycle(input [17:0] a, input bit oe_n, input [1:0] we_n, input bit dsf);
		@(posedge clk_mem);
		A <= a; OE_N <= oe_n; WE_N <= we_n; DSF1 <= dsf;
		mem_cycles(2);
		RAS_N <= 0;
		mem_cycles(4);
	endtask
	task automatic ras_end();
		@(posedge clk_mem);
		RAS_N <= 1; CAS_N <= 1; OE_N <= 1; WE_N <= 2'b11; DSF1 <= 0;
		mem_cycles(4);
	endtask

	// Read transfer of row/column a (full or split) and serial read-out of
	// 'n' words starting at the shift register position the transfer sets.
	task automatic rt_read(input [17:0] a, input bit split, input int n);
		ras_cycle(a, 0, 2'b11, split);
		ras_end();
		wait_idle();
		// expected shift register contents after the transfer
		if (!split) begin
			for (int i = a[8:1] * 2; i < 512; i++) begin sr_l[i] = rl({a[17:9], 9'(i)}); sr_r[i] = rr({a[17:9], 9'(i)}); end
			sq_pos = a[8:0];
		end else begin
			for (int i = 0; i < 256; i++) begin
				sr_l[{a[8], 8'(i)}] = rl({a[17:8], 8'(i)});
				sr_r[{a[8], 8'(i)}] = rr({a[17:8], 8'(i)});
			end
			sq_pos = vram_l.SR_RA;
		end
		sq_read(n, $sformatf("RT %05h%s", a, split ? " split" : ""));
	endtask

	// serial read-out of 'n' more words of the video shift register
	task automatic sq_read(input int n, input string what = "read-out");
		for (int k = 0; k < n; k++) begin
			@(posedge clk_mem); SC <= 1;
			mem_cycles(3);
			@(posedge clk_mem); SC <= 0;
			mem_cycles(3);
			checks++;
			if (SQL !== sr_l[sq_pos] || SQR !== sr_r[sq_pos])
				fail($sformatf("%s word %03h: got %04h/%04h expected %04h/%04h", what, sq_pos,
				               SQL, SQR, sr_l[sq_pos], sr_r[sq_pos]));
			sq_pos = (sq_pos + 1) % 512;
		end
	endtask

	// CPU random write (both halves) through ddram.sv
	task automatic cpu_write(input [17:0] a, input [15:0] dl, input [15:0] dr);
		// ddram.sv's busy pauses MADAM in the core: no new write until it drops
		while (ddram.busy) @(posedge clk_mem);
		@(posedge clk_mem);
		w_addr <= a; w_ldata <= dl; w_rdata <= dr; w_ras <= 1;
		mem_cycles(2);
		w_lwe <= 2'b11; w_rwe <= 2'b11;
		mem_cycles(3);
		w_lwe <= 0; w_rwe <= 0; w_ras <= 0;
		mem_cycles(3);
		ref_l[a] = dl; ref_r[a] = dr;
	endtask

	// Write masks: the CPU's write data to MADAM's SPORT space is the write
	// mask of a write transfer or flash write (1: the bit is written, 0: the
	// row keeps it), one per VRAM half. In the core it is on the data bus
	// from CAS (PHASE2 of the access; P3DO.sv registers the CPU's write data
	// at PHASE1), not yet when RAS falls: the bus model puts the mask's
	// complement there until CAS, as a stand-in for the stale data.
	function automatic [15:0] merge(input [15:0] new_, input [15:0] old, input [15:0] m);
		return (new_ & m) | (old & ~m);
	endfunction
	task automatic sport_ras(input [17:0] a, input bit oe_n, input [1:0] we_n, input bit dsf,
	                         input [15:0] dl, input [15:0] dr);
		@(posedge clk_mem); DL <= ~dl; DR <= ~dr;
		ras_cycle(a, oe_n, we_n, dsf);
	endtask
	task automatic sport_cas(input [15:0] dl, input [15:0] dr);
		@(posedge clk_mem); DL <= dl; DR <= dr; CAS_N <= 0;
		mem_cycles(4);
	endtask

	// MWT: write the current shift register into row 'row'
	task automatic mwt(input [8:0] row, input [15:0] ml = 16'hFFFF, input [15:0] mr = 16'hFFFF);
		sport_ras({row, 9'h0}, 0, 2'b00, 0, ml, mr);
		sport_cas(ml, mr);
		ras_end();
		wait_idle();
		for (int i = 0; i < 512; i++) begin
			ref_l[{row, 9'(i)}] = merge(sr_l[i], rl({row, 9'(i)}), ml);
			ref_r[{row, 9'(i)}] = merge(sr_r[i], rr({row, 9'(i)}), mr);
		end
	endtask

	// The CPU's SPORT read transfer (MADAM: SPORT space read, column 0, full
	// row) into the CPU shift register, and its write transfer from it
	task automatic cpu_rt(input [8:0] row);
		@(posedge clk_mem); SP_CPU <= 1;
		ras_cycle({row, 9'h0}, 0, 2'b11, 0);
		ras_end();
		SP_CPU <= 0;
		wait_idle();
		for (int i = 0; i < 512; i++) begin sc_l[i] = rl({row, 9'(i)}); sc_r[i] = rr({row, 9'(i)}); end
	endtask
	task automatic cpu_mwt(input [8:0] row, input [15:0] ml = 16'hFFFF, input [15:0] mr = 16'hFFFF);
		@(posedge clk_mem); SP_CPU <= 1;
		sport_ras({row, 9'h0}, 0, 2'b00, 0, ml, mr);
		sport_cas(ml, mr);
		ras_end();
		SP_CPU <= 0;
		wait_idle();
		for (int i = 0; i < 512; i++) begin
			ref_l[{row, 9'(i)}] = merge(sc_l[i], rl({row, 9'(i)}), ml);
			ref_r[{row, 9'(i)}] = merge(sc_r[i], rr({row, 9'(i)}), mr);
		end
	endtask

	// Phase 12: commands issued as soon as MADAM may, as in the core: when a
	// RAS falls while a VRAM half is still busy with a transfer, that half's
	// RDY drops, PAUSE stops MADAM with the command on the pins, and the half
	// takes the command when it becomes ready. 'paused_hung' is set if a half
	// never becomes ready.
	bit paused_hung = 0;
	task automatic hold_until_ready(input string what);
		int to;
		mem_cycles(4);
		to = 0;
		while ((!RDYL || !RDYR) && to < 20000) begin @(posedge clk_mem); to++; end
		if (to >= 20000) begin
			fail($sformatf("%s: a VRAM half never became ready (L RDY %b MWT %b, R RDY %b MWT %b): its write transfer did not end",
			               what, RDYL, vram_l.MWT_EXEC, RDYR, vram_r.MWT_EXEC));
			paused_hung = 1;
		end
		mem_cycles(4);
	endtask
	// the CPU's write transfer into 'row', not waiting for it to end
	// (CAS falls before the busy half is ready: the half takes the command
	// late, with CAS already low)
	task automatic cpu_mwt_paused(input [8:0] row);
		@(posedge clk_mem); SP_CPU <= 1;
		sport_ras({row, 9'h0}, 0, 2'b00, 0, 16'hFFFF, 16'hFFFF);
		sport_cas(16'hFFFF, 16'hFFFF);
		hold_until_ready($sformatf("write transfer into row %03h", row));
		ras_end();
		SP_CPU <= 0;
		for (int i = 0; i < 512; i++) begin ref_l[{row, 9'(i)}] = sc_l[i]; ref_r[{row, 9'(i)}] = sc_r[i]; end
	endtask
	// a video split read transfer to one half only, not waiting for it to end
	task automatic half_rt_paused(input bit right, input [17:0] a);
		if (right) l_off = 1; else r_off = 1;
		ras_cycle(a, 0, 2'b11, 1);
		hold_until_ready($sformatf("%s read transfer %05h", right ? "right" : "left", a));
		ras_end();
		l_off = 0; r_off = 0;
	endtask

	// Phase 12 coverage. ddram.sv serves a half's write burst in two passes
	// of 128 beats (one half-row each) and serves the left half first.
	// l_between: a left write burst started while the right half's burst was
	// between its two passes (its first done, its second still to come);
	// r_during_l: a right write burst latched while only the left half's
	// burst was in progress.
	int ph12_l_between = 0, ph12_r_during_l = 0;
	bit ph12_brwr_d = 0, ph12_lstart_d = 0;
	always @(posedge clk_mem) begin
		ph12_brwr_d <= ddr_brwr;
		if (ddr_brwr && !ph12_brwr_d && ddram.burst_write_lbusy && !ddram.burst_write_rbusy) ph12_r_during_l++;
		if (ddram.state == 0 && !DDRAM_BUSY && ddram.burst_write_lbusy && !ph12_lstart_d &&
		    ddram.burst_write_rbusy && ddram.burst_raddr[10] && ddram.burst_raddr != ddram.burst_laddr) ph12_l_between++;
		ph12_lstart_d <= ddram.state == 0 && !DDRAM_BUSY && ddram.burst_write_lbusy;
	end

	// FW: load the colour registers, flash-write row 'row' (MADAM: the
	// CPU's writes to SPORT space with address bit 13, the colour, and bit
	// 14, the mask)
	task automatic flash_write(input [8:0] row, input [15:0] cl, input [15:0] cr,
	                           input [15:0] ml = 16'hFFFF, input [15:0] mr = 16'hFFFF);
		// colour load: RAS with DSF and no OE/WE, then CAS with the colour
		sport_ras({row, 9'h0}, 1, 2'b11, 1, cl, cr);
		sport_cas(cl, cr);
		ras_end();
		// flash write: RAS with WE and DSF, then CAS with the mask
		sport_ras({row, 9'h0}, 1, 2'b00, 1, ml, mr);
		sport_cas(ml, mr);
		ras_end();
		wait_idle();
		for (int i = 0; i < 512; i++) begin
			ref_l[{row, 9'(i)}] = merge(cl, rl({row, 9'(i)}), ml);
			ref_r[{row, 9'(i)}] = merge(cr, rr({row, 9'(i)}), mr);
		end
	endtask

	// on-chip VRAM in this testbench (vram.sv USE_INT_RAM1 with USE_BRAM 0):
	// the BRAM1 window and the VDL area
	function automatic bit on_chip(input [17:0] a);
		return (a >= ({BRAM1_OFFS, 16'h0000} >> 2) && a <= ({BRAM1_OFFS, 16'hBFFF} >> 2)) || a >= (20'hFC000 >> 2);
	endfunction
	// A random write as the core makes it: the VRAM pins (RAS, then WE with
	// the data: on-chip VRAM is written there, and vram.sv sees the write)
	// and, for VRAM outside, ddram.sv's write port at the same time
	task automatic pin_write(input [17:0] a, input [15:0] dl, input [15:0] dr);
		bit ext;
		ext = !on_chip(a);
		while (ddram.busy) @(posedge clk_mem);
		@(posedge clk_mem);
		A <= a; DL <= dl; DR <= dr; OE_N <= 1; WE_N <= 2'b11; DSF1 <= 0;
		if (ext) begin w_addr <= a; w_ldata <= dl; w_rdata <= dr; w_ras <= 1; end
		mem_cycles(2);
		RAS_N <= 0;
		mem_cycles(4);
		WE_N <= 2'b00;
		if (ext) begin w_lwe <= 2'b11; w_rwe <= 2'b11; end
		mem_cycles(4);
		WE_N <= 2'b11;
		if (ext) begin w_lwe <= 0; w_rwe <= 0; w_ras <= 0; end
		mem_cycles(2);
		RAS_N <= 1;
		mem_cycles(4);
		ref_l[a] = dl; ref_r[a] = dr;
	endtask

	// ---------------- CEL-engine style framebuffer writes ----------------
	// MADAM's CFB access (MADAM_AG.sv) writes one pixel per MCLK with a
	// WE/CAS pulse during the CE_R cycle, to the address it drives; the next
	// pixel's address follows right after. The core stops MADAM only through
	// PAUSE: p3do_gamebub.sv registers ddram.sv's busy at the end of every
	// CE_F cycle and MADAM's CE_R is gated with it. This BFM reproduces that
	// timing on ddram.sv's random-access port (clk_sys = 2 clk_mem cycles).
	typedef struct packed { bit [17:0] a; bit [15:0] dl, dr; bit [1:0] lm, rm; bit [3:0] gap; bit sync; } cfbw_t;
	cfbw_t cfb_q [$];
	bit        cfb_en = 0;
	bit [1:0]  cfb_ph = 0;          // 0,1: CE_R cycle  2,3: CE_F cycle
	int        cfb_issued = 0, cfb_paused = 0;
	always @(posedge clk_mem) begin
		if (!cfb_en) cfb_ph <= 0;
		else begin
			cfb_ph <= cfb_ph + 2'd1;
			if (cfb_ph == 2'd3) begin
				// end of the CE_F cycle: PAUSE <= busy; the CE_R cycle that
				// follows writes only if not paused
				if (ddram.busy) cfb_paused++;
				else if (cfb_q.size() != 0 && cfb_q[0].gap != 0) cfb_q[0].gap = cfb_q[0].gap - 4'd1;   // idle MCLK
				// 'sync' writes wait for the cache to request a fill: the write
				// is then latched on the edge ddram.sv starts that burst, while
				// ddram.sv was idle (the case write_lbusy does not cover)
				else if (cfb_q.size() != 0 && cfb_q[0].sync && !cache.fill_issue) ;
				else if (cfb_q.size() != 0) begin
					cfbw_t w;
					w = cfb_q.pop_front();
					w_addr <= w.a; w_ldata <= w.dl; w_rdata <= w.dr; w_lwe <= w.lm; w_rwe <= w.rm;
					if (w.lm[1]) ref_l[w.a][15:8] = w.dl[15:8];
					if (w.lm[0]) ref_l[w.a][ 7:0] = w.dl[ 7:0];
					if (w.rm[1]) ref_r[w.a][15:8] = w.dr[15:8];
					if (w.rm[0]) ref_r[w.a][ 7:0] = w.dr[ 7:0];
					cfb_issued++;
				end
			end
			if (cfb_ph == 2'd1) begin
				// end of the CE_R cycle: WE goes away, the next address is
				// driven (and stays on the bus while MADAM is paused)
				w_lwe <= 2'b00; w_rwe <= 2'b00;
				if (cfb_q.size() != 0) begin
					w_addr <= cfb_q[0].a; w_ldata <= cfb_q[0].dl; w_rdata <= cfb_q[0].dr;
				end
			end
		end
	end
	// writes latched by ddram.sv while it was not free to issue them at once,
	// and writes latched while it was idle just as a fill burst started
	// (served first, so the write waits although ddram.sv was idle)
	int cfb_latched_busy = 0, cfb_latched_at_burst = 0;
	bit cfb_old_we = 0;
	always @(posedge clk_mem) begin
		cfb_old_we <= |w_lwe || |w_rwe;
		if (cfb_en && (|w_lwe || |w_rwe) && !cfb_old_we) begin
			if (ddram.state != 0 || DDRAM_BUSY) cfb_latched_busy++;
			else if (ddram.burst_read_lbusy || ddram.burst_read_rbusy || ddr_blrd || ddr_brrd) cfb_latched_at_burst++;
		end
	end

	// read transfer for use while other traffic runs: waits only for the
	// transfer itself (rows that nothing writes during it)
	task automatic rt_read_busy(input [17:0] a, input int n);
		int pos, to;
		ras_cycle(a, 0, 2'b11, 0);
		ras_end();
		to = 0;
		do begin mem_cycles(4); to++; end while ((vram_l.RT_EXEC || vram_r.RT_EXEC) && to < 50000);
		if (to >= 50000) fail("timeout waiting for a read transfer");
		for (int i = a[8:1] * 2; i < 512; i++) begin sr_l[i] = rl({a[17:9], 9'(i)}); sr_r[i] = rr({a[17:9], 9'(i)}); end
		pos = a[8:0];
		for (int k = 0; k < n; k++) begin
			@(posedge clk_mem); SC <= 1;
			mem_cycles(3);
			@(posedge clk_mem); SC <= 0;
			mem_cycles(3);
			checks++;
			if (SQL !== sr_l[pos] || SQR !== sr_r[pos])
				fail($sformatf("RT %05h word %03h: got %04h/%04h expected %04h/%04h", a, pos,
				               SQL, SQR, sr_l[pos], sr_r[pos]));
			pos = (pos + 1) % 512;
		end
	endtask

	// VDL frame buffer hint: a level change as MADAM_AG.sv makes (clk_sys)
	task automatic vdl_hint(input [17:0] curr, input bit curr_v, input [17:0] prev, input bit prev_v);
		@(posedge clk_sys);
		hint_curr <= curr; hint_curr_v <= curr_v; hint_prev <= prev; hint_prev_v <= prev_v; hint <= 1;
		@(posedge clk_sys); @(posedge clk_sys);
		hint <= 0;
	endtask

	// invariant: no prefetch fill starts within 128 cycles of a transfer
	// request (the video DMA's other transfers of the line would wait for it)
	int rq_age = 1000, rq_age_d = 1000;
	bit [31:0] pf_cnt_d = 0;
	always @(posedge clk_mem) begin
		if (!rst && cache.fill_issue && cache.stat_prefetches != pf_cnt_d && rq_age_d < 128 &&
		    !(cache.fill_h == cache.hint_h1 || (cache.hint_v2 && cache.fill_h == cache.hint_h2)))   // VDL hints are not held off
			fail($sformatf("prefetch fill h=%03h started %0d cycles after a transfer request", cache.fill_h, rq_age_d));
		pf_cnt_d <= cache.stat_prefetches;
		rq_age_d <= rq_age;
		rq_age = (v_lrd || v_rrd || cache.req_v[0] || cache.req_v[1]) ? 0 : rq_age + 1;
	end

	// invariant: no two valid entries hold the same half-row
	always @(posedge clk_mem) if (!rst) begin
		for (int i = 0; i < 16; i++)
			for (int j = i + 1; j < 16; j++)
				if (cache.valid[i] && cache.valid[j] && cache.tag[i] == cache.tag[j])
					fail($sformatf("cache entries %0d and %0d both hold half-row %03h", i, j, cache.tag[i]));
	end

	// +rtc_trace=<from_ns>: cache event trace
	longint trace_from = -1;
	bit dl_act_d [2];
	always @(posedge clk_mem) begin dl_act_d[0] <= cache.dl_act[0]; dl_act_d[1] <= cache.dl_act[1]; end

	// phase 13 coverage: the ways vram.sv carries out a masked write.
	// n_mrd: destination-row reads outside (partial mask); n_rmw: on-chip
	// merged block writes; n_lazy: ddram.sv lazy flash fills (both halves
	// FFFF, in step); n_fwm: a half's flash colour written as a burst
	int  n_mrd = 0, n_rmw = 0, n_lazy = 0, n_fwm = 0;
	bit  mrd_l_d = 0, mrd_r_d = 0, bfw_d = 0, fwm_l_d = 0, fwm_r_d = 0;
	always @(posedge clk_mem) begin
		mrd_l_d <= vram_l.MRD_EXEC; mrd_r_d <= vram_r.MRD_EXEC; bfw_d <= ddr_bfw;
		fwm_l_d <= vram_l.MWT_EXEC && vram_l.FWM; fwm_r_d <= vram_r.MWT_EXEC && vram_r.FWM;
		if (vram_l.MRD_EXEC && !mrd_l_d) n_mrd++;
		if (vram_r.MRD_EXEC && !mrd_r_d) n_mrd++;
		if (ddr_bfw && !bfw_d) n_lazy++;
		if (vram_l.MWT_EXEC && vram_l.FWM && !fwm_l_d) n_fwm++;
		if (vram_r.MWT_EXEC && vram_r.FWM && !fwm_r_d) n_fwm++;
		if (vram_l.MEM_SWR && vram_l.MASKED) n_rmw++;
		if (vram_r.MEM_SWR && vram_r.MASKED) n_rmw++;
	end

	// read transfers the left VRAM module executes (a skipped split transfer
	// does not start one)
	int  n_rt_l = 0;
	bit  rt_l_d = 0;
	always @(posedge clk_mem) begin rt_l_d <= vram_l.RT_EXEC; if (vram_l.RT_EXEC && !rt_l_d) n_rt_l++; end
	initial void'($value$plusargs("rtc_trace=%d", trace_from));
	always @(posedge clk_mem) if (trace_from >= 0 && $realtime >= trace_from) begin
		for (int s = 0; s < 2; s++) if (cache.req_v[s])
			$display("[%0t] RTC req side %0d A=%05h h=%03h", $realtime, s, cache.req_a[s], cache.req_a[s][17:8]);
		if (cache.fill_issue) $display("[%0t] RTC fill e=%0d h=%03h", $realtime, cache.fill_e, cache.fill_h);
		for (int s = 0; s < 2; s++) if (cache.dl_act[s] && !dl_act_d[s])
			$display("[%0t] RTC deliver side %0d e=%0d (tag %03h valid %b filled %0d) from beat %0d", $realtime, s,
			         cache.dl_e[s], cache.tag[cache.dl_e[s]], cache.valid[cache.dl_e[s]], cache.filled[cache.dl_e[s]], cache.dl_beat[s]);
		if (|cache.snoop_hit) $display("[%0t] RTC invalidate %b (we %b h=%03h fw %b row=%03h)", $realtime, cache.snoop_hit,
		                               cache.sn_we, cache.sn_h, cache.sn_fw, cache.sn_row);
		if (ddr_blwr != tr_blwr_d || ddr_brwr != tr_brwr_d)
			$display("[%0t] RTC write burst L %b R %b (L %05h R %05h)", $realtime, ddr_blwr, ddr_brwr, ddr_bladdr, ddr_braddr);
		if (cache.fill_busy && cache.d_blte && cache.d_ba[8:2] == 7'd127)
			$display("[%0t] RTC fill h=%03h done", $realtime, cache.fill_h);
	end
	bit tr_blwr_d = 0, tr_brwr_d = 0;
	always @(posedge clk_mem) begin tr_blwr_d <= ddr_blwr; tr_brwr_d <= ddr_brwr; end

	initial begin
		bit [8:0] rows [8];
		$display("tb_rtcache: start");
		mem_cycles(10);
		rst = 0;
		wait (init_done);
		mem_cycles(50);

		for (int i = 0; i < 8; i++) rows[i] = 9'(16 + i * 3);     // VRAM 0x08000.. (external)

		// 1) fill 8 rows with CPU writes (a sample of words per row; rest 0)
		foreach (rows[i]) for (int w = 0; w < 512; w += 7) cpu_write({rows[i], 9'(w)}, $urandom(), $urandom());
		wait_idle();

		// 2) read all rows back through read transfers (misses + prefetches)
		foreach (rows[i]) rt_read({rows[i], 9'h0}, 0, 512);
		$display("[%0t] phase 2: full-row reads done, errors=%0d (hits %0d misses %0d)", $realtime, errors, st_hits, st_misses);

		// 3) the same rows again: now from the cache
		foreach (rows[i]) rt_read({rows[i], 9'h0}, 0, 512);
		$display("[%0t] phase 3: cached reads done, errors=%0d (hits %0d misses %0d)", $realtime, errors, st_hits, st_misses);

		// 4) CPU writes into cached rows, then read again (invalidation)
		for (int k = 0; k < 12; k++) begin
			bit [8:0] r;
			int inv0;
			r = rows[$urandom() % 8];
			rt_read({r, 9'h0}, 0, 512);                 // row now cached
			if (!cache.find({r, 1'b0})[4]) fail("row not cached before the CPU write");
			inv0 = st_inv;
			for (int j = 0; j < 4; j++) cpu_write({r, 1'b0, 8'($urandom())}, $urandom(), $urandom());
			wait_idle();
			if (st_inv == inv0) fail("CPU write into a cached row did not invalidate it");
			rt_read({r, 9'h0}, 0, 512);
		end
		$display("[%0t] phase 4: after CPU writes, errors=%0d (invalidations %0d)", $realtime, errors, st_inv);

		// 5) SPORT copy: the CPU's read transfer of row a, then its write
		//    transfer into cached row b. Between them, as when a copy runs
		//    into the picture, video transfers of other rows with serial
		//    read-out: b must get row a, and the video read-out must go on
		//    with its own row across both of the copy's transfers. Then b
		//    is read back. Also the legacy path (a write transfer that is not
		//    the CPU's stores the video shift register).
		for (int k = 0; k < 4; k++) begin
			int inv0;
			rt_read({rows[k + 4], 9'h0}, 0, 512);       // destination row now cached
			rt_read({rows[(k + 1) % 4], 9'h0}, 0, 16);  // video: row c, 16 words out
			cpu_rt(rows[k]);                            // copy source -> CPU shift register
			sq_read(16, "video read-out after the CPU's read transfer");
			rt_read({rows[(k + 2) % 4], 9'h0}, 0, 16);  // another video transfer inside the copy
			if (!cache.find({rows[k + 4], 1'b0})[4]) fail("MWT destination not cached before the copy");
			inv0 = st_inv;
			cpu_mwt(rows[k + 4]);
			if (st_inv == inv0) fail("MWT into a cached row did not invalidate it");
			sq_read(16, "video read-out after the CPU's write transfer");
			rt_read({rows[k + 4], 9'h0}, 0, 512);
		end
		for (int k = 0; k < 2; k++) begin
			rt_read({rows[k + 2], 9'h0}, 0, 0);         // legacy: video shift register
			mwt(rows[k + 6]);
			rt_read({rows[k + 6], 9'h0}, 0, 512);
		end
		// A split transfer of the half-row the video shift register holds is
		// skipped (MiSTer core). A copy into that row must not leave the old
		// data there: the next split transfer of the half shows the copy.
		for (int k = 0; k < 2; k++) begin
			int n0;
			rt_read({rows[k + 4], 9'h000}, 0, 16);      // video register <- row d
			n0 = n_rt_l;
			rt_read({rows[k + 4], 9'h000}, 1, 16);      // split, same half
			if (n_rt_l != n0) fail("split transfer of the half the video shift register holds was not skipped");
			cpu_rt(rows[k + 2]);                        // copy another row into d
			cpu_mwt(rows[k + 4]);
			rt_read({rows[k + 4], 9'h000}, 1, 64);      // split, same half: the copied data
		end
		$display("[%0t] phase 5: MWT copies, errors=%0d (invalidations %0d)", $realtime, errors, st_inv);

		// 6) flash writes into cached rows
		for (int k = 0; k < 3; k++) begin
			int inv0;
			rt_read({rows[k], 9'h0}, 0, 512);           // row now cached
			if (!cache.find({rows[k], 1'b0})[4]) fail("FW row not cached before the flash write");
			inv0 = st_inv;
			flash_write(rows[k], 16'h1111 * (k + 1), 16'h0F0F + k);
			if (st_inv == inv0) fail("flash write into a cached row did not invalidate it");
			rt_read({rows[k], 9'h0}, 0, 512);
		end
		// a CPU write into a flash-filled row
		cpu_write({rows[1], 9'h055}, 16'hABCD, 16'h1234);
		wait_idle();
		rt_read({rows[1], 9'h0}, 0, 512);
		$display("[%0t] phase 6: flash writes, errors=%0d (invalidations %0d)", $realtime, errors, st_inv);

		// 7) split transfers and transfers starting mid-row
		foreach (rows[i]) begin
			rt_read({rows[i], 9'h000}, 0, 64);
			rt_read({rows[i], 9'h100}, 1, 256);       // other half (split)
			rt_read({rows[i], 9'h0A2}, 0, 100);
		end
		$display("[%0t] phase 7: split/mid-row transfers, errors=%0d", $realtime, errors);

		// 8) random mix
		for (int k = 0; k < 120; k++) begin
			bit [8:0] r;
			r = rows[$urandom() % 8];
			case ($urandom() % 6)
				0, 1: rt_read({r, 9'($urandom() % 2 ? 0 : 9'(($urandom() % 256) * 2))}, 0, 40);
				2:    begin cpu_write({r, 9'($urandom())}, $urandom(), $urandom()); wait_idle(); end
				3:    begin
				          cpu_rt(rows[$urandom() % 8]);
				          if ($urandom() % 2) rt_read({rows[$urandom() % 8], 9'h0}, 0, 8);
				          cpu_mwt(r);
				      end
				4:    flash_write(r, $urandom(), $urandom());
				5:    begin rt_read({rows[$urandom() % 8], 9'h0}, 0, 0); mwt(r); end
			endcase
		end
		$display("[%0t] phase 8: random mix, errors=%0d", $realtime, errors);

		// 9) CEL-engine style framebuffer writes (one per MCLK, stopped only
		//    by PAUSE) into flash-filled and plain rows, while read transfers
		//    of 16 other rows keep ddram.sv busy with bursts.
		begin
			bit [8:0] rows_w [4], rows_c [16];
			int errors0, n;
			bit rt_done;
			errors0 = errors;
			rows_w = '{9'h060, 9'h061, 9'h0A3, 9'h0A4};
			foreach (rows_c[i]) rows_c[i] = 9'(9'h100 + i);
			flash_write(rows_w[0], 16'h7FFF, 16'h7C00);
			flash_write(rows_w[1], 16'h03E0, 16'h001F);
			n = 0;
			while (n < 20000) begin
				bit [17:0] a;
				int run, stride;
				a = {rows_w[$urandom() % 4], 9'($urandom())};
				run = 1 + $urandom() % 24;
				stride = ($urandom() % 3 == 0) ? 2 : 1;
				for (int k = 0; k < run && n < 20000; k++, n++) begin
					cfbw_t w;
					w.a = {a[17:9], 9'(a[8:0] + k * stride)};
					w.dl = 16'($urandom()); w.dr = 16'($urandom());
					// idle MCLKs before the write (CEL source fetches, transparent pixels)
					w.gap = ($urandom() % 2 == 0) ? 4'(2 + $urandom() % 14) : 4'd0;
					w.sync = (n % 200 == 199);
					if (w.sync) w.gap = 4'd8;              // SDRAM idle by then
					if (n % 200 == 0) w.gap = 4'd0;        // the write right after a sync write
					case ($urandom() % 8)
						0, 1:    begin w.lm = 2'b11; w.rm = 2'b00; end   // left chip only
						2, 3:    begin w.lm = 2'b00; w.rm = 2'b11; end   // right chip only
						4, 5, 6: begin w.lm = 2'b11; w.rm = 2'b11; end
						default: begin w.lm = 2'($urandom() % 3 + 1); w.rm = 2'($urandom() % 4); end
					endcase
					cfb_q.push_back(w);
				end
			end
			rt_done = 0;
			fork
				begin
					@(posedge clk_mem); w_ras <= 1;
					mem_cycles(2);
					cfb_en = 1;
					while (cfb_q.size() != 0) @(posedge clk_mem);
					mem_cycles(8);
					cfb_en = 0;
					wait_idle();
					@(posedge clk_mem); w_ras <= 0;
				end
				begin
					int k;
					k = 0;
					// one transfer every 15-40 us. Video DMA does one per
					// 63.5 us line; each transfer here misses and prefetches
					// two more half-rows (3 fills of ~6 us), and ddram.sv
					// serves bursts before random writes, so a much higher
					// rate would only starve the writes.
					while (cfb_en || cfb_q.size() != 0) begin
						rt_read_busy({rows_c[k % 16], 9'h0}, 32);
						mem_cycles(1500 + $urandom() % 2500);
						k++;
					end
				end
			join
			$display("[%0t] phase 9: %0d framebuffer writes (%0d latched while ddram.sv was busy, %0d as a fill burst started; %0d paused MCLKs)",
			         $realtime, cfb_issued, cfb_latched_busy, cfb_latched_at_burst, cfb_paused);
			foreach (rows_w[i]) rt_read({rows_w[i], 9'h0}, 0, 512);
			if (cfb_latched_busy < 100) fail("phase 9 did not exercise writes latched while ddram.sv was busy");
			if (cfb_latched_at_burst < 5) fail("phase 9 did not exercise writes latched as a fill burst started");
			$display("[%0t] phase 9: framebuffer writes during bursts, errors=%0d", $realtime, errors - errors0);
		end

		// 10) VDL frame buffer hint: MADAM_AG.sv passes the frame buffer
		//     addresses a VDL entry loads ~7 us before the video DMA's first
		//     transfers from them. Those half-rows must then be in the cache
		//     and, in the SDRAM, completely filled (else the fill pauses
		//     MADAM past the start of the line); in the SRAM (no pause) the
		//     fill must be under way.
		begin
			bit [8:0] rows_h [6];
			int errors0, m0, h0, pf0, fill_cyc;
			errors0 = errors;
			rows_h = '{9'h0C0, 9'h0C2, 9'h0C4, 9'h0C6, 9'h0C8, 9'h0CA};
			// one fill (clk_mem cycles) from the memory these rows are in:
			// two hinted rows are fetched one after the other
			fill_cyc = !in_sram(rows_h[0]) ? 700 : sram_mode == 2'd1 ? 1600 : 1100;
			foreach (rows_h[i]) begin
				for (int w = 0; w < 512; w += 5) cpu_write({rows_h[i], 9'(w)}, $urandom(), $urandom());
				wait_idle();
				if (cache.find({rows_h[i], 1'b0})[4] || cache.find({rows_h[i], 1'b1})[4])
					fail($sformatf("phase 10: row %03h cached before the test", rows_h[i]));
			end
			// control: no hint, the first transfer misses
			m0 = st_misses;
			rt_read({rows_h[0], 9'h0}, 0, 320);
			if (st_misses != m0 + 1) fail("phase 10: transfer without a hint did not miss");
			// hint (current frame buffer only), then the transfer 7 us later
			h0 = st_hits; m0 = st_misses;
			vdl_hint({rows_h[1], 9'h0}, 1, '0, 0);
			mem_cycles(700);
			begin
				bit [4:0] f0, f1;
				f0 = cache.find({rows_h[1], 1'b0});
				f1 = cache.find({rows_h[1], 1'b1});
				// An SDRAM fill pauses the 3DO, so it must have ended before the
				// line. An SRAM fill pauses nothing and runs ahead of a line's
				// serial read-out (fill-rate check below): it must be under way.
				if (!f0[4] || (cache.filled[f0[3:0]] != 8'd128 &&
				               !(in_sram(rows_h[1]) && cache.fill_busy && cache.fill_e == f0[3:0] && cache.filled[f0[3:0]] != 0)))
					fail($sformatf("phase 10: hinted half-row %03h not %s 7 us after the hint", {rows_h[1], 1'b0},
					               in_sram(rows_h[1]) ? "filling" : "filled"));
				// only what the first line needs: the next half-row is
				// prefetched by the line's first transfer
				if (f1[4]) fail($sformatf("phase 10: half-row %03h fetched for the hint as well", {rows_h[1], 1'b1}));
			end
			rt_read({rows_h[1], 9'h0}, 0, 320);
			if (st_misses != m0) fail("phase 10: transfer after the hint missed");
			if (st_hits == h0) fail("phase 10: transfer after the hint did not hit");
			// current and previous frame buffers in different rows
			vdl_hint({rows_h[2], 9'h0}, 1, {rows_h[3], 9'h0}, 1);
			mem_cycles(2 * fill_cyc);
			if (!cache.find({rows_h[2], 1'b0})[4]) fail("phase 10: current frame buffer row not prefetched");
			if (!cache.find({rows_h[3], 1'b0})[4]) fail("phase 10: previous frame buffer row not prefetched");
			m0 = st_misses;
			rt_read({rows_h[3], 9'h0}, 0, 64);
			rt_read({rows_h[2], 9'h0}, 0, 64);
			if (st_misses != m0) fail("phase 10: transfer from a hinted row missed");
			// on-chip VRAM: no fill
			pf0 = st_pf;
			vdl_hint({9'h180, 9'h0}, 1, '0, 0);
			mem_cycles(1400);
			if (st_pf != pf0) fail("phase 10: hint for on-chip VRAM started a fill");
			// a hint in the same cycle as a transfer request is applied after it
			fork
				rt_read({rows_h[0], 9'h100}, 1, 32);
				begin
					@(posedge clk_mem iff vram_l.RT_REQ);
					vdl_hint({rows_h[4], 9'h0}, 1, {rows_h[5], 9'h0}, 1);
				end
			join
			mem_cycles(2 * fill_cyc);
			if (!cache.find({rows_h[4], 1'b0})[4] || !cache.find({rows_h[5], 1'b0})[4])
				fail("phase 10: hint during a transfer request was lost");
			rt_read({rows_h[4], 9'h0}, 0, 64);
			rt_read({rows_h[5], 9'h0}, 0, 64);
			// a hint right after transfer requests (the VDL entry's own CLUT
			// transfers come just before it) must not be held off like a
			// prefetch: its fill has to start at once to end before the line
			begin
				bit [8:0] rx;
				bit started;
				rx = 9'h0CC;
				for (int w = 0; w < 512; w += 9) cpu_write({rx, 9'(w)}, $urandom(), $urandom());
				wait_idle();
				started = 0;
				fork
					rt_read({rows_h[4], 9'h0}, 0, 32);
					begin
						@(posedge clk_mem iff vram_l.RT_REQ);
						mem_cycles(30);
						vdl_hint({rx, 9'h0}, 1, '0, 0);
						for (int k = 0; k < 50 && !started; k++) begin
							@(posedge clk_mem);
							if (cache.fill_issue && cache.fill_h == {rx, 1'b0}) started = 1;
						end
						if (!started) fail("phase 10: hinted fill held off after a transfer request");
					end
				join
				wait_idle();
				rt_read({rx, 9'h0}, 0, 64);
			end
			// start of a frame (vertical blanking): the first half-rows of
			// the last two frame buffers are fetched again
			begin
				bit [8:0] fa, fb;
				fa = 9'h0D0; fb = 9'h0D2;
				for (int w = 0; w < 512; w += 11) begin
					cpu_write({fa, 9'(w)}, $urandom(), $urandom());
					cpu_write({fb, 9'(w)}, $urandom(), $urandom());
				end
				wait_idle();
				vdl_hint({fa, 9'h0}, 1, '0, 0); mem_cycles(fill_cyc + 100);
				vdl_hint({fb, 9'h0}, 1, '0, 0); mem_cycles(fill_cyc + 100);
				if (!cache.find({fa, 1'b0})[4] || !cache.find({fb, 1'b0})[4])
					fail("phase 10: frame buffer rows not fetched for their hints");
				// other rows push them out of the cache
				for (int k = 0; k < 12; k++) rt_read({9'(9'h0E0 + 2 * k), 9'h0}, 0, 16);
				if (cache.find({fa, 1'b0})[4] || cache.find({fb, 1'b0})[4])
					fail("phase 10: frame buffer rows still cached, the vertical-blank test cannot work");
				// no requests for a while: no fetch without the frame start
				mem_cycles(6000);
				if (cache.find({fa, 1'b0})[4] || cache.find({fb, 1'b0})[4])
					fail("phase 10: frame buffer rows fetched again without a frame start");
				@(posedge clk_sys); frame <= 1;
				@(posedge clk_sys); @(posedge clk_sys); frame <= 0;
				mem_cycles(2 * fill_cyc);   // two fills
				if (!cache.find({fa, 1'b0})[4] || !cache.find({fb, 1'b0})[4])
					fail("phase 10: frame buffer rows not fetched again at the frame start");
				m0 = st_misses;
				rt_read({fa, 9'h0}, 0, 32);
				rt_read({fb, 9'h0}, 0, 32);
				if (st_misses != m0) fail("phase 10: first line after the frame start missed");
			end
			$display("[%0t] phase 10: VDL frame buffer hints (%0d), errors=%0d", $realtime, st_hints, errors - errors0);
		end

		// ---------------- phase 11: a line's two transfers apart ----------------
		// MADAM's video DMA issues a line's transfers to the two VRAM halves
		// one after the other (VID_PREV, VID_CURR, ~0.15 us apart). When the
		// first missed, its fill started at once and (in the core) paused the
		// 3DO before the second was issued, which then came after the start of
		// the line. While MADAM is in its video DMA sequence (vid_dma) the fill
		// now waits for the second request, at most 2 us. (a) Control, without
		// vid_dma: the fill starts before the second request, so the case is
		// exercised. (b) With vid_dma: it waits. (c) vid_dma stuck, second
		// request 2.5 us late: the fill starts 2 us after the miss. The data of
		// both halves is checked each time.
		begin
			bit [8:0] rx [3];
			int errors0;
			realtime t_l, t_r, t_fill;
			errors0 = errors;
			rx = '{9'h0D0, 9'h0D2, 9'h0D4};
			foreach (rx[i]) begin
				for (int w = 0; w < 512; w += 7) cpu_write({rx[i], 9'(w)}, $urandom(), $urandom());
				wait_idle();
				if (cache.find({rx[i], 1'b0})[4]) fail($sformatf("phase 11: row %03h cached before the test", rx[i]));
			end
			for (int c = 0; c < 3; c++) begin
				r_delay = (c == 2) ? 250 : 15;
				t_l = 0; t_r = 0; t_fill = 0;
				fork
					begin
						vid_dma = (c != 0);
						rt_read({rx[c], 9'h0}, 0, 64);
					end
					begin
						@(posedge clk_mem iff v_lrd);  t_l = $realtime;
					end
					begin
						@(posedge clk_mem iff v_rrd);  t_r = $realtime;
						mem_cycles(5);
						vid_dma = 0;              // MADAM leaves its video DMA sequence
					end
					begin
						@(posedge clk_mem iff (cache.fill_issue && cache.fill_h == {rx[c], 1'b0}));  t_fill = $realtime;
					end
				join
				if (c == 0 && !(t_fill < t_r))
					fail($sformatf("phase 11: control: the fill did not start before the second transfer (%0.2f / %0.2f us after the first)",
					               (t_fill - t_l) / 1000.0, (t_r - t_l) / 1000.0));
				if (c == 1 && t_fill < t_r)
					fail($sformatf("phase 11: the fill started %0.2f us after the line's first transfer, before its second (%0.2f us)",
					               (t_fill - t_l) / 1000.0, (t_r - t_l) / 1000.0));
				if (c == 2 && (t_fill >= t_r || t_fill - t_l < 1.9us || t_fill - t_l > 2.3us))
					fail($sformatf("phase 11: with the second transfer %0.2f us late the fill started after %0.2f us (expected ~2 us)",
					               (t_r - t_l) / 1000.0, (t_fill - t_l) / 1000.0));
				$display("[%0t] phase 11 (%s): second transfer +%0.2f us, fill +%0.2f us", $realtime,
				         c == 0 ? "control, no vid_dma" : c == 1 ? "vid_dma" : "vid_dma, second transfer late",
				         (t_r - t_l) / 1000.0, (t_fill - t_l) / 1000.0);
			end
			r_delay = 0;
			$display("[%0t] phase 11: a line's two transfers apart, errors=%0d", $realtime, errors - errors0);
		end

		// ---------------- phase 12: write transfers with the halves out of step ----------------
		// A frame buffer clear as games do it: the CPU's SPORT read transfer
		// of a source row, then write transfers into one row after another,
		// each issued as soon as MADAM may (held while a VRAM half is busy,
		// as PAUSE does in the core). The video DMA's transfers go to one
		// half at a time, so a half can still be busy with one when a write
		// transfer comes: the other half starts its write burst first.
		// ddram.sv serves a half's write burst in two passes of 128 beats
		// and serves the left half first, so a left burst can start between
		// the right half's two passes. It used to count that pass as the
		// second one and end the burst after it: the left module then waited
		// for the rest of its write transfer for ever (the core hung, paused),
		// and the right half's second pass was counted as a first one and a
		// third ran on into the next row.
		// (a) a video transfer to the left half before every write transfer
		// (the left half starts late), (b) to the right half, (c) none. The
		// destination rows and the row after each (a guard row nothing
		// writes) are flash-filled before and read back after, and every
		// transfer must end.
		begin
			bit [8:0] src, vid [2], dst [6];
			int errors0;
			errors0 = errors;
			src = 9'h140; vid = '{9'h150, 9'h152};
			foreach (dst[i]) dst[i] = 9'(9'h160 + 2 * i);
			for (int w = 0; w < 512; w += 3) cpu_write({src, 9'(w)}, $urandom(), $urandom());
			foreach (vid[i]) for (int w = 0; w < 512; w += 9) cpu_write({vid[i], 9'(w)}, $urandom(), $urandom());
			wait_idle();
			for (int c = 0; c < 3 && !paused_hung; c++) begin
				int lb0, rl0, n;
				lb0 = ph12_l_between; rl0 = ph12_r_during_l;
				foreach (dst[i]) begin
					flash_write(dst[i], 16'hD100 + 16'(c), 16'h2E00 + 16'(c));
					flash_write(9'(dst[i] + 1), 16'h5A00 + 16'(c), 16'hA500 + 16'(c));
				end
				cpu_rt(src);
				// the video rows' half-rows in the cache, so a video transfer
				// ends ~1.3 us after it starts (a miss would wait for the
				// write bursts to end)
				foreach (vid[i]) rt_read({vid[i], 9'h0}, 0, 0);
				n = 0;
				foreach (dst[i]) begin
					if (paused_hung) break;
					// a different half-row each time: a split transfer of the
					// half-row the video shift register holds is skipped
					if (c != 2) half_rt_paused(c == 1, {vid[i % 2], (i / 2) % 2 == 1, 8'h00});
					if (paused_hung) break;
					cpu_mwt_paused(dst[i]);
					n++;
				end
				if (!paused_hung) wait_idle();
				if (vram_l.MWT_EXEC || vram_r.MWT_EXEC || vram_l.RT_EXEC || vram_r.RT_EXEC) begin
					fail($sformatf("phase 12 (%s): a transfer never ended (left MWT %b RT %b, right MWT %b RT %b)",
					               c == 0 ? "left half late" : c == 1 ? "right half late" : "in step",
					               vram_l.MWT_EXEC, vram_l.RT_EXEC, vram_r.MWT_EXEC, vram_r.RT_EXEC));
					paused_hung = 1;
				end
				if (paused_hung) break;
				foreach (dst[i]) begin
					rt_read({dst[i], 9'h0}, 0, 512);
					rt_read({9'(dst[i] + 1), 9'h0}, 0, 512);
				end
				$display("[%0t] phase 12 (%s): %0d write transfers; left bursts started between the right half's passes %0d, right bursts latched during a left one %0d",
				         $realtime, c == 0 ? "left half late" : c == 1 ? "right half late" : "in step", n,
				         ph12_l_between - lb0, ph12_r_during_l - rl0);
				if (c == 0 && ph12_l_between == lb0)
					fail("phase 12: no left write burst started between the right half's two passes (case not exercised)");
				if (c == 1 && ph12_r_during_l == rl0)
					fail("phase 12: no right write burst latched during a left one (case not exercised)");
			end
			$display("[%0t] phase 12: write transfers with the halves out of step, errors=%0d", $realtime, errors - errors0);
		end

		// ---------------- phase 13: write masks; split transfers after writes ----------------
		// The CPU's write transfers (SPORT copies) and flash writes take a
		// write mask, one per VRAM half: 1 bits are written, 0 bits keep the
		// row's (US 5,502,462). The core ignored it: a zero or partial mask
		// overwrote the whole row. For a row in each memory (on-chip, SRAM,
		// SDRAM): copies and flash writes with partial masks, no bits, all
		// bits, and different masks in the two halves, each followed by a
		// read-back of every word of the row and of the next (guard) row.
		// Then split transfers: the half-row the video shift register holds
		// is not transferred again (MiSTer core); a flash write, a masked
		// copy or a random write into that half must make its next split
		// transfer reload it, and a write into the other half must not.
		begin
			bit [8:0] srcs [3], dsts [3];
			int errors0;
			errors0 = errors;
			srcs = '{9'h188, 9'h040, 9'h1A0};   // on-chip (BRAM1 window), SRAM (SDRAM with it off), SDRAM
			dsts = '{9'h18A, 9'h042, 9'h1A2};
			for (int k = 0; k < 3; k++) begin
				bit [8:0] s, d;
				string mem;
				int e0, mrd0, rmw0, lazy0, fwm0, n0;
				s = srcs[k]; d = dsts[k];
				mem = on_chip({d, 9'h0}) ? "on-chip" : in_sram(d) ? "SRAM" : "SDRAM";
				if ((k == 0) != on_chip({d, 9'h0}) || (k == 1 && sram_mode != 2'd2 && !in_sram(d)) || (k == 2 && in_sram(d)))
					fail($sformatf("phase 13: row %03h is not in the memory the test needs (%s)", d, mem));
				e0 = errors; mrd0 = n_mrd; rmw0 = n_rmw; lazy0 = n_lazy; fwm0 = n_fwm;
				// every word of the source and destination rows its own
				flash_write(9'(d + 1), 16'hC3C3, 16'h3C3C);
				for (int w = 0; w < 512; w++) begin
					pin_write({s, 9'(w)}, $urandom(), $urandom());
					pin_write({d, 9'(w)}, $urandom(), $urandom());
				end
				wait_idle();
				// copies and flash writes, each read back (row and guard row)
				for (int op = 0; op < 12; op++) begin
					int e1;
					string what;
					e1 = errors;
					case (op)
						0:  begin
						        int pf0;
						        // the destination row's read is not for the display: no prefetch
						        cpu_rt(s); mem_cycles(400); wait_idle();
						        pf0 = st_pf;
						        cpu_mwt(d, 16'h00FF, 16'h0F0F); mem_cycles(400); wait_idle();
						        if (st_pf != pf0) fail($sformatf("phase 13 (%s): the masked copy's destination-row read started %0d prefetches", mem, st_pf - pf0));
						        what = "copy, masks 00FF/0F0F";
						    end
						1:  begin cpu_rt(s); cpu_mwt(d, 16'h0000, 16'h0000); what = "copy, masks 0000/0000"; end
						2:  begin flash_write(d, 16'h1234, 16'h5678, 16'hF0F0, 16'hFF00); what = "flash, masks F0F0/FF00"; end
						3:  begin flash_write(d, 16'h9ABC, 16'hDEF0, 16'h0000, 16'h0000); what = "flash, masks 0000/0000"; end
						4:  begin cpu_rt(s); cpu_mwt(d, 16'hFFFF, 16'h3C3C); what = "copy, masks FFFF/3C3C"; end
						5:  begin flash_write(d, 16'h2468, 16'h1357, 16'hFFFF, 16'h0000); what = "flash, masks FFFF/0000"; end
						6:  begin flash_write(d, 16'h7531, 16'h8642, 16'h0000, 16'hFFFF); what = "flash, masks 0000/FFFF"; end
						7:  begin cpu_rt(s); cpu_mwt(d, 16'h0000, 16'hA5A5); what = "copy, masks 0000/A5A5"; end
						8:  begin flash_write(d, 16'h0F1E, 16'h2D3C, 16'h5555, 16'hFFFF); what = "flash, masks 5555/FFFF"; end
						9:  begin rt_read({s, 9'h0}, 0, 0); mwt(d, 16'h33CC, 16'hFFFF); what = "video write transfer, masks 33CC/FFFF"; end
						10: begin flash_write(d, 16'h4B4B, 16'hB4B4); what = "flash, masks FFFF/FFFF"; end
						default: begin cpu_rt(s); cpu_mwt(d); what = "copy, masks FFFF/FFFF"; end
					endcase
					rt_read({d, 9'h0}, 0, 512);
					rt_read({9'(d + 1), 9'h0}, 0, 512);
					if (errors != e1) $display("[%0t] phase 13 (%s): %s: %0d mismatches", $realtime, mem, what, errors - e1);
				end
				// the way each memory carries them out
				if (k == 0 && (n_rmw == rmw0 || n_mrd != mrd0 || n_lazy != lazy0 || n_fwm != fwm0))
					fail($sformatf("phase 13 (on-chip): merged writes %0d, row reads %0d, lazy fills %0d, colour bursts %0d (expected merged writes only)",
					               n_rmw - rmw0, n_mrd - mrd0, n_lazy - lazy0, n_fwm - fwm0));
				if (k != 0 && (n_mrd == mrd0 || n_fwm == fwm0 || n_lazy == lazy0 || n_rmw != rmw0))
					fail($sformatf("phase 13 (%s): row reads %0d, colour bursts %0d, lazy fills %0d, merged on-chip writes %0d (expected all but the last)",
					               mem, n_mrd - mrd0, n_fwm - fwm0, n_lazy - lazy0, n_rmw - rmw0));
				$display("[%0t] phase 13 (%s): masked copies and flash writes, errors=%0d (row reads %0d, merged on-chip writes %0d, lazy fills %0d, colour bursts %0d)",
				         $realtime, mem, errors - e0, n_mrd - mrd0, n_rmw - rmw0, n_lazy - lazy0, n_fwm - fwm0);

				// split transfers after writes into the half-row the video
				// shift register holds (the lower one: the transfer started
				// at column 0); 256 words read out, so the upper half is the
				// one being shifted out and the lower one the inactive half
				e0 = errors;
				for (int c = 0; c < 5; c++) begin
					string what;
					bit reload;
					rt_read({d, 9'h000}, 0, 256);
					n0 = n_rt_l;
					rt_read({d, 9'h000}, 1, 0);
					if (n_rt_l != n0) fail($sformatf("phase 13 (%s): split transfer of the half-row the video shift register holds was not skipped", mem));
					rt_read({d, 9'h000}, 0, 256);
					reload = 1;
					case (c)
						0: begin flash_write(d, 16'h1357, 16'h2468); what = "flash write"; end
						1: begin flash_write(d, 16'hE1E1, 16'h1E1E, 16'h0FF0, 16'hF00F); what = "masked flash write"; end
						2: begin cpu_rt(s); cpu_mwt(d, 16'hFF00, 16'h00FF); what = "masked copy"; end
						3: begin pin_write({d, 9'h013}, 16'hBEEF, 16'hF00D); what = "random write"; end
						default: begin pin_write({d, 9'h1F3}, 16'hCAFE, 16'hD00D); what = "random write into the other half"; reload = 0; end
					endcase
					n0 = n_rt_l;
					rt_read({d, 9'h000}, 1, 512);
					if (reload && n_rt_l == n0) fail($sformatf("phase 13 (%s): split transfer after a %s into its half-row was skipped", mem, what));
					if (!reload && n_rt_l != n0) fail($sformatf("phase 13 (%s): split transfer was not skipped after a %s", mem, what));
				end
				$display("[%0t] phase 13 (%s): split transfers after writes, errors=%0d", $realtime, mem, errors - e0);
			end
			$display("[%0t] phase 13: write masks, split transfers after writes, errors=%0d", $realtime, errors - errors0);
		end

		$display("tb_rtcache: %0d words checked, hits %0d misses %0d prefetches %0d invalidations %0d",
		         checks, st_hits, st_misses, st_pf, st_inv);
		$display("tb_rtcache: read-transfer fills: %0d from the SDRAM (longest %0.2f us), %0d from the SRAM (longest %0.2f us)",
		         fr_n[0], fr_max[0], fr_n[1], fr_max[1]);
		if (sram_mode != 2'd2 && fr_n[1] == 0) fail("no read-transfer fill came from the SRAM");
		$display("tb_rtcache: TB errors=%0d, SDRAM model errors=%0d, SRAM model errors=%0d (%0d SRAM writes)",
		         errors, model.errors, sram.errors, sram.writes);
		if (sram_mode != 2 && sram.writes == 0) fail("no VRAM write reached the SRAM");
		if (sram_mode == 2 && sram.writes != 0) fail("VRAM writes reached the SRAM with it off");
		// a failure ends with a non-zero exit status ($fatal), so scripts see it
		if (errors == 0 && model.errors == 0 && sram.errors == 0 && st_inv > 0) begin $display("tb_rtcache: PASS"); $finish; end
		else $fatal(1, "tb_rtcache: FAIL");
	end

	initial begin
		#80ms;
		$display("tb_rtcache: TIMEOUT");
		$fatal(1, "tb_rtcache: FAIL");
	end
endmodule
