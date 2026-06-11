`timescale 1 ns / 1 ps

module picorv32_icache #(
	parameter integer NUM_WAYS = 1,
	parameter integer NUM_SETS = 16,
	parameter integer LINE_WORDS = 1
) (
	input wire clk,
	input wire resetn,

	// CPU-side PicoRV32 native memory interface.
	input wire        c_valid,
	input wire        c_instr,
	input wire [31:0] c_addr,
	input wire [31:0] c_wdata,
	input wire [ 3:0] c_wstrb,
	output wire       c_ready,
	output wire [31:0] c_rdata,

	// External memory-side PicoRV32 native memory interface.
	input wire        m_ready,
	input wire [31:0] m_rdata,
	output wire       m_valid,
	output wire       m_instr,
	output wire [31:0] m_addr,
	output wire [31:0] m_wdata,
	output wire [ 3:0] m_wstrb,

	input wire flush
);
	generate
		if (NUM_WAYS == 1 && LINE_WORDS == 1) begin : direct_word_cache
			localparam integer SET_BITS = $clog2(NUM_SETS);
			localparam integer TAG_BITS = 32 - SET_BITS - 2;

			reg [31:0] data [0:NUM_SETS-1];
			reg [TAG_BITS-1:0] tag [0:NUM_SETS-1];
			reg valid [0:NUM_SETS-1];

			wire [SET_BITS-1:0] set_index = c_addr[SET_BITS+1:2];
			wire [TAG_BITS-1:0] addr_tag = c_addr[31:SET_BITS+2];
			wire cacheable = c_valid && c_instr && (c_wstrb == 4'b0000) &&
					c_addr >= 32'h0010_0000 && c_addr < 32'h0200_0000;
			wire hit = cacheable && valid[set_index] && tag[set_index] == addr_tag;

			assign m_valid = c_valid && !hit;
			assign m_instr = c_instr;
			assign m_addr = c_addr;
			assign m_wdata = c_wdata;
			assign m_wstrb = c_wstrb;

			assign c_ready = hit || (!hit && m_ready);
			assign c_rdata = hit ? data[set_index] : m_rdata;

			integer i;

			always @(posedge clk) begin
				if (!resetn || flush) begin
					for (i = 0; i < NUM_SETS; i = i + 1)
						valid[i] <= 1'b0;
				end else if (cacheable && !hit && m_ready) begin
					data[set_index] <= m_rdata;
					tag[set_index] <= addr_tag;
					valid[set_index] <= 1'b1;
				end
			end
		end else begin : set_assoc_cache
			localparam integer SET_BITS = $clog2(NUM_SETS);
			localparam integer WORD_BITS = LINE_WORDS > 1 ? $clog2(LINE_WORDS) : 1;
			localparam integer WAY_BITS = NUM_WAYS > 1 ? $clog2(NUM_WAYS) : 1;
			localparam integer LINE_ADDR_BITS = SET_BITS + (LINE_WORDS > 1 ? WORD_BITS : 0);
			localparam integer LINE_WORD_COUNT = NUM_SETS * LINE_WORDS;
			localparam integer OFF_BITS = 2 + (LINE_WORDS > 1 ? WORD_BITS : 0);
			localparam integer TAG_BITS = 32 - SET_BITS - OFF_BITS;

			localparam [1:0] S_IDLE = 2'd0;
			localparam [1:0] S_LOOKUP = 2'd1;
			localparam [1:0] S_REFILL = 2'd2;

			reg [1:0] state;

			(* ram_style = "block" *) reg [31:0] data [0:NUM_WAYS-1][0:LINE_WORD_COUNT-1];
			(* ram_style = "block" *) reg [TAG_BITS-1:0] tag [0:NUM_WAYS-1][0:NUM_SETS-1];
			reg [31:0] way_rdata [0:NUM_WAYS-1];
			reg [TAG_BITS-1:0] way_tag [0:NUM_WAYS-1];
			reg valid [0:NUM_SETS-1][0:NUM_WAYS-1];
			reg [WAY_BITS-1:0] lru_age [0:NUM_SETS-1][0:NUM_WAYS-1];

			wire input_cacheable = c_valid && c_instr && (c_wstrb == 4'b0000) &&
					c_addr >= 32'h0010_0000 && c_addr < 32'h0200_0000;
			wire [WORD_BITS-1:0] input_word = LINE_WORDS > 1 ? c_addr[WORD_BITS+1:2] : {WORD_BITS{1'b0}};
			wire [SET_BITS-1:0] input_set = c_addr[OFF_BITS+SET_BITS-1:OFF_BITS];
			wire [TAG_BITS-1:0] input_tag = c_addr[31:OFF_BITS+SET_BITS];
			wire [LINE_ADDR_BITS-1:0] input_line_addr =
					LINE_WORDS > 1 ? {input_set, input_word} : input_set;

			reg [31:0] req_addr;
			reg [SET_BITS-1:0] req_set;
			reg [TAG_BITS-1:0] req_tag;
			reg [WORD_BITS-1:0] req_word;
			reg [WAY_BITS-1:0] req_way;
			reg [WORD_BITS-1:0] refill_word;

			wire [LINE_ADDR_BITS-1:0] req_line_addr =
					LINE_WORDS > 1 ? {req_set, req_word} : req_set;
			wire [LINE_ADDR_BITS-1:0] refill_line_addr =
					LINE_WORDS > 1 ? {req_set, refill_word} : req_set;
			wire [31:0] line_base = {req_addr[31:OFF_BITS], {OFF_BITS{1'b0}}};

			integer hit_i, replace_i, way_i, s, w, lru_i;

			reg hit;
			reg [WAY_BITS-1:0] hit_way;

			always @* begin
				hit = 1'b0;
				hit_way = {WAY_BITS{1'b0}};

				for (hit_i = 0; hit_i < NUM_WAYS; hit_i = hit_i + 1) begin
					if (valid[req_set][hit_i] && way_tag[hit_i] == req_tag) begin
						hit = 1'b1;
						hit_way = hit_i[WAY_BITS-1:0];
					end
				end
			end

			reg [WAY_BITS-1:0] replace_way;
			reg [WAY_BITS-1:0] replace_age;
			reg found_invalid;

			always @* begin
				replace_way = {WAY_BITS{1'b0}};
				replace_age = {WAY_BITS{1'b0}};
				found_invalid = 1'b0;

				for (replace_i = 0; replace_i < NUM_WAYS; replace_i = replace_i + 1) begin
					if (!valid[input_set][replace_i] && !found_invalid) begin
						replace_way = replace_i[WAY_BITS-1:0];
						found_invalid = 1'b1;
					end else if (!found_invalid && lru_age[input_set][replace_i] >= replace_age) begin
						replace_way = replace_i[WAY_BITS-1:0];
						replace_age = lru_age[input_set][replace_i];
					end
				end
			end

			reg c_ready_reg;
			reg [31:0] c_rdata_reg;
			reg m_valid_reg;
			reg m_instr_reg;
			reg [31:0] m_addr_reg;
			reg [31:0] m_wdata_reg;
			reg [3:0] m_wstrb_reg;

			assign c_ready = c_ready_reg;
			assign c_rdata = c_rdata_reg;
			assign m_valid = m_valid_reg;
			assign m_instr = m_instr_reg;
			assign m_addr = m_addr_reg;
			assign m_wdata = m_wdata_reg;
			assign m_wstrb = m_wstrb_reg;

			always @* begin
				c_ready_reg = 1'b0;
				c_rdata_reg = 32'hxxxxxxxx;

				m_valid_reg = 1'b0;
				m_instr_reg = c_instr;
				m_addr_reg = c_addr;
				m_wdata_reg = c_wdata;
				m_wstrb_reg = c_wstrb;

				case (state)
					S_IDLE: begin
						if (c_valid && !input_cacheable) begin
							m_valid_reg = 1'b1;
							c_ready_reg = m_ready;
							c_rdata_reg = m_rdata;
						end
					end

					S_LOOKUP: begin
						if (hit) begin
							c_ready_reg = 1'b1;
							c_rdata_reg = way_rdata[hit_way];
						end
					end

					S_REFILL: begin
						m_valid_reg = 1'b1;
						m_instr_reg = 1'b1;
						m_addr_reg = line_base + {refill_word, 2'b00};
						m_wdata_reg = 32'b0;
						m_wstrb_reg = 4'b0000;

						if (m_ready && refill_word == LINE_WORDS-1) begin
							c_ready_reg = 1'b1;
							c_rdata_reg = req_word == refill_word ? m_rdata : way_rdata[req_way];
						end
					end
				endcase
			end

			always @(posedge clk) begin
				for (way_i = 0; way_i < NUM_WAYS; way_i = way_i + 1) begin
					if (state == S_REFILL && m_ready && way_i[WAY_BITS-1:0] == req_way)
						data[way_i][refill_line_addr] <= m_rdata;

					way_rdata[way_i] <= data[way_i][state == S_IDLE ? input_line_addr : req_line_addr];
					way_tag[way_i] <= tag[way_i][state == S_IDLE ? input_set : req_set];
				end

				if (!resetn || flush) begin
					state <= S_IDLE;
					for (s = 0; s < NUM_SETS; s = s + 1) begin
						for (w = 0; w < NUM_WAYS; w = w + 1) begin
							valid[s][w] <= 1'b0;
							lru_age[s][w] <= w[WAY_BITS-1:0];
						end
					end
				end else begin
					case (state)
						S_IDLE: begin
							if (input_cacheable) begin
								req_addr <= c_addr;
								req_set <= input_set;
								req_tag <= input_tag;
								req_word <= input_word;
								req_way <= replace_way;
								refill_word <= {WORD_BITS{1'b0}};
								state <= S_LOOKUP;
							end
						end

						S_LOOKUP: begin
							if (hit) begin
								for (lru_i = 0; lru_i < NUM_WAYS; lru_i = lru_i + 1) begin
									if (lru_i[WAY_BITS-1:0] == hit_way) begin
										lru_age[req_set][lru_i] <= {WAY_BITS{1'b0}};
									end else if (valid[req_set][lru_i] &&
											lru_age[req_set][lru_i] < lru_age[req_set][hit_way]) begin
										lru_age[req_set][lru_i] <= lru_age[req_set][lru_i] + 1'b1;
									end
								end
								state <= S_IDLE;
							end else begin
								refill_word <= {WORD_BITS{1'b0}};
								state <= S_REFILL;
							end
						end

						S_REFILL: begin
							if (m_ready) begin
								if (refill_word == LINE_WORDS-1) begin
									tag[req_way][req_set] <= req_tag;
									valid[req_set][req_way] <= 1'b1;
									for (lru_i = 0; lru_i < NUM_WAYS; lru_i = lru_i + 1) begin
										if (lru_i[WAY_BITS-1:0] == req_way) begin
											lru_age[req_set][lru_i] <= {WAY_BITS{1'b0}};
										end else if (valid[req_set][lru_i] &&
												lru_age[req_set][lru_i] < NUM_WAYS-1) begin
											lru_age[req_set][lru_i] <= lru_age[req_set][lru_i] + 1'b1;
										end
									end
									state <= S_IDLE;
								end else begin
									refill_word <= refill_word + 1'b1;
								end
							end
						end
					endcase
				end
			end
		end
	endgenerate
endmodule
