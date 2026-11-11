// Video transfer deadline under SDRAM secondary-port traffic.
//
// Every secondary-port transfer pauses the 3DO while the scanout goes on.
// A line's video transfers (MADAM_SPORT's VIDOUT_REQ at HCOUNT 1469, bus
// states VID_PREV1 and VID_CURR1) must be on the bus before the scanout of
// the line starts (VIDEO_TRANS_EXEC, HCOUNT 9), about 4.4 us later; a
// 512-word transfer takes 5.6 us, and short transfers back to back keep
// the 3DO paused just as long (audit 2026-11-10: 2- and 4-word requests
// with no gap, 64-word ones with gaps up to 20 cycles). vid_sec_guard.sv
// and sec_arb.sv start no transfer while MADAM_SPORT's VID_GUARD is high,
// unless the 3DO is stalled for something else.
//
// Real RTL: CLIO_VIDEO, VE, MADAM_SPORT, MADAM_ARB, sec_arb, vid_sec_guard,
// sdram_3do and the SDRAM model; the 3DO pause is p3do_gamebub's PAUSE logic
// (pause on the secondary port's hold or on a stall). Client 0 of sec_arb
// issues long transfers (the role of the video cache fills, CD and host
// blocks), client 1 short ones (host words, short CD or cache requests).
// The CPU and CEL engine are not present. Based on the probes of the video
// pressure audits (2026-11-09, 2026-11-10).
//
// Every line is checked (both transfers before its scanout), and no
// transfer may start while VID_GUARD has been high for longer than the
// guard's own latency, except during a stall. Phases:
//  1. long transfers (64, 256, 512 words, read and write) requested at
//     HCOUNTs from well before the guard to after the scanout start: no
//     line late, every transfer done within 16 us of its request;
//  2. streams of short transfers (2, 4, 64 words) back to back, 0 to 40
//     clk_mem cycles apart, from before the guard through two lines: no
//     line late, the stream goes on outside the guards;
//  3. a stall (the 3DO paused for a VRAM access waiting in ddram.sv or the
//     cache, which may need a secondary-port transfer) inside the guard: a
//     long or short transfer requested then starts within 0.5 us. The test
//     holds the stall for the whole transfer, so MADAM is paused through the
//     line's request and those lines are late by construction: they are
//     counted separately and are not guard failures (the guard does not
//     hold back a transfer the 3DO may be waiting for).
// +no_guard ties sec_arb's hold low (the RTL before the guard): phases 1
// and 2 must then find late lines (the audits' 512 words at HCOUNT 1460,
// short streams with no gap), which shows the check detects the failure.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
`include "3DO_pkg.svh"
import P3DO_PKG::*;

module tb_vidguard;
	bit clk = 0, mem = 0, vid = 0, sclk = 0, rst = 1;
	always #10 clk = ~clk;                  // clk_sys 50 MHz
	always #5 mem = ~mem;                   // clk_mem 100 MHz, aligned
	always #10.191 vid = ~vid;
	always @(mem) sclk <= #1.875 mem;
	int pal = 1, no_guard = 0, errors = 0;
	initial begin
		void'($value$plusargs("pal=%d", pal));
		if ($test$plusargs("no_guard")) no_guard = 1;
	end
	task automatic fail(string s);
		errors++;
		if (errors <= 30) $display("[%0t] TB ERROR: %s", $realtime, s);
	endtask

	wire vce;
	ce_gen vce_gen(.CLK(clk), .RST_N(~rst), .CE(vce));

	// p3do_gamebub: CE_R/CE_F, PAUSE, sec_hold_s / sec_paused
	bit div = 0;
	always @(posedge clk) div <= ~div;
	wire CE_R = div, CE_F = ~div;
	bit  pause = 0, sec_paused = 0, sec_hold_s = 0, stall = 0;
	wire sec_hold;
	always @(posedge clk) sec_hold_s <= sec_hold;
	always @(posedge clk) begin
		if (CE_F) begin
			pause      <= stall || sec_hold_s;
			sec_paused <= sec_hold_s;
		end
		if (!sec_hold_s) sec_paused <= 0;
	end
	wire ce_r = CE_R && !pause, ce_f = CE_F && !pause;

	wire hs, vs, pcsc; wire [10:0] hc; wire [8:0] vc;
	wire [23:0] ad; wire de;
	CLIO_VIDEO cv(.CLK(clk), .RST_N(~rst), .EN(1'b1), .PAL(pal[0]),
		.VCE(vce), .HSYNC_N(hs), .VSYNC_N(vs), .HCNT(hc), .VCNT(vc), .FLD(),
		.S(32'b0), .LSC_N(1'b1), .RSC_N(1'b1), .PCSC(pcsc), .AD(ad), .DE(de),
		.HINTREPOL_DISABLE(1'b1), .VINTREPOL_DISABLE(1'b1), .DBG_EXT(8'b0));
	VE ve(.MCLK(clk), .VCLK(vid), .RST_N(~rst), .EN(1'b1), .PAL(pal[0]),
		.VCE(vce), .AD(ad), .DE(de), .HSYNC_N(hs), .VSYNC_N(vs), .RGB(),
		.HS_N(), .VS_N(), .HBLK_N(), .VBLK_N(), .DCLK(), .DBG_EXT(8'b0),
		.DBG_BORD_DIS(1'b0), .DBG_HS_START(), .DBG_HS_END());

	wire ph1, ph2, vreq, vack, midack, sg, clreq, clack, midreq, midcurr, midfirst, vid_guard;
	AddrGenCtl_t sportctl;
	BusState_t   bus_state;
	bit          setup_vdl = 0;
	CLUTCtrl_t   control;
	always_comb begin control = '0; control.LINE = 9'd511; control.ENVIDDMA = 1; end
	MADAM_SPORT sport(.CLK(clk), .RST_N(~rst), .EN(1'b1), .CE_R(ce_r), .CE_F(ce_f),
		.MDTI(control), .BUS_STATE(setup_vdl ? CLUT_CTRL1 : bus_state), .GRANT(sg),
		.AG_CTL(sportctl), .LINE0(), .LMIDLINE_REQ(1'b0), .RMIDLINE_REQ(1'b0),
		.CLUTXEN(1'b0), .VSCTXEN(1'b1), .CLUTWR_REQ(clreq), .CLUTWR_ACK(clack),
		.CLUTWR_FORCE(1'b0), .VIDOUT_REQ(vreq), .VIDOUT_PFL(1'b0), .VIDMID_REQ(midreq),
		.VIDMID_CURR(midcurr), .VIDMID_FIRST(midfirst), .VIDOUT_ACK(vack), .VIDMID_ACK(midack),
		.VCE(vce), .PCSC(pcsc), .LSC(), .RSC(), .FIELD(), .V480(), .VID_GUARD(vid_guard));
	MADAM_ARB arb(.CLK(clk), .RST_N(~rst), .EN(1'b1), .CE_R(ce_r), .CE_F(ce_f),
		.PHASE1(ph1), .PHASE2(ph2), .CPU_GRANT(), .CPU_READY(1'b1), .CPU_AG_CTL('0),
		.PBI(1'b0), .CLIO_REQ(1'b0), .EXTP_REQ(1'b0), .EXTP_ACK(), .EXTP_GRANT(),
		.EXTP_AG_CTL('0), .EXTP_NEXT('0), .SCOBLD_REQ('0), .SCOB_SEL('0),
		.SPRDATA_REQ('0), .SPR_SEL('0), .SPRDRAW_REQ(1'b0), .CFB_SEL('0),
		.CFB_SUSPEND(), .SPRPAUS_REQ(1'b0), .SPREND_REQ(1'b0), .SE_ACK(),
		.SE_GRANT(), .SE_AG_CTL('0), .CLUTWR_REQ(clreq), .CLUTWR_ACK(clack),
		.VIDOUT_REQ(vreq), .VIDMID_REQ(midreq), .VIDMID_CURR(midcurr),
		.VIDMID_FIRST(midfirst), .VIDOUT_ACK(vack), .VIDMID_ACK(midack), .SPORT_GRANT(sg),
		.SPORT_AG_CTL(sportctl), .PLAYER_REQ(1'b0), .REFRESH_REQ(1'b0),
		.PLAYER_GRANT(), .PLAYER_AG_CTL('0), .BUS_STATE(bus_state), .BUS_PB(),
		.DMA_CTL(), .DBG_EXT('0));

	// Secondary port: guard, arbiter, SDRAM controller and model
	wire vhold;
	vid_sec_guard vsg(.clk_sys(clk), .vid_guard(vid_guard), .reset_3do(rst), .stall(stall),
		.clk_mem(mem), .rst_mem(rst), .hold(vhold));

	bit  [1:0] c_req = '0, c_we = '0;
	bit  [9:0] long_len = 10'd512, short_len = 10'd4;
	wire [1:0] c_done, c_wnext, c_rvalid;
	wire       m_req, m_we, m_wnext, m_rvalid, m_done;
	wire [23:0] m_addr; wire [9:0] m_len; wire [15:0] m_wdata, m_rdata; wire [1:0] m_wbe;
	sec_arb #(.N(2)) sarb(.clk(mem), .rst(rst), .hold(no_guard ? 1'b0 : vhold),
		.c_req(c_req), .c_we(c_we), .c_addr('{24'h800000, 24'h810000}), .c_len('{long_len, short_len}),
		.c_wdata('{16'hA55A, 16'h5AA5}), .c_wbe('{2'b11, 2'b11}), .c_wnext(c_wnext), .c_rdata(),
		.c_rvalid(c_rvalid), .c_done(c_done),
		.m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_len(m_len), .m_wdata(m_wdata), .m_wbe(m_wbe),
		.m_wnext(m_wnext), .m_rdata(m_rdata), .m_rvalid(m_rvalid), .m_done(m_done));

	wire init_done;
	wire sc, cke, cs, ras, cas, we, oe; wire [1:0] dqm, ba; wire [12:0] a;
	wire [15:0] dq_out, dq_in;
	sdram_3do #(.POWERUP_US(2)) ram(.clk(mem), .clk_sdram(sclk), .rst(rst),
		.SDRAM_CLK(sc), .SDRAM_CKE(cke), .SDRAM_nCS(cs), .SDRAM_nRAS(ras),
		.SDRAM_nCAS(cas), .SDRAM_nWE(we), .SDRAM_DQM(dqm), .SDRAM_BA(ba),
		.SDRAM_A(a), .SDRAM_DQ_IN(dq_in), .SDRAM_DQ_OUT(dq_out), .SDRAM_DQ_OE(oe),
		.init_done(init_done), .sync(ph1), .laddr('0), .lwe('0), .lras(1'b0), .lcode('0),
		.raddr('0), .rwe('0), .rras(1'b0), .rcode('0), .din('0), .dout(),
		.CORE_RST(1'b0), .SEC_PAUSED(sec_paused), .SEC_HOLD(sec_hold),
		.sec_req(m_req), .sec_we(m_we), .sec_addr(m_addr), .sec_len(m_len),
		.sec_wdata(m_wdata), .sec_wbe(m_wbe), .sec_wnext(m_wnext), .sec_rdata(m_rdata),
		.sec_rvalid(m_rvalid), .sec_done(m_done));
	sdram_model model(.clk(sc), .cke(cke), .cs_n(cs), .ras_n(ras), .cas_n(cas),
		.we_n(we), .dqm(dqm), .ba(ba), .a(a), .dq_from_fpga(dq_out),
		.dq_oe_fpga(oe), .dq_to_fpga(dq_in));

	// Line check: armed at the line's scheduled request (VIDEO_TRANS_PEND,
	// HCOUNT 1469, on the dot clock, not stopped by the pause), so a line
	// whose VIDOUT_REQ the pause delays past its scanout is checked too.
	bit armed = 0, prev_seen = 0, curr_seen = 0, exec_d = 0, pend_d = 0, measure = 0, stalled = 0;
	int lines = 0, late = 0, late_stalled = 0;
	realtime curr_t = 0;   // last VID_CURR1
	always @(posedge clk) begin
		if (sport.VIDEO_TRANS_PEND && !pend_d) begin armed = 1; prev_seen = 0; curr_seen = 0; stalled = 0; end
		if (stall) stalled = 1;
		if (ce_r && sport.BUS_STATE_FF == VID_PREV1) prev_seen = 1;
		if (ce_r && sport.BUS_STATE_FF == VID_CURR1) begin curr_seen = 1; curr_t = $realtime; end
		if (sport.VIDEO_TRANS_EXEC && !exec_d && armed) begin
			armed = 0;
			if (measure) begin
				lines++;
				if (!prev_seen || !curr_seen) begin
					if (stalled) late_stalled++;
					else begin
						late++;
						if (!no_guard) fail($sformatf("line %0d: scanout started before its video transfers (prev %b curr %b)",
						                              sport.VCOUNT, prev_seen, curr_seen));
					end
				end
			end
		end
		exec_d  <= sport.VIDEO_TRANS_EXEC;
		pend_d  <= sport.VIDEO_TRANS_PEND;
	end

	// Grant (start) time of client 0's and client 1's transfers: the first
	// cycle sdram_3do sees the request (sec_req passes the arbiter)
	realtime start_t [2];
	bit      started [2];
	always @(posedge mem) for (int i = 0; i < 2; i++)
		if (c_req[i] && !started[i] && m_req && sarb.sel == 1'(i)) begin started[i] = 1; start_t[i] = $realtime; end

	// No transfer may start while VID_GUARD has been high for more than the
	// guard's own latency (4 clk_sys cycles: VID_GUARD -> defer -> hold ->
	// arbiter), unless the 3DO is stalled for something else.
	int guard_cyc = 0, stall_cyc = 0, starts = 0, starts_in_guard = 0;
	bit m_req_d = 0;
	always @(posedge clk) begin
		guard_cyc = vid_guard ? guard_cyc + 1 : 0;
		stall_cyc = stall ? 8 : (stall_cyc ? stall_cyc - 1 : 0);
	end
	always @(posedge mem) begin
		if (m_req && !m_req_d) begin
			starts++;
			if (guard_cyc > 4 && stall_cyc == 0) begin
				starts_in_guard++;
				if (!no_guard) fail($sformatf("%0d-word transfer started %0d clk_sys cycles into the video guard", m_len, guard_cyc));
			end
		end
		m_req_d <= m_req;
	end

	task automatic wait_h(input int h);
		do @(posedge clk); while (!(vce && sport.HCOUNT == 11'(h)));
	endtask

	// One transfer on client c, requested now; returns request-to-start and
	// request-to-done times (ns)
	task automatic xfer(input int c, input bit wr, output realtime t_start, output realtime t_done);
		realtime t0;
		@(negedge mem);
		started[c] = 0;
		c_we[c] = wr; c_req[c] = 1; t0 = $realtime;
		while (!c_done[c] && $realtime - t0 < 40us) @(posedge mem);
		if (!c_done[c]) fail($sformatf("client %0d transfer not done 40 us after its request", c));
		@(negedge mem); c_req[c] = 0;
		t_start = started[c] ? start_t[c] - t0 : -1;
		t_done  = $realtime - t0;
	endtask

	int n_xfer = 0;
	bit stream_on = 0;
	initial begin
		int words [3] = '{64, 256, 512};
		int aligns [12] = '{1150, 1250, 1300, 1320, 1328, 1340, 1400, 1440, 1460, 1490, 1520, 50};
		int late_512_1460 = 0;
		realtime ts, td, max_done = 0;
		#1000; rst = 0;
		wait (init_done);
		wait (vc == 60 && hc > 100);
		@(negedge clk); setup_vdl = 1;
		repeat (20) @(negedge clk);
		setup_vdl = 0;
		wait (sport.ENVIDDMA);
		wait_h(100);
		measure = 1;

		// 1. long transfers at every alignment
		foreach (words[w]) for (int wr = 0; wr < 2; wr++) foreach (aligns[k]) begin
			int late0;
			late0 = late;
			long_len = 10'(words[w]);
			repeat (2) begin
				wait_h(aligns[k]);
				xfer(0, wr[0], ts, td);
				n_xfer++;
				if (td > max_done) max_done = td;
				if (td > 16us) fail($sformatf("%0d-word transfer at HCOUNT %0d done %0.2f us after its request", words[w], aligns[k], td / 1us));
				wait_h(100);
			end
			if (words[w] == 512 && aligns[k] == 1460) late_512_1460 += late - late0;
			if (late != late0) $display("phase 1: %0d words %s at HCOUNT %0d: %0d of 2 lines late", words[w], wr ? "write" : "read", aligns[k], late - late0);
		end
		$display("phase 1: %0d transfer starts, %0d of them inside the video guard", starts, starts_in_guard);
		$display("phase 1: %0d long transfers, slowest done %0.2f us after its request, %0d lines checked, %0d late (512 words at HCOUNT 1460: %0d of 4)",
		         n_xfer, max_done / 1us, lines, late, late_512_1460);
		if (no_guard && late_512_1460 == 0) fail("+no_guard: no late line with 512-word transfers at HCOUNT 1460 (the check does not see the failure)");

		// 2. streams of short transfers back to back through two lines
		begin
			int lens [3] = '{2, 4, 64};
			int gaps [4] = '{0, 10, 20, 40};
			int late0, late_nogap, n_done, n_in;
			realtime ts, td, max_start;
			late_nogap = 0;
			foreach (lens[li]) foreach (gaps[gi]) begin
				late0 = late; n_done = 0; max_start = 0;
				short_len = 10'(lens[li]);
				wait_h(1250);
				stream_on = 1;
				fork
					while (stream_on) begin
						xfer(1, n_done[0], ts, td);
						n_done++;
						if (ts > max_start) max_start = ts;
						repeat (gaps[gi]) @(posedge mem);
					end
					begin
						repeat (2) begin wait (sport.VIDEO_TRANS_EXEC); wait (!sport.VIDEO_TRANS_EXEC); end
						wait_h(100);
						stream_on = 0;
					end
				join
				if (lens[li] <= 4 && gaps[gi] == 0) late_nogap += late - late0;
				$display("phase 2: %0d-word transfers %0d cycles apart: %0d done, longest wait %0.2f us, %0d of 2 lines late",
				         lens[li], gaps[gi], n_done, max_start / 1us, late - late0);
				if (max_start > 16us) fail($sformatf("phase 2: a %0d-word transfer waited %0.2f us", lens[li], max_start / 1us));
				wait_h(100);
			end
			if (no_guard && late_nogap == 0) fail("+no_guard: no late line with short transfers back to back (the check does not see the failure)");
		end

		// 3. a stall inside the guard: transfers are not held back
		if (!no_guard) begin
			realtime ts, td;
			long_len = 10'd512; short_len = 10'd4;
			for (int h = 1340; h <= 1500; h += 40) for (int c = 0; c < 2; c++) begin
				wait_h(h);
				@(negedge clk); stall = 1;
				repeat (4) @(posedge clk);
				xfer(c, 1'b0, ts, td);
				@(negedge clk); stall = 0;
				if (ts < 0 || ts > 500) fail($sformatf("%s transfer during a stall at HCOUNT %0d started %0.2f us after its request",
				                                       c ? "short" : "long", h, ts / 1us));
				wait_h(100);
			end
			$display("phase 3: transfers during a stall started at once; %0d lines late with the 3DO stalled through the request (by construction, not guard failures)",
			         late_stalled);
		end

		wait_h(200);
		$display("tb_vidguard%s: %0d lines checked, %0d late (and %0d late with the 3DO stalled), %0d transfer starts inside the guard, SDRAM model errors %0d, %0d errors",
		         no_guard ? " +no_guard" : "", lines, late, late_stalled, starts_in_guard, model.errors, errors);
		if (model.errors != 0) fail("SDRAM model errors");
		if (errors != 0) $fatal(1, "tb_vidguard: FAIL");
		if (no_guard) $display("tb_vidguard +no_guard: PASS (without the guard the check finds the late lines)");
		else $display("tb_vidguard: PASS");
		$finish;
	end
	initial begin #800ms; $fatal(1, "tb_vidguard: timeout"); end
endmodule
