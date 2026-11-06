module MADAM_MATH_MATRIX (
	input             CLK,
	
	input     [ 3: 0] WA,
	input     [31: 0] DIN,
	input             WE,
	
	input     [ 3: 0] RA,
	output    [31: 0] DOUT
);
		
`ifdef SIM

	reg [31:0] BUF[16];
	initial begin
		BUF = '{16{'0}};
	end
	
	always @(posedge CLK) begin
		if (WE) begin
			BUF[WA] <= DIN;
		end
	end

	assign DOUT = BUF[RA];
											  	
`else 

	wire [31: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RA),
				.wraddress (WA),
				.wren (WE),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 32,
		altdpram_component.widthad = 4,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule

module MADAM_MATH_VECTOR (
	input             CLK,
	
	input     [ 1: 0] WA,
	input     [31: 0] DIN,
	input             WE,
	
	input     [ 1: 0] RA,
	output    [31: 0] DOUT
);
		
`ifdef SIM

	reg [31:0] BUF[4];
	initial begin
		BUF = '{4{'0}};
	end
	
	always @(posedge CLK) begin
		if (WE) begin
			BUF[WA] <= DIN;
		end
	end

	assign DOUT = BUF[RA];
											  	
`else 

	wire [31: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RA),
				.wraddress (WA),
				.wren (WE),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 32,
		altdpram_component.widthad = 2,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule

module MADAM_MATH_STACK (
	input             CLK,
	input             EN,
	
	input     [ 2: 0] WA,
	input     [31: 0] DIN,
	input     [ 1: 0] WE,
	
	input     [ 2: 0] RA,
	output    [31: 0] DOUT
);
		
`ifdef SIM

	reg [15:0] XBUF[8],YBUF[8];
	initial begin
		XBUF = '{8{'0}};
		YBUF = '{8{'0}};
	end
	
	always @(posedge CLK) begin
		if (EN) begin
			if (WE[1]) begin
				XBUF[WA] <= DIN[31:16];
			end
			if (WE[0]) begin
				YBUF[WA] <= DIN[15:0];
			end
		end
	end

	assign DOUT = {XBUF[RA],YBUF[RA]};
											  	
`else 

	wire [31: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RA),
				.wraddress (WA),
				.wren (|WE),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena ({{2{WE[1]}},{2{WE[0]}}}),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 32,
		altdpram_component.widthad = 3,
		altdpram_component.width_byteena = 4,
		altdpram_component.byte_size = 8,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule

