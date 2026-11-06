# Disc streaming for the Game Bub 3DO core

**Status:** investigation and proposal. Nothing here is implemented yet.

The core currently loads the whole disc image into SDRAM at startup, so discs are limited
to 22 MiB. Commercial 3DO discs are 100–650 MB. This note covers what Game Bub (framework
and firmware v1.1-beta) offers today, the smallest change that would let the core read
sectors on demand, and how fast that could be.

## What exists today

Facts below are from the Game Bub sources (`github.com/elipsitz/gamebub`, tag `v1.1-beta`).

**The FPGA framework already has a core-to-MCU command channel.**
- `HostV0.commandCore` (`request`/`busy`/`done`/`error`) is wired to the control register
  `0xF100_1104`.
- A rising edge on `request` sets interrupt-pending bit 4 (`coreRequest`) in `HandheldTop.scala`.
- Parameters and results are exchanged through the core's own `0xF000_1000` block, as the
  interface docs describe.

**The MCU firmware (ESP32-S3, Rust on ESP-IDF) does not use that channel.**
- The constants `REG_CTRL_CMD_CORE` and `REG_CMD_CORE_BASE` are declared but never used
  (`firmware/handheld/src/device/drivers/fpga/mod.rs:33,39`).
- The `Irq` enum stops at bit 3 (`fpga/mod.rs:67-72`).
- The worker thread acts only on vblank (`worker/mod.rs:83-90`).
- With stock firmware, a core request is never answered.

**Reading the SD card while a core runs is possible.** No thread owns the card (FATFS
through VFS). The firmware already writes saves and screenshots at runtime, and keeps the
selected file's path for the whole session (`core/mod.rs:594`).

**Bulk transfers to the core use QSPI at up to 40 MHz × 4 lines** (`max_transfer_speed`
up to 20000 KB/s, `core/mod.rs:644-651`).

**Constraint:** the FPGA's SPI request FIFO holds 512 entries and has no backpressure.
The core must accept host writes at the transfer rate.

## Proposed protocol (core-initiated sector read)

| Step | Who | Action |
|------|-----|--------|
| 1 | core | Write the parameter block at `0xF000_1000`: opcode `FILE_STREAM_READ` (a new ID, e.g. `0x0380`), file id, byte offset, length, destination address. |
| 2 | core | Raise `commandCore.request`. The framework interrupts the MCU (`coreRequest`, bit 4). |
| 3 | MCU | Read the parameters. Seek in the cached `File` and read `length` bytes into the scratch buffer. |
| 4 | MCU | Write the data to the destination with the existing `spi_write` path, then write the byte count to `0xF000_1000`. |
| 5 | MCU | Set `done`, or `done|error` (e.g. EOF, or no stream support). |
| 6 | core | See `done`, drop `request`. The MCU then clears `done`. |

`files.json` gains one optional field on the disc file, `"stream": true`.

**Patched firmware** registers the file, sends `FileWriteStart`/`FileWriteEnd` with the
file size but no data, and answers requests.

**Stock firmware** ignores the unknown field and loads the file as now (the core's
`max_size` stops oversized images). The core detects streaming mode automatically: the
size is announced but no data was written. Otherwise it keeps using the preloaded image.
Images of 22 MiB or less therefore keep working on stock firmware.

## Core side (planned)

- **`cdd_emu.sv`:** in streaming mode, a sector fetch becomes a `FILE_STREAM_READ` for
  2048 bytes (or a few sectors, as read-ahead).
- **Destination:** a block-RAM sector buffer mapped into the core's host address space
  (e.g. `0x4000_0000`). This is the same 2 KiB buffer that `cdd_emu` streams to the CD
  controller today. Host writes go straight into block RAM, so the transfer never touches
  the SDRAM and needs no 3DO pause, and the core always keeps up with the SPI FIFO.
- **Timeout:** if no answer arrives, the drive reports a read error. Stock firmware never
  answers a streaming request.

## Firmware side (minimal change, about 150–250 lines of Rust)

1. `Irq::CoreRequest = 4`, enabled when the core enters the running stage and disabled on
   exit.
2. `CoreFile.stream: bool` (serde default `false`). For stream files, `load_files`
   announces the size without sending data, and `persist_files` skips them.
3. Worker: on `CoreRequest`, call a new `CoreManager::handle_core_request()`. It reads the
   parameter block, keeps the `File` handle open between requests, and reads and writes
   through the existing `SCRATCH` buffer with the file's `max_transfer_speed`. It then
   writes the result and `done` and waits for `request` to drop. It must not use the
   5 ms polling of `run_core_command`.
4. Optional: `CONFIG_FATFS_USE_FASTSEEK=y`, so backward seeks in large FAT32 files do
   not walk the cluster chain.

The firmware is GPL-3. It builds with the `esp` Rust toolchain
(`cargo build --release --features rev4`, ESP-IDF v5.4.3) and installs as a UF2 through
the DFU loader. Device owners can flash their own build.

## Expected performance (estimated, not measured)

| Step per 2 KB request | Time |
|---|---|
| Interrupt path (ISR, I2C status read, ack, worker queue) | 0.1–0.4 ms |
| Parameter read | ~0.05 ms |
| SD seek and 2 KB read | 0.3–1 ms |
| QSPI write at 40 MHz | 0.1–0.15 ms |
| Done handshake | ~0.05 ms |
| **Total** | **~0.7–1.5 ms**, i.e. 700–1400 sectors/s |

A 2x CD drive needs 150 sectors/s; MiSTer delivers about 330 sectors/s. Requesting
several sectors at once amortizes the per-request overhead. The firmware's own load-time
log (`core/mod.rs:711-718`) would give real SD and QSPI numbers on the device.

## Open points

- The command ID and field layout should be agreed with the Game Bub author, so the
  framework docs and a future official firmware use the same protocol.
- While the in-game menu is rendering, the overlay holds the device lock, which delays
  requests. The core's CD timing tolerates this, because a real drive also has seek delays.
