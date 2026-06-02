
# Cache Design

## Cache types

A brief discussion of different caching techniques.

### Direct mapping
- Each instruction address is mapped to a specific cache slot (which might have 256 slots, 8 bits)
- The cache slot has a tag which matches the start of the instruction address (to double check whether a different instruction mapping to the same cache slot is not stored there)
- There is also a valid check bit which tells you if there is valid memory stored there (not garbage)

#### An example of direct mapping
- Say the next instruction address is `0000 0011 0101 1100` (assume a 16-bit system here for simplicity).
- Split the address as follows:
- Index (bits 0-7): `0101 1100 = 86` and tag (bits 8-15): `0000 0011`.
- Goto index 86 in the cache (which has `2^8 = 256`) slots.
- `valid` tells us if the data stored in the cache here has been stored intentionally by the CPU as a result of reading an instruction. If `valid = 0`, it means the data here is garbage and we automatically get a `MISS`.

| valid | tag       | inst       |
| ----- | --------- | ---------- |
| 1     | 0000 0011 | 0x00A0006F |

- If the `tag`s match, then the instruction is copied, bypassing the main memory!
- Otherwise, if they don't, we get a `MISS`, and we need to do the usual process going through main memory.
- If we get a `MISS` for any reason, the cache slot is updated with the current instruction.

#### Advantages
- Requires just one cache lookup which is very fast.
#### Disadvantages
- If we have two alternating instructions with the same `index`, we can get repeated `MISS`.

### Fully associative caching

We do not use indexing on the instruction to find the cache slot. Instead, when we get a cache `MISS`:
1. **Cache is full**: use a strategy such as LRU (least recently used) and overwrite the least recently used instruction with the instruction that missed.
2. **Cache is not full**: simply add the instruction at the first free available slot.

#### Advantages
- We do not run into repeated `MISS` issues because we only remove the least recently used instruction.
#### Disadvantages
- Have to search every cache slot to find a match, i.e. it is `O(cache size)`.

### Set associative caching

This combines the two previous approaches. We divide the cache into sets, each with `N` slots. E.g. for `N = 2` on a `8 bit` cache, we get `128` sets, which is `2-way set associative caching`. 

We use indexing to find which **set** to go to, and then use a strategy like LRU for each set independently of the others.

This gives us the benefit of avoiding cache misses with fully associative caching while also cutting down the number of cache searches significantly!

### Which strategy?

We decided to choose set associative caching due to the advantages described above. Virtually every modern CPU uses set associative caching.

## Implementation plan

### Configuration Parameters

For the PicoRV32 integration, we propose the following configurable parameters:

- **`CACHE_SETS`**: Number of sets in the cache (default: 64)
- **`CACHE_WAYS`**: Associativity level, i.e., number of ways per set (default: 4 for 4-way set associative)
- **`CACHE_LINE_WIDTH`**: Width of each cache line in bits (default: 32 for single 32-bit instruction)
- **`TAG_WIDTH`**: Width of the tag field derived from high-order address bits
- **`ENABLE_CACHE`**: Parameter to enable/disable cache (default: 1)

