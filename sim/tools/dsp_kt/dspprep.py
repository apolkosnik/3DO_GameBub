#!/usr/bin/env python3
"""Turn the Opera DSP trace (dsp_snap.bin, dsp_io.bin) and the ARM data trace of the
same run into the files tb_dsp_kt reads: nmem.hex (512 words), imem.hex (1024 words),
fifo.txt ("tick ch word" per input FIFO word in trace order; the word the CPU supplied
at 0x070+n and the DSP's next read took is not a FIFO word and is left out), cpu.txt
("tick kind addr word": the CPU's writes before that tick: I = DSP I memory word,
N = DSP N memory word, C = CLIO register (FIFO init / DMA enable)).  The CLIO register
writes come from the ARM trace, placed at the tick of the DSP-memory write before them.
Usage: python3 -I dspprep.py <opera_vram dir> <out dir> [arm dtrace]
"""
import sys, os
import numpy as np
d, out = sys.argv[1], sys.argv[2]
snap = np.fromfile(d + '/dsp_snap.bin', dtype='<u2')
nmem, imem = snap[:2048], snap[2048:3072]
with open(out + '/nmem.hex', 'w') as f:
    f.write('\n'.join('%04x' % w for w in nmem[:512]) + '\n')
with open(out + '/imem.hex', 'w') as f:
    f.write('\n'.join('%04x' % w for w in imem) + '\n')
io = np.fromfile(d + '/dsp_io.bin', dtype='<u4').reshape(-1, 4)
tick, addr, kind, val = io[:, 0], io[:, 2] & 0xFFFF, io[:, 2] >> 16, io[:, 3]
supplied = [False] * 16
n_fifo = n_sup = n_det = 0
# per channel, the reads that are FIFO words: not the CPU's supplied word, and not
# the zeros a channel gives once its DMA buffer has ended (Opera: no buffer -> 0),
# i.e. the run of zeros right before the CPU supplies the head word again
# A channel's DMA buffer ends where its reads become the zeros of an ended buffer
# (Opera: no buffer -> 0): the run of zeros right before the CPU supplies the head
# word again.  fifo.txt marks the end of each buffer segment ("tick ch END": MADAM
# ends the transfer, nothing more until the CPU enables the channel again), and
# idle.txt lists the ticks each channel is without a buffer ("ch from to").
reads = {ch: [] for ch in range(16)}
idle = []
for i, (t, a, k, v) in enumerate(zip(tick.tolist(), addr.tolist(), kind.tolist(), val.tolist())):
    if k == 2 and 0x70 <= a <= 0x7C:
        ch = a & 0xF
        n = 0
        while reads[ch] and reads[ch][-1][2] == 0:
            n += 1; reads[ch].pop(); n_det += 1
        if n:
            idle.append((ch, reads[ch][-1][1] + 1 if reads[ch] else 0, t))
        reads[ch].append((i, t, None))                 # the segment's end
        supplied[ch] = True
    elif k == 0 and (0xF0 <= a <= 0xFC or 0x70 <= a <= 0x7C):
        ch = a & 0xF
        if supplied[ch]:
            supplied[ch] = False; n_sup += 1
        else:
            reads[ch].append((i, t, v))
# a channel reading only zeros from the window's start has no buffer from the start
for ch in range(16):
    if reads[ch] and reads[ch][0][2] is None:
        idle.append((ch, 0, reads[ch][0][1]))
rows = sorted((i, t, ch, v) for ch in reads for (i, t, v) in reads[ch])
with open(out + '/fifo.txt', 'w') as f:
    for i, t, ch, v in rows:
        if v is None:
            f.write('%d %d END\n' % (t, ch))
        else:
            f.write('%d %d %04x\n' % (t, ch, v)); n_fifo += 1
with open(out + '/idle.txt', 'w') as f:
    for ch, a, b in sorted(idle, key=lambda x: (x[0], x[1])):
        f.write('%d %d %d\n' % (ch, a, b))
print('idle:', sorted(idle))
# CPU writes: DSP memory from the DSP trace (exact ticks), CLIO registers from the ARM trace
cpu = [(int(t), 'I' if k == 2 else 'N', int(a), int(v)) for t, a, k, v in zip(tick, addr, kind, val) if k in (2, 3)]
n_clio = 0
if len(sys.argv) > 3:
    dt = np.fromfile(sys.argv[3], dtype='<u4').reshape(-1, 5)
    seq, pc, aaddr, aval, fl = (dt[:, k].astype(np.int64) for k in range(5))
    w = ((fl & 1) != 0) & ((fl & 4) == 0) & ((aaddr & 0xFFFF0000) == 0x03400000)
    off = aaddr[w] & 0xFFFF; sq = seq[w]; vv = aval[w]
    # anchors: the DSP-memory writes, in order, matched 1:1 with the DSP trace's
    def dspmem(o):
        if 0x1800 <= o < 0x2000: return ('N', ((o - 0x1800) >> 1) & 0x3FF, 2)
        if 0x2000 <= o < 0x3000: return ('N', ((o - 0x2000) >> 2) & 0x3FF, 1)
        if 0x3000 <= o < 0x3400: return ('I', ((o - 0x3000) >> 1) & 0xFF, 2)
        if 0x3400 <= o < 0x3800: return ('I', ((o - 0x3400) >> 2) & 0xFF, 1)
        return None
    # the DSP-memory writes, matched 1:1 in order with the ARM trace's, carry the
    # tick; a CLIO register write gets the tick of the nearer (by ARM instruction
    # count) DSP-memory write, and the ARM order is kept
    rows = []      # (seq, tick, kind, addr, val)
    ci = 0
    pending = []   # CLIO register writes waiting for the next anchor
    last = None    # (seq, tick) of the previous anchor
    for o, s_, v in zip(off.tolist(), sq.tolist(), vv.tolist()):
        m = dspmem(o)
        if m is not None:
            k, a, n = m
            if ci < len(cpu) and cpu[ci][1] == k and cpu[ci][2] == a:
                t = cpu[ci][0]
                for (ps, po, pv) in pending:
                    pt = t if last is None or (s_ - ps) <= (ps - last[0]) else last[1]
                    rows.append((ps, pt, 'C', po, pv))
                pending = []
                for q in range(n):
                    rows.append((s_, t, cpu[ci + q][1], cpu[ci + q][2], cpu[ci + q][3]))
                ci += n
                last = (s_, t)
            else:
                print('anchor mismatch at ARM seq %d: %s %03x vs DSP trace %s' % (s_, k, a, cpu[ci] if ci < len(cpu) else None))
                break
        elif o in (0x300, 0x304, 0x308):
            if last is not None:
                pending.append((s_, o, v))
    for (ps, po, pv) in pending:
        rows.append((ps, last[1], 'C', po, pv))
    rows.sort(key=lambda r: r[0])
    cpu = [(t, k, a, v) for (_, t, k, a, v) in rows]
    n_clio = sum(1 for c in cpu if c[1] == 'C')
with open(out + '/cpu.txt', 'w') as f:
    for t, k, a, v in cpu:
        f.write('%d %s %03x %04x\n' % (t, k, a, v))
print('ticks %d, FIFO words %d (supplied words left out %d, ended-buffer zeros %d), CPU writes: DSP memory %d, CLIO registers %d' %
      (tick.max() + 1, n_fifo, n_sup, n_det, sum(1 for c in cpu if c[1] != 'C'), n_clio))
for c in cpu[:40]: print('  tick %5d %s %03x = %04x' % c)
