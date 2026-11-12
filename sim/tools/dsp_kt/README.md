# DSP lockstep with Opera

`tb_dsp_kt` (sim/tb/tb_dsp_kt.sv) runs the real CLIO on a game's DSP program with
the I memory, the input FIFO words and the CPU's writes of an instrumented run of
the Opera emulator (libretro core, commit 595fd1d), and `dspcmp.py` compares what
the DSP wrote, tick by tick, with Opera's per-instruction trace. It found the
input FIFO head-word and same-clock read defects behind Killing Time's embossed
EZFlix intro (see the CLIO section of the main README).

1. Apply `opera_trace.patch` to the Opera source and build `opera_libretro.so`.
   It adds, read from the environment: `OPERA_ITRACE`, `OPERA_DTRACE`,
   `OPERA_REGDUMP` (+`_FRAME`, `_N`), `OPERA_TRACE_FRAMES` (ARM instruction and
   data traces, a register dump at the first screen writes of a frame),
   `OPERA_SNAP` (+`_FRAME`, `_PC`: RAM and registers before an instruction),
   `OPERA_VRAM_LOG`, `OPERA_VRAM_DUMP`, and `OPERA_DSP_TRACE` + `OPERA_DSP_FRAMES`
   (DSP memory snapshot at the first tick, per-tick, per-instruction and
   per-access traces, with the CPU's writes to DSP memory). The record formats
   are in the patch's comments.
2. Run RetroArch headless over the frames of interest, for example
   `OPERA_DSP_TRACE=out/dsp OPERA_DSP_FRAMES=905-917 OPERA_DTRACE=out/dtrace.bin
   OPERA_TRACE_FRAMES=905-917 retroarch -L opera_libretro.so game.cue
   --max-frames=918` (video, audio and input drivers `null`).
3. `python3 -I dspprep.py out data out/dtrace.bin` writes `nmem.hex`, `imem.hex`,
   `fifo.txt` (the FIFO words with the DMA buffer ends), `cpu.txt` (the CPU's
   DSP-memory, FIFO reset and DMA enable writes before each tick) and `idle.txt`.
4. `sim/run_tb.sh tb_dsp_kt +nmem=data/nmem.hex +imem=data/imem.hex
   +fifo=data/fifo.txt +cpu=data/cpu.txt +ticks=9560 +log=data/run.log`
5. `python3 -I dspcmp.py data/run.log out 9560` reports the first differing tick
   and write, with Opera's instructions around it; `+trace_from=/+trace_to=`
   make the testbench log every clock of those ticks.

`dspdis.py out/dsp_snap.bin out/dsp_itrace.bin` lists the program with the
operand words decoded and the execution counts.

The trace files hold the game's code and data and are not in the repository.
