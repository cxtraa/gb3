module picorv32_icache #(
	parameter integer NUM_SETS = 256
) (
	input wire clk,
	input wire resetn,

	input wire c_valid,
	input wire c_instr,
	input wire [31:0] c_addr,
	input wire [31:0] c_wdata,
	input wire [3:0] c_wstrb,
	output reg c_ready,
	output reg [31:0] c_rdata,

	input wire m_ready,
	input wire [31:0] m_rdata,
	output reg m_valid,
	output reg m_instr,
	output reg [31:0] m_addr,
	output reg [31:0] m_wdata,
	output reg [3:0] m_wstrb,

	input wire flush
);
	localparam integer BYTE_BITS = 2;
	localparam integer SET_BITS = $clog2(NUM_SETS);
	localparam integer TAG_BITS = 32 - BYTE_BITS - SET_BITS;

	localparam [1:0] CACHE_IDLE = 2'd0;
	localparam [1:0] CACHE_LOOKUP = 2'd1;
	localparam [1:0] CACHE_REFILL = 2'd2;
	localparam [1:0] CACHE_BYPASS = 2'd3;

	reg [1:0] state;

	wire [SET_BITS-1:0] requested_set = c_addr[BYTE_BITS + SET_BITS - 1:BYTE_BITS];
	wire [TAG_BITS-1:0] requested_tag = c_addr[31:BYTE_BITS + SET_BITS];
	wire cacheable_instruction_fetch = c_valid && c_instr && (c_wstrb == 4'b0000) &&
			(c_addr >= 32'h0002_0000) && (c_addr < 32'h0200_0000);

	(* ram_style = "block" *) reg [31:0] data [0:NUM_SETS-1];
	reg [TAG_BITS-1:0] tag [0:NUM_SETS-1];
	reg valid [0:NUM_SETS-1];

	reg [31:0] request_addr;
	reg [SET_BITS-1:0] request_set;
	reg [TAG_BITS-1:0] request_tag;

	reg [31:0] lookup_data;
	reg [TAG_BITS-1:0] lookup_tag;
	reg lookup_valid;

	wire lookup_hit = lookup_valid && (lookup_tag == request_tag);

	integer i;

	always @* begin
		c_ready = 1'b0;
		c_rdata = 32'hxxxxxxxx;

		m_valid = 1'b0;
		m_instr = c_instr;
		m_addr = c_addr;
		m_wdata = c_wdata;
		m_wstrb = c_wstrb;

		case (state)
			CACHE_LOOKUP: begin
				if (lookup_hit) begin
					c_ready = 1'b1;
					c_rdata = lookup_data;
				end
			end

			CACHE_REFILL: begin
				m_valid = 1'b1;
				m_instr = 1'b1;
				m_addr = request_addr;
				m_wdata = 32'h00000000;
				m_wstrb = 4'b0000;

				if (m_ready) begin
					c_ready = 1'b1;
					c_rdata = m_rdata;
				end
			end

			CACHE_BYPASS: begin
				m_valid = c_valid;
				m_instr = c_instr;
				m_addr = c_addr;
				m_wdata = c_wdata;
				m_wstrb = c_wstrb;
				c_ready = m_ready;
				c_rdata = m_rdata;
			end
		endcase
	end

	always @(posedge clk) begin
		lookup_data <= data[requested_set];
		lookup_tag <= tag[requested_set];
		lookup_valid <= valid[requested_set];

		if (!resetn || flush) begin
			state <= CACHE_IDLE;

			for (i = 0; i < NUM_SETS; i = i + 1)
				valid[i] <= 1'b0;
		end else begin
			case (state)
				CACHE_IDLE: begin
					if (cacheable_instruction_fetch) begin
						request_addr <= c_addr;
						request_set <= requested_set;
						request_tag <= requested_tag;
						state <= CACHE_LOOKUP;
					end else if (c_valid) begin
						state <= CACHE_BYPASS;
					end
				end

				CACHE_LOOKUP: begin
					if (lookup_hit) begin
						state <= CACHE_IDLE;
					end else begin
						state <= CACHE_REFILL;
					end
				end

				CACHE_REFILL: begin
					if (m_ready) begin
						data[request_set] <= m_rdata;
						tag[request_set] <= request_tag;
						valid[request_set] <= 1'b1;
						state <= CACHE_IDLE;
					end
				end

				CACHE_BYPASS: begin
					if (m_ready)
						state <= CACHE_IDLE;
				end
			endcase
		end
	end
endmodule
