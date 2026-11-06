// Testbench: VRAM read-transfer cache (vram_rtcache) coherence and data path.
//
// Real modules: two P3DO_VRAM (left/right halves, external path only),
// vram_rtcache, ddram.sv, ddr_bridge, sdram_3do and the SDRAM model. A
// bus-functional model drives the VRAM pins the way MADAM does for:
//   * read transfers (RT, full and split) followed by serial read-out (SC/SQ)
//   * random CPU writes (ddram.sv's posted write port)
//   * write transfers (MWT, shift register -> row: SPORT row copy)
//   * flash writes (FW, colour register -> whole row)
// and checks every word shifted out against a reference model of VRAM. The
// important cases write to rows that are already in the cache.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_rtcache;
	reg clk_mem = 0, clk_sys = 0;
	always #5  clk_mem = ~clk_mem;
	always #10 clk_sys = ~clk_sys;
	reg rst = 1;

	localparam [3:0] BRAM1_OFFS = 4'hC;   // on-chip block at 0xC0000: test rows below it

	// ---------------- VRAM pins (both halves driven alike) ----------------
	reg  [17:0] A = 0;
	reg  [15:0] DL = 0, DR = 0;
	reg         RAS_N = 1, CAS_N = 1, OE_N = 1, DSF1 = 0, SC = 0;
	reg  [ 1:0] WE_N = 2'b11;
	wire [15:0] SQL, SQR;
	wire        RDYL, RDYR;

	wire [17:0] v_laddr, v_raddr;
	wire        v_lwr, v_rwr, v_lrd, v_rrd, v_lfw;
	wire        v_lte, v_rte;
	wire [31:0] v_lq, v_rq, bldata, brdata;

	P3DO_VRAM #(0) vram_l (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~rst),
		.A(A), .D(DL), .Q(), .RAS_N(RAS_N), .CAS_N(CAS_N), .WE_N(WE_N), .OE_N(OE_N), .DSF1(DSF1),
		.SC(SC), .SE_N(1'b0), .SQ(SQL), .QSF(), .RDY(RDYL),
		.EQ(16'h0), .ESADDR(v_laddr), .ESDATA(bldata), .ESWR(v_lwr), .ESRD(v_lrd), .ESFW(v_lfw),
		.ESQ(v_lq), .ESTE(v_lte),
		.BRAM4_OFFS(4'h0), .BRAM2_OFFS(4'h4), .BRAM1_OFFS(BRAM1_OFFS), .DBG_WAIT_CNT()
	);
	P3DO_VRAM #(0) vram_r (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~rst),
		.A(A), .D(DR), .Q(), .RAS_N(RAS_N), .CAS_N(CAS_N), .WE_N(WE_N), .OE_N(OE_N), .DSF1(DSF1),
		.SC(SC), .SE_N(1'b0), .SQ(SQR), .QSF(), .RDY(RDYR),
		.EQ(16'h0), .ESADDR(v_raddr), .ESDATA(brdata), .ESWR(v_rwr), .ESRD(v_rrd), .ESFW(),
		.ESQ(v_rq), .ESTE(v_rte),
		.BRAM4_OFFS(4'h0), .BRAM2_OFFS(4'h4), .BRAM1_OFFS(BRAM1_OFFS), .DBG_WAIT_CNT()
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
	wire [31:0] st_hits, st_misses, st_pf, st_inv;

	vram_rtcache #(.ENTRIES(16)) cache (
		.clk(clk_mem), .rst(rst), .BRAM1_OFFS(BRAM1_OFFS),
		.l_esrd(v_lrd), .l_esaddr(v_laddr), .l_eswr(v_lwr), .l_esfw(v_lfw), .l_este(v_lte), .l_esq(v_lq),
		.r_esrd(v_rrd), .r_esaddr(v_raddr), .r_eswr(v_rwr), .r_este(v_rte), .r_esq(v_rq),
		.d_bladdr(ddr_bladdr), .d_blrd(ddr_blrd), .d_blwr(ddr_blwr), .d_bfw(ddr_bfw),
		.d_braddr(ddr_braddr), .d_brrd(ddr_brrd), .d_brwr(ddr_brwr),
		.d_blte(ddr_blte), .d_brte(ddr_brte), .d_bout(ddr_bout), .d_ba(ddr_ba), .d_bbusy(ddr_bbusy),
		.ddr_we(DDRAM_WE && !DDRAM_BUSY), .ddr_addr(DDRAM_ADDR),
		.stat_hits(st_hits), .stat_misses(st_misses), .stat_prefetches(st_pf), .stat_invalidations(st_inv)
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

	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;

	sdram_3do #(.POWERUP_US(2)) sdram (
		.clk(clk_mem), .rst(rst),
		.SDRAM_CLK(s_clk), .SDRAM_CKE(s_cke), .SDRAM_nCS(s_cs), .SDRAM_nRAS(s_ras), .SDRAM_nCAS(s_cas),
		.SDRAM_nWE(s_we), .SDRAM_DQM(s_dqm), .SDRAM_BA(s_ba), .SDRAM_A(s_a),
		.SDRAM_DQ_IN(s_dq_in), .SDRAM_DQ_OUT(s_dq_out), .SDRAM_DQ_OE(s_oe), .init_done(init_done),
		.sync(1'b0), .laddr('0), .lwe('0), .lras(1'b0), .lcode('0), .raddr('0), .rwe('0), .rras(1'b0),
		.rcode('0), .din('0), .dout(),
		.CORE_RST(1'b1), .SEC_PAUSED(1'b0), .SEC_HOLD(),
		.sec_req(sec_req), .sec_we(sec_we), .sec_addr(sec_addr), .sec_len(sec_len),
		.sec_wdata(sec_wdata), .sec_wbe(sec_wbe), .sec_wnext(sec_wnext),
		.sec_rdata(sec_rdata), .sec_rvalid(sec_rvalid), .sec_done(sec_done)
	);

	sdram_model model (
		.clk(s_clk), .cke(s_cke), .cs_n(s_cs), .ras_n(s_ras), .cas_n(s_cas), .we_n(s_we),
		.dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_from_fpga(s_dq_out), .dq_oe_fpga(s_oe), .dq_to_fpga(s_dq_in)
	);

	// ---------------- reference model ----------------
	bit [15:0] ref_l [bit [17:0]];
	bit [15:0] ref_r [bit [17:0]];
	bit [15:0] sr_l [512], sr_r [512];     // expected shift register contents
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
		end while ((vram_l.RT_EXEC || vram_l.MWT_EXEC || vram_l.FW_EXEC || vram_r.RT_EXEC || vram_r.MWT_EXEC ||
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
		int pos;
		ras_cycle(a, 0, 2'b11, split);
		ras_end();
		wait_idle();
		// expected shift register contents after the transfer
		if (!split) begin
			for (int i = a[8:1] * 2; i < 512; i++) begin sr_l[i] = rl({a[17:9], 9'(i)}); sr_r[i] = rr({a[17:9], 9'(i)}); end
			pos = a[8:0];
		end else begin
			for (int i = 0; i < 256; i++) begin
				sr_l[{a[8], 8'(i)}] = rl({a[17:8], 8'(i)});
				sr_r[{a[8], 8'(i)}] = rr({a[17:8], 8'(i)});
			end
			pos = vram_l.SR_RA;
		end
		for (int k = 0; k < n; k++) begin
			@(posedge clk_mem); SC <= 1;
			mem_cycles(3);
			@(posedge clk_mem); SC <= 0;
			mem_cycles(3);
			checks++;
			if (SQL !== sr_l[pos] || SQR !== sr_r[pos])
				fail($sformatf("RT %05h%s word %03h: got %04h/%04h expected %04h/%04h", a, split ? " split" : "", pos,
				               SQL, SQR, sr_l[pos], sr_r[pos]));
			pos = (pos + 1) % 512;
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

	// MWT: write the current shift register into row 'row'
	task automatic mwt(input [8:0] row);
		ras_cycle({row, 9'h0}, 0, 2'b00, 0);
		ras_end();
		wait_idle();
		for (int i = 0; i < 512; i++) begin ref_l[{row, 9'(i)}] = sr_l[i]; ref_r[{row, 9'(i)}] = sr_r[i]; end
	endtask

	// FW: load the colour registers, flash-write row 'row'
	task automatic flash_write(input [8:0] row, input [15:0] cl, input [15:0] cr);
		// colour load: RAS with DSF and no OE/WE, then CAS with the colour
		ras_cycle({row, 9'h0}, 1, 2'b11, 1);
		@(posedge clk_mem); DL <= cl; DR <= cr; mem_cycles(2);
		CAS_N <= 0; mem_cycles(4);
		ras_end();
		// flash write: RAS with WE and DSF, then CAS
		ras_cycle({row, 9'h0}, 1, 2'b00, 1);
		@(posedge clk_mem); CAS_N <= 0; mem_cycles(4);
		ras_end();
		wait_idle();
		for (int i = 0; i < 512; i++) begin ref_l[{row, 9'(i)}] = cl; ref_r[{row, 9'(i)}] = cr; end
	endtask

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
	end

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

		// 5) SPORT copy (RT row a, MWT into cached row b), read b
		for (int k = 0; k < 4; k++) begin
			int inv0;
			rt_read({rows[k + 4], 9'h0}, 0, 512);       // destination row now cached
			rt_read({rows[k], 9'h0}, 0, 0);             // load the source into the shift register
			if (!cache.find({rows[k + 4], 1'b0})[4]) fail("MWT destination not cached before the copy");
			inv0 = st_inv;
			mwt(rows[k + 4]);
			if (st_inv == inv0) fail("MWT into a cached row did not invalidate it");
			rt_read({rows[k + 4], 9'h0}, 0, 512);
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
			case ($urandom() % 5)
				0, 1: rt_read({r, 9'($urandom() % 2 ? 0 : 9'(($urandom() % 256) * 2))}, 0, 40);
				2:    begin cpu_write({r, 9'($urandom())}, $urandom(), $urandom()); wait_idle(); end
				3:    begin rt_read({rows[$urandom() % 8], 9'h0}, 0, 0); mwt(r); end
				4:    flash_write(r, $urandom(), $urandom());
			endcase
		end
		$display("[%0t] phase 8: random mix, errors=%0d", $realtime, errors);

		$display("tb_rtcache: %0d words checked, hits %0d misses %0d prefetches %0d invalidations %0d",
		         checks, st_hits, st_misses, st_pf, st_inv);
		$display("tb_rtcache: TB errors=%0d, SDRAM model errors=%0d", errors, model.errors);
		if (errors == 0 && model.errors == 0 && st_inv > 0) $display("tb_rtcache: PASS");
		else                                                  $display("tb_rtcache: FAIL");
		$finish;
	end

	initial begin
		#80ms;
		$display("tb_rtcache: TIMEOUT");
		$display("tb_rtcache: FAIL");
		$finish;
	end
endmodule
