// Behavioral replacements for the Altera megafunctions used by the
// MiSTer 3DO core, written so that Xilinx Vivado infers equivalent
// distributed (LUT) RAM / block RAM on the Artix-7.
//
// Only the configurations that the 3DO RTL actually uses are supported:
//   altdpram : registered write (INCLOCK), unregistered (asynchronous) read.
//              This maps 1:1 onto Xilinx distributed RAM (RAM32M/RAM64M...).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none

module altdpram #(
	parameter integer width                 = 1,
	parameter integer widthad               = 1,
	parameter integer numwords              = 0,
	parameter integer width_byteena         = 1,
	parameter integer byte_size             = 8,
	// The following parameters are accepted for source compatibility only.
	parameter         indata_aclr           = "OFF",
	parameter         indata_reg            = "INCLOCK",
	parameter         intended_device_family = "Cyclone V",
	parameter         lpm_type              = "altdpram",
	parameter         lpm_hint              = "UNUSED",
	parameter         outdata_aclr          = "OFF",
	parameter         outdata_reg           = "UNREGISTERED",
	parameter         ram_block_type        = "MLAB",
	parameter         rdaddress_aclr        = "OFF",
	parameter         rdaddress_reg         = "UNREGISTERED",
	parameter         rdcontrol_aclr        = "OFF",
	parameter         rdcontrol_reg         = "UNREGISTERED",
	parameter         read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
	parameter         wraddress_aclr        = "OFF",
	parameter         wraddress_reg         = "INCLOCK",
	parameter         wrcontrol_aclr        = "OFF",
	parameter         wrcontrol_reg         = "INCLOCK",
	parameter         use_eab               = "ON",
	parameter         power_up_uninitialized = "FALSE"
) (
	input  wire [width-1:0]         data,
	input  wire                     inclock,
	input  wire                     outclock,
	input  wire [widthad-1:0]       rdaddress,
	input  wire [widthad-1:0]       wraddress,
	input  wire                     wren,
	output wire [width-1:0]         q,
	input  wire                     aclr,
	input  wire [width_byteena-1:0] byteena,
	input  wire                     inclocken,
	input  wire                     outclocken,
	input  wire                     rdaddressstall,
	input  wire                     rden,
	input  wire                     wraddressstall
);
	localparam integer DEPTH     = (numwords != 0) ? numwords : (1 << widthad);
	localparam integer LANE_BITS = width / width_byteena;

	(* ram_style = "distributed" *) reg [width-1:0] mem [0:DEPTH-1];

	integer i;
	initial begin
		for (i = 0; i < DEPTH; i = i + 1) mem[i] = {width{1'b0}};
	end

	// inclocken is tied high by every 3DO instance; it is still honoured.
	genvar b;
	generate
		for (b = 0; b < width_byteena; b = b + 1) begin : g_lane
			always @(posedge inclock) begin
				if (wren && inclocken && byteena[b])
					mem[wraddress][b*LANE_BITS +: LANE_BITS] <= data[b*LANE_BITS +: LANE_BITS];
			end
		end
	endgenerate

	assign q = mem[rdaddress];
endmodule

// Mixed-width dual-port block RAM, one clock (replacement for bram.vhd's
// dpram_dif, which wraps altsyncram in BIDIR_DUAL_PORT mode).
// Only data_width_a == 16 / data_width_b == 8 with addr_width_b == addr_width_a+1
// (the configuration used by 3DO_CDROM.sv), or equal widths, are supported.
// Byte ordering follows Altera's convention: the narrow port's even address
// maps to the low byte of the wide word.
module dpram_dif #(
	parameter integer addr_width_a = 8,
	parameter integer data_width_a = 8,
	parameter integer addr_width_b = 8,
	parameter integer data_width_b = 8
) (
	input  wire                    clock,
	input  wire [addr_width_a-1:0] address_a,
	input  wire [data_width_a-1:0] data_a,
	input  wire                    wren_a,
	output reg  [data_width_a-1:0] q_a,
	input  wire [addr_width_b-1:0] address_b,
	input  wire [data_width_b-1:0] data_b,
	input  wire                    wren_b,
	output reg  [data_width_b-1:0] q_b
);
	localparam integer RATIO = data_width_a / data_width_b;

	generate
		if (RATIO == 1) begin : g_same
			reg [data_width_a-1:0] mem [0:(1<<addr_width_a)-1];
			always @(posedge clock) begin
				if (wren_a) mem[address_a] <= data_a;
				q_a <= wren_a ? data_a : mem[address_a];
			end
			always @(posedge clock) begin
				if (wren_b) mem[address_b] <= data_b;
				q_b <= wren_b ? data_b : mem[address_b];
			end
		end else begin : g_mixed
			// Split into RATIO narrow lanes so that every RAM is a plain
			// simple/true dual-port RAM that Vivado can infer.
			reg                     [$clog2(RATIO)-1:0] lane_b_q;
			wire [data_width_a-1:0] qa_w;
			wire [data_width_b-1:0] qb_lane [0:RATIO-1];
			genvar l;
			for (l = 0; l < RATIO; l = l + 1) begin : g_lane
				reg [data_width_b-1:0] mem [0:(1<<addr_width_a)-1];
				reg [data_width_b-1:0] ra, rb;
				wire we_b = wren_b && (address_b[$clog2(RATIO)-1:0] == l);
				always @(posedge clock) begin
					if (wren_a) begin
						mem[address_a] <= data_a[l*data_width_b +: data_width_b];
						ra <= data_a[l*data_width_b +: data_width_b];
					end else begin
						ra <= mem[address_a];
					end
				end
				always @(posedge clock) begin
					if (we_b) begin
						mem[address_b[addr_width_b-1:$clog2(RATIO)]] <= data_b;
						rb <= data_b;
					end else begin
						rb <= mem[address_b[addr_width_b-1:$clog2(RATIO)]];
					end
				end
				assign qa_w[l*data_width_b +: data_width_b] = ra;
				assign qb_lane[l] = rb;
			end
			always @(posedge clock) lane_b_q <= address_b[$clog2(RATIO)-1:0];
			always @* q_a = qa_w;
			always @* q_b = qb_lane[lane_b_q];
		end
	endgenerate
endmodule

`default_nettype wire
