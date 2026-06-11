# PicoSoC Edited Files Notes

This file is a short companion to the existing `picosoc/README.md`. It only
describes the files that were changed or added for this version of the PicoSoC
design.

## Main Files

| File | Purpose |
| ---- | ------- |
| `picosoc/firmware.c` | Default interactive PicoSoC firmware. It now accepts either carriage return or newline at the "Press ENTER" prompt, which makes serial terminals that send LF behave correctly. |
| `picosoc/benchmark.c` | Standalone IceBreaker benchmark firmware. It initializes PicoSoC, enables QSPI/QDDR flash mode, runs repeatable sort, CRC, matrix, and instruction-footprint workloads, writes the benchmark checksum to the 7-segment register, and toggles an LED each loop. |
| `picosoc/picosoc.v` | PicoSoC top-level integration. It includes the instruction-cache wrapper between the CPU and the SPI flash path, exposes cache sizing parameters, passes UART divider writes through directly, and keeps the PicoRV32 CPU configuration aligned with the selected core parameters. |
| `picorv32_icache.v` | New instruction-cache module for PicoRV32's native memory interface. It caches instruction fetches from the flash-backed executable address range and forwards data accesses, writes, and uncached requests to memory. |
| `picosoc/icebreaker.v` | IceBreaker board top level. The PLL divider was adjusted for the lower 12 MHz build target. |
| `picosoc/Makefile` | Build rules now include `../picorv32_icache.v`, allow `CROSS` to be overridden from the environment or command line, and request a 12 MHz nextpnr target for HX8K and IceBreaker builds. |

## Benchmark Firmware

`picosoc/benchmark.c` is separate from the normal demo firmware. It is intended
for measuring the cache and flash-fetch behavior without waiting for serial
input.

The benchmark does four deterministic workloads:

- Bubble-sort over a fixed byte array.
- CRC-style bit processing over generated values.
- Small matrix multiply using an 8-bit software multiply helper.
- A larger instruction-footprint workload made from many noinline cache blocks.

The final mixed checksum is reduced to one byte and written to the 7-segment
peripheral at `0x03000001`. LED bit `0x02` toggles after each benchmark pass so
progress is visible on hardware.

To build the normal IceBreaker firmware, keep using:

```sh
make -C picosoc icebreaker_fw.bin
```

To use the benchmark as the IceBreaker firmware, build it with the same startup
file and linker script used by `firmware.c`, but compile `benchmark.c` instead.
For example:

```sh
make -C picosoc icebreaker_sections.lds
riscv64-unknown-elf-gcc -DICEBREAKER -mabi=ilp32 -march=rv32im \
  -Wl,-Bstatic,-T,picosoc/icebreaker_sections.lds,--strip-debug \
  -ffreestanding -nostdlib \
  -o picosoc/benchmark_fw.elf picosoc/start.s picosoc/benchmark.c
riscv64-unknown-elf-objcopy -O binary picosoc/benchmark_fw.elf picosoc/benchmark_fw.bin
```

If your toolchain has a different prefix, pass it through `CROSS` for Makefile
targets or replace the `riscv64-unknown-elf-` prefix in the manual commands.

## Cache Notes

The new cache is instruction-only. It treats reads as cacheable when they are:

- Instruction fetches.
- Read-only transfers with `c_wstrb == 4'b0000`.
- In the flash-backed executable range `0x00100000` through `0x01ffffff`.

Everything else passes through to the existing PicoSoC memory path. The cache
also supports a `flush` input; the current PicoSoC integration ties this low.

## Quick Checks

Useful commands from the repository root:

```sh
make icebsim
make icebreaker.json
make icebreaker.bin
make picosoc clean
```

The FPGA build expects the iCE40/Yosys/nextpnr tools and a RISC-V bare-metal
toolchain to be installed.
