
module picorv32_icache #(
    parameter integer NUM_WAYS=4,
    parameter integer NUM_SETS=64,
    parameter integer LINE_WORDS=4
) (
    input wire clk,
    input wire resetn,

    // CPU-side from picorv32 core
    input wire c_valid, // CPU request valid
    input wire c_instr, // Is it an instruction?
    input wire[31:0] c_addr, // Address of instruction/data
    input wire[31:0] c_wdata, // Data to potentially write to mem
    input wire[3:0] c_wstrb, // Bits to write (0 means read)
    output reg c_ready, // Cache/memory has completed request
    output reg[31:0] c_rdata, // Read data returned to CPU

    // Memory side (connects to external memory)
    input wire m_ready, // Memory request was completed
    input wire[31:0] m_rdata, // Data out of memory
    output reg m_valid, // Request to ext. memory
    output reg m_instr, // Are we retrieving instr. from mem? 
    output reg[31:0] m_addr, // Address in ext. memory
    output reg[31:0] m_wdata, // Data to write
    output reg[3:0] m_wstrb, // Bits to write

    input wire flush
);

    localparam integer SET_BITS = $clog2(NUM_SETS); // Num bits for determining set
    localparam integer WORD_BITS = $clog2(LINE_WORDS); // Num bits for determining word in line
    localparam integer BYTE_BITS = 2; // 2 bits for determining byte
    localparam integer OFF_BITS = BYTE_BITS + WORD_BITS; 
    localparam integer TAG_BITS = 32 - SET_BITS - OFF_BITS; // Tag bits are remaining
    localparam integer WAY_BITS = $clog2(NUM_WAYS); // Num bits for determining way in set
    localparam integer AGE_BITS = $clog2(NUM_WAYS); // Age bits for LRU

    // Cache state machine

    // Normal state.
    // If CPU requests instruction, check cache.
    // If cache hit, return data.
    // Else, goto CACHE_REFILL.
    localparam[1:0] CACHE_LOOKUP = 2'd0;

    // Cache miss occurred.
    // Get cache line from external mem.
    localparam[1:0] CACHE_REFILL = 2'd1;

    // Data request
    // Send data from external memory straightt to CPU
    localparam[1:0] CACHE_BYPASS = 2'd2;

    reg[1:0] state;

    reg[31:0] data[0:NUM_SETS-1][0:NUM_WAYS-1][0:LINE_WORDS-1];

    reg [TAG_BITS-1:0] tag[0:NUM_SETS-1][0:NUM_WAYS-1];

    reg valid[0:NUM_SETS-1][0:NUM_WAYS-1];

    reg[AGE_BITS-1:0] age[0:NUM_SETS-1][0:NUM_WAYS-1];

    wire [WORD_BITS-1:0] requested_word_index;
    wire [SET_BITS-1:0] requested_set_index;
    wire [TAG_BITS-1:0] requested_tag;

    assign requested_word_index = c_addr[BYTE_BITS + WORD_BITS - 1 : BYTE_BITS];
    assign requested_set_index  = c_addr[OFF_BITS + SET_BITS - 1 : OFF_BITS];
    assign requested_tag        = c_addr[31: OFF_BITS + SET_BITS];

    wire cacheable_instruction_fetch = c_valid && c_instr && (c_wstrb == 4'b0000);
    integer i, s, w;

    reg cache_hit;                  
    reg[WAY_BITS-1:0] matched_way;

    always @* begin
        cache_hit = 1'b0;
        matched_way = {WAY_BITS{1'b0}}; // 0 repeated WAY_BITS times

        for (i = 0; i < NUM_WAYS; i = i + 1) begin
            if (valid[requested_set_index][i] && tag[requested_set_index][i] == requested_tag) begin
                cache_hit = 1'b1;
                matched_way = i;
            end
        end
    end

    reg[WAY_BITS-1:0] replacement_way;

    always @* begin
        replacement_way = {WAY_BITS{1'b0}};

        for (i = 0; i < NUM_WAYS; i = i + 1) begin
            if (!valid[requested_set_index][i])
                replacement_way = i;
        end

        for (i = 0; i < NUM_WAYS; i = i + 1) begin
            if (valid[requested_set_index][i] && age[requested_set_index][i] == NUM_WAYS-1)
                replacement_way = i;
        end
    end

    // Cache miss takes multiple cycles, so we need to store:
    // - line we wanted
    // - address wanted
    // - set index
    // - tag
    // etc.
    reg[31:0] missed_address;
    reg[SET_BITS-1:0] missed_set_index;
    reg[TAG_BITS-1:0] missed_tag;
    reg[WORD_BITS-1:0] missed_word_index;
    reg[WAY_BITS-1:0] missed_replacement_way;

    // Index of the word in the line
    reg[WORD_BITS-1:0] refill_word_index;

    // Base address of the line the address belongs to 
    wire[31:0] line_base_address;
    assign line_base_address = {missed_address[31:OFF_BITS], {OFF_BITS{1'b0}}};

    // LRU task
    // When we request a word from a line, update that way to age 0.
    // Ways that were newer than it become 1 step older.

    task update_lru;
        input[SET_BITS-1:0] set_i;
        input[WAY_BITS-1:0] used_way;
        integer k;
        reg[AGE_BITS-1:0] old_age;
        begin
            old_age = age[set_i][used_way];
            for (k = 0; k < NUM_WAYS; k = k + 1) begin
                if (k[WAY_BITS-1:0] == used_way) begin
                    age[set_i][k] <= 0;
                end
                else if (age[set_i][k] < old_age) begin
                    age[set_i][k] <= age[set_i][k] + 1'b1;
                end
            end
        end
    endtask

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
                if (cacheable_instruction_fetch && cache_hit) begin
                    c_ready = 1'b1;
                    c_rdata = data[requested_set_index][matched_way][requested_word_index];
                end
                else if (c_valid && !cacheable_instruction_fetch) begin
                    // Not instruction fetch
                    m_valid = 1'b1;
                    c_ready = m_ready;
                    c_rdata = m_rdata;
                end
            end

            CACHE_REFILL: begin
                m_valid = 1'b1;
                m_instr = 1'b1;
                m_wstrb = 4'b0000;
                m_addr = line_base_address + {refill_word_index, 2'b00};
                if (m_ready && refill_word_index == missed_word_index) begin
                    c_rdata = m_rdata;
                end
                else begin
                    c_rdata = data[missed_set_index][missed_replacement_way][missed_word_index];
                end

                if (m_ready && refill_word_index == LINE_WORDS-1)
                    c_ready = 1'b1;
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

        // Flush / reset the whole cache, so need to invalidate it
        if (!resetn || flush) begin
            state <= CACHE_LOOKUP;

            for (s = 0; s < NUM_SETS; s = s + 1) begin
                for (w = 0; w < NUM_WAYS; w = w + 1) begin
                    valid[s][w] <= 1'b0;
                    age[s][w] <= w[AGE_BITS-1:0];
                end
            end
        end
        else begin

            case (state)
                CACHE_LOOKUP: begin
                    if (cacheable_instruction_fetch && cache_hit) begin
                        update_lru(requested_set_index, matched_way);
                    end
                    else if (cacheable_instruction_fetch && !cache_hit) begin
                        missed_address <= c_addr;
                        missed_set_index <= requested_set_index;
                        missed_tag <= requested_tag;
                        missed_word_index <= requested_word_index;
                        missed_replacement_way <= replacement_way;

                        refill_wird_index <= 0;
                        state <= CACHE_REFILL;
                    end
                    else if (c_valid && !cacheable_instruction_fetch) begin
                        state <= CACHE_BYPASS;
                    end
                end

                CACHE_REFILL: begin
                    if (m_ready) begin
                        data[missed_set_index][missed_replacement_way][refill_word_index] <= m_rdata;

                        if (refill_word_index == LINE_WORDS-1) begin
                            tag[missed_set_index][missed_replacement_way] <= missed_tag;
                            valid[missed_set_index][missed_replacement_way] <= 1'b1;
                            update_lru(missed_set_index, missed_replacement_way);
                            state <= CACHE_LOOKUP;
                        end
                        else begin
                            refill_word_index <= refill_word_index + 1'b1;
                        end
                    end

                CACHE_BYPASS: begin
                    if (m_ready)
                        state <= CACHE_LOOKUP;
                end
            endcase
        end
    end
endmodule