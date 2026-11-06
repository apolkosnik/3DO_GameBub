module CLIO_INTERPOL
(
	input              CLK,
	input              RST_N,
	input              EN,
	
	input              CE,
	
	input              ACLK1,
	input              ACLK2,
	
	input              HION,
	input              VION,
	input              SPH,
	input              SPV,
	
	input      [23: 0] LP0,
	input      [23: 0] LP1,
	input      [23: 0] LP2,
	input      [23: 0] LP3,
	input              DE_IN,
	
	output reg [23: 0] OUT,
	output reg         DE
);

	function bit [7:0] ColorInterp(input bit [7:0] c0, input bit [7:0] c1);
		bit [8:0] sum;
		
		sum = {1'b0,c0} + {1'b0,c1};
		return sum[8:1];
	endfunction

	function bit [23:0] PixInterp(input bit [23:0] lp0, input bit [23:0] lp1);
		bit [23:0] ret;
		
		ret[23:16] = ColorInterp(lp0[23:16],lp1[23:16]);
		ret[15: 8] = ColorInterp(lp0[15: 8],lp1[15: 8]);
		ret[ 7: 0] = ColorInterp(lp0[ 7: 0],lp1[ 7: 0]);
		return ret;
	endfunction
	
	bit [23: 0] SUM0,SUM1;
	bit         DE_IN_FF;
	always @(posedge CLK) begin
		if (EN && CE) begin
			case (HION)
				1'b0: begin SUM0 <= PixInterp(LP3,LP3); SUM1 <= PixInterp(LP0,LP0); end
				1'b1: begin SUM0 <= PixInterp(LP2,LP3); SUM1 <= PixInterp(LP0,LP1); end
			endcase
			case (VION)
				1'b0: OUT <= PixInterp(SUM0,SUM0);
				1'b1: OUT <= PixInterp(SUM0,SUM1);
			endcase
			
			DE_IN_FF <= DE_IN;
			DE <= DE_IN_FF;
		end
	end
		

endmodule

