// Testbench: the CLIO DSP against an instrumented Opera run of a game's DSP
// program (Game Bub 3DO core).
//
// The real CLIO runs a DSP program with the I memory and the input FIFO
// words of an Opera trace (scratchpad opera_build, OPERA_DSP_TRACE), and
// logs what the DSP writes and what its FIFOs hand it, tick by tick, for
// kt_cmp/dspcmp.py to compare with Opera's per-instruction trace. The
// testbench plays MADAM: it answers CLIO's DMA requests to the input FIFOs
// with the next words of the trace (code 2 bus cycles, then code 7), drains
// the output FIFOs the same way, and replays the CPU's writes to the DSP's
// I memory between the ticks they happened in. Every tick starts with the
// audio word strobe (audio lock), as in the game.
//   +nmem=<file>   N memory, 512 hex words (one per line)
//   +imem=<file>   I memory, 1024 hex words (0x000-0x06F through the CPU,
//                  0x100-0x1FF and 0x300-0x30F straight into the memories)
//   +fifo=<file>   lines "<tick> <channel> <hex word>": input FIFO words in order;
//                  "<tick> <channel> END": the channel's DMA buffer ends there
//                  (MADAM ends the transfer with code 4, nothing more until the
//                  CPU enables the channel again)
//   +cpu=<file>    lines "<tick> <kind> <addr> <hex word>": the CPU's writes before a
//                  tick: I = DSP I memory word (through 0x3400), N = DSP N memory
//                  word (through 0x2000), C = CLIO register (FIFO init, DMA enable)
//   +ticks=<n>     DSP ticks to run (default 200)
//   +period=<n>    MCLKs per tick (the audio word period; default 576)
//   +words=<n>     32-bit words per DMA transfer to an input FIFO (default 2)
//   +dmaen=<mask>  input FIFO channels whose DMA is on at the start (default 0x1F)
//   +log=<file>    the log: T <tick>, W <addr> <data> <pc>, F <ch> <word>,
//                  R <addr> <data> <pc>, S <mclks> (the tick slept after that long)
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps
module tb_dsp_kt;
	reg clk = 0;
	always #10 clk = ~clk;                 // clk_sys, 50 MHz
	reg ce_r = 0;                          // MCLK phases, 25 MHz
	always @(posedge clk) ce_r <= ~ce_r;
	wire ce_f = ~ce_r;
	reg rst_n = 0;

	reg  [15:2] a = 0;
	reg  [31:0] di = 0;
	wire [31:0] q;
	reg  [ 2:0] clc = 0;
	reg         dsp_en = 0;
	reg  [31:0] mem_di = 0;               // MADAM's bus (DMA data to CLIO)
	reg         aclk_ce = 0;              // audio clock enable
	wire [31:0] dma_do;                   // CLIO's DMA data to MADAM
	wire        dmareq, cready_n;
	wire [ 4:0] dmach;
	wire        firq_n;

	CLIO dut (
		.CLK(clk), .RST_N(rst_n), .EN(1'b1), .PAL(1'b0), .CE_R(ce_r), .CE_F(ce_f),
		.IO_EN(1'b1), .DSP_EN(dsp_en), .PON(1'b0), .RESET_N(), .MCLK_PH1(ce_r), .MCLK_PH2(ce_f),
		.A(a), .CPU_DI(di), .CPU_DO(q), .DI(mem_di), .DO(dma_do), .CLC(clc), .CREADY_N(cready_n), .DMAREQ(dmareq), .DMACH(dmach),
		.PB_INT(1'b0), .FIRQ_N(firq_n),
		.EDI(8'hFF), .EDO(), .ESTR_N(), .EWRT_N(), .ERST_N(), .ECMD_N(), .ESEL_N(), .ERDY_N(1'b0), .EINT_N(1'b1),
		.ADBIO_I(4'h0), .ADBIO_O(), .ADBIO_D(),
		.VCE(1'b0), .HSYNC_N(1'b1), .VSYNC_N(1'b1), .S(32'h0), .LPSC_N(1'b1), .RPSC_N(1'b1), .PCSC(),
		.AD(), .DE(), .ACLK_CE(aclk_ce), .AUDIOL(), .AUDIOR(),
		.HINTREPOL_DISABLE(1'b1), .VINTREPOL_DISABLE(1'b1), .DBG_EXT(8'h00)
	);

	// one MCLK: to the next clk edge with CE_R set (CLIO acts on CE_R)
	task automatic mclk(input int n = 1);
		repeat (n) @(posedge clk iff ce_r);
	endtask

	// CPU accesses as MADAM_EXTPIF.sv makes them: CLC for one CE_R
	task automatic wr(input [15:0] adr, input [31:0] val);
		mclk(); #1;
		a = adr[15:2]; di = val; clc = 3'h1;
		mclk(); #1;
		clc = 3'h0;
		mclk(3);
	endtask

	// ---------------- the trace ----------------
	string      nmem_file, imem_file, fifo_file, cpu_file, log_file;
	int         n_ticks = 200, period = 576, dma_words = 2, dmaen = 32'h1F;
	bit [15:0]  nmem [512];
	bit [15:0]  imem [1024];
	bit [15:0]  fifo_q [13][$];          // input FIFO words still to deliver, per channel
	int         seg_q [13][$];           // words in each DMA buffer segment, in order
	int         seg_left [13];           // words left in the current segment (-1: none begun)
	bit [15:0]  fifo_in [13][$];         // delivered to the FIFO, not yet read by the DSP
	int         cpu_tick [$];
	string      cpu_kind [$];
	bit [15:0]  cpu_addr [$];
	bit [31:0]  cpu_val [$];
	int         logf;

	task automatic load_trace();
		int fd, t, ch, ad, w, n;
		string kind;
		if (!$value$plusargs("nmem=%s", nmem_file) || !$value$plusargs("imem=%s", imem_file) ||
		    !$value$plusargs("fifo=%s", fifo_file) || !$value$plusargs("log=%s", log_file)) begin
			$display("tb_dsp_kt: +nmem= +imem= +fifo= +log= are required");
			$finish;
		end
		void'($value$plusargs("cpu=%s", cpu_file));
		void'($value$plusargs("ticks=%d", n_ticks));
		void'($value$plusargs("period=%d", period));
		void'($value$plusargs("words=%d", dma_words));
		void'($value$plusargs("dmaen=%h", dmaen));
		void'($value$plusargs("trace_from=%d", trace_from));
		void'($value$plusargs("trace_to=%d", trace_to));
		$readmemh(nmem_file, nmem);
		$readmemh(imem_file, imem);
		fd = $fopen(fifo_file, "r");
		if (fd == 0) begin $display("tb_dsp_kt: cannot open %s", fifo_file); $finish; end
		n = 0;
		for (int c = 0; c < 13; c++) seg_left[c] = 0;
		begin
			string tok;
			while ($fscanf(fd, "%d %d %s", t, ch, tok) == 3) begin
				if (tok == "END") begin
					seg_q[ch].push_back(seg_left[ch]); seg_left[ch] = 0;
				end
				else begin
					void'($sscanf(tok, "%h", w));
					fifo_q[ch].push_back(16'(w));
					seg_left[ch]++; n++;
				end
			end
		end
		for (int c = 0; c < 13; c++) begin seg_q[c].push_back(seg_left[c]); seg_left[c] = -1; end
		$fclose(fd);
		// a channel whose first words come only after a buffer end has no buffer at
		// the start: its DMA is off until the CPU enables it
		for (int c = 0; c < 13; c++)
			if (seg_q[c].size() > 1 && seg_q[c][0] == 0) begin
				void'(seg_q[c].pop_front());
				dmaen[c] = 1'b0;
			end
		$display("tb_dsp_kt: %0d input FIFO words (ch0 %0d, ch1 %0d, ch2 %0d, ch3 %0d, ch4 %0d)",
		         n, fifo_q[0].size(), fifo_q[1].size(), fifo_q[2].size(), fifo_q[3].size(), fifo_q[4].size());
		if (cpu_file != "") begin
			fd = $fopen(cpu_file, "r");
			if (fd != 0) begin
				while ($fscanf(fd, "%d %s %h %h", t, kind, ad, w) == 4) begin
					cpu_tick.push_back(t); cpu_kind.push_back(kind); cpu_addr.push_back(16'(ad)); cpu_val.push_back(32'(w));
				end
				$fclose(fd);
			end
		end
		logf = $fopen(log_file, "w");
	endtask

	// ---------------- MADAM: DMA service ----------------
	bit         req_pend = 0;
	bit [4:0]   req_ch;
	int         dma_served = 0, dma_starved = 0;
	always @(posedge clk) if (rst_n && ce_r && dmareq) begin
		req_pend <= 1;
		req_ch <= dmach;
	end

	// to an input FIFO: up to dma_words 32-bit words (two FIFO words each, the
	// first in bits 31-16), each a code 2 bus cycle, then code 7
	task automatic serve_to_dsp(input [3:0] ch);
		bit [15:0] w0, w1;
		int n;
		bit ended;
		n = 0; ended = 0;
		if (seg_left[ch] < 0) begin                        // the next buffer segment begins
			if (seg_q[ch].size()) seg_left[ch] = seg_q[ch].pop_front();
			else seg_left[ch] = 0;
		end
		while (n < dma_words && seg_left[ch] >= 2 && fifo_q[ch].size() >= 2) begin
			w0 = fifo_q[ch].pop_front(); w1 = fifo_q[ch].pop_front();
			fifo_in[ch].push_back(w0); fifo_in[ch].push_back(w1);
			mclk(); #1 mem_di = {w0, w1}; clc = 3'h2;
			mclk(); #1 clc = 3'h0;
			mclk(3);
			n++; seg_left[ch] -= 2;
		end
		if (seg_left[ch] < 2) begin                        // the buffer is done: code 4, the channel stops
			ended = 1; seg_left[ch] = -1;
		end
		if (n == 0 && !ended) dma_starved++;
		mclk(); #1 clc = 3'h7;
		if (ended) begin mclk(); #1 clc = 3'h4; end
		mclk(); #1 clc = 3'h0;
	endtask
	// from an output FIFO: two code 2 bus cycles (two FIFO words each), then code 7
	task automatic serve_from_dsp();
		repeat (2) begin
			mclk(); #1 clc = 3'h2;
			mclk(); #1 clc = 3'h0;
			mclk(3);
		end
		mclk(); #1 clc = 3'h7;
		mclk(); #1 clc = 3'h0;
	endtask
	// n MCLKs, serving DMA requests as they come
	task automatic run(input int n);
		int i;
		i = 0;
		while (i < n) begin
			mclk(); i++;
			if (req_pend) begin
				req_pend = 0;
				dma_served++;
				if (req_ch <= 5'h0C) serve_to_dsp(req_ch[3:0]);
				else if (req_ch >= 5'h10 && req_ch <= 5'h13) serve_from_dsp();
				else begin mclk(); #1 clc = 3'h7; mclk(); #1 clc = 3'h0; end
			end
		end
	endtask

	// ---------------- the log ----------------
	//   +trace_from=<tick> +trace_to=<tick>: every MCLK of those ticks (lines
	//   "X <pc> <nrc> f<fetch> o<oper> c<comp> rd <addr>=<data> wr <addr>=<data> mv<move_we> dw<do_write> an<arith_num> cn<comp_num>")
	int         trace_from = -1, trace_to = -2;
	int         tick = -1;
	int         tick_mclk = 0;
	bit         slept = 0;
	bit         ei_oe_d = 0;
	bit         audws_d = 0;
	// ticks are the frames the audio word strobe starts (as Opera's DSP loop
	// calls); the CPU's reset that starts the DSP makes one or two resets
	// before the first strobe, whose activity is logged before "T 0"
	always @(posedge clk) if (rst_n && ce_r) begin
		tick_mclk++;
		audws_d <= dut.AUDWS;
		if (dsp_en && dut.DSP_RESET && audws_d) begin
			tick++;
			tick_mclk = 0;
			slept = 0;
			$fdisplay(logf, "T %0d", tick);
		end
		// (the DSP's SLEEP clears a clock after the reset: not this tick's sleep)
		if (dsp_en && dut.DSP.SLEEP && !slept && tick_mclk > 4) begin
			slept = 1;
			$fdisplay(logf, "S %0d", tick_mclk);
		end
		if (dsp_en && tick >= trace_from && tick <= trace_to)
			$fdisplay(logf, "X %03x %04x f%0d o%0d c%0d rd%0d %03x=%04x wr%0d %03x=%04x mv%0d dw%0d%0d an%0d cn%0d",
			          dut.DSP_PC, dut.DSP.NRC, dut.DSP.FETCH_ST, dut.DSP.OPER_ST, dut.DSP.COMP_ST,
			          dut.DSP.RDEN, dut.DSP.RDADDR, dut.DSP.RDDATA, dut.DSP.WREN, dut.DSP.WRADDR, dut.DSP.WRDATA,
			          dut.DSP.MOVE_WRITE_EN, dut.DSP.DO_WRITE[0], dut.DSP.DO_WRITE[1], dut.DSP.ARITH_NUM, dut.DSP.COMP_NUM);
		if (dsp_en && dut.DSP.WREN && dut.DSP.WRADDR >= 10'h100)
			$fdisplay(logf, "W %03x %04x %03x", dut.DSP.WRADDR, dut.DSP.WRDATA, dut.DSP_PC);
		ei_oe_d <= dut.DSP.EI_OE;
		if (dsp_en && dut.DSP.EI_OE && !ei_oe_d && dut.DSP.EI_ADDR >= 8'hD0)
			$fdisplay(logf, "R %02x %04x %03x", dut.DSP.EI_ADDR, dut.DSP_EI_DATA, dut.DSP_PC);
		if (dut.EIFIFO0.RD_OK) begin $fdisplay(logf, "F 0 %04x", dut.EIFIFO_Q[0]); if (fifo_in[0].size()) void'(fifo_in[0].pop_front()); end
		if (dut.EIFIFO1.RD_OK) begin $fdisplay(logf, "F 1 %04x", dut.EIFIFO_Q[1]); if (fifo_in[1].size()) void'(fifo_in[1].pop_front()); end
		if (dut.EIFIFO2.RD_OK) begin $fdisplay(logf, "F 2 %04x", dut.EIFIFO_Q[2]); if (fifo_in[2].size()) void'(fifo_in[2].pop_front()); end
		if (dut.EIFIFO3.RD_OK) begin $fdisplay(logf, "F 3 %04x", dut.EIFIFO_Q[3]); if (fifo_in[3].size()) void'(fifo_in[3].pop_front()); end
		if (dut.EIFIFO4.RD_OK) begin $fdisplay(logf, "F 4 %04x", dut.EIFIFO_Q[4]); if (fifo_in[4].size()) void'(fifo_in[4].pop_front()); end
	end

	// the audio clock: ACLK_CE pulses so that the audio word strobe (every
	// 0x180 of them) comes every `period` MCLKs
	int aclk_div = 3;
	always begin
		repeat (aclk_div - 1) @(posedge clk);
		@(posedge clk) aclk_ce = 1;
		@(posedge clk) aclk_ce = 0;
	end

	initial begin
		int t;
		load_trace();
		aclk_div = (period * 2) / 384;
		if (aclk_div < 2) aclk_div = 2;
		repeat (8) @(posedge clk);
		rst_n = 1;
		mclk(8);
		dsp_en = 1;
		wr(16'h17FC, 32'h0);                               // DSP stopped
		wr(16'h0308, 32'hFFFFFFFF);                        // every DMA channel off
		for (int i = 0; i < 512; i++) wr(16'h2000 + 16'(4 * i), {16'h0, nmem[i]});
		for (int i = 0; i < 16'h70; i++) wr(16'h3400 + 16'(4 * i), {16'h0, imem[i]});
		for (int i = 0; i < 256; i++) dut.DSP.IRAM.altdpram_component.mem[i] = imem[16'h100 + i];
		for (int i = 0; i < 16; i++) begin
			dut.EORAM.altdpram_component.mem[i] = imem[16'h300 + i];
			dut.EORAM_ODD.altdpram_component.mem[i] = imem[16'h300 + i];
		end
		dut.AUDLOCK = 1;                                   // frames with the audio word strobe
		wr(16'h0304, 32'h000F0000 | dmaen);                // DMA to the input FIFOs on, from output FIFOs 0-3
		run(64);                                           // the first refills
		// the DSP runs from the first frame the audio word strobe starts (tick 0)
		@(posedge clk iff (ce_r && dut.DSP_RESET));
		wr(16'h17FC, 32'h1);
		t = 0;
		while (tick < n_ticks - 1) begin
			run(16);
			// the CPU's writes for the next tick, once this tick's program sleeps
			// (Opera makes them between two calls of the DSP loop)
			if (slept) begin
				while (cpu_tick.size() && cpu_tick[0] <= tick + 1) begin
					if (cpu_kind[0] == "I" && cpu_addr[0] < 16'h80)
						wr(16'h3400 + 16'(cpu_addr[0] * 4), {16'h0, cpu_val[0][15:0]});
					else if (cpu_kind[0] == "N")
						wr(16'h2000 + 16'(cpu_addr[0] * 4), {16'h0, cpu_val[0][15:0]});
					else if (cpu_kind[0] == "C") begin
						// a FIFO reset: the words the DMA had put in the FIFO are
						// lost, and the CPU points the DMA at its buffer again
						if (cpu_addr[0] == 16'h0300)
							for (int ch = 0; ch < 13; ch++)
								if (cpu_val[0][ch]) begin
									while (fifo_in[ch].size()) fifo_q[ch].push_front(fifo_in[ch].pop_back());
								end
						wr(cpu_addr[0], cpu_val[0]);
					end
					$fdisplay(logf, "C %s %03x %08x", cpu_kind[0], cpu_addr[0], cpu_val[0]);
					void'(cpu_tick.pop_front()); void'(cpu_kind.pop_front()); void'(cpu_addr.pop_front()); void'(cpu_val.pop_front());
				end
			end
			if (dma_starved > 0) begin
				$display("tb_dsp_kt: input FIFO trace exhausted at tick %0d", tick);
				break;
			end
		end
		run(period);
		wr(16'h17FC, 32'h0);
		$fclose(logf);
		$display("tb_dsp_kt: %0d ticks, %0d DMA transfers, log %s", tick + 1, dma_served, log_file);
		$finish;
	end
endmodule
