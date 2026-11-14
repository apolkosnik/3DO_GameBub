// The 3DO mouse from the Game Bub host (gb_host registers), as the PS/2
// packets HPS2PAD's mouse device takes (the MiSTer format: bit 24 toggles
// with every packet, bits 7:0 the flags byte, 15:8 dx, 23:16 dy).
//
// Every write of the motion register is one packet: dx right positive, dy
// down positive (PS/2 counts y up, so dy is negated), each clamped to the
// packet's 9 bits (-256..255); HPS2PAD moves the 3DO mouse one count per unit
// and takes at most 511 counts per control port read. Buttons: bit 0 left,
// bit 1 right, bit 2 middle (PS/2 flag bits 0, 1, 2), in the flags byte at
// all times: HPS2PAD reads them as they stand, so a button written without
// a motion packet (the firmware does, with the mouse still) counts.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module host_mouse (
	input             clk,
	input             rst,
	input             pkt,          // a motion register write (one clock)
	input      [15:0] dx,           // signed
	input      [15:0] dy,           // signed, down positive
	input      [ 2:0] buttons,      // {middle, right, left}
	output reg [24:0] ps2_mouse
);
	function automatic [8:0] clamp9(input signed [16:0] v);
		if (v > 17'sd255)       clamp9 = 9'h0FF;
		else if (v < -17'sd256) clamp9 = 9'h100;
		else                    clamp9 = v[8:0];
	endfunction
	// 17 bits: -(-32768) does not wrap (it is +255 up, not -256 down)
	wire signed [16:0] sdx = {dx[15], dx};
	wire signed [16:0] sdy = {dy[15], dy};
	wire [8:0] cx = clamp9(sdx);
	wire [8:0] cy = clamp9(-sdy);
	always @(posedge clk) begin
		if (rst) ps2_mouse <= '0;
		else begin
			// the flags byte: y sign, x sign, always 1, middle, right, left
			ps2_mouse[7:0] <= {1'b0, 1'b0, cy[8], cx[8], 1'b1, buttons[2], buttons[1], buttons[0]};
			if (pkt) begin
				ps2_mouse[15:8]  <= cx[7:0];
				ps2_mouse[23:16] <= cy[7:0];
				ps2_mouse[24]    <= ~ps2_mouse[24];
			end
		end
	end
endmodule