module madam_div (
	input              CLK,
	input              START,
	input      [31: 0] denom,
	input      [63: 0] numer,
	output reg [63: 0] quotient,
	output reg [31: 0] remain,
	output reg         BUSY
);
	// GameBub/Xilinx port. The original is a purely combinational Altera
	// LPM_DIVIDE (64/32 signed, LPM_REMAINDERPOSITIVE=TRUE), which cannot
	// meet timing on an Artix-7. This is a sequential restoring divider that
	// retires two quotient bits per clock (32 clocks per division) and
	// reproduces the LPM semantics exactly:
	//   numer = quotient * denom + remain,  0 <= remain < |denom|
	// Division by zero yields the restoring-algorithm result (|q| all ones).
	bit  [63: 0] n_abs;
	bit  [31: 0] d_abs;
	bit  [63: 0] q;
	bit  [32: 0] r;
	bit  [ 5: 0] cnt;
	bit          n_neg, d_neg;

	function automatic [96:0] step(input [32:0] rin, input [63:0] qin, input [63:0] nin, input [31:0] d);
		bit [33:0] t;
		bit [32:0] r1;
		bit [63:0] n1;
		t  = {rin, nin[63]} - {2'b00, d};
		r1 = t[33] ? {rin[31:0], nin[63]} : t[32:0];
		n1 = {nin[62:0], 1'b0};
		step = {r1, qin[62:0], ~t[33]};
	endfunction

	always @(posedge CLK) begin
		bit [96:0] s1, s2;
		bit [63:0] n_sh;
		bit [63:0] q_t;
		if (START) begin
			n_neg <= numer[63];
			d_neg <= denom[31];
			n_abs <= numer[63] ? -numer : numer;
			d_abs <= denom[31] ? -denom : denom;
			q     <= '0;
			r     <= '0;
			cnt   <= 6'd32;
			BUSY  <= 1;
		end else if (cnt != 0) begin
			s1 = step(r, q, n_abs, d_abs);
			n_sh = {n_abs[62:0], 1'b0};
			s2 = step(s1[96:64], s1[63:0], n_sh, d_abs);
			r     <= s2[96:64];
			q     <= s2[63:0];
			n_abs <= {n_abs[61:0], 2'b00};
			cnt   <= cnt - 6'd1;
			if (cnt == 6'd1) begin
				// Final sign fix-up (remainder made non-negative).
				q_t = (n_neg ^ d_neg) ? -s2[63:0] : s2[63:0];
				if (n_neg && s2[95:64] != 32'd0) begin
					quotient <= d_neg ? q_t + 64'd1 : q_t - 64'd1;
					remain   <= d_abs - s2[95:64];
				end else begin
					quotient <= q_t;
					remain   <= s2[95:64];
				end
				BUSY <= 0;
			end
		end
	end
endmodule

module MADAM_DMA_STACK (
	input             CLK,
	input             CE,
	input             EN,
	
	input     [ 6: 0] WADDR,
	input     [21: 0] DIN,
	input             WE,
	
	input     [ 6: 0] RADDR,
	output    [21: 0] DOUT
);
	
// synopsys translate_off
`define SIM
// synopsys translate_on
	
`ifdef SIM

	reg [21:0]  BUF[128];
	initial begin
		BUF <= '{128{'0}};
		BUF[7'h60] <= 22'h080000;
	end
	
	always @(posedge CLK) begin
		if (EN) begin
			if (WE && CE) begin
				BUF[WADDR] <= DIN;
			end
		end
	end

	assign DOUT = BUF[RADDR];
											  	
`else 

	wire [21: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WE && EN && CE),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 22,
		altdpram_component.widthad = 7,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;

`endif

endmodule

module MADAM_SPRYTE_DATA_FIFO (
	input             CLK,
	input             EN,
	input             RST,
	
	input     [15: 0] DIN,
	input             WRREQ,
	
	input             RDREQ,
	output    [15: 0] DOUT,
	
	output            FULL,
	output            LESSHALF,
	output            EMPTY
);

	bit  [ 3: 0] RADDR;
	bit  [ 3: 0] WADDR;
	bit  [ 4: 0] AMOUNT;
	
	always @(posedge CLK) begin
		if (RST) begin
			AMOUNT <= '0;
			RADDR <= '0;
			WADDR <= '0;
		end
		else if (EN) begin
			if (WRREQ && !AMOUNT[4]) begin
				WADDR <= WADDR + 4'd1;
			end
			if (RDREQ && AMOUNT) begin
				RADDR <= RADDR + 4'd1;
			end
			
			if (WRREQ && !RDREQ && !AMOUNT[4]) begin
				AMOUNT <= AMOUNT + 5'd1;
			end else if (!WRREQ && RDREQ && AMOUNT) begin
				AMOUNT <= AMOUNT - 5'd1;
			end
		end
	end
	assign FULL = AMOUNT[4];
	assign LESSHALF = (AMOUNT <= 5'd8);
	assign EMPTY = ~|AMOUNT;
	
`ifdef SIM

	reg [15:0] BUF[16];
	initial begin
		BUF = '{16{'0}};
	end
	
	always @(posedge CLK) begin
		if (EN) begin
			if (WRREQ) begin
				BUF[WADDR] <= DIN;
			end
		end
	end

	assign DOUT = BUF[RADDR];
											  	
`else 

	wire [15: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WRREQ && EN),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 16,
		altdpram_component.widthad = 4,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule


module MADAM_PIP (
	input             CLK,
	input             EN,
	
	input     [ 4: 0] WA,
	input     [15: 0] DIN,
	input             WE,
	
	input     [ 4: 0] RA,
	output    [15: 0] DOUT
);
		
`ifdef SIM

	reg [15:0] BUF[32];
	initial begin
		BUF = '{32{'0}};
	end
	
	always @(posedge CLK) begin
		if (EN) begin
			if (WE) begin
				BUF[WA] <= DIN;
			end
		end
	end

	assign DOUT = BUF[RA];
											  	
`else 

	wire [15: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RA),
				.wraddress (WA),
				.wren (WE),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = 16,
		altdpram_component.widthad = 5,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule

module MADAM_SYNC_FIFO 
# (parameter width = 16)
(
	input               CLK,
	input               EN,
	input               RST,
	
	input  [width-1: 0] DIN,
	input               WRREQ,
	
	input               RDREQ,
	output [width-1: 0] DOUT,
	
	output              FULL,
	output              LESSHALF,
	output              EMPTY
);

	bit  [ 3: 0] RADDR;
	bit  [ 3: 0] WADDR;
	bit  [ 4: 0] AMOUNT;
	
	always @(posedge CLK) begin
		if (RST) begin
			AMOUNT <= '0;
			RADDR <= '0;
			WADDR <= '0;
		end
		else if (EN) begin
			if (WRREQ && !AMOUNT[4]) begin
				WADDR <= WADDR + 4'd1;
			end
			if (RDREQ && AMOUNT) begin
				RADDR <= RADDR + 4'd1;
			end
			
			if (WRREQ && !RDREQ && !AMOUNT[4]) begin
				AMOUNT <= AMOUNT + 5'd1;
			end else if (!WRREQ && RDREQ && AMOUNT) begin
				AMOUNT <= AMOUNT - 5'd1;
			end
		end
	end
	assign FULL = AMOUNT >= 5'h0F;
	assign LESSHALF = AMOUNT <= 5'd3;
	assign EMPTY = ~|AMOUNT;
	
`ifdef SIM

	reg [width-1:0] BUF[16];
	initial begin
		BUF = '{16{'0}};
	end
	
	always @(posedge CLK) begin
		if (EN) begin
			if (WRREQ) begin
				BUF[WADDR] <= DIN;
			end
		end
	end

	assign DOUT = BUF[RADDR];
											  	
`else 

	wire [width-1: 0] sub_wire0;

	altdpram	altdpram_component (
				.data (DIN),
				.inclock (CLK),
				.rdaddress (RADDR),
				.wraddress (WADDR),
				.wren (WRREQ && EN),
				.q (sub_wire0),
				.aclr (1'b0),
				.byteena (1'b1),
				.inclocken (1'b1),
				.rdaddressstall (1'b0),
				.rden (1'b1),
//				.sclr (1'b0),
				.wraddressstall (1'b0));
	defparam
		altdpram_component.indata_aclr = "OFF",
		altdpram_component.indata_reg = "INCLOCK",
		altdpram_component.intended_device_family = "Cyclone V",
		altdpram_component.lpm_type = "altdpram",
		altdpram_component.outdata_aclr = "OFF",
		altdpram_component.outdata_reg = "UNREGISTERED",
		altdpram_component.ram_block_type = "MLAB",
		altdpram_component.rdaddress_aclr = "OFF",
		altdpram_component.rdaddress_reg = "UNREGISTERED",
		altdpram_component.rdcontrol_aclr = "OFF",
		altdpram_component.rdcontrol_reg = "UNREGISTERED",
		altdpram_component.read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
		altdpram_component.width = width,
		altdpram_component.widthad = 4,
		altdpram_component.width_byteena = 1,
		altdpram_component.wraddress_aclr = "OFF",
		altdpram_component.wraddress_reg = "INCLOCK",
		altdpram_component.wrcontrol_aclr = "OFF",
		altdpram_component.wrcontrol_reg = "INCLOCK";
		
	assign DOUT = sub_wire0;
	
`endif

endmodule
