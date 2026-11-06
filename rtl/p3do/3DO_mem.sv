module VRAM_SHIFTREG 
#( parameter addr_width = 9 )
(
	input                    CLK,
	input  [addr_width-4: 1] WADDR,
	input  [         255: 0] DATA,
	input  [           7: 0] WREN,
	input  [addr_width-4: 1] RADDR,
	output [         255: 0] Q
);

	wire [255:0] sub_wire0;

	altdpram	altdpram_component_0 (
				.data (DATA[31:0]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[0]),
				.q (sub_wire0[31:0]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_0.indata_aclr = "OFF",
		altdpram_component_0.indata_reg = "INCLOCK",
		altdpram_component_0.intended_device_family = "Cyclone V",
		altdpram_component_0.lpm_type = "altdpram",
		altdpram_component_0.outdata_aclr = "OFF",
		altdpram_component_0.outdata_reg = "UNREGISTERED",
		altdpram_component_0.ram_block_type = "MLAB",
		altdpram_component_0.rdaddress_aclr = "OFF",
		altdpram_component_0.rdaddress_reg = "UNREGISTERED",
		altdpram_component_0.rdcontrol_aclr = "OFF",
		altdpram_component_0.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_0.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_0.width = 32,
		altdpram_component_0.widthad = addr_width-4,
		altdpram_component_0.width_byteena = 1,
		altdpram_component_0.wraddress_aclr = "OFF",
		altdpram_component_0.wraddress_reg = "INCLOCK",
		altdpram_component_0.wrcontrol_aclr = "OFF",
		altdpram_component_0.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_1 (
				.data (DATA[63:32]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[1]),
				.q (sub_wire0[63:32]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_1.indata_aclr = "OFF",
		altdpram_component_1.indata_reg = "INCLOCK",
		altdpram_component_1.intended_device_family = "Cyclone V",
		altdpram_component_1.lpm_type = "altdpram",
		altdpram_component_1.outdata_aclr = "OFF",
		altdpram_component_1.outdata_reg = "UNREGISTERED",
		altdpram_component_1.ram_block_type = "MLAB",
		altdpram_component_1.rdaddress_aclr = "OFF",
		altdpram_component_1.rdaddress_reg = "UNREGISTERED",
		altdpram_component_1.rdcontrol_aclr = "OFF",
		altdpram_component_1.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_1.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_1.width = 32,
		altdpram_component_1.widthad = addr_width-4,
		altdpram_component_1.width_byteena = 1,
		altdpram_component_1.wraddress_aclr = "OFF",
		altdpram_component_1.wraddress_reg = "INCLOCK",
		altdpram_component_1.wrcontrol_aclr = "OFF",
		altdpram_component_1.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_2 (
				.data (DATA[95:64]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[2]),
				.q (sub_wire0[95:64]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_2.indata_aclr = "OFF",
		altdpram_component_2.indata_reg = "INCLOCK",
		altdpram_component_2.intended_device_family = "Cyclone V",
		altdpram_component_2.lpm_type = "altdpram",
		altdpram_component_2.outdata_aclr = "OFF",
		altdpram_component_2.outdata_reg = "UNREGISTERED",
		altdpram_component_2.ram_block_type = "MLAB",
		altdpram_component_2.rdaddress_aclr = "OFF",
		altdpram_component_2.rdaddress_reg = "UNREGISTERED",
		altdpram_component_2.rdcontrol_aclr = "OFF",
		altdpram_component_2.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_2.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_2.width = 32,
		altdpram_component_2.widthad = addr_width-4,
		altdpram_component_2.width_byteena = 1,
		altdpram_component_2.wraddress_aclr = "OFF",
		altdpram_component_2.wraddress_reg = "INCLOCK",
		altdpram_component_2.wrcontrol_aclr = "OFF",
		altdpram_component_2.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_3 (
				.data (DATA[127:96]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[3]),
				.q (sub_wire0[127:96]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_3.indata_aclr = "OFF",
		altdpram_component_3.indata_reg = "INCLOCK",
		altdpram_component_3.intended_device_family = "Cyclone V",
		altdpram_component_3.lpm_type = "altdpram",
		altdpram_component_3.outdata_aclr = "OFF",
		altdpram_component_3.outdata_reg = "UNREGISTERED",
		altdpram_component_3.ram_block_type = "MLAB",
		altdpram_component_3.rdaddress_aclr = "OFF",
		altdpram_component_3.rdaddress_reg = "UNREGISTERED",
		altdpram_component_3.rdcontrol_aclr = "OFF",
		altdpram_component_3.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_3.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_3.width = 32,
		altdpram_component_3.widthad = addr_width-4,
		altdpram_component_3.width_byteena = 1,
		altdpram_component_3.wraddress_aclr = "OFF",
		altdpram_component_3.wraddress_reg = "INCLOCK",
		altdpram_component_3.wrcontrol_aclr = "OFF",
		altdpram_component_3.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_4 (
				.data (DATA[159:128]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[4]),
				.q (sub_wire0[159:128]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_4.indata_aclr = "OFF",
		altdpram_component_4.indata_reg = "INCLOCK",
		altdpram_component_4.intended_device_family = "Cyclone V",
		altdpram_component_4.lpm_type = "altdpram",
		altdpram_component_4.outdata_aclr = "OFF",
		altdpram_component_4.outdata_reg = "UNREGISTERED",
		altdpram_component_4.ram_block_type = "MLAB",
		altdpram_component_4.rdaddress_aclr = "OFF",
		altdpram_component_4.rdaddress_reg = "UNREGISTERED",
		altdpram_component_4.rdcontrol_aclr = "OFF",
		altdpram_component_4.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_4.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_4.width = 32,
		altdpram_component_4.widthad = addr_width-4,
		altdpram_component_4.width_byteena = 1,
		altdpram_component_4.wraddress_aclr = "OFF",
		altdpram_component_4.wraddress_reg = "INCLOCK",
		altdpram_component_4.wrcontrol_aclr = "OFF",
		altdpram_component_4.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_5 (
				.data (DATA[191:160]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[5]),
				.q (sub_wire0[191:160]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_5.indata_aclr = "OFF",
		altdpram_component_5.indata_reg = "INCLOCK",
		altdpram_component_5.intended_device_family = "Cyclone V",
		altdpram_component_5.lpm_type = "altdpram",
		altdpram_component_5.outdata_aclr = "OFF",
		altdpram_component_5.outdata_reg = "UNREGISTERED",
		altdpram_component_5.ram_block_type = "MLAB",
		altdpram_component_5.rdaddress_aclr = "OFF",
		altdpram_component_5.rdaddress_reg = "UNREGISTERED",
		altdpram_component_5.rdcontrol_aclr = "OFF",
		altdpram_component_5.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_5.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_5.width = 32,
		altdpram_component_5.widthad = addr_width-4,
		altdpram_component_5.width_byteena = 1,
		altdpram_component_5.wraddress_aclr = "OFF",
		altdpram_component_5.wraddress_reg = "INCLOCK",
		altdpram_component_5.wrcontrol_aclr = "OFF",
		altdpram_component_5.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_6 (
				.data (DATA[223:192]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[6]),
				.q (sub_wire0[223:192]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_6.indata_aclr = "OFF",
		altdpram_component_6.indata_reg = "INCLOCK",
		altdpram_component_6.intended_device_family = "Cyclone V",
		altdpram_component_6.lpm_type = "altdpram",
		altdpram_component_6.outdata_aclr = "OFF",
		altdpram_component_6.outdata_reg = "UNREGISTERED",
		altdpram_component_6.ram_block_type = "MLAB",
		altdpram_component_6.rdaddress_aclr = "OFF",
		altdpram_component_6.rdaddress_reg = "UNREGISTERED",
		altdpram_component_6.rdcontrol_aclr = "OFF",
		altdpram_component_6.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_6.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_6.width = 32,
		altdpram_component_6.widthad = addr_width-4,
		altdpram_component_6.width_byteena = 1,
		altdpram_component_6.wraddress_aclr = "OFF",
		altdpram_component_6.wraddress_reg = "INCLOCK",
		altdpram_component_6.wrcontrol_aclr = "OFF",
		altdpram_component_6.wrcontrol_reg = "INCLOCK";

	altdpram	altdpram_component_7 (
				.data (DATA[255:224]),
				.inclock (CLK),
				.outclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WREN[7]),
				.q (sub_wire0[255:224]),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.outclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component_7.indata_aclr = "OFF",
		altdpram_component_7.indata_reg = "INCLOCK",
		altdpram_component_7.intended_device_family = "Cyclone V",
		altdpram_component_7.lpm_type = "altdpram",
		altdpram_component_7.outdata_aclr = "OFF",
		altdpram_component_7.outdata_reg = "UNREGISTERED",
		altdpram_component_7.ram_block_type = "MLAB",
		altdpram_component_7.rdaddress_aclr = "OFF",
		altdpram_component_7.rdaddress_reg = "UNREGISTERED",
		altdpram_component_7.rdcontrol_aclr = "OFF",
		altdpram_component_7.rdcontrol_reg = "UNREGISTERED",
		altdpram_component_7.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component_7.width = 32,
		altdpram_component_7.widthad = addr_width-4,
		altdpram_component_7.width_byteena = 1,
		altdpram_component_7.wraddress_aclr = "OFF",
		altdpram_component_7.wraddress_reg = "INCLOCK",
		altdpram_component_7.wrcontrol_aclr = "OFF",
		altdpram_component_7.wrcontrol_reg = "INCLOCK";
		
	assign Q = sub_wire0;

endmodule

module VRAM_MEM 
#( parameter addr_width = 16 )
(
	input                    CLK,
	input  [addr_width-1: 0] ADDR,
	input  [          15: 0] DATA,
	input  [           1: 0] WREN,
	output [          15: 0] Q,
	
	input                    SCLK,
	input  [addr_width-1: 4] SADDR,
	input  [         255: 0] SDATA,
	input                    SWREN,
	output [         255: 0] SQ
);
	// GameBub/Xilinx port: the original is an altsyncram in BIDIR_DUAL_PORT
	// mode with a 16-bit port A and a 256-bit port B. It is rebuilt here from
	// 16 true-dual-port 16-bit lanes; lane i holds port-A words whose
	// address satisfies ADDR[3:0] == i, which matches Altera's mixed-width
	// ordering (SQ[16*i +: 16] <-> ADDR = {SADDR, i}).
	// Both ports are read-first-irrelevant: the 3DO never reads a word in
	// the same cycle it writes it on the same port ("NEW_DATA_NO_NBE_READ"
	// is reproduced anyway for port A).
	localparam LANE_AW = addr_width - 4;

	bit  [ 3: 0] lane_q;
	wire [15: 0] qa_lane [16];

	always @(posedge CLK) lane_q <= ADDR[3:0];

	genvar l;
	generate
		for (l = 0; l < 16; l = l + 1) begin : g_lane
			(* ram_style = "block" *) reg [15:0] mem [0:(1<<LANE_AW)-1];
			reg [15:0] ra, rb;
			wire sel_a = (ADDR[3:0] == l);
			integer k;
			initial for (k = 0; k < (1<<LANE_AW); k = k + 1) mem[k] = 16'h0000;

			always @(posedge CLK) begin
				if (sel_a && WREN[0]) mem[ADDR[addr_width-1:4]][ 7:0] <= DATA[ 7:0];
				if (sel_a && WREN[1]) mem[ADDR[addr_width-1:4]][15:8] <= DATA[15:8];
				ra <= mem[ADDR[addr_width-1:4]];
			end
			always @(posedge SCLK) begin
				if (SWREN) mem[SADDR] <= SDATA[l*16 +: 16];
				rb <= mem[SADDR];
			end
			assign qa_lane[l] = ra;
			assign SQ[l*16 +: 16] = rb;
		end
	endgenerate

	// Port A write-through (NEW_DATA) for the byte lanes being written.
	bit  [15: 0] wdata_q;
	bit  [ 1: 0] wren_q;
	always @(posedge CLK) begin
		wdata_q <= DATA;
		wren_q  <= WREN;
	end
	assign Q = {wren_q[1] ? wdata_q[15:8] : qa_lane[lane_q][15:8],
	            wren_q[0] ? wdata_q[ 7:0] : qa_lane[lane_q][ 7:0]};

endmodule

module VE_LINE_BUF 
(
	input          CLK0,
	input  [10: 0] ADDR0,
	input  [23: 0] DATA0,
	input          WREN0,
	output [23: 0] Q0,
	
	input          CLK1,
	input  [10: 0] ADDR1,
	input  [23: 0] DATA1,
	input          WREN1,
	output [23: 0] Q1
);
	// GameBub/Xilinx port of the altsyncram BIDIR_DUAL_PORT line buffer.
	(* ram_style = "block" *) reg [23:0] mem [0:2047];
	reg [23:0] q0_r, q1_r;

	always @(posedge CLK0) begin
		if (WREN0) begin
			mem[ADDR0] <= DATA0;
			q0_r <= DATA0;
		end else begin
			q0_r <= mem[ADDR0];
		end
	end
	always @(posedge CLK1) begin
		if (WREN1) begin
			mem[ADDR1] <= DATA1;
			q1_r <= DATA1;
		end else begin
			q1_r <= mem[ADDR1];
		end
	end
	assign Q0 = q0_r;
	assign Q1 = q1_r;

endmodule
