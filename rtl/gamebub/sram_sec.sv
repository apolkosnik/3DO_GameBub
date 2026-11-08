// The Game Bub's asynchronous SRAM (512 KiB, 256K x 16, on its own bus) as
// a slave of the 16-bit secondary-port protocol of sdram_3do.sv: request
// (req held until done), write words consumed with wnext, read words
// returned with rvalid, done at the end. vram_sram.sv sends it the requests
// of ddr_bridge.sv that address SRAM-mapped VRAM.
//
// Every SRAM pin comes from a register in its I/O block (the fork's SRAM
// controller found on the board that placement-dependent fabric delays
// between the pins corrupted writes), WE from an ODDR so that both of its
// edges fall in the middle of a cycle, half a cycle away from the address
// and data changes. The data bus direction is a single fabric register (the
// framework has one direction bit for all 16 pins); the bus changes
// direction only with an idle cycle in between.
//
// One 16-bit word takes two cycles at clk_mem (100 MHz), or three with
// `slow` (taken at the start of each request):
//   write, 2 cycles: address, data and byte enables for both, WE low from
//     the middle of the first to the middle of the second (10 ns);
//   write, 3 cycles: WE low from the middle of the first to the end of the
//     second (15 ns), address held through the third;
//   read: address with OE and both byte enables low for both (three)
//     cycles, the data taken at the edge that ends them (20 / 30 ns after
//     the address leaves the I/O block).
// A write word with both byte enables off is skipped (ddram.sv's random
// writes enable one VRAM half, two of a beat's four words).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module sram_sec (
	input              clk,             // clk_mem
	input              rst,
	input              slow,            // three cycles per word instead of two

	// secondary-port protocol (slave)
	input              req,             // level, held until done
	input              we,
	input      [17: 0] addr,            // SRAM word address of the first word
	input      [ 9: 0] len,             // words
	input      [15: 0] wdata,           // word N, held while wnext pulses for it
	input      [ 1: 0] wbe,
	output             wnext,           // the write word is taken at this edge
	output reg [15: 0] rdata,
	output reg         rvalid,
	output reg         done,

	// SRAM pins (framework SramV0)
	output             sram_ceN,
	output             sram_weN,
	output             sram_oeN,
	output     [ 1: 0] sram_writeMaskN,
	output     [17: 0] sram_address,
	input      [15: 0] sram_dataIn,
	output     [15: 0] sram_dataOut,
	output             sram_dataDir
);
	// Plan registers (fabric): the I/O block registers and the ODDR take them
	// at the next edge, so all pins change together.
	reg [17:0] p_addr = '0;
	reg [15:0] p_data = '0;
	reg [ 1:0] p_mask = 2'b11;
	reg        p_oe_n = 1, p_dir = 0, p_we1 = 1, p_we2 = 1;

	(* IOB = "TRUE" *) reg [17:0] o_addr = '0;
	(* IOB = "TRUE" *) reg [15:0] o_data = '0;
	(* IOB = "TRUE" *) reg [ 1:0] o_mask = 2'b11;
	(* IOB = "TRUE" *) reg        o_oe_n = 1;
	(* IOB = "TRUE" *) reg [15:0] i_data = '0;
	reg o_dir = 0;
	always @(posedge clk) begin
		o_addr <= p_addr;
		o_data <= p_data;
		o_mask <= p_mask;
		o_oe_n <= p_oe_n;
		o_dir  <= p_dir;
		i_data <= sram_dataIn;
	end
	ODDR #(
		.DDR_CLK_EDGE("SAME_EDGE"),
		.INIT(1'b1),
		.SRTYPE("SYNC")
	) we_oddr (
		.Q (sram_weN),
		.C (clk),
		.CE(1'b1),
		.D1(p_we1),
		.D2(p_we2),
		.R (1'b0),
		.S (1'b0)
	);
	assign sram_ceN        = 1'b0;
	assign sram_oeN        = o_oe_n;
	assign sram_writeMaskN = o_mask;
	assign sram_address    = o_addr;
	assign sram_dataOut    = o_data;
	assign sram_dataDir    = o_dir;

	typedef enum bit [2:0] {
		S_IDLE,
		S_GAP,       // bus turnaround
		S_WR,        // write words
		S_TAIL,      // write data held one more cycle
		S_RD,        // read words
		S_RDWAIT,    // the last read words' samples
		S_DONE,
		S_DROP       // until the client drops its request
	} st_t;
	st_t st = S_IDLE;

	reg        cur_we = 0;      // direction of the request
	reg        last_we = 0;     // direction of the last access
	reg        sl = 0;          // slow, for this request
	reg [17:0] a;               // address of the next word
	reg [ 9:0] left;            // words still to issue
	reg [ 1:0] ph;              // cycle within the word
	reg [ 9:0] rd_left;         // read words still to return
	reg [ 4:0] rd_due = '0;     // a read word's sample is in i_data (bit 3 / bit 4 with sl)

	wire last_ph = sl ? (ph == 2'd2) : (ph == 2'd1);
	assign wnext = (st == S_WR) && (ph == 2'd0);

	always @(posedge clk) begin
		rvalid <= 0;
		done   <= 0;
		rd_due <= {rd_due[3:0], 1'b0};
		if (sl ? rd_due[4] : rd_due[3]) begin
			rdata   <= i_data;
			rvalid  <= 1;
			rd_left <= rd_left - 1'd1;
		end

		if (rst) begin
			st     <= S_IDLE;
			p_oe_n <= 1;
			p_dir  <= 0;
			p_mask <= 2'b11;
			p_we1  <= 1;
			p_we2  <= 1;
			rd_due <= '0;
		end else begin
			case (st)
				S_IDLE: begin
					p_we1 <= 1; p_we2 <= 1;
					if (req) begin
						cur_we  <= we;
						sl      <= slow;
						a       <= addr;
						left    <= len;
						rd_left <= len;
						ph      <= '0;
						st      <= (we != last_we) ? S_GAP : (we ? S_WR : S_RD);
						last_we <= we;
					end
				end

				S_GAP: begin
					p_dir  <= 0;
					p_oe_n <= 1;
					p_mask <= 2'b11;
					st     <= cur_we ? S_WR : S_RD;
				end

				S_WR: begin
					if (ph == 2'd0) begin
						// take the word (wnext)
						if (wbe == 2'b00) begin
							p_we1 <= 1; p_we2 <= 1;          // skipped: no write cycle
							a     <= a + 1'd1;
							left  <= left - 1'd1;
							if (left == 10'd1) st <= S_TAIL;
						end else begin
							p_addr <= a;
							p_data <= wdata;
							p_mask <= ~wbe;
							p_dir  <= 1;
							p_oe_n <= 1;
							p_we1  <= 1; p_we2 <= 0;         // WE falls in the middle of the cycle
							ph     <= 2'd1;
						end
					end else begin
						if (sl && ph == 2'd1) begin
							p_we1 <= 0; p_we2 <= 0;          // low through the second cycle
						end else if (sl) begin
							p_we1 <= 1; p_we2 <= 1;          // rises at the start of the third
						end else begin
							p_we1 <= 0; p_we2 <= 1;          // rises in the middle of the second
						end
						ph <= ph + 1'd1;
						if (last_ph) begin
							ph   <= '0;
							a    <= a + 1'd1;
							left <= left - 1'd1;
							if (left == 10'd1) st <= S_TAIL;
						end
					end
				end

				S_TAIL: begin
					// data and address held for one more cycle after the last WE edge
					p_we1 <= 1; p_we2 <= 1;
					st    <= S_DONE;
				end

				S_RD: begin
					if (ph == 2'd0) begin
						p_addr <= a;
						p_oe_n <= 0;
						p_mask <= 2'b00;
						p_dir  <= 0;
						rd_due[0] <= 1;
					end
					ph <= ph + 1'd1;
					if (last_ph) begin
						ph   <= '0;
						a    <= a + 1'd1;
						left <= left - 1'd1;
						if (left == 10'd1) st <= S_RDWAIT;
					end
				end

				S_RDWAIT: begin
					// OE rises at the pins after the last sample has been taken
					p_oe_n <= 1;
					p_mask <= 2'b11;
					if (rd_left == 10'd0 && rd_due == '0 && !rvalid) st <= S_DONE;
				end

				S_DONE: begin
					p_dir  <= 0;
					p_mask <= 2'b11;
					done   <= 1;
					st     <= S_DROP;
				end

				S_DROP: if (!req) st <= S_IDLE;

				default: st <= S_IDLE;
			endcase
		end
	end
endmodule
