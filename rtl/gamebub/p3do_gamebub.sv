// 3DO Interactive Multiplayer core for Game Bub - top level.
//
// Port of the MiSTer 3DO core (https://github.com/MiSTer-devel/3DO_MiSTer,
// srg320) to the Game Bub framework (Xilinx XC7A100T, one 32 MiB SDRAM).
// This module takes the place of MiSTer's 3DO.sv (emu) top level:
//
//   MiSTer                         Game Bub
//   -----------------------------  --------------------------------------------
//   SDRAM: 3DO DRAM (sdram.sv)     sdram_3do.sv TDM part, same scheduling
//   DDR3: VRAM overflow, BIOS,     ddram.sv unchanged, on ddr_bridge.sv ->
//         kanji, NVRAM             SDRAM secondary port, bank 2
//   HPS: CD image streaming        ISO preloaded into SDRAM, cdd_emu.sv
//   HPS: BIOS/kanji/save loading   host files (files.json) via gb_host.sv
//   BRAM VRAM (448 KiB)            BRAM1 region only (64 KiB): the
//                                  framework's double framebuffer needs the
//                                  rest of the XC7A100T block RAM
//   video_mixer/scaler             framework framebuffer, 320x240, 18-bit
//
// Copyright (c) 2026 Adam Polkosnik. Derived from the MiSTer 3DO core
// (c) srg320, GPL-3.0.
// SPDX-License-Identifier: GPL-3.0-or-later

