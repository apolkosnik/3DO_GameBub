// SDRAM controller for the 3DO core on Game Bub (single 32 MiB x16 SDR SDRAM,
// 8192 rows x 512 columns x 4 banks).
//
// Two clients share the chip:
//
//  * The 3DO DRAM emulation (TDM part). This is the MiSTer 3DO sdram.sv
//    scheme by srg320: the 3DO's own RAS/CAS cycles (LCODE/RCODE) are
//    replayed in lock-step with MCLK (8 clk_mem slots per MCLK), the left
//    DRAM half living in bank 0 and the right half in bank 1, with the 3DO
//    page (512 words) mapped onto one SDRAM row. Command timing and the read
//    capture pipeline are kept identical to the MiSTer original; only the
//    column mapping (9 column bits) and the split data bus are different.
//
//  * A secondary burst port (SEC part) used for everything that lived in
//    DDR3 or on the HPS on MiSTer (VRAM overflow, BIOS/kanji ROM, NVRAM, CD
//    image, host file transfers). It can only own the bus while the 3DO is
//    frozen: either held in reset (CORE_RST) or paused (SEC_PAUSED). The
//    requester raises SEC_HOLD as soon as it has work; the top level turns
//    that into PAUSE, and SEC_PAUSED is fed back once PAUSE is in effect.
//    Bursts must stay within one SDRAM row (512 words).
//    If a SEC access targets bank 0/1 while the TDM part has a page open
//    there, the page is closed first and re-opened afterwards, so the 3DO
//    sees no difference.
//
// Copyright (c) 2026 Adam Polkosnik. TDM scheduling derived from the MiSTer
// 3DO core (c) srg320, GPL-3.0.
// SPDX-License-Identifier: GPL-3.0-or-later

