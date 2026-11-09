// VRAM read-transfer cache with prefetch (Game Bub 3DO core).
//
// Why: on MiSTer, VRAM that is not in block RAM lives in DDR3. On Game Bub it
// lives in the single 16-bit SDRAM, which the 3DO's own DRAM uses in lock
// step; the SDRAM can only be used by other clients after the 3DO has been
// paused, and a 128-beat transfer (one half VRAM row) takes ~5.5 us after
// ~0.5 us of latency. MADAM's video DMA starts shifting a freshly loaded VRAM
// row out after ~160 ns, and the video beam cannot be paused, so the display
// showed stale shift-register data.
//
// What: every read transfer (RT) that the VRAM modules send to the external
// path (ESRD) is served from this cache. Granularity is one half VRAM row
// (256 words per side = 128 beats of 64 bits, the unit of a split transfer
// and of a ddram.sv burst). On a hit the beats are delivered on chip within a
// few cycles; on a miss an entry is allocated, filled through ddram.sv (both
// sides in one burst) and delivered as the beats arrive. Every request for
// half-row h prefetches h+1 and h+2: video DMA walks the framebuffer
// sequentially, so displayed rows are normally in the cache before they are
// needed, wherever the framebuffer is.
//
// The top of a frame cannot be predicted from the previous request: when a
// VDL entry loads new frame buffer addresses, MADAM_AG.sv passes them on
// (hint) and they are prefetched before anything else that is queued. The
// video DMA's first transfers from them come ~7 us later, about the time a
// fill takes; without this the first line's transfer missed, its fill
// paused MADAM past the start of the line, and the line showed the VDL
// words left in the serial register.
//
// At the start of each frame (vertical blanking) the first half-rows of the
// last two frame buffers are fetched again, so the first line hits even when
// its VDL entry is processed late and the hint comes too close to the line.
//
// Prefetch fills start only once no transfer request has come for 1.28 us:
// the video DMA issues a line's transfers (both VRAM halves) within ~0.3 us,
// and a fill pauses the 3DO for ~6 us, which held the second of them back
// past the start of the line when a prefetch started after the first.
//
// A VRAM module's read of a write transfer's destination row (vram.sv, a
// write mask: the row is read, merged and written back) is not for the
// display: it prefetches nothing (l_esnp / r_esnp) and leaves the queued
// prefetches alone. Its prefetches would have evicted the display's rows,
// and the fill of the row after it waited behind the merged write burst.
//
// For the same reason a demand fill for one side waits while MADAM is still
// in its video DMA sequence (vid_dma), until the other side has requested
// too, or 2 us have passed. When a line's first transfer missed, the fill
// (~3.8 us) used to start at once and pause the 3DO before MADAM had issued
// the line's second transfer, ~0.15 us later, which then came after the
// start of the line. The first side is not delayed in effect: its beats
// arrive long before the beam needs them. The second side hits the entry
// being filled (same half-row), or misses and is served by the same fill.
//
// Coherence: writes are snooped where they become visible to later reads,
// at ddram.sv's committed DDRAM write commands. A single-beat write updates
// the enabled bytes of an idle cached half-row instead of evicting it: a
// CEL write after prefetch otherwise caused a cold video read, and fills
// for different previous/current rows ran in sequence past scanout.
// Write bursts and flash writes still invalidate matching entries. A
// delivery or fill in progress also retains the original invalidation
// behavior, keeping the serial snapshot intact and dropping dirty fills.
// The stat_invalidations counter continues to count matched write snoops,
// including the single-beat updates.
//
// ddram.sv's burst interface is shared: fills use both sides' read inputs
// (same address, so ddram.sv runs one combined burst), MWT write bursts and
// flash writes from the VRAM modules pass through unchanged but are held off
// while a fill owns the burst interface.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module vram_rtcache #(
	parameter int ENTRIES = 16          // power of two
)(
	input              clk,                // clk_mem
	input              rst,

	input      [ 3: 0] BRAM1_OFFS,         // on-chip VRAM block (never cached)

	// VRAM modules, external path
	input              l_esrd,
	input              l_esnp,             // the request is not for the display: no prefetch
	input      [17: 0] l_esaddr,
	input              l_eswr,
	input              l_esfw,
	output             l_este,
	output     [31: 0] l_esq,
	input              r_esrd,
	input              r_esnp,
	input      [17: 0] r_esaddr,
	input              r_eswr,
	output             r_este,
	output     [31: 0] r_esq,

	// ddram.sv burst interface
	output     [17: 0] d_bladdr,
	output reg         d_blrd,
	output             d_blwr,
	output             d_bfw,
	output     [17: 0] d_braddr,
	output reg         d_brrd,
	output             d_brwr,
	input              d_blte,
	input              d_brte,
	input      [63: 0] d_bout,
	input      [ 9: 2] d_ba,
	input              d_bbusy,

	// snoop: ddram.sv DDRAM write commands
	input              ddr_we,
	input      [28: 0] ddr_addr,
	input      [63: 0] ddr_din,
	input      [ 7: 0] ddr_be,
	input      [ 7: 0] ddr_burstcnt,

	// start of a frame (MADAM SPORT LINE0, in vertical blanking; clk_sys
	// pulse, taken on its rising edge)
	input              frame,
	input              vid_dma,            // MADAM's bus is in a video DMA sequence (clk_sys, phase aligned)
	// framebuffer addresses a VDL entry has just loaded (MADAM_AG.sv; level
	// from the clk_sys domain, new on its rising edge): prefetched first
	input              hint,
	input      [17: 0] hint_curr,
	input              hint_curr_v,
	input      [17: 0] hint_prev,
	input              hint_prev_v,

	// statistics (simulation / debug)
	output reg [31: 0] stat_hits,
	output reg [31: 0] stat_misses,
	output reg [31: 0] stat_prefetches,
	output reg [31: 0] stat_invalidations,
	output reg [31: 0] stat_hints
);
	localparam int EW = $clog2(ENTRIES);

	// Timing at 100 MHz: requests are registered before the tag lookup,
	// the fill engine works from registered lookup results, snoops are
	// registered, and replacement is a second-chance ("clock") pointer that
	// advances one entry per cycle, so no path depends on ENTRIES serially.

	// ------------------------------------------------------------------
	// Entries
	// ------------------------------------------------------------------
	reg  [ 9:0] tag      [ENTRIES];   // half-row index (VRAM word address [17:8])
	reg         valid    [ENTRIES];   // allocated (filled, or filling)
	reg  [ 7:0] filled   [ENTRIES];   // beats available, 0..128
	reg         dirty    [ENTRIES];   // written while filling: drop when the fill ends
	reg         used     [ENTRIES];   // second-chance bit

	(* ram_style = "block" *) reg [63:0] data [0:ENTRIES*128-1];

	// on-chip VRAM regions (vram.sv USE_INT_RAM1) are never requested here,
	// and must not be prefetched either
	function automatic bit is_internal(input [9:0] h);
		bit [17:0] w;
		w = {h, 8'h00};
		is_internal = (w >= ({BRAM1_OFFS, 16'h0000} >> 2) && w <= ({BRAM1_OFFS, 16'hBFFF} >> 2)) ||
		              (w >= (20'hFC000 >> 2));
	endfunction

	// tag lookup: one-hot match, then encode (shallow)
	function automatic [EW:0] find(input [9:0] h);
		bit [ENTRIES-1:0] m;
		bit [EW-1:0] e;
		for (int i = 0; i < ENTRIES; i++) m[i] = valid[i] && tag[i] == h;
		e = '0;
		for (int i = 0; i < ENTRIES; i++) if (m[i]) e = e | EW'(i);
		find = {|m, e};
	endfunction

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	reg         fill_busy;        // fill issued, ddram.sv burst in progress
	reg         fill_issue;       // one-cycle request pulse to ddram.sv
	reg [EW-1:0] fill_e;
	reg  [ 9:0] fill_h;

	reg         req_v    [2];     // registered new requests (ESRD)
	reg         req_np   [2];     // ... not for the display (ESNP)
	reg  [17:0] req_a    [2];

	reg         dem_pend [2];     // demand misses waiting for an entry
	reg  [ 9:0] dem_h    [2];
	reg  [ 7:0] dem_beat [2];

	reg         pf_v [2];         // prefetch queue
	reg  [ 9:0] pf_h [2];
	reg         pf_hint [2];      // queued by a VDL hint: not held off

	reg         dl_act  [2];      // delivery per side
	reg [EW-1:0] dl_e   [2];
	reg  [ 7:0] dl_beat [2];

	// registered lookups for the fill engine. They describe dem_h/pf_h of
	// the previous cycle; those change only when a request is processed, so
	// no fill starts in that cycle and the next one (req_d). A stale result
	// would drop a prefetch or allocate a second entry for a cached tag.
	reg         hit_d [2], hit_p [2];
	reg         req_d;

	// Prefetch fills wait until no transfer request has come for PF_HOLDOFF
	// cycles. MADAM's video DMA issues the transfers of a line (both VRAM
	// halves, previous and current line) within ~0.3 us of each other, and a
	// fill pauses the 3DO for ~6 us (SDRAM): a prefetch started after the
	// first of them held the others back past the start of the line, which
	// then showed the serial register's old contents. Demand fills start at
	// once. (Counting from the end of fills too was tried: the second half of
	// a full-row transfer, requested as the first half's fill ends, then
	// missed instead of hitting its prefetch.)
	localparam int PF_HOLDOFF = 128;   // clk_mem cycles, 1.28 us
	// Demand fills for one side wait for the other side's request while the
	// video DMA sequence runs (see the header), at most DEM_HOLD_MAX.
	localparam int DEM_HOLD_MAX = 200; // clk_mem cycles, 2 us
	reg  [ 7:0] dem_age;               // cycles a demand miss has waited
	wire        dem_hold = vid_dma && (dem_pend[0] != dem_pend[1]) && dem_age < 8'(DEM_HOLD_MAX);
	reg  [ 7:0] req_age;
	wire        pf_quiet = req_age >= 8'(PF_HOLDOFF);

	// VDL framebuffer hint: waits for a cycle without a request (requests
	// write the prefetch queue too), then replaces the queued prefetches.
	// hint_q blocks fill starts for the cycle after, when hit_p is stale.
	reg         hint_d, hint_pend, hint_q, hint_v2;
	reg  [ 9:0] hint_h1, hint_h2;

	// Frame start again at the start of each frame (vertical blanking, ~20
	// lines before the picture): the first half-rows of the last two frame
	// buffers the VDL pointed at (double buffering) are queued like a hint.
	// The next frame's first line then hits even if its VDL entry is
	// processed late, e.g. behind a CPU access to CLIO, when the hint itself
	// comes too close to the line. (Detecting vertical blanking from idle
	// time was tried: CPU accesses to CLIO can hold the video DMA back that
	// long in the middle of a frame, and the fill then delayed a line.)
	reg         frame_d, frame_pend;
	reg  [ 9:0] last_h [2];
	reg         last_v [2];

	// registered snoops
	reg         sn_we;
	reg  [ 9:0] sn_h;
	reg  [ 6:0] sn_beat;
	reg  [63:0] sn_data;
	reg  [ 7:0] sn_be;
	reg         sn_single;
	reg  [EW-1:0] sn_e;         // entry holding sn_h when the write was issued
	reg         sn_hit;
	reg         sn_fw;
	reg  [ 8:0] sn_row;

	// write bursts / flash writes from the VRAM pass when no fill owns ddram.sv
	assign d_blwr = l_eswr & ~fill_busy & ~fill_issue;
	assign d_brwr = r_eswr & ~fill_busy & ~fill_issue;
	assign d_bfw  = l_esfw;
	assign d_bladdr = fill_issue ? {fill_h, 8'h00} : l_esaddr;
	assign d_braddr = fill_issue ? {fill_h, 8'h00} : r_esaddr;

	function automatic bit entry_busy(input [EW-1:0] e);
		entry_busy = (fill_busy && fill_e == e) || (dl_act[0] && dl_e[0] == e) || (dl_act[1] && dl_e[1] == e);
	endfunction

	// second-chance victim pointer: stops on an entry that is free, or valid
	// and not recently used, and not busy; otherwise clears the used bit and
	// moves on (one entry per cycle)
	reg [EW-1:0] vptr;
	wire         v_ok = !entry_busy(vptr) && (!valid[vptr] || !used[vptr]);

	// cache-side ESTE/ESQ, merged with ddram.sv's write-burst steps
	reg         c_l_este, c_r_este;
	reg  [31:0] c_l_esq, c_r_esq;
	assign l_este = c_l_este | (d_blte & l_eswr & ~fill_busy);
	assign r_este = c_r_este | (d_brte & r_eswr & ~fill_busy);
	assign l_esq  = c_l_esq;
	assign r_esq  = c_r_esq;

	// ------------------------------------------------------------------
	// Delivery read port: one beat per cycle, alternating between sides
	// ------------------------------------------------------------------
	reg         rd_side;
	reg         rd_v;
	reg  [63:0] rd_q;
	reg         rr;
	wire [ 7:0] fl0 = filled[dl_e[0]];
	wire [ 7:0] fl1 = filled[dl_e[1]];
	wire        want0 = dl_act[0] && (dl_beat[0] < fl0);
	wire        want1 = dl_act[1] && (dl_beat[1] < fl1);
	wire        rd_s  = want1 && (!want0 || rr);
	wire        do_rd = want0 || want1;
	wire [EW+6:0] rd_addr = rd_s ? {dl_e[1], dl_beat[1][6:0]} : {dl_e[0], dl_beat[0][6:0]};

	always @(posedge clk) rd_q <= data[rd_addr];

	// Update enabled bytes of idle cached rows on committed single-beat writes.
	// Bursts retain their base address; they and active deliveries still invalidate.
	// One byte-enabled write port, shared by fills and committed writes.
	// Keeping its address/data mux outside the RAM write process preserves
	// block-RAM inference on the Game Bub FPGA. ddram.sv takes no write
	// command while a fill's read burst runs, so the two never meet; should
	// they, the fill writes and the snooped entry is invalidated instead.
	// The entry is looked up a cycle early, on the write command's address
	// (sn_e/sn_hit, registered with the other snoop inputs), so the block
	// RAM's write address does not wait for the 16-way tag compare. In the
	// merge cycle one compare checks that entry still holds the half-row: a
	// fill issued in between sets the tag, valid and fill_busy together, so a
	// re-used entry is busy and not merged; an entry that became valid in
	// between is not merged either. Either way the snoop invalidates it
	// (snoop_hit, compared afresh), as for any write it does not merge.
	wire fill_write = fill_busy && d_blte;
	wire sn_merge = sn_we && sn_single && sn_hit && valid[sn_e] && tag[sn_e] == sn_h &&
	                !entry_busy(sn_e) && !fill_write;
	wire [EW+6:0] data_wa = fill_write ? {fill_e, d_ba[8:2]} : {sn_e, sn_beat};
	wire [63:0] data_wd = fill_write ? d_bout : sn_data;
	wire [7:0] data_wbe = fill_write ? 8'hFF : sn_merge ? sn_be : 8'h00;
	always @(posedge clk) begin
		for (int b = 0; b < 8; b++)
			if (data_wbe[b]) data[data_wa][b*8 +: 8] <= data_wd[b*8 +: 8];
	end

	wire [EW:0] fdem0 = find(dem_h[0]);
	wire [EW:0] fdem1 = find(dem_h[1]);
	wire [EW:0] fpf0  = find(pf_h[0]);
	wire [EW:0] fpf1  = find(pf_h[1]);
	// a waiting demand miss resolves (finds its entry) in this cycle
	wire        dres0 = dem_pend[0] && !req_v[0] && fdem0[EW];
	wire        dres1 = dem_pend[1] && !req_v[1] && fdem1[EW];

	// entries hit by a registered snoop
	wire [ENTRIES-1:0] snoop_hit;
	genvar gi;
	generate
		for (gi = 0; gi < ENTRIES; gi = gi + 1) begin : g_snoop
			assign snoop_hit[gi] = valid[gi] && ((sn_we && tag[gi] == sn_h) || (sn_fw && tag[gi][9:1] == sn_row));
		end
	endgenerate

	// ------------------------------------------------------------------
	// Control
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		c_l_este   <= 0;
		c_r_este   <= 0;
		fill_issue <= 0;
		d_blrd     <= 0;
		d_brrd     <= 0;

		// registered inputs
		req_d    <= req_v[0] | req_v[1];
		if (l_esrd || r_esrd || req_v[0] || req_v[1]) req_age <= '0;
		else if (!pf_quiet) req_age <= req_age + 1'd1;
		frame_d <= frame;
		if (frame && !frame_d && last_v[0]) frame_pend <= 1;
		hint_d   <= hint;
		hint_q   <= 0;
		req_v[0] <= l_esrd; req_a[0] <= l_esaddr; req_np[0] <= l_esnp;
		req_v[1] <= r_esrd; req_a[1] <= r_esaddr; req_np[1] <= r_esnp;
		sn_we  <= ddr_we && ddr_addr[24:17] == '0;
		sn_h   <= ddr_addr[16:7];
		sn_beat <= ddr_addr[6:0];
		sn_data <= ddr_din;
		sn_be <= ddr_be;
		sn_single <= ddr_burstcnt == 8'd1;
		{sn_hit, sn_e} <= find(ddr_addr[16:7]);
		sn_fw  <= l_esfw;
		sn_row <= l_esaddr[17:9];
		hit_d[0] <= fdem0[EW];
		hit_d[1] <= fdem1[EW];
		hit_p[0] <= fpf0[EW];
		hit_p[1] <= fpf1[EW];

		if (rst) begin
			for (int i = 0; i < ENTRIES; i++) begin
				valid[i] <= 0; filled[i] <= '0; dirty[i] <= 0; used[i] <= 0;
			end
			fill_busy <= 0;
			req_v[0] <= 0; req_v[1] <= 0;
			dem_pend[0] <= 0; dem_pend[1] <= 0;
			pf_v[0] <= 0; pf_v[1] <= 0;
			pf_hint[0] <= 0; pf_hint[1] <= 0;
			dl_act[0] <= 0; dl_act[1] <= 0;
			rd_v <= 0;
			vptr <= '0;
			stat_hits <= '0; stat_misses <= '0; stat_prefetches <= '0; stat_invalidations <= '0;
			stat_hints <= '0;
			hint_pend <= 0;
			req_age   <= '0;
			dem_age   <= '0;
			last_v[0] <= 0; last_v[1] <= 0;
			frame_pend <= 0;
		end else begin
			// ---------------- demand wait ----------------
			if (!dem_pend[0] && !dem_pend[1]) dem_age <= '0;
			else if (dem_age != 8'hFF)         dem_age <= dem_age + 1'd1;

			// ---------------- victim pointer ----------------
			if (!v_ok) begin
				if (valid[vptr] && used[vptr] && !entry_busy(vptr)) used[vptr] <= 0;
				vptr <= vptr + 1'd1;
			end

			// ---------------- requests (registered) ----------------
			for (int s = 0; s < 2; s++) begin
				if (req_v[s]) begin
					bit [EW:0] f;
					bit [9:0]  h;
					h = req_a[s][17:8];
					f = find(h);
					if (f[EW]) begin
						stat_hits <= stat_hits + 1'd1;
						dl_act[s]  <= 1;
						dl_e[s]    <= f[EW-1:0];
						dl_beat[s] <= {1'b0, req_a[s][7:1]};
						used[f[EW-1:0]] <= 1;
					end else begin
						stat_misses <= stat_misses + 1'd1;
						dem_pend[s] <= 1;
						dem_h[s]    <= h;
						dem_beat[s] <= {1'b0, req_a[s][7:1]};
					end
					if (!req_np[s]) begin
						if (!is_internal(10'(h + 1))) begin pf_v[0] <= 1; pf_h[0] <= 10'(h + 1); pf_hint[0] <= 0; end
						if (!is_internal(10'(h + 2))) begin pf_v[1] <= 1; pf_h[1] <= 10'(h + 2); pf_hint[1] <= 0; end
					end
				end
			end

			// ---------------- demand waiting for an entry ----------------
			for (int s = 0; s < 2; s++) begin
				if ((s == 0) ? dres0 : dres1) begin
					bit [EW:0] f;
					f = (s == 0) ? fdem0 : fdem1;
					begin
						dem_pend[s] <= 0;
						dl_act[s]   <= 1;
						dl_e[s]     <= f[EW-1:0];
						dl_beat[s]  <= dem_beat[s];
						used[f[EW-1:0]] <= 1;
					end
				end
			end

			// ---------------- start a fill ----------------
			// demand misses first, then prefetches; ddram.sv must be idle and
			// no VRAM write burst or flash write may be starting; not while a
			// request is being looked up (the victim could be what it hits)
			if (!fill_busy && !fill_issue && !d_bbusy && !l_eswr && !r_eswr && !l_esfw &&
			    !req_v[0] && !req_v[1] && !req_d && !hint_q && !l_esrd && !r_esrd && !dres0 && !dres1 && v_ok) begin
				bit        go;
				bit [9:0]  nh;
				bit        from_pf, from_hint;
				go = 0; from_pf = 0; from_hint = 0; nh = '0;
				if (dem_pend[0] && !hit_d[0]) begin if (!dem_hold) begin go = 1; nh = dem_h[0]; end end
				else if (dem_pend[1] && !hit_d[1]) begin if (!dem_hold) begin go = 1; nh = dem_h[1]; end end
				else if (pf_v[0] && (pf_quiet || pf_hint[0])) begin
					from_pf = 1;
					from_hint = pf_hint[0];
					if (!hit_p[0]) begin go = 1; nh = pf_h[0]; end
					pf_v[0] <= 0;
				end else if (pf_v[1] && (pf_quiet || pf_hint[1])) begin
					from_pf = 1;
					from_hint = pf_hint[1];
					if (!hit_p[1]) begin go = 1; nh = pf_h[1]; end
					pf_v[1] <= 0;
				end
				if (go) begin
					tag[vptr]    <= nh;
					valid[vptr]  <= 1;
					filled[vptr] <= '0;
					dirty[vptr]  <= 0;
					used[vptr]   <= !from_pf || from_hint;   // unused prefetches are evicted first,
					                                         // frame-start rows are kept
					fill_e       <= vptr;
					fill_h       <= nh;
					fill_issue   <= 1;
					d_blrd       <= 1;
					d_brrd       <= 1;
					fill_busy    <= 1;
					vptr         <= vptr + 1'd1;
					if (from_pf) stat_prefetches <= stat_prefetches + 1'd1;
				end
			end

			// ---------------- VDL framebuffer hint ----------------
			// The first line needs the first half-row of the current frame
			// buffer, and that of the previous one (the other VRAM half) if it
			// is another row. Only those: a second fill (~6 us) would not end
			// before the line's transfers either. The next half-row is
			// prefetched by the line's first transfer, as usual. Hinted
			// prefetches are not held off: the VDL's own transfers have been
			// issued, and the video DMA's come ~7 us later.
			if (hint && !hint_d && (hint_curr_v || hint_prev_v)) begin
				bit [9:0] c, p;
				c = hint_curr_v ? hint_curr[17:8] : hint_prev[17:8];
				p = hint_prev_v ? hint_prev[17:8] : c;
				hint_pend <= 1;
				hint_h1   <= c;
				hint_h2   <= p;
				hint_v2   <= p != c;
				stat_hints <= stat_hints + 1'd1;
				if (!last_v[0] || c != last_h[0]) begin
					last_h[1] <= last_h[0]; last_v[1] <= last_v[0];
					last_h[0] <= c;         last_v[0] <= 1;
				end
			end
			else if (hint_pend && !req_v[0] && !req_v[1]) begin
				hint_pend <= 0;
				hint_q    <= 1;
				pf_v[0] <= !is_internal(hint_h1); pf_h[0] <= hint_h1; pf_hint[0] <= 1;
				if (hint_v2) begin pf_v[1] <= !is_internal(hint_h2); pf_h[1] <= hint_h2; pf_hint[1] <= 1; end
			end
			else if (frame_pend) begin
				frame_pend <= 0;
				hint_pend <= 1;
				hint_h1   <= last_h[0];
				hint_h2   <= last_h[1];
				hint_v2   <= last_v[1];
			end

			// ---------------- fill progress ----------------
			if (fill_busy && d_blte) begin
				filled[fill_e] <= {1'b0, d_ba[8:2]} + 8'd1;
				if (d_ba[8:2] == 7'd127) begin
					fill_busy <= 0;
					if (dirty[fill_e]) valid[fill_e] <= 0;   // data kept for a delivery in progress
				end
			end

			// ---------------- delivery ----------------
			rd_v    <= do_rd;
			rd_side <= rd_s;
			if (do_rd) begin
				rr <= ~rd_s;
				dl_beat[rd_s] <= dl_beat[rd_s] + 1'd1;
				if (dl_beat[rd_s] == 8'd127) dl_act[rd_s] <= 0;
			end
			if (rd_v) begin
				if (!rd_side) begin
					c_l_este <= 1;
					c_l_esq  <= {rd_q[63:48], rd_q[31:16]};
				end else begin
					c_r_este <= 1;
					c_r_esq  <= {rd_q[47:32], rd_q[15: 0]};
				end
			end

			// ---------------- coherence (registered snoops) ----------------
			// A write registered here was issued to ddram.sv one cycle earlier;
			// ddram.sv is serial, so no fill can start in between.
			for (int i = 0; i < ENTRIES; i++) begin
				if (snoop_hit[i]) begin
					if (fill_busy && fill_e == EW'(i)) dirty[i] <= 1;
					else if (sn_fw || !sn_merge) valid[i] <= 0;
				end
			end
			if (|snoop_hit) stat_invalidations <= stat_invalidations + 1'd1;
		end
	end

	// The VRAM modules sample ESQ in the cycle ESTE is high. Write bursts
	// (MWT) step on ddram.sv's ESTE pulses, passed through above only when no
	// fill owns ddram.sv. A delivery whose entry is invalidated meanwhile
	// completes with the data read so far (as ddram.sv would have returned).
endmodule