From these, we derive:
- **Index bits** = $\log_2(\text{CACHE SETS})$
- **Offset bits** = 2 (since we're caching 32-bit aligned instructions)
- **Tag bits** = 32 - Index bits - Offset bits
- **Total cache storage** = `CACHE_SETS * CACHE_WAYS * (1 + TAG_WIDTH + 32 + log2(CACHE_WAYS))` bits
  - Where: 1 (valid) + TAG_WIDTH (tag) + 32 (instruction) + log2(CACHE_WAYS) (LRU state)
  - Example: 64 sets, 4-way cache → 64 × 4 × (1 + 24 + 32 + 2) = 15,104 bits ≈ 1.9 KB

### Data Structures

Each cache entry contains:
- **Valid bit**: 1 bit indicating if the entry contains valid data
- **Tag**: `TAG_WIDTH` bits from the instruction address
- **Data**: 32-bit cached instruction
- **LRU bits**: $\log_2(\text{CACHE WAYS})$ bits to track least recently used slot within a set

Example for 4-way set associative cache with 64 sets:
```
┌─────────────────────────────────────────┐
│ Per Cache Set (4 entries)               │
├─────────────────────────────────────────┤
│ [Entry 0]  Valid | Tag [19:0] | Instr  │
│ [Entry 1]  Valid | Tag [19:0] | Instr  │
│ [Entry 2]  Valid | Tag [19:0] | Instr  │
│ [Entry 3]  Valid | Tag [19:0] | Instr  │
├─────────────────────────────────────────┤
│ LRU State: 2-bit counter for each way   │
└─────────────────────────────────────────┘
```

### Cache Lookup Algorithm

**Input**: 32-bit instruction address (`mem_addr`)

**Output**: Cache hit/miss signal, cached instruction or memory request

1. Extract **index** from bits `[7:2]` (for 64-set cache): `index = mem_addr[7:2]`
2. Extract **tag** from bits `[31:8]`: `tag = mem_addr[31:8]`
3. **Parallel lookup** in all 4 ways of the selected set:
   - For each way $i \in [0, 3]$:
     - Compare `cache[index][i].tag == tag AND cache[index][i].valid`
   - If any way matches: **CACHE HIT** → return instruction, mark that way as most recently used
   - If no way matches: **CACHE MISS** → fetch from main memory
4. On cache miss, update LRU tracker for the selected set and prepare to write the new instruction

### Replacement Policy: Least Recently Used (LRU)

**LRU State per Set**: 2-bit counter for 4-way cache (values 0-3)

**On Cache Hit**:
- Update LRU counter of the referenced way to 3 (most recent)
- Decrement LRU counters of other ways that are greater than the current way's new value

**On Cache Miss**:
- Identify the way with `LRU_counter = 0` (least recently used)
- Replace instruction in that way
- Set the LRU counter of the new way to 3
- Decrement LRU counters of all other ways if needed to maintain ordering

### Hardware Interface

The cache module interfaces with the PicoRV32 memory subsystem:

**Inputs**:
- `clk`: Clock signal
- `rst`: Reset signal
- `mem_addr[31:0]`: Instruction address from CPU
- `mem_valid`: CPU requesting a fetch
- `mem_rdata[31:0]`: Data returned from main memory on miss

**Outputs**:
- `cache_hit`: Indicates a cache hit (combinational)
- `cache_instr[31:0]`: Cached instruction (combinational on hit)
- `cache_miss_addr[31:0]`: Requested address (for forwarding to main memory)
- `mem_req_valid`: Request forwarded to main memory (on cache miss)

### Verilog Module Outline

```verilog
module picorv32_icache #(
    parameter CACHE_SETS = 64,
    parameter CACHE_WAYS = 4,
    parameter TAG_WIDTH = 20
) (
    input clk, rst,
    input [31:0] mem_addr,
    input mem_valid,
    input [31:0] mem_rdata,
    input mem_ready,
    
    output cache_hit,
    output [31:0] cache_instr,
    output [31:0] miss_addr,
    output mem_req_valid
);
    // Cache memory arrays
    reg [TAG_WIDTH-1:0] tag_array [0:CACHE_SETS-1][0:CACHE_WAYS-1];
    reg valid_array [0:CACHE_SETS-1][0:CACHE_WAYS-1];
    reg [31:0] data_array [0:CACHE_SETS-1][0:CACHE_WAYS-1];
    
    // LRU state for each set
    reg [$clog2(CACHE_WAYS)-1:0] lru_array [0:CACHE_SETS-1][0:CACHE_WAYS-1];
    
    // Extract address components
    wire [5:0] index = mem_addr[7:2];
    wire [TAG_WIDTH-1:0] tag = mem_addr[31:8];
    
    // Hit detection logic (parallel comparators)
    wire [CACHE_WAYS-1:0] way_hit;
    generate
        for (genvar i = 0; i < CACHE_WAYS; i = i + 1) begin
            assign way_hit[i] = valid_array[index][i] && 
                                (tag_array[index][i] == tag);
        end
    endgenerate
    
    assign cache_hit = |way_hit;
    
    // TODO: Priority encoder to select hit way
    // TODO: LRU update logic on hit
    // TODO: Cache line fill logic on miss
    // TODO: Write-back interface to main memory
    
endmodule
```

### Implementation Steps

1. **Phase 1: Basic Data Structures**
   - Implement tag, valid, and data arrays
   - Implement LRU tracking mechanism
   - Test with simulation

2. **Phase 2: Cache Lookup Path**
   - Implement parallel tag comparators for all ways
   - Implement hit/miss detection logic
   - Implement priority encoder to select hit way on multiple matches

3. **Phase 3: Replacement & Write-back**
   - Implement LRU replacement policy
   - Integrate with main memory interface
   - Implement cache line fill on miss

4. **Phase 4: Pipeline Integration**
   - Integrate cache with PicoRV32 fetch stage
   - Handle address translation and forwarding
   - Implement performance monitoring (hit rate, miss count)

5. **Phase 5: Testing & Optimization**
   - Create testbenches for cache behavior
   - Measure hit rate on real firmware
   - Tune associativity and set count parameters

### Performance Metrics

Track the following metrics:
- **Cache hit rate**: (# hits) / (# accesses)
- **AMAT** (Average Memory Access Time): $\text{hit\_time} + \text{miss\_rate} \times \text{miss\_penalty}$
- **Instruction fetch cycles**: Compare cached vs. uncached execution
- **Power overhead**: Area and power cost of cache storage

