
# Cache Design

## Direct mapping
- Each instruction address is mapped to a specific cache slot (which might have 256 slots, 8 bits)
- The cache slot has a tag which matches the start of the instruction address (to double check whether a different instruction mapping to the same cache slot is not stored there)
- There is also a valid check bit which tells you if there is valid memory stored there (not garbage)

### An example of direct mapping
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

## Fully associative caching