module p3do_gamebub #(
	parameter int DISPLAY_DIVIDER = 31
)(
	input  logic        clock,
	input  logic        reset,
	input  logic        clocks_clockIn50M,
	output logic        clocks_clockOutSystem,
	output logic        clocks_clockOutDisplay,
	output logic        clocks_clockOutSpi,
	output logic        clocks_locked,
	output logic [5:0]  video_data_r,
	output logic [5:0]  video_data_g,
	output logic [5:0]  video_data_b,
	output logic        video_dataEnable,
	output logic        video_vblank,
	output logic        video_hblank,
	output logic [15:0] audio_left,
	output logic [15:0] audio_right,
	input  logic        host_mem_enable,
	input  logic        host_mem_write,
	output logic        host_mem_done,
	input  logic [31:0] host_mem_address,
	output logic [31:0] host_mem_dataRead,
	input  logic [31:0] host_mem_dataWrite,
	input  logic        host_commandHost_request,
	output logic        host_commandHost_busy,
	output logic        host_commandHost_done,
	output logic        host_commandHost_error,
	output logic        host_commandCore_request,
	input  logic        host_commandCore_busy,
	input  logic        host_commandCore_done,
	input  logic        host_commandCore_error,
	input  logic        input_buttons_a,
	input  logic        input_buttons_b,
	input  logic        input_buttons_x,
	input  logic        input_buttons_y,
	input  logic        input_buttons_up,
	input  logic        input_buttons_down,
	input  logic        input_buttons_left,
	input  logic        input_buttons_right,
	input  logic        input_buttons_l,
	input  logic        input_buttons_r,
	input  logic        input_buttons_start,
	input  logic        input_buttons_select,
	output logic        sdram_clock,
	output logic        sdram_cke,
	output logic        sdram_cs,
	output logic        sdram_ras,
	output logic        sdram_cas,
	output logic        sdram_we,
	output logic [1:0]  sdram_dqm,
	output logic [1:0]  sdram_bank,
	output logic [12:0] sdram_address,
	input  logic [15:0] sdram_dataIn,
	output logic [15:0] sdram_dataOut,
	output logic        sdram_dataDir
);
	/////////////////////////  CLOCKS / RESET  ///////////////////////////////
	wire clk_mem, clk_vid, clk_sys_gen;

	gb_clocks #(.DISPLAY_DIVIDER(DISPLAY_DIVIDER)) clocks (
		.clk_in_50mhz(clocks_clockIn50M),
		.clk_sys     (clk_sys_gen),
		.clk_mem     (clk_mem),
		.clk_spi     (clocks_clockOutSpi),
		.clk_disp    (clocks_clockOutDisplay),
		.clk_vid     (clk_vid),
		.locked      (clocks_locked)
	);
	assign clocks_clockOutSystem = clk_sys_gen;

	// The framework clocks this module (and all interfaces) with the system
	// clock we generate; use that net for all clk_sys logic.
	wire clk_sys = clock;

	// clk_mem reset (synchronous release)
	(* ASYNC_REG = "TRUE" *) reg [2:0] rst_mem_s = '1;
	always @(posedge clk_mem) rst_mem_s <= {rst_mem_s[1:0], reset};
	wire rst_mem = rst_mem_s[2];

	// clk_vid reset
	(* ASYNC_REG = "TRUE" *) reg [2:0] rst_vid_s = '1;
	always @(posedge clk_vid) rst_vid_s <= {rst_vid_s[1:0], reset};
	wire rst_vid = rst_vid_s[2];

	/////////////////////////  HOST INTERFACE  ///////////////////////////////
	wire        core_halt, core_reset_pulse, focus, HOST_LE;
	wire        disc_present, bios_loaded, kanji_loaded;
	wire [24:0] disc_bytes;
	wire [ 1:0] cd_speed;
	wire [ 1:0] region_sel;
	wire        bios_pal;
	wire        disc_stream, disc_change;
	wire        toc_we, sb_we;
	wire [ 8:0] toc_wa;
	wire [ 9:0] sb_wa;
	wire [31:0] toc_wd, sb_wd;
	wire [31:0] core_cmd_words [4];
	wire        nvram_wr;

	wire        host_sec_req, host_sec_we;
	wire [23:0] host_sec_addr;
	wire [ 9:0] host_sec_len;
	wire [15:0] host_sec_wdata;
	wire [ 1:0] host_sec_wbe;
	wire        host_sec_wnext, host_sec_rvalid, host_sec_done;

	gb_host host (
		.clk             (clk_sys),
		.reset           (reset),
		.mem_address     (host_mem_address),
		.mem_enable      (host_mem_enable),
		.mem_write       (host_mem_write),
		.mem_dataRead    (host_mem_dataRead),
		.mem_dataWrite   (host_mem_dataWrite),
		.mem_done        (host_mem_done),
		.cmd_request     (host_commandHost_request),
		.cmd_busy        (host_commandHost_busy),
		.cmd_done        (host_commandHost_done),
		.cmd_error       (host_commandHost_error),
		.core_halt       (core_halt),
		.core_reset_pulse(core_reset_pulse),
		.focus           (focus),
		.HOST_LE         (HOST_LE),
		.disc_present    (disc_present),
		.disc_bytes      (disc_bytes),
		.bios_loaded     (bios_loaded),
		.kanji_loaded    (kanji_loaded),
		.cd_speed        (cd_speed),
		.region_sel      (region_sel),
		.bios_pal        (bios_pal),
		.disc_stream     (disc_stream),
		.disc_change     (disc_change),
		.toc_we          (toc_we),
		.toc_wa          (toc_wa),
		.toc_wd          (toc_wd),
		.sb_we           (sb_we),
		.sb_wa           (sb_wa),
		.sb_wd           (sb_wd),
		.core_cmd_words  (core_cmd_words),
		.nvram_wr        (nvram_wr),
		.clk_mem         (clk_mem),
		.rst_mem         (rst_mem),
		.sec_req         (host_sec_req),
		.sec_we          (host_sec_we),
		.sec_addr        (host_sec_addr),
		.sec_len         (host_sec_len),
		.sec_wdata       (host_sec_wdata),
		.sec_wbe         (host_sec_wbe),
		.sec_wnext       (host_sec_wnext),
		.sec_rdata       (sec_rdata),
		.sec_rvalid      (host_sec_rvalid),
		.sec_done        (host_sec_done)
	);
	// host_commandCore_request: disc sector requests from cdd_emu (below)

	// SDRAM SEC hold request, seen in clk_sys
	wire sec_hold;
	reg  sec_hold_s;
	always @(posedge clk_sys) sec_hold_s <= sec_hold;

	// 3DO reset: host halt, "Reset" action, missing BIOS. Like MiSTer, a
	// reset request is stretched. While the SDRAM secondary port is using
	// the reset window, reset is held so the 3DO cannot start mid-transfer.
	reg        reset_3do = 1;
	reg        core_rst_lock;
	reg [12:0] reset_delay = '0;
	always @(posedge clk_sys) begin
		reg rst_cond, rst_cond_old;
		rst_cond = reset | core_halt | core_reset_pulse | ~bios_loaded;
		rst_cond_old <= rst_cond;
		if (rst_cond && !rst_cond_old) reset_delay <= '1;
		else if (reset_delay) reset_delay <= reset_delay - 13'd1;
		reset_3do     <= rst_cond | (|reset_delay) | (reset_3do & sec_hold_s);
		core_rst_lock <= reset_3do & sec_hold_s;
	end

	/////////////////////////  3DO  //////////////////////////////////////////
	wire [23: 2] LA;
	wire         LRAS0_N, LRAS2_N, LRAS3_N, LCAS_N;
	wire [ 1: 0] LWE_N;
	wire         LOE_N, LDSF, LSC, LQSF;
	wire [ 3: 0] LCODE;
	wire [23: 2] RA;
	wire         RRAS0_N, RRAS2_N, RRAS3_N, RCAS_N;
	wire [ 1: 0] RWE_N;
	wire         ROE_N, RDSF, RSC, RQSF;
	wire [ 3: 0] RCODE;
	wire [31: 0] RAM_DI;
	wire [31: 0] RAM_DO;
	wire         PBDIN, PBDOUT, PBCLK;
	wire [19: 0] PA;
	wire [31: 0] PDI;
	wire [ 7: 0] PDO;
	wire         ROMCS_N, SRAMW_N, SRAMR_N, ROM_SEL;
	wire [ 7: 0] CDDI, CDDO;
	wire         CDEN_N, CDCMD_N, CDHWR_N, CDHRD_N, CDRST_N, CDSTEN_N, CDDTEN_N, CDMDCHG;
	wire [31: 0] VRAM_SQ;
	wire         P3DO_FIELD;
	wire [ 7: 0] R, G, B;
	wire         HS_N, VS_N, DCLK, HBL_N, VBL_N;
	wire         MCLK_CE;
	wire [15: 0] AUDIO_L, AUDIO_R;

	reg CLK_DIV;
	always @(posedge clk_sys) CLK_DIV <= ~CLK_DIV;
	wire CE_R =  CLK_DIV;
	wire CE_F = ~CLK_DIV;

	wire VCE;      // video clock enable (NTSC 24.5454 MHz)
	ce_gen #(.IN_CLK(50_000_000), .OUT_CLK(24_545_400)) vce_gen (.CLK(clk_sys), .RST_N(1'b1), .CE(VCE));
	wire ACLK_CE;  // audio clock enable (16.9344 MHz)
	ce_gen #(.IN_CLK(50_000_000), .OUT_CLK(16_934_400)) aclk_gen (.CLK(clk_sys), .RST_N(1'b1), .CE(ACLK_CE));

	reg POWER_ON;
	always @(posedge clk_sys) begin
		if (reset_3do) POWER_ON <= 1;
		else if (CE_R) POWER_ON <= 0;
	end

	// Per-game VRAM layout / DSP pause tables (MiSTer 3DO.sv), keyed on the
	// disc id and lead-out MSF from the disc-info block.
	wire [31:0] disc_id, disc_msf;
	wire        disc_info_valid;
	reg  [ 3:0] BRAM4_OFFS, BRAM2_OFFS, BRAM1_OFFS;
	reg         NEED_DSP_PAUSE;
	always @(posedge clk_sys) begin
		{BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h0,4'h4,4'h6};
		NEED_DSP_PAUSE <= 0;
		if (disc_info_valid) begin
			if (disc_id == 32'h29E4D882) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'hC,4'hA,4'h9};//3D Atlas (US)
			if (disc_id == 32'h274E924C) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h4,4'h2,4'h8};//Alone in the Dark (US)
			if (disc_id == 32'h0340842C) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'hC,4'hA,4'h9};//Cannon Fodder (US)
			if (disc_id == 32'h2D731C98) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'hC,4'hA,4'h9};//FIFA International Soccer (US, Korea)
			if (disc_id == 32'h2584F855) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h8,4'hC,4'hE};//Psychic Detective (US) (Disc 1)
			if (disc_id == 32'h031BED09) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h8,4'h6,4'hC};//Quarantine (US)
			if (disc_id == 32'h06DE0DC2) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'hC,4'hA,4'h9};//Road & Track Presents - The Need for Speed (US, EU)
			if (disc_id == 32'h2D95DCB6) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h8,4'h6,4'hC};//Seal of the Pharaoh (US)
			if (disc_id == 32'h07732394) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h0,4'h6,4'h4};//Space Hulk - Vengeance of the Blood Angels (US)
			if (disc_id == 32'h0387DF78) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h4,4'h8,4'hA};//Bodyconscious Digital Rave! Part 1 (Japan)
			if (disc_id == 32'h213128DD) {BRAM4_OFFS,BRAM2_OFFS,BRAM1_OFFS} <= {4'h8,4'hC,4'hE};//Live! 3DO Magazine CD-ROM 1 (Japan)
			if (disc_id == 32'h25609184                            ) NEED_DSP_PAUSE <= 1;//Blade Force (US)
			if (disc_id == 32'h043DCD69 && disc_msf == 32'h69026900) NEED_DSP_PAUSE <= 1;//Decathlon (US) (Unl)
			if (disc_id == 32'h0A9B739E                            ) NEED_DSP_PAUSE <= 1;//Killing Time (US) (RE1)
			if (disc_id == 32'h06065D10                            ) NEED_DSP_PAUSE <= 1;//Snow Job Starring Tracy Scoggins (US)
			if (disc_id == 32'h3AC732DE                            ) NEED_DSP_PAUSE <= 1;//BattleSport (USA) (Beta) (1995-09-22)
		end
	end

	reg pause;
	reg sec_paused;

	// NTSC / PAL: the "Region" setting, or by BIOS (MiSTer's checksums of
	// the PAL Panasonic FZ-1 dumps). Taken while the 3DO is in reset.
	reg PAL = 0;
	always @(posedge clk_sys) if (reset_3do) PAL <= (region_sel == 2'd0) ? bios_pal : (region_sel == 2'd2);

	wire        VID_FRAME;                                   // start of a frame (vertical blanking)
	wire        VID_FB_HINT, VID_FB_CURR_V, VID_FB_PREV_V;   // frame buffer addresses from the VDL
	wire [19:2] VID_FB_CURR, VID_FB_PREV;                   // (VRAM word addresses), for vram_rtcache
	wire        VRAM_SP_CPU;                                 // VRAM access is the CPU's SPORT access (vram.sv)

	P3DO p3do (
		.RST_N(~reset_3do),
		.CLK(clk_sys),
		.VCLK(clk_vid),
		.EN(1'b1),
		.PAUSE(pause),
		.DSP_PAUSE(pause & NEED_DSP_PAUSE),
		.PAL(PAL),
		.CE_F(CE_F),
		.CE_R(CE_R),
		.PON(POWER_ON),
		.LA(LA), .LRAS0_N(LRAS0_N), .LRAS2_N(LRAS2_N), .LRAS3_N(LRAS3_N), .LCAS_N(LCAS_N),
		.LWE_N(LWE_N), .LOE_N(LOE_N), .LDSF(LDSF), .LSC(LSC), .LQSF(LQSF), .LCODE(LCODE),
		.RA(RA), .RRAS0_N(RRAS0_N), .RRAS2_N(RRAS2_N), .RRAS3_N(RRAS3_N), .RCAS_N(RCAS_N),
		.RWE_N(RWE_N), .ROE_N(ROE_N), .RDSF(RDSF), .RSC(RSC), .RQSF(RQSF), .RCODE(RCODE),
		.DI(RAM_DI),
		.DO(RAM_DO),
		.PBDIN(PBDIN), .PBDOUT(PBDOUT), .PBCLK(PBCLK),
		.PA(PA), .PDI(PDI), .PDO(PDO),
		.ROMCS_N(ROMCS_N), .SRAMW_N(SRAMW_N), .SRAMR_N(SRAMR_N), .ROM_SEL(ROM_SEL),
		.CDDI(CDDI), .CDDO(CDDO), .CDEN_N(CDEN_N), .CDCMD_N(CDCMD_N), .CDHWR_N(CDHWR_N),
		.CDHRD_N(CDHRD_N), .CDRST_N(CDRST_N), .CDSTEN_N(CDSTEN_N), .CDDTEN_N(CDDTEN_N), .CDMDCHG(CDMDCHG),
		.MCLK_CE(MCLK_CE),
		.VCE(VCE),
		.S(VRAM_SQ),
		.FIELD(P3DO_FIELD),
		.VID_FRAME(VID_FRAME),
		.VID_FB_HINT(VID_FB_HINT), .VID_FB_CURR(VID_FB_CURR), .VID_FB_CURR_V(VID_FB_CURR_V),
		.VID_FB_PREV(VID_FB_PREV), .VID_FB_PREV_V(VID_FB_PREV_V),
		.VRAM_SP_CPU(VRAM_SP_CPU),
		.RGB({R,G,B}),
		.HS_N(HS_N), .VS_N(VS_N), .HBLK_N(HBL_N), .VBLK_N(VBL_N), .DCLK(DCLK),
		.ACLK_CE(ACLK_CE),
		.AUDIOL(AUDIO_L),
		.AUDIOR(AUDIO_R),
		.HINTREPOL_DISABLE(1'b1),
		.VINTREPOL_DISABLE(1'b1),
		.SCRN_EN(3'b111),
		.DBG_EXT(8'hFF)
	);

	/////////////////////////  CD-ROM  ///////////////////////////////////////
	wire [64:0] cdd_comm;
	wire [15:0] cdd_data;
	wire        cdd_wr, cdd_dten, cdd_dien;

	P3DO_CDROM cdrom (
		.RST_N(~reset_3do),
		.CLK(clk_sys),
		.EN(1'b1),
		.CE(CE_R),
		.CDDI(CDDO),
		.CDDO(CDDI),
		.CDEN_N(CDEN_N),
		.CDCMD_N(CDCMD_N),
		.CDHWR_N(CDHWR_N),
		.CDHRD_N(CDHRD_N),
		.CDRST_N(CDRST_N),
		.CDSTEN_N(CDSTEN_N),
		.CDDTEN_N(CDDTEN_N),
		.CDMDCHG(CDMDCHG),
		.CDD_DATA(cdd_data),
		.CDD_WR(cdd_wr),
		.CDD_DTEN(cdd_dten),
		.CDD_DIEN(cdd_dien),
		.CDD_COMM(cdd_comm),
		.TRAY_OPEN(1'b0)
	);

	// Sector pacing: MiSTer delivers one sector per 3 ms HPS poll.
	reg [31:0] sector_delay;
	always @(posedge clk_sys) begin
		case (cd_speed)
			2'd0:    sector_delay <= 32'd333_333;  // 6.67 ms: 150 sectors/s (real 2x drive)
			2'd1:    sector_delay <= 32'd150_000;  // 3 ms: MiSTer HPS polling rate
			default: sector_delay <= 32'd25_000;   // 0.5 ms
		endcase
	end

	wire        cdd_sec_req, cdd_sec_we;
	wire [23:0] cdd_sec_addr;
	wire [ 9:0] cdd_sec_len;
	wire [15:0] cdd_sec_wdata;
	wire [ 1:0] cdd_sec_wbe;
	wire        cdd_sec_wnext, cdd_sec_rvalid, cdd_sec_done;

	cdd_emu cdd (
		.clk_sys        (clk_sys),
		.rst_sys        (reset_3do),
		.sector_delay   (sector_delay),
		.host_le        (HOST_LE),
		.disc_present   (disc_present),
		.disc_bytes     (disc_bytes),
		.disc_stream    (disc_stream),
		.disc_change    (disc_change),
		.toc_we         (toc_we),
		.toc_wa         (toc_wa),
		.toc_wd         (toc_wd),
		.sb_we          (sb_we),
		.sb_wa          (sb_wa),
		.sb_wd          (sb_wd),
		.core_cmd_words (core_cmd_words),
		.core_req       (host_commandCore_request),
		.core_done      (host_commandCore_done),
		.core_error     (host_commandCore_error),
		.disc_id        (disc_id),
		.disc_msf       (disc_msf),
		.disc_info_valid(disc_info_valid),
		.cd_comm        (cdd_comm),
		.CDD_DATA       (cdd_data),
		.CDD_WR         (cdd_wr),
		.CDD_DTEN       (cdd_dten),
		.CDD_DIEN       (cdd_dien),
		.clk_mem        (clk_mem),
		.rst_mem        (rst_mem),
		.sec_req        (cdd_sec_req),
		.sec_we         (cdd_sec_we),
		.sec_addr       (cdd_sec_addr),
		.sec_len        (cdd_sec_len),
		.sec_wdata      (cdd_sec_wdata),
		.sec_wbe        (cdd_sec_wbe),
		.sec_wnext      (cdd_sec_wnext),
		.sec_rdata      (sec_rdata),
		.sec_rvalid     (cdd_sec_rvalid),
		.sec_done       (cdd_sec_done)
	);

	/////////////////////////  PAD  //////////////////////////////////////////
	// MiSTer joystick bits: 0 right, 1 left, 2 down, 3 up, 4 A, 5 B, 6 C,
	// 7 P (play/pause), 8 X (stop), 9 R, 10 L.
	// Game Bub (SNES-style face buttons): Y/B/A -> 3DO A/B/C (left to right),
	// Start -> P, Select or X -> X, L -> L, R -> R.
	wire [12:0] joy0 = {
		2'b00,
		input_buttons_l,
		input_buttons_r,
		input_buttons_select | input_buttons_x,
		input_buttons_start,
		input_buttons_a,
		input_buttons_b,
		input_buttons_y,
		input_buttons_up,
		input_buttons_down,
		input_buttons_left,
		input_buttons_right
	};

	HPS2PAD pad (
		.RST(reset_3do),
		.CLK(clk_sys),
		.CE(CE_R),
		.PBDIN(PBDIN),
		.PBDOUT(PBDOUT),
		.PBCLK(PBCLK),
		.EXPBDIN(1'b1),
		.EXPBDOUT(),
		.PAD_SEL(3'd1),
		.ARCADE_SEL(2'd0),
		.STICK_EN(1'b0),
		.MOUSE_EN(1'b0),
		.ARCADE_SERVICE(1'b0),
		.joystick_0(joy0),
		.joystick_1('0),
		.joystick_2('0),
		.joystick_3('0),
		.joy0_x0('0), .joy0_y0('0), .joy0_x1('0), .joy0_y1('0),
		.joy1_x0('0), .joy1_y0('0), .joy1_x1('0), .joy1_y1('0),
		.ps2_mouse('0)
	);

	/////////////////////////  SDRAM  ////////////////////////////////////////
	wire [31:0] sdr_dout;
	wire        sdram_init_done;

	wire        m_req, m_we, m_wnext, m_rvalid, m_done;
	wire [23:0] m_addr;
	wire [ 9:0] m_len;
	wire [15:0] m_wdata, sec_rdata;
	wire [ 1:0] m_wbe;

	sdram_3do sdram (
		.clk         (clk_mem),
		.rst         (reset),
		.SDRAM_CLK   (sdram_clock),
		.SDRAM_CKE   (sdram_cke),
		.SDRAM_nCS   (sdram_cs),
		.SDRAM_nRAS  (sdram_ras),
		.SDRAM_nCAS  (sdram_cas),
		.SDRAM_nWE   (sdram_we),
		.SDRAM_DQM   (sdram_dqm),
		.SDRAM_BA    (sdram_bank),
		.SDRAM_A     (sdram_address),
		.SDRAM_DQ_IN (sdram_dataIn),
		.SDRAM_DQ_OUT(sdram_dataOut),
		.SDRAM_DQ_OE (sdram_dataDir),
		.init_done   (sdram_init_done),
		.sync        (MCLK_CE),
		.laddr       ({2'b00,~LRAS3_N,LA[19:2]}),
		.lwe         (~LWE_N),
		.lras        (!LRAS2_N || !LRAS3_N),
		.lcode       (LCODE),
		.raddr       ({2'b00,~RRAS3_N,RA[19:2]}),
		.rwe         (~RWE_N),
		.rras        (!RRAS2_N || !RRAS3_N),
		.rcode       (RCODE),
		.din         (RAM_DO),
		.dout        (sdr_dout),
		.CORE_RST    (core_rst_lock),
		.SEC_PAUSED  (sec_paused),
		.SEC_HOLD    (sec_hold),
		.sec_req     (m_req),
		.sec_we      (m_we),
		.sec_addr    (m_addr),
		.sec_len     (m_len),
		.sec_wdata   (m_wdata),
		.sec_wbe     (m_wbe),
		.sec_wnext   (m_wnext),
		.sec_rdata   (sec_rdata),
		.sec_rvalid  (m_rvalid),
		.sec_done    (m_done)
	);

	// Secondary port arbitration: 0 = 3DO (DDR bridge), 1 = CD, 2 = host
	wire        ddr_sec_req, ddr_sec_we;
	wire [23:0] ddr_sec_addr;
	wire [ 9:0] ddr_sec_len;
	wire [15:0] ddr_sec_wdata;
	wire [ 1:0] ddr_sec_wbe;
	wire [ 2:0] arb_wnext, arb_rvalid, arb_done;

	sec_arb #(.N(3)) arb (
		.clk     (clk_mem),
		.rst     (rst_mem),
		.c_req   ({host_sec_req, cdd_sec_req, ddr_sec_req}),
		.c_we    ({host_sec_we,  cdd_sec_we,  ddr_sec_we}),
		.c_addr  ('{ddr_sec_addr,  cdd_sec_addr,  host_sec_addr}),
		.c_len   ('{ddr_sec_len,   cdd_sec_len,   host_sec_len}),
		.c_wdata ('{ddr_sec_wdata, cdd_sec_wdata, host_sec_wdata}),
		.c_wbe   ('{ddr_sec_wbe,   cdd_sec_wbe,   host_sec_wbe}),
		.c_wnext (arb_wnext),
		.c_rdata (),
		.c_rvalid(arb_rvalid),
		.c_done  (arb_done),
		.m_req   (m_req),
		.m_we    (m_we),
		.m_addr  (m_addr),
		.m_len   (m_len),
		.m_wdata (m_wdata),
		.m_wbe   (m_wbe),
		.m_wnext (m_wnext),
		.m_rdata (sec_rdata),
		.m_rvalid(m_rvalid),
		.m_done  (m_done)
	);
	wire ddr_sec_wnext  = arb_wnext[0],  ddr_sec_rvalid  = arb_rvalid[0],  ddr_sec_done  = arb_done[0];
	assign cdd_sec_wnext  = arb_wnext[1];
	assign cdd_sec_rvalid = arb_rvalid[1];
	assign cdd_sec_done   = arb_done[1];
	assign host_sec_wnext  = arb_wnext[2];
	assign host_sec_rvalid = arb_rvalid[2];
	assign host_sec_done   = arb_done[2];

	/////////////////////////  VRAM  /////////////////////////////////////////
	// Only the BRAM1 block (48 KiB window + 16 KiB VDL area) is on chip; the
	// rest of VRAM goes through ddram.sv to SDRAM (MiSTer USE_BRAM=0 build).
	localparam USE_BRAM_BLOCKS_FOR_VRAM = 0;

	wire [31: 0] VRAM_Q;
	wire         VRAM_LRDY, VRAM_RRDY;
	wire [31: 0] vram_bldata, vram_brdata;

	wire [31: 0] ddr_do;
	// VRAM modules <-> read-transfer cache <-> ddram.sv
	wire [17: 0] v_laddr, v_raddr;
	wire         v_lwr, v_rwr, v_lrd, v_rrd, v_lfw;
	wire         v_lte, v_rte;
	wire [31: 0] v_lq, v_rq;
	wire [17: 0] ddr_bladdr, ddr_braddr;
	wire         ddr_blwr, ddr_brwr, ddr_blrd, ddr_brrd, ddr_bfw;
	wire [63: 0] ddr_bin = {vram_bldata[31:16],vram_brdata[31:16],vram_bldata[15:0],vram_brdata[15:0]};
	wire [63: 0] ddr_bout;
	wire         ddr_blte, ddr_brte;
	wire [ 9: 2] ddr_ba;

	P3DO_VRAM #(USE_BRAM_BLOCKS_FOR_VRAM) vram_l (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~reset_3do),
		.A(LA[19:2]), .D(RAM_DO[31:16]), .Q(VRAM_Q[31:16]),
		.RAS_N(LRAS0_N), .CAS_N(LCAS_N), .WE_N(LWE_N), .OE_N(LOE_N), .DSF1(LDSF),
		.SC(LSC), .SE_N(1'b0), .SQ(VRAM_SQ[31:16]), .QSF(LQSF), .RDY(VRAM_LRDY),
		.EQ(ddr_do[31:16]), .ESADDR(v_laddr), .ESDATA(vram_bldata),
		.ESWR(v_lwr), .ESRD(v_lrd), .ESFW(v_lfw),
		.ESQ(v_lq), .ESTE(v_lte),
		.BRAM4_OFFS(BRAM4_OFFS), .BRAM2_OFFS(BRAM2_OFFS), .BRAM1_OFFS(BRAM1_OFFS),
		.SP_CPU(VRAM_SP_CPU),
		.DBG_WAIT_CNT()
	);

	P3DO_VRAM #(USE_BRAM_BLOCKS_FOR_VRAM) vram_r (
		.CLK(clk_sys), .CLK_MEM(clk_mem), .RST_N(~reset_3do),
		.A(RA[19:2]), .D(RAM_DO[15:0]), .Q(VRAM_Q[15:0]),
		.RAS_N(RRAS0_N), .CAS_N(RCAS_N), .WE_N(RWE_N), .OE_N(ROE_N), .DSF1(RDSF),
		.SC(RSC), .SE_N(1'b0), .SQ(VRAM_SQ[15:0]), .QSF(RQSF), .RDY(VRAM_RRDY),
		.EQ(ddr_do[15:0]), .ESADDR(v_raddr), .ESDATA(vram_brdata),
		.ESWR(v_rwr), .ESRD(v_rrd), .ESFW(),
		.ESQ(v_rq), .ESTE(v_rte),
		.BRAM4_OFFS(BRAM4_OFFS), .BRAM2_OFFS(BRAM2_OFFS), .BRAM1_OFFS(BRAM1_OFFS),
		.SP_CPU(VRAM_SP_CPU),
		.DBG_WAIT_CNT()
	);

	assign RAM_DI = !LRAS0_N || !RRAS0_N ? VRAM_Q : sdr_dout;

	// the 3DO wrote its NVRAM (save changed since loaded)
	reg sramw_n_d = 1;
	always @(posedge clk_sys) sramw_n_d <= SRAMW_N;
	assign nvram_wr = !SRAMW_N && sramw_n_d;
	assign PDI = !SRAMR_N ? (ddr_io_do>>{~PA[3:2],3'b000}) & 32'h000000FF : ddr_io_do;

	/////////////////////////  "DDR" (VRAM overflow, ROMs, NVRAM)  ///////////
	wire [31: 0] ddr_io_do;
	wire         ddr_io_busy, ddr_busy, ddr_bbusy;

	wire         ddr_luse = ~((USE_BRAM_BLOCKS_FOR_VRAM && LA[19:2] >= ({BRAM4_OFFS+0,16'h0000}>>2) && LA[19:2] <= ({BRAM4_OFFS+3,16'hFFFF}>>2)) || (USE_BRAM_BLOCKS_FOR_VRAM && LA[19:2] >= ({BRAM2_OFFS+0,16'h0000}>>2) && LA[19:2] <= ({BRAM2_OFFS+1,16'hFFFF}>>2)) || (LA[19:2] >= ({BRAM1_OFFS+0,16'h0000}>>2) && LA[19:2] <= ({BRAM1_OFFS+0,16'hBFFF}>>2)) || (LA[19:2] >= (20'hFC000>>2)));
	wire         ddr_ruse = ~((USE_BRAM_BLOCKS_FOR_VRAM && RA[19:2] >= ({BRAM4_OFFS+0,16'h0000}>>2) && RA[19:2] <= ({BRAM4_OFFS+3,16'hFFFF}>>2)) || (USE_BRAM_BLOCKS_FOR_VRAM && RA[19:2] >= ({BRAM2_OFFS+0,16'h0000}>>2) && RA[19:2] <= ({BRAM2_OFFS+1,16'hFFFF}>>2)) || (RA[19:2] >= ({BRAM1_OFFS+0,16'h0000}>>2) && RA[19:2] <= ({BRAM1_OFFS+0,16'hBFFF}>>2)) || (RA[19:2] >= (20'hFC000>>2)));

	wire         DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
	wire [ 7: 0] DDRAM_BURSTCNT, DDRAM_BE;
	wire [28: 0] DDRAM_ADDR;
	wire [63: 0] DDRAM_DOUT, DDRAM_DIN;

	ddram ddram (
		.DDRAM_CLK(),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.clk(clk_mem),
		.rst(rst_mem | reset_3do),
		// ROM (BIOS/kanji) and NVRAM accesses from the 3DO slow bus
		.io_addr(!SRAMW_N || !SRAMR_N ? {1'b1,6'b000000,PA[16:4]} : {1'b0,ROM_SEL,PA[19:2]}),
		.io_din ({4{PDO}}),
		.io_we  (!SRAMW_N ? (4'h8>>PA[3:2])&{4{MCLK_CE}} : 4'b0000),
		.io_rd  ((~ROMCS_N|~SRAMR_N)&MCLK_CE),
		.io_dout(ddr_io_do),
		.io_busy(ddr_io_busy),
		// MiSTer save-file port: the Game Bub host accesses NVRAM directly
		.nvram_addr('0),
		.nvram_din ('0),
		.nvram_wr  (1'b0),
		.nvram_rd  (1'b0),
		.nvram_dout(),
		.nvram_busy(),
		.sclk(CE_R),
		.laddr(LA[19:2]),
		.ldin (RAM_DO[31:16]),
		.lras (!LRAS0_N),
		.lwe  (ddr_luse ? ~LWE_N : 2'b00),
		.lrd  (ddr_luse ? ~LOE_N : 1'b0),
		.ldout(ddr_do[31:16]),
		.raddr(RA[19:2]),
		.rdin (RAM_DO[15:0]),
		.rras (!RRAS0_N),
		.rwe  (ddr_ruse ? ~RWE_N : 2'b00),
		.rrd  (ddr_ruse ? ~ROE_N : 1'b0),
		.rdout(ddr_do[15:0]),
		.busy(ddr_busy),
		.bladdr(ddr_bladdr),
		.blwr  (ddr_blwr),
		.blrd  (ddr_blrd),
		.braddr(ddr_braddr),
		.brwr  (ddr_brwr),
		.brrd  (ddr_brrd),
		.bfw   (ddr_bfw),
		.ba(ddr_ba),
		.bin(ddr_bin),
		.bout(ddr_bout),
		.blte(ddr_blte),
		.brte(ddr_brte),
		.bbusy(ddr_bbusy)
	);

	// Read transfers from SDRAM-backed VRAM are served from a prefetching
	// half-row cache (see vram_rtcache.sv for why).
	wire [31:0] rtc_hits, rtc_misses, rtc_prefetches, rtc_invalidations, rtc_hints;
	vram_rtcache #(.ENTRIES(16)) rtcache (
		.clk(clk_mem), .rst(rst_mem | reset_3do),
		.BRAM1_OFFS(BRAM1_OFFS),
		.l_esrd(v_lrd), .l_esaddr(v_laddr), .l_eswr(v_lwr), .l_esfw(v_lfw), .l_este(v_lte), .l_esq(v_lq),
		.r_esrd(v_rrd), .r_esaddr(v_raddr), .r_eswr(v_rwr), .r_este(v_rte), .r_esq(v_rq),
		.d_bladdr(ddr_bladdr), .d_blrd(ddr_blrd), .d_blwr(ddr_blwr), .d_bfw(ddr_bfw),
		.d_braddr(ddr_braddr), .d_brrd(ddr_brrd), .d_brwr(ddr_brwr),
		.d_blte(ddr_blte), .d_brte(ddr_brte), .d_bout(ddr_bout), .d_ba(ddr_ba), .d_bbusy(ddr_bbusy),
		.ddr_we(DDRAM_WE && !DDRAM_BUSY), .ddr_addr(DDRAM_ADDR),
		.frame(VID_FRAME),
		.hint(VID_FB_HINT), .hint_curr(VID_FB_CURR), .hint_curr_v(VID_FB_CURR_V),
		.hint_prev(VID_FB_PREV), .hint_prev_v(VID_FB_PREV_V),
		.stat_hits(rtc_hits), .stat_misses(rtc_misses), .stat_prefetches(rtc_prefetches),
		.stat_invalidations(rtc_invalidations), .stat_hints(rtc_hints)
	);

	ddr_bridge ddr_bridge (
		.clk             (clk_mem),
		.rst             (rst_mem),
		.host_le         (HOST_LE),
		.DDRAM_BUSY      (DDRAM_BUSY),
		.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
		.DDRAM_ADDR      (DDRAM_ADDR),
		.DDRAM_DOUT      (DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD        (DDRAM_RD),
		.DDRAM_DIN       (DDRAM_DIN),
		.DDRAM_BE        (DDRAM_BE),
		.DDRAM_WE        (DDRAM_WE),
		.sec_req         (ddr_sec_req),
		.sec_we          (ddr_sec_we),
		.sec_addr        (ddr_sec_addr),
		.sec_len         (ddr_sec_len),
		.sec_wdata       (ddr_sec_wdata),
		.sec_wbe         (ddr_sec_wbe),
		.sec_wnext       (ddr_sec_wnext),
		.sec_rdata       (sec_rdata),
		.sec_rvalid      (ddr_sec_rvalid),
		.sec_done        (ddr_sec_done)
	);

	/////////////////////////  PAUSE  ////////////////////////////////////////
	// As MiSTer: stall the 3DO while slow memory is busy. In addition the
	// SDRAM secondary port requests a pause (sec_hold) before it may use the
	// bus; sec_paused tells it the pause is in effect and will be held.
	always @(posedge clk_sys) begin
		bit cond;
		if (CE_F) begin
			cond = ddr_io_busy || ddr_busy || !VRAM_LRDY || !VRAM_RRDY || sec_hold_s;
			pause      <= cond;
			sec_paused <= sec_hold_s;
		end
		if (!sec_hold_s) sec_paused <= 0;
	end

	/////////////////////////  VIDEO / AUDIO  ////////////////////////////////
	video_capture #(.CDEPTH(6)) vcap (
		.vclk        (clk_vid),
		.vrst        (rst_vid),
		.RGB         ({R,G,B}),
		.DCLK        (DCLK),
		.HBLK_N      (HBL_N),
		.VBLK_N      (VBL_N),
		.clk         (clk_sys),
		.rst         (reset),
		.video_r     (video_data_r),
		.video_g     (video_data_g),
		.video_b     (video_data_b),
		.video_de    (video_dataEnable),
		.video_hblank(video_hblank),
		.video_vblank(video_vblank)
	);

	assign audio_left  = focus ? AUDIO_L : 16'h0000;
	assign audio_right = focus ? AUDIO_R : 16'h0000;

endmodule
