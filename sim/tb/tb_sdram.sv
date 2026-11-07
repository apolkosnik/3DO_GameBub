// Testbench: sdram_3do (TDM + secondary port) against the SDRAM model.
//
// The 3DO side is driven by a bus-functional model that issues the same
// LCODE/RCODE sequences MADAM produces (RAS 8, CAS read 1, CAS write 2,
// refresh 4, page close by dropping RAS), one code per MCLK, with the slot
// counter synchronised to PHASE1 exactly as in the core. "Pausing" freezes
// PHASE1 like the core's PAUSE does. The secondary port is exercised with
// reads/writes of random length into every bank, including bank 0/1 rows
// above the 3DO DRAM while a 3DO page is open in that bank (close/re-open).
// The 3DO refreshing just as the controller's own refresh comes due, with
// the port's inputs still presenting the last write (phase 2c).
// All data is checked against a reference model.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module tb_sdram;
	reg clk_mem = 0;
	always #5 clk_mem = ~clk_mem;          // 100 MHz
	// the MMCM's SDRAM clock: clk_mem delayed by 67.5 degrees (gb_clocks.sv)
	reg clk_sdram = 0;
	always @(clk_mem) clk_sdram <= #1.875 clk_mem;

	reg rst = 1;

	// SDRAM pins
	wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we, s_oe;
	wire [ 1:0] s_dqm, s_ba;
	wire [12:0] s_a;
	wire [15:0] s_dq_out, s_dq_in;
	wire        init_done;

	// 3DO DRAM side
	reg         sync = 0;
	reg  [22:2] laddr = 0, raddr = 0;
	reg  [ 1:0] lwe = 0, rwe = 0;
	reg         lras = 0, rras = 0;
	reg  [ 3:0] lcode = 0, rcode = 0;
	reg  [31:0] din = 0;
	wire [31:0] dout;

	// secondary port
	reg         core_rst = 1;
	reg         sec_paused = 0;
	wire        sec_hold;
	reg         sec_req = 0, sec_we = 0;
	reg  [23:0] sec_addr = 0;
	reg  [ 9:0] sec_len = 0;
	wire [15:0] sec_wdata;
	reg  [ 1:0] sec_wbe = 2'b11;
	wire        sec_wnext;
	wire [15:0] sec_rdata;
	wire        sec_rvalid, sec_done;

	sdram_3do #(.POWERUP_US(2)) dut (
		.clk(clk_mem), .clk_sdram(clk_sdram), .rst(rst),
		.SDRAM_CLK(s_clk), .SDRAM_CKE(s_cke), .SDRAM_nCS(s_cs), .SDRAM_nRAS(s_ras),
		.SDRAM_nCAS(s_cas), .SDRAM_nWE(s_we), .SDRAM_DQM(s_dqm), .SDRAM_BA(s_ba),
		.SDRAM_A(s_a), .SDRAM_DQ_IN(s_dq_in), .SDRAM_DQ_OUT(s_dq_out), .SDRAM_DQ_OE(s_oe),
		.init_done(init_done),
		.sync(sync), .laddr(laddr), .lwe(lwe), .lras(lras), .lcode(lcode),
		.raddr(raddr), .rwe(rwe), .rras(rras), .rcode(rcode), .din(din), .dout(dout),
		.CORE_RST(core_rst), .SEC_PAUSED(sec_paused), .SEC_HOLD(sec_hold),
		.sec_req(sec_req), .sec_we(sec_we), .sec_addr(sec_addr), .sec_len(sec_len),
		.sec_wdata(sec_wdata), .sec_wbe(sec_wbe), .sec_wnext(sec_wnext),
		.sec_rdata(sec_rdata), .sec_rvalid(sec_rvalid), .sec_done(sec_done)
	);

	sdram_model model (
		.clk(s_clk), .cke(s_cke), .cs_n(s_cs), .ras_n(s_ras), .cas_n(s_cas), .we_n(s_we),
		.dqm(s_dqm), .ba(s_ba), .a(s_a), .dq_from_fpga(s_dq_out), .dq_oe_fpga(s_oe),
		.dq_to_fpga(s_dq_in)
	);

	int errors = 0;
	task automatic fail(input string m);
		errors++;
		if (errors < 40) $display("[%0t] TB ERROR: %s", $realtime, m);
	endtask

	// ------------------------------------------------------------------
	// Reference memory (word addressed like the SEC port)
	// ------------------------------------------------------------------
	bit [15:0] ref_mem [bit [23:0]];
	function automatic [15:0] ref_rd(input [23:0] a);
		ref_rd = ref_mem.exists(a) ? ref_mem[a] : 16'h0000;
	endfunction

	// ------------------------------------------------------------------
	// Secondary port BFM
	// ------------------------------------------------------------------
	bit [15:0] wbuf [512];
	int        widx;
	assign sec_wdata = wbuf[widx];
	always @(posedge clk_mem) if (sec_wnext) widx <= widx + 1;

	bit [15:0] rbuf [512];
	int        ridx;
	always @(posedge clk_mem) if (sec_rvalid) begin rbuf[ridx] <= sec_rdata; ridx <= ridx + 1; end

	task automatic sec_xfer(input bit we, input [23:0] addr, input int len);
		@(posedge clk_mem);
		widx <= 0; ridx <= 0;
		sec_we <= we; sec_addr <= addr; sec_len <= len[9:0]; sec_req <= 1;
		@(posedge clk_mem);
		while (!sec_done) @(posedge clk_mem);
		sec_req <= 0;
		@(posedge clk_mem);
		if (we) begin
			if (widx != len) fail($sformatf("write consumed %0d words, expected %0d", widx, len));
		end else begin
			if (ridx != len) fail($sformatf("read returned %0d words, expected %0d", ridx, len));
		end
	endtask

	task automatic sec_write_check(input [23:0] addr, input int len);
		for (int i = 0; i < len; i++) begin
			wbuf[i] = $urandom();
			ref_mem[addr + i] = wbuf[i];
		end
		sec_xfer(1, addr, len);
	endtask

	task automatic sec_read_check(input [23:0] addr, input int len);
		sec_xfer(0, addr, len);
		for (int i = 0; i < len; i++)
			if (rbuf[i] !== ref_rd(addr + i))
				fail($sformatf("SEC read %06h: got %04h expected %04h", addr + i, rbuf[i], ref_rd(addr + i)));
	endtask

	// ------------------------------------------------------------------
	// 3DO DRAM BFM: one LCODE/RCODE per MCLK (8 clk_mem), PHASE1 high for
	// the first half. The TDM samples the code at fixed slots.
	// ------------------------------------------------------------------
	bit frozen = 0;      // PAUSE: PHASE1 stops toggling
	// MADAM_AG: read codes are gated with PHASE1, write codes with PHASE2
	// (LCODE = {START, REF, ACCESS&WE&PHASE2, ACCESS&~WE&PHASE1}). All bus
	// signals of an MCLK change together with the PHASE1 rise.
	int bfm_pauses = 0;
	task automatic mclk_cycle(input [3:0] lc, input [3:0] rc, input [20:2] a,
	                          input [31:0] d, input [1:0] we, input bit ras_l, input bit ras_r);
		@(posedge clk_mem);
		// Like the core: SEC_HOLD pauses the 3DO at the next phase boundary
		if (sec_hold && !core_rst) begin
			bfm_pauses++;
			frozen = 1;
			while (sec_hold) @(posedge clk_mem);
			frozen = 0;
			@(posedge clk_mem);
		end
		sync  <= 1;
		laddr <= {2'b00, a}; raddr <= {2'b00, a};
		din   <= d; lwe <= we; rwe <= we;
		lras  <= ras_l; rras <= ras_r;
		lcode <= {lc[3:2], 1'b0, lc[0]};
		rcode <= {rc[3:2], 1'b0, rc[0]};
		repeat (4) @(posedge clk_mem);
		sync  <= 0;
		lcode <= {lc[3:2], lc[1], 1'b0};
		rcode <= {rc[3:2], rc[1], 1'b0};
		repeat (3) @(posedge clk_mem);
	endtask

	// DRAM reference: 3DO 32-bit words, left half in bank 0, right in bank 1
	bit [31:0] dram_ref [bit [20:2]];
	bit [20:2] page_a;

	task automatic dram_open(input [20:2] a);
		page_a = a;
		mclk_cycle(4'h8, 4'h8, a, 32'h0, 2'b00, 1, 1);
	endtask
	task automatic dram_write(input [20:2] a, input [31:0] d);
		mclk_cycle(4'h2, 4'h2, a, d, 2'b11, 1, 1);
		dram_ref[a] = d;
	endtask
	task automatic dram_read_check(input [20:2] a);
		mclk_cycle(4'h1, 4'h1, a, 32'h0, 2'b00, 1, 1);
		// MiSTer timing: dout holds {left,right} from the clock edge that
		// starts the next MCLK; MADAM samples it later in that MCLK.
		@(posedge clk_mem); @(posedge clk_mem);
		if (dout !== (dram_ref.exists(a) ? dram_ref[a] : 32'h0))
			fail($sformatf("DRAM read %05h: got %08h expected %08h", {a, 2'b00}, dout, dram_ref.exists(a) ? dram_ref[a] : 32'h0));
	endtask
	task automatic dram_close();
		mclk_cycle(4'h0, 4'h0, page_a, 32'h0, 2'b00, 0, 0);
	endtask
	task automatic dram_refresh();
		mclk_cycle(4'h4, 4'h0, page_a, 32'h0, 2'b00, 1, 0);
		mclk_cycle(4'h0, 4'h0, page_a, 32'h0, 2'b00, 0, 0);
	endtask

	// Pause (as the core does): hold PHASE1, assert SEC_PAUSED while SEC_HOLD
	always @(posedge clk_mem) sec_paused <= sec_hold && frozen;

	// The secondary port must transfer only what is requested. In the core
	// the arbiter keeps presenting the last client's address, direction and
	// length after the request has gone, and the bridge its next write data.
	always @(posedge clk_mem) begin
		if (sec_wnext && !sec_req) fail($sformatf("secondary port write to %06h without a request", dut.cur_row));
		if (sec_rvalid && !sec_req) fail("secondary port read data without a request");
	end
	// Race of phase 2c: the controller has left S_IDLE because its own refresh
	// is due (sst S_WAIT_QUIET = 1, enum values count from 0), and the 3DO's
	// refresh clears ref_due before the pause takes effect, no request waiting.
	int  races = 0;
	bit  ref_due_d = 0;
	always @(posedge clk_mem) begin
		ref_due_d <= dut.ref_due;
		if (ref_due_d && !dut.ref_due && dut.sst == 4'd1 && !sec_req) races++;
	end

	// ------------------------------------------------------------------
	initial begin
		int pass_lines;
		$display("tb_sdram: start");
		#100 rst = 0;
		wait (init_done);
		$display("[%0t] SDRAM init done", $realtime);

		// 1) Core in reset: SEC transfers in all banks, lengths 1..512
		core_rst = 1;
		for (int b = 0; b < 4; b++) begin
			for (int t = 0; t < 6; t++) begin
				int len;
				bit [23:0] a;
				len = (t == 0) ? 512 : (t == 1) ? 1 : 1 + ($urandom() % 64);
				a = {b[1:0], 13'($urandom()), 9'd0};
				if (b < 2) a[21] = 1'b1;                       // above the 3DO DRAM rows
				a[8:0] = (len == 512) ? 9'd0 : 9'($urandom() % (512 - len));
				sec_write_check(a, len);
				sec_read_check(a, len);
			end
		end
		// byte enables
		begin
			bit [23:0] a = 24'hC12345 & 24'hFFFE00;
			wbuf[0] = 16'hAABB; ref_mem[a] = 16'hAABB; sec_wbe = 2'b11; sec_xfer(1, a, 1);
			wbuf[0] = 16'h1122; sec_wbe = 2'b01; ref_mem[a] = 16'hAA22; sec_xfer(1, a, 1);
			wbuf[0] = 16'h3344; sec_wbe = 2'b10; ref_mem[a] = 16'h3322; sec_xfer(1, a, 1);
			sec_wbe = 2'b11;
			sec_read_check(a, 1);
		end
		$display("[%0t] phase 1 (reset window) done, errors=%0d", $realtime, errors);

		// 2) Core running: 3DO DRAM traffic through the TDM part
		core_rst = 0;
		repeat (20) @(posedge clk_mem);
		for (int p = 0; p < 8; p++) begin
			bit [20:2] base;
			base = {p[9:0], 9'd0};
			dram_open(base);
			for (int i = 0; i < 16; i++) dram_write(base + i, $urandom());
			for (int i = 0; i < 16; i++) dram_read_check(base + i);
			dram_close();
			dram_refresh();
		end
		$display("[%0t] phase 2 (3DO DRAM) done, errors=%0d", $realtime, errors);

		// 2b) 80 us of traffic in one open page without any 3DO refresh: the
		//     controller must pause the 3DO and refresh on its own, closing
		//     and re-opening the open pages around it.
		begin
			bit [20:2] base;
			base = {10'd300, 9'd0};
			dram_open(base);
			for (int i = 0; i < 64; i++) dram_write(base + i, $urandom());
			for (int k = 0; k < 1000; k++) begin
				int i;
				i = $urandom() % 64;
				if (k % 3 == 0) dram_write(base + i, $urandom());
				else            dram_read_check(base + i);
			end
			dram_close();
		end
		$display("[%0t] phase 2b (no 3DO refresh) done, errors=%0d, pauses=%0d", $realtime, errors, bfm_pauses);

		// 2c) The 3DO refreshes just as the controller's own refresh comes due
		//     (15 us without one): the controller has asked for a pause, and
		//     the 3DO's refresh, issued before the pause, clears ref_due. It
		//     must then release the bus, not start a transfer from the port's
		//     stale inputs (the last write, 4 words, with new write data):
		//     that rewrote the last VRAM beat in the core. The delay and its
		//     phase within the MCLK are swept to hit the window.
		for (int d = 0; d < 8; d++) begin
			for (int k = 0; k < 6; k++) begin
				bit [23:0] aa;
				bit [20:2] base;
				aa   = {2'd2, 13'(3000 + d * 8 + k), 9'(k * 40)};
				base = {10'd310, 9'd0};
				frozen = 1;
				sec_write_check(aa, 4);
				frozen = 0;
				for (int i = 0; i < 512; i++) wbuf[i] = 16'hDEAD ^ 16'(i);
				// (no page open: a refresh right after a page close is skipped)
				dram_refresh();
				repeat (d) @(posedge clk_mem);
				for (int m = 0; m < 183 + k; m++) mclk_cycle(4'h0, 4'h0, base, 32'h0, 2'b00, 0, 0);
				dram_refresh();
				for (int m = 0; m < 8; m++) mclk_cycle(4'h0, 4'h0, base, 32'h0, 2'b00, 0, 0);
				frozen = 1;
				sec_read_check(aa, 4);
				frozen = 0;
			end
		end
		$display("[%0t] phase 2c (3DO refresh as the controller's comes due) done, errors=%0d, races=%0d", $realtime, errors, races);
		if (races == 0) fail("phase 2c did not hit the refresh race");

		// 3) Pause with a 3DO page open in banks 0/1, SEC accesses to banks
		//    0..3 (forcing TDM page close/re-open), resume and keep using the
		//    page. The core pauses on a phase boundary: either in PHASE2 (after
		//    a write) or in PHASE1 (after the reads of an MCLK were issued; MADAM
		//    samples the data only after the pause).
		for (int r = 0; r < 12; r++) begin
			bit [20:2] base;
			bit [23:0] aa;
			base = {10'(r + 100), 9'd0};
			aa   = {2'(r % 4), 13'(1024 + 37 * r), 9'(r * 13)};
			dram_open(base);
			for (int i = 0; i < 4; i++) dram_write(base + i, $urandom());
			if (r % 3 == 2) begin
				// frozen in PHASE1 of a WRITE MCLK: the write code (PHASE2)
				// only appears after the pause; the write must not be lost
				bit [31:0] d;
				d = $urandom();
				@(posedge clk_mem);
				sync <= 1; laddr <= {2'b00, base + 3}; raddr <= {2'b00, base + 3};
				lcode <= 4'h0; rcode <= 4'h0; lwe <= 2'b11; rwe <= 2'b11; din <= d;
				repeat (4) @(posedge clk_mem);
				frozen = 1;
				sec_write_check(aa, 64);
				sec_read_check(aa, 64);
				frozen = 0;
				@(posedge clk_mem); sync <= 0; lcode <= 4'h2; rcode <= 4'h2;
				repeat (4) @(posedge clk_mem);    // full PHASE2 half (slots 4-7)
				lwe <= 0; rwe <= 0; lcode <= 4'h0; rcode <= 4'h0;
				dram_ref[base + 3] = d;
			end else if (r[0] == 0) begin
				// frozen in PHASE2 after the last write (PHASE1 stays low)
				@(posedge clk_mem);
				frozen = 1;
				sec_write_check(aa, 64);
				sec_read_check(aa, 64);
				frozen = 0;
			end else begin
				// frozen in PHASE1 of a read MCLK
				@(posedge clk_mem);
				sync <= 1; laddr <= {2'b00, base + 2}; raddr <= {2'b00, base + 2};
				lcode <= 4'h1; rcode <= 4'h1; lwe <= 0; rwe <= 0;
				repeat (4) @(posedge clk_mem);
				frozen = 1;
				sec_write_check(aa, 64);
				sec_read_check(aa, 64);
				frozen = 0;
				// resume: PHASE1 falls, PHASE2 half, then MADAM takes the data
				@(posedge clk_mem); sync <= 0; lcode <= 4'h0; rcode <= 4'h0;
				repeat (2) @(posedge clk_mem);
				if (dout !== dram_ref[base + 2])
					fail($sformatf("DRAM read across pause %05h: got %08h expected %08h", {base + 2, 2'b00}, dout, dram_ref[base + 2]));
				@(posedge clk_mem);
			end
			for (int i = 0; i < 4; i++) dram_read_check(base + i);
			for (int i = 4; i < 8; i++) dram_write(base + i, $urandom());
			for (int i = 0; i < 8; i++) dram_read_check(base + i);
			dram_close();
			dram_refresh();
		end
		$display("[%0t] phase 3 (pause + SEC with open 3DO pages) done, errors=%0d", $realtime, errors);

		// 4) Everything written by the secondary port is still intact
		core_rst = 1;
		foreach (ref_mem[a]) begin
			sec_xfer(0, a, 1);
			if (rbuf[0] !== ref_mem[a]) fail($sformatf("retention %06h: got %04h expected %04h", a, rbuf[0], ref_mem[a]));
			if (errors > 30) break;
		end
		core_rst = 1;

		repeat (100) @(posedge clk_mem);
		$display("tb_sdram: 3DO BFM paused %0d times for SEC refresh", bfm_pauses);
		if (bfm_pauses == 0) fail("SEC refresh while running was not exercised");
		$display("tb_sdram: TB errors=%0d, SDRAM model errors=%0d", errors, model.errors);
		if (errors == 0 && model.errors == 0) $display("tb_sdram: PASS");
		else                                  $display("tb_sdram: FAIL");
		$finish;
	end

	initial begin
		#20ms;
		$display("tb_sdram: TIMEOUT");
		$display("tb_sdram: FAIL");
		$finish;
	end
endmodule