module sdram_3do #(
	parameter int CLK_HZ         = 100_000_000,
	parameter int POWERUP_US     = 200,
	// The SDRAM is refreshed by the 3DO's own refresh cycles (as on MiSTer).
	// If none is seen for REFRESH_CYCLES (3DO in reset, or its BIOS has not
	// enabled DRAM refresh yet) the SEC part inserts one, pausing the 3DO if
	// it is running and closing/re-opening its open pages around it.
	parameter int REFRESH_CYCLES = 1500,    // 15 us
	// Pipeline stage at which read data is taken. With READ_STAGE = 5 the
	// DQ sampling instant and the cycle in which `dout` updates are exactly
	// those of MiSTer's sdram.sv (DQ sampled about 40 ns after the READ
	// command leaves the FPGA, SDRAM clocked on the inverted clk_mem); the
	// newest word comes straight from the IOB input register.
	parameter int READ_STAGE     = 5
)(
	input              clk,                // clk_mem
	input              rst,                // asynchronous-to-start reset (synchronised inside)

	// SDRAM pins (via the Game Bub framework SdramV0 bundle)
	output             SDRAM_CLK,
	output             SDRAM_CKE,
	output reg         SDRAM_nCS,
	output reg         SDRAM_nRAS,
	output reg         SDRAM_nCAS,
	output reg         SDRAM_nWE,
	output reg  [ 1:0] SDRAM_DQM,
	output reg  [ 1:0] SDRAM_BA,
	output reg  [12:0] SDRAM_A,
	input       [15:0] SDRAM_DQ_IN,
	output reg  [15:0] SDRAM_DQ_OUT,
	output reg         SDRAM_DQ_OE,

	output reg         init_done,

	// 3DO DRAM interface (MiSTer sdram.sv compatible)
	input              sync,               // MADAM PH1 (MCLK phase)
	input      [22: 2] laddr,
	input      [ 1: 0] lwe,
	input              lras,
	input      [ 3: 0] lcode,
	input      [22: 2] raddr,
	input      [ 1: 0] rwe,
	input              rras,
	input      [ 3: 0] rcode,
	input      [31: 0] din,
	output reg [31: 0] dout,

	// Secondary port
	input              CORE_RST,           // 3DO held in reset (TDM idle)
	input              SEC_PAUSED,         // 3DO paused with SEC_HOLD asserted
	output             SEC_HOLD,           // request PAUSE
	input              sec_req,            // level, held until sec_done
	input              sec_we,
	input      [23: 0] sec_addr,           // {bank[1:0], row[12:0], col[8:0]} in 16-bit words
	input      [ 9: 0] sec_len,            // number of words, 1..512, must not cross a row
	input      [15: 0] sec_wdata,          // must hold word N while sec_wnext pulses for word N
	input      [ 1: 0] sec_wbe,            // byte enables for the current write word
	output             sec_wnext,          // current write word is consumed at this edge; present the next one after it
	output reg [15: 0] sec_rdata,
	output reg         sec_rvalid,
	output reg         sec_done
);
	localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles
	localparam BURST          = 3'd0; // 1 word
	localparam ACCESS_TYPE    = 1'd0;
	localparam CAS_LATENCY    = 3'd2;
	localparam OP_MODE        = 2'd0;
	localparam NO_WRITE_BURST = 1'd1;
	localparam bit [12:0] MODE = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST};

	localparam STATE_IDLE  = 3'd0;
	localparam STATE_START = STATE_IDLE+1'd1;
	localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
	localparam STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;
	localparam STATE_LAST  = STATE_READY;

	localparam MODE_NORMAL = 2'b00;
	localparam MODE_RESET  = 2'b01;
	localparam MODE_LDM    = 2'b10;
	localparam MODE_PRE    = 2'b11;

	localparam int POWERUP_CYCLES = (CLK_HZ / 1_000_000) * POWERUP_US;

	// ------------------------------------------------------------------
	// Reset synchroniser and power-up delay
	// ------------------------------------------------------------------
	reg [2:0] rst_sync = '1;
	always @(posedge clk) rst_sync <= {rst_sync[1:0], rst};
	wire rst_s = rst_sync[2];

	reg [$clog2(POWERUP_CYCLES+1)-1:0] pwr_cnt = '0;
	wire pwr_ok = (pwr_cnt == POWERUP_CYCLES);
	always @(posedge clk) begin
		if (rst_s) pwr_cnt <= '0;
		else if (!pwr_ok) pwr_cnt <= pwr_cnt + 1'd1;
	end

	// ------------------------------------------------------------------
	// Initialisation (same sequence as MiSTer sdram.sv)
	// ------------------------------------------------------------------
	reg [2:0] init_state = '0;
	reg [1:0] mode = MODE_RESET;
	reg [4:0] reset = 5'h1f;
	always @(posedge clk) begin
		if (rst_s || !pwr_ok) begin
			init_state <= '0;
			reset      <= 5'h1f;
			mode       <= MODE_RESET;
			init_done  <= 0;
		end else begin
			if (mode != MODE_NORMAL || init_state != STATE_IDLE || reset) begin
				init_state <= init_state + 1'd1;
				if (init_state == STATE_LAST) init_state <= STATE_IDLE;
			end
			if (init_state == STATE_LAST) begin
				if (reset != 0) begin
					reset <= reset - 5'd1;
					if (reset == 15 || reset == 14) mode <= MODE_PRE;
					else if (reset == 4 || reset == 3) mode <= MODE_LDM;
					else mode <= MODE_RESET;
				end else begin
					mode      <= MODE_NORMAL;
					init_done <= 1;
				end
			end
		end
	end

	localparam CTRL_IDLE = 2'd0;
	localparam CTRL_RAS  = 2'd1;
	localparam CTRL_CAS  = 2'd2;
	localparam CTRL_PRE  = 2'd3;

	typedef struct packed {
		bit [ 1:0] CMD;
		bit [ 1:0] BANK;
		bit [12:0] ROW;
		bit [ 8:0] COL;
		bit [15:0] DATA;
		bit        RD;
		bit        WE;
		bit [ 1:0] BE;
		bit        RFS;
		bit        SEC;   // read belongs to the secondary port
		bit        ALL;   // precharge all banks
	} state_t;
	state_t state[8];      // state[0] is the mux of tdm_s0/sec_s0 below
	state_t tdm_s0, sec_s0; // registered command from each part (MiSTer's state[0])
	reg     sec_own;        // sec_active delayed: which part produced the current state[0]

	// ------------------------------------------------------------------
	// MCLK slots
	//
	// MiSTer runs a free counter from the PHASE1 rising edge: slot 0 is the
	// cycle in which the rise is seen, slots 1-3 follow, slots 4-7 fall in
	// PHASE2. That is only correct if PHASE2 starts exactly 4 cycles after
	// PHASE1. When the 3DO is paused with PHASE1 high (which the secondary
	// port does at arbitrary times), the counter would run through slots
	// 4-7 during the freeze and park, and the PHASE2 work after the pause
	// (DRAM writes, RAS) would be lost. Here slots 0-3 start at the PHASE1
	// rise and slots 4-7 at the PHASE1 fall, parking (SLOT_PARK) in between.
	// In normal operation the slot sequence is cycle-identical to MiSTer.
	// ------------------------------------------------------------------
	localparam bit [3:0] SLOT_PARK = 4'd8;
	reg  [3:0] slot_cnt;
	reg        sync_old;
	wire       sync_rise = sync && !sync_old;
	wire       sync_fall = !sync && sync_old;
	wire [3:0] slot = sync_rise ? 4'd0 : sync_fall ? 4'd4 : slot_cnt;
	always @(posedge clk) begin
		sync_old <= sync;
		if (!init_done)                         slot_cnt <= SLOT_PARK;
		else if (sync_rise)                     slot_cnt <= 4'd1;
		else if (sync_fall)                     slot_cnt <= 4'd5;
		else if (slot_cnt == 4'd3 || slot_cnt == 4'd7) slot_cnt <= SLOT_PARK;
		else if (slot_cnt != SLOT_PARK)         slot_cnt <= slot_cnt + 4'd1;
	end
	wire parked = (slot == SLOT_PARK);

	// ------------------------------------------------------------------
	// TDM part: 3DO DRAM in banks 0 (left) and 1 (right)
	// ------------------------------------------------------------------
	reg        lpage_opened = 0, rpage_opened = 0;
	reg [12:0] lpage_row, rpage_row;
	reg        sec_active;                  // SEC owns the command bus
	reg        tdm_refresh_seen;
	reg        r_pre_slot3;                 // right page was closed at slot 3 in this MCLK
	// Cycles since an ACTIVE was issued to bank 0/1 (by either part),
	// measured on the issued command stream (state[0]); a command decided
	// now is issued act_cnt + 2 cycles after that ACTIVE.
	reg  [3:0] act_cnt [2];

	always @(posedge clk) begin
		state_t t;
		t = '0;
		tdm_refresh_seen <= 0;
		if (!init_done) begin
			t.CMD = init_state == STATE_START ? CTRL_RAS :
			        init_state == STATE_CONT  ? CTRL_CAS :
			                                    CTRL_IDLE;
			t.RFS = 1;
		end else if (!sec_active) begin
			if (lras && lcode == 4'h8 && slot == 4'd5) begin
				t.CMD  = CTRL_RAS;
				t.ROW  = laddr[22:11];
				t.BANK = 2'd0;
				lpage_opened <= 1;
				lpage_row    <= laddr[22:11];
			end
			if (rras && rcode == 4'h8 && slot == 4'd6) begin
				t.CMD  = CTRL_RAS;
				t.ROW  = raddr[22:11];
				t.BANK = 2'd1;
				rpage_opened <= 1;
				rpage_row    <= raddr[22:11];
			end
			// Slot 0 is the first cycle of PHASE1. MiSTer's parked counter also
			// matched here and re-issued this read on every cycle of a pause
			// with PHASE1 high, overwriting the right half of `dout` with left
			// data before MADAM samples it; here it is issued once.
			if (lras && lcode == 4'h1 && slot == 4'd0 && lpage_opened) begin
				t.CMD  = CTRL_CAS;
				t.COL  = laddr[10:2];
				t.RD   = 1;
				t.BANK = 2'd0;
			end
			if (rras && rcode == 4'h1 && slot == 4'd1 && rpage_opened) begin
				t.CMD  = CTRL_CAS;
				t.COL  = raddr[10:2];
				t.RD   = 1;
				t.BANK = 2'd1;
			end
			if (lras && lcode == 4'h2 && (slot == 4'd2 || slot == 4'd6) && lpage_opened) begin
				t.CMD  = CTRL_CAS;
				t.COL  = laddr[10:2];
				t.WE   = 1;
				t.BE   = lwe;
				t.DATA = din[31:16];
				t.BANK = 2'd0;
			end
			if (rras && rcode == 4'h2 && (slot == 4'd3 || slot == 4'd7) && rpage_opened) begin
				t.CMD  = CTRL_CAS;
				t.COL  = raddr[10:2];
				t.WE   = 1;
				t.BE   = rwe;
				t.DATA = din[15:0];
				t.BANK = 2'd1;
			end
			// 3DO refresh. Skipped if it would follow a deferred slot-3
			// precharge by one cycle (tRP); the SEC refresh covers any gap.
			if (lras && (lcode == 4'h4 || lcode == 4'hC) && slot == 4'd4 && !r_pre_slot3) begin
				t.CMD  = CTRL_RAS;
				t.BANK = 2'd0;
				t.RFS  = 1;
				tdm_refresh_seen <= 1;
			end
			else if (!lras && !rras && (lcode == 4'h2) && slot == 4'd4 && !r_pre_slot3) begin
				t.CMD  = CTRL_RAS;
				t.BANK = 2'd0;
				t.RFS  = 1;
				tdm_refresh_seen <= 1;
			end
			// Page close: slot 0/1 as MiSTer, and while parked (MiSTer's parked
			// counter matched slot 0 too) so pages close in reset/pauses.
			// tRAS: if the page was opened only in the previous MCLK (slot 5/6
			// -> slot 0/1 would be 30 ns), the precharge moves to slot 2/3.
			if (!lras && lpage_opened && (((slot == 4'd0 || parked) && act_cnt[0] >= 4'd3) || slot == 4'd2)) begin
				t.CMD  = CTRL_PRE;
				t.BANK = 2'd0;
				lpage_opened <= 0;
			end
			if (!rras && rpage_opened && (((slot == 4'd1 || (parked && !(!lras && lpage_opened))) && act_cnt[1] >= 4'd3) || slot == 4'd3)) begin
				t.CMD  = CTRL_PRE;
				t.BANK = 2'd1;
				rpage_opened <= 0;
				r_pre_slot3 <= (slot == 4'd3);
			end
			if (slot == 4'd0) r_pre_slot3 <= 0;
		end
		tdm_s0 <= t;
	end

	// ------------------------------------------------------------------
	// SEC part
	// ------------------------------------------------------------------
	typedef enum bit [3:0] {
		S_IDLE,
		S_WAIT_QUIET,
		S_DRAIN,
		S_CLOSE_TDM,
		S_ACT,
		S_RCD,
		S_XFER,
		S_TAIL,
		S_PRE,
		S_RP,
		S_REOPEN,
		S_REOPEN_WAIT,
		S_REF_RP,
		S_REFRESH,
		S_REFRESH_WAIT,
		S_DONE
	} sec_state_t;
	sec_state_t sst;

	reg  [ 3:0] wait_cnt;
	reg  [ 4:0] quiet_cnt;
	reg  [ 9:0] xfer_cnt;
	reg  [ 8:0] col;
	reg  [ 9:0] rd_left;
	reg  [ 1:0] cur_bank;
	reg  [12:0] cur_row;
	reg         cur_we;
	reg  [10:0] ref_cnt;
	reg         ref_due;
	reg         reopen_l, reopen_r;
	reg         op_refresh;
	reg         paused_s, core_rst_s;

	always @(posedge clk) begin
		paused_s   <= SEC_PAUSED;
		core_rst_s <= CORE_RST;
	end
	wire quiet_ok = core_rst_s | paused_s;

	// The 3DO has stopped issuing MCLK slots (slot counter parked). While
	// parked, the TDM logic may keep repeating its slot-0 command (same read,
	// precharge); those are harmless and are muted once SEC takes the bus.
	// The first SEC data command is issued >5 cycles after sec_active, so the
	// last TDM read still in the pipeline completes undisturbed.
	wire tdm_idle = parked;

	assign SEC_HOLD = (sst != S_IDLE) || (sec_req && init_done) || ref_due;

	// SEC-side refresh, see REFRESH_CYCLES.
	always @(posedge clk) begin
		if (!init_done || tdm_refresh_seen || (sst == S_REFRESH)) ref_cnt <= '0;
		else if (ref_cnt != '1) ref_cnt <= ref_cnt + 1'd1;
		ref_due <= init_done && (ref_cnt >= REFRESH_CYCLES);
	end

	always @(posedge clk) begin
		state_t sec_cmd;
		sec_cmd = '0;
		sec_done   <= 0;

		if (!init_done) begin
			sst        <= S_IDLE;
			sec_active <= 0;
			reopen_l   <= 0;
			reopen_r   <= 0;
		end else begin
			case (sst)
				S_IDLE: begin
					sec_active <= 0;
					if (ref_due || (sec_req && !sec_done)) begin
						quiet_cnt <= '0;
						sst <= S_WAIT_QUIET;
					end
				end

				// Wait until the 3DO is frozen (SEC_HOLD has turned into PAUSE,
				// or the core is in reset) for a while, and the TDM part is idle.
				S_WAIT_QUIET: begin
					if (!quiet_ok) quiet_cnt <= '0;
					else if (quiet_cnt != '1) quiet_cnt <= quiet_cnt + 1'd1;
					if (quiet_cnt >= 5'd16 && tdm_idle) begin
						sec_active <= 1;
						wait_cnt <= 4'd2;
						sst <= S_DRAIN;
					end
				end

				S_DRAIN: begin
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else if (ref_due) begin
						// Refresh first; a pending transfer follows from S_IDLE.
						// AUTO REFRESH needs all banks closed: close the 3DO's
						// pages and re-open them afterwards.
						op_refresh <= 1;
						reopen_l <= lpage_opened;
						reopen_r <= rpage_opened;
						if (lpage_opened || rpage_opened) begin
							sec_cmd.CMD = CTRL_PRE;
							sec_cmd.ALL = 1;
							wait_cnt <= 4'd2;
							sst <= S_REF_RP;
						end else begin
							sst <= S_REFRESH;
						end
					end else if (!sec_req) begin
						// We left S_IDLE for a refresh, and the 3DO did its own
						// meanwhile (before the pause took effect), which cleared
						// ref_due. No transfer is waiting: release the bus. Going
						// on would have started a transfer from the inputs the
						// arbiter still presents (the last client's address,
						// direction and length, and stale write data), i.e. a
						// phantom write over the last address written.
						sst <= S_IDLE;
					end else begin
						op_refresh <= 0;
						cur_bank <= sec_addr[23:22];
						cur_row  <= sec_addr[21:9];
						col      <= sec_addr[8:0];
						cur_we   <= sec_we;
						xfer_cnt <= sec_len;
						rd_left  <= sec_we ? 10'd0 : sec_len;
						reopen_l <= 0;
						reopen_r <= 0;
						sst <= S_CLOSE_TDM;
					end
				end

				S_CLOSE_TDM: begin
					// Close a TDM page in the bank we are about to use.
					if (cur_bank == 2'd0 && lpage_opened) begin
						sec_cmd.CMD  = CTRL_PRE;
						sec_cmd.BANK = 2'd0;
						reopen_l <= 1;
						wait_cnt <= 4'd2;
						sst <= S_RP;
					end else if (cur_bank == 2'd1 && rpage_opened) begin
						sec_cmd.CMD  = CTRL_PRE;
						sec_cmd.BANK = 2'd1;
						reopen_r <= 1;
						wait_cnt <= 4'd2;
						sst <= S_RP;
					end else begin
						sst <= S_ACT;
					end
				end

				S_RP: begin
					// tRP after closing a TDM page
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else sst <= S_ACT;
				end

				S_ACT: begin
					sec_cmd.CMD  = CTRL_RAS;
					sec_cmd.BANK = cur_bank;
					sec_cmd.ROW  = cur_row;
					wait_cnt <= RASCAS_DELAY - 1'd1;
					sst <= S_RCD;
				end

				S_RCD: begin
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else sst <= S_XFER;
				end

				S_XFER: begin
					sec_cmd.CMD  = CTRL_CAS;
					sec_cmd.BANK = cur_bank;
					sec_cmd.COL  = col;
					sec_cmd.SEC  = 1;
					if (cur_we) begin
						sec_cmd.WE   = 1;
						sec_cmd.DATA = sec_wdata;
						sec_cmd.BE   = sec_wbe;
					end else begin
						sec_cmd.RD   = 1;
					end
					col      <= col + 1'd1;
					xfer_cnt <= xfer_cnt - 1'd1;
					if (xfer_cnt == 10'd1) begin
						// tWR (writes) / last read issued; also covers tRAS(min)=42ns
						wait_cnt <= 4'd4;
						sst <= S_TAIL;
					end
				end

				S_TAIL: begin
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else sst <= S_PRE;
				end

				S_PRE: begin
					sec_cmd.CMD  = CTRL_PRE;
					sec_cmd.BANK = cur_bank;
					wait_cnt <= 4'd2;
					sst <= S_REOPEN_WAIT;
				end

				S_REOPEN_WAIT: begin
					// tRP, and wait for the last read word to leave the pipeline
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else if (rd_left == 0) sst <= S_REOPEN;
				end

				S_REOPEN: begin
					// Re-activate the 3DO page(s) closed for this access/refresh
					// (tRRD between the two ACTIVEs, tRCD before the 3DO resumes).
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else if (reopen_l) begin
						sec_cmd.CMD  = CTRL_RAS;
						sec_cmd.BANK = 2'd0;
						sec_cmd.ROW  = lpage_row;
						reopen_l <= 0;
						wait_cnt <= 4'd2;
					end else if (reopen_r) begin
						sec_cmd.CMD  = CTRL_RAS;
						sec_cmd.BANK = 2'd1;
						sec_cmd.ROW  = rpage_row;
						reopen_r <= 0;
						wait_cnt <= 4'd2;
					end else begin
						sst <= S_DONE;
					end
				end

				S_REF_RP: begin
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else sst <= S_REFRESH;
				end

				S_REFRESH: begin
					sec_cmd.CMD  = CTRL_RAS;
					sec_cmd.RFS  = 1;
					wait_cnt <= 4'd7; // tRFC
					sst <= S_REFRESH_WAIT;
				end

				S_REFRESH_WAIT: begin
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else if (reopen_l || reopen_r) sst <= S_REOPEN;   // ends in S_DONE
					else sst <= S_IDLE;
				end

				S_DONE: begin
					// tRCD after a re-open so the 3DO can CAS right away
					if (wait_cnt) wait_cnt <= wait_cnt - 1'd1;
					else begin
						sec_done   <= !op_refresh;   // a refresh completes no client transfer
						sec_active <= 0;
						sst <= S_IDLE;
					end
				end

				default: sst <= S_IDLE;
			endcase

			if (sec_rvalid && rd_left) rd_left <= rd_left - 1'd1;
		end
		sec_s0 <= sec_cmd;
	end

	assign sec_wnext = (sst == S_XFER) && cur_we;

	// ------------------------------------------------------------------
	// Command pipeline (unchanged from MiSTer)
	// ------------------------------------------------------------------
	// Each part registers its command (as MiSTer registers state[0]). Both
	// were computed from the same pre-edge sec_active, so selecting with the
	// delayed copy never drops a command at a hand-over.
	always @(posedge clk) sec_own <= sec_active;
	always_comb state[0] = sec_own ? sec_s0 : tdm_s0;

	always @(posedge clk) begin
		for (int b = 0; b < 2; b++) begin
			if (state[0].CMD == CTRL_RAS && !state[0].RFS && state[0].BANK == 2'(b)) act_cnt[b] <= '0;
			else if (act_cnt[b] != '1) act_cnt[b] <= act_cnt[b] + 1'd1;
		end
	end

	always @(posedge clk) begin
		state[1] <= state[0];
		state[2] <= state[1];
		state[3] <= state[2];
		state[4] <= state[3];
		state[5] <= state[4];
		state[6] <= state[5];
		state[7] <= state[6];
	end

	wire [ 1:0] ctrl_cmd  = state[0].CMD;
	wire [12:0] ctrl_row  = state[0].ROW;
	wire [ 8:0] ctrl_col  = state[0].COL;
	wire [15:0] ctrl_data = state[0].DATA;
	wire        ctrl_we   = state[0].WE;
	wire [ 1:0] ctrl_be   = state[0].BE;
	wire [ 1:0] ctrl_bank = state[0].BANK;
	wire        ctrl_rfs  = state[0].RFS;

	// Read data capture, same timing as MiSTer: the DQ pins are registered
	// every cycle (rbuf) and picked up when the command reaches stage 5.
	(* IOB = "TRUE" *) reg [15:0] dq_in_r;
	reg [15:0] dq_prev;
	always @(posedge clk) begin
		dq_in_r <= SDRAM_DQ_IN;
		dq_prev <= dq_in_r;
	end

	always @(posedge clk) begin
		sec_rvalid <= 0;
		if (state[READ_STAGE].RD) begin
			if (state[READ_STAGE].SEC) begin
				sec_rdata  <= dq_in_r;
				sec_rvalid <= 1;
			end else begin
				dout <= {dq_prev, dq_in_r};   // {left, right}: left was read one slot earlier
			end
		end
	end

	localparam CMD_NOP             = 3'b111;
	localparam CMD_ACTIVE          = 3'b011;
	localparam CMD_READ            = 3'b101;
	localparam CMD_WRITE           = 3'b100;
	localparam CMD_PRECHARGE       = 3'b010;
	localparam CMD_AUTO_REFRESH    = 3'b001;
	localparam CMD_LOAD_MODE       = 3'b000;

	wire [1:0] dqm = ~ctrl_be;

	always @(posedge clk) begin
		if (ctrl_cmd == CTRL_RAS || ctrl_cmd == CTRL_CAS || ctrl_cmd == CTRL_PRE) SDRAM_BA <= (mode == MODE_NORMAL) ? ctrl_bank : 2'b00;

		casex ({init_done,ctrl_rfs,ctrl_we,mode,ctrl_cmd})
			{3'bX0X, MODE_NORMAL, CTRL_RAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_ACTIVE,1'b0};
			{3'bX1X, MODE_NORMAL, CTRL_RAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_AUTO_REFRESH,1'b0};
			{3'b101, MODE_NORMAL, CTRL_CAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_WRITE,1'b0};
			{3'b100, MODE_NORMAL, CTRL_CAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_READ,1'b0};
			{3'b10X, MODE_NORMAL, CTRL_PRE}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_PRECHARGE,1'b0};
			{3'bXXX,    MODE_LDM, CTRL_RAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_LOAD_MODE, 1'b0};
			{3'bXXX,    MODE_PRE, CTRL_RAS}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_PRECHARGE, 1'b0};
			default:                         {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_nCS} <= {CMD_NOP,1'b1};
		endcase

		SDRAM_DQ_OE <= 0;
		if ({init_done,ctrl_rfs,ctrl_we,mode,ctrl_cmd} ==? {3'b101, MODE_NORMAL, CTRL_CAS}) begin
			SDRAM_DQ_OUT <= ctrl_data;
			SDRAM_DQ_OE  <= 1;
		end

		// DQM: masks for writes, always enabled for reads
		SDRAM_DQM <= 2'b00;
		if (mode == MODE_NORMAL) begin
			casex ({ctrl_we,ctrl_cmd})
				{1'bX,CTRL_RAS}: SDRAM_A <= ctrl_row;
				{1'b0,CTRL_CAS}: SDRAM_A <= {4'b0000, ctrl_col};
				{1'b1,CTRL_CAS}: begin SDRAM_A <= {4'b0000, ctrl_col}; SDRAM_DQM <= dqm; end
				{1'bX,CTRL_PRE}: SDRAM_A <= {2'b00, state[0].ALL, 10'b0000000000}; // A10: all banks
			endcase
		end
		else if (mode == MODE_LDM && ctrl_cmd == CTRL_RAS) SDRAM_A <= MODE;
		else if (mode == MODE_PRE && ctrl_cmd == CTRL_RAS) SDRAM_A <= 13'b0010000000000; // all banks
		else SDRAM_A <= '0;
	end

	assign SDRAM_CKE = 1'b1;

	// SDRAM clock: inverted copy of clk_mem through an output DDR register
	// (MiSTer uses altddio_out with datain_h=0/datain_l=1 for the same).
	ODDR #(
		.DDR_CLK_EDGE("OPPOSITE_EDGE"),
		.INIT(1'b0),
		.SRTYPE("SYNC")
	) sdram_clk_oddr (
		.Q (SDRAM_CLK),
		.C (clk),
		.CE(1'b1),
		.D1(1'b0),
		.D2(1'b1),
		.R (1'b0),
		.S (1'b0)
	);

endmodule
