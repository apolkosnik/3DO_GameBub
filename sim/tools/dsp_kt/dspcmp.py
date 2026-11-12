#!/usr/bin/env python3
"""Compare tb_dsp_kt's log with Opera's DSP trace, tick by tick.

Per tick: the DSP's writes (address, value) in order, Opera's from dsp_io.bin
(kind 1, addresses >= 0x100; 0x300 holds the frame counter and is skipped),
ours from the log's W lines; and the input FIFO words per channel (Opera's EI
reads vs the words our FIFOs handed over, F lines).  Reports the first
differing write with the surrounding instructions.
The ticks a channel is without a DMA buffer (idle.txt from dspprep.py, next to
the log) are not compared for that channel's output FIFO and the scratch words
0x130-0x134: Opera reads zeros from such a channel, the FIFO repeats its last word.
Usage: python3 -I dspcmp.py <log> <opera_vram dir> [max_ticks]
"""
import sys
import numpy as np
from collections import defaultdict
log, d = sys.argv[1], sys.argv[2]
max_ticks = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
SKIP = {0x300}
# ---- Opera ----
io = np.fromfile(d + '/dsp_io.bin', dtype='<u4').reshape(-1, 4)
it = np.fromfile(d + '/dsp_itrace.bin', dtype='<u4').reshape(-1, 4)
tk = np.fromfile(d + '/dsp_ticks.bin', dtype='<u4').reshape(-1, 4)
o_w = defaultdict(list); o_f = defaultdict(list)
supplied = [False] * 16      # the CPU's word at 0x070+n: the next read takes it, not a FIFO word
for tick, idx, ak, val in io.tolist():
    a, k = ak & 0xFFFF, ak >> 16
    if k == 1 and a >= 0x100 and a not in SKIP:
        o_w[tick].append((a, val & 0xFFFF, idx))
    elif k == 2 and 0x70 <= a <= 0x7C:
        ch = a & 0xF
        while o_f[ch] and o_f[ch][-1] == 0:      # an ended buffer's zeros (see dspprep.py)
            o_f[ch].pop()
        supplied[ch] = True
    elif k == 0 and (0xF0 <= a <= 0xFC or 0x70 <= a <= 0x7C):
        if supplied[a & 0xF]:
            supplied[a & 0xF] = False
        else:
            o_f[a & 0xF].append(val & 0xFFFF)
# ---- ours ----
u_w = defaultdict(list); u_f = defaultdict(list); u_s = {}
tick = -1
for line in open(log):
    p = line.split()
    if p[0] == 'T': tick = int(p[1])
    elif p[0] == 'W':
        if int(p[1], 16) not in SKIP:
            u_w[tick].append((int(p[1], 16), int(p[2], 16), int(p[3], 16)))
    elif p[0] == 'F': u_f[int(p[1])].append(int(p[2], 16))
    elif p[0] == 'S': u_s[tick] = int(p[1])
# our first full tick (the DSP's start makes one or two short ones) is Opera's tick 0
off = 0
while off <= tick and len(u_w[off]) < 10:
    off += 1
if off:
    u_w = defaultdict(list, {t - off: v for t, v in u_w.items() if t >= off})
    u_s = {t - off: v for t, v in u_s.items() if t >= off}
    tick -= off
    print('skipping %d short start-up ticks' % off)
n = min(tick + 1, max_ticks)
print('ours: %d ticks; sleep after (MCLK) min %d max %d of the first %d ticks' %
      (tick + 1, min(u_s.get(t, 9999) for t in range(n)), max(u_s.get(t, -1) for t in range(n)), n))
for ch in range(5):
    a, b = o_f[ch], u_f[ch]
    m = min(len(a), len(b))
    bad = [i for i in range(m) if a[i] != b[i]]
    print('FIFO %d: opera %d words, ours %d; first %d equal%s' % (ch, len(a), len(b), m - len(bad), '' if not bad else ', first difference at %d: opera %04x ours %04x' % (bad[0], a[bad[0]], b[bad[0]])))
# Writes to the output FIFOs, the DAC and the control registers (>= 0x3E0) are
# streams: compared in order.  I-memory writes (0x100-0x3DF) may be reordered by
# the pipeline (an ALU writeback lands after the next MOVE's write): compared as
# the multiset of (address, value) per tick.
STREAM = 0x3E0
import os
idle = defaultdict(list)
try:
    for line in open(os.path.join(os.path.dirname(log), 'idle.txt')):
        ch, a, b = (int(x) for x in line.split())
        idle[ch].append((a, b))
except OSError:
    pass
def is_idle(ch, t):
    return any(a <= t < b for a, b in idle[ch])
SCRATCH = {0x130, 0x131, 0x132, 0x133, 0x134}
def keep(t, a):
    if 0x3F0 <= a <= 0x3F3:
        return not is_idle(a - 0x3F0, t)
    if a in SCRATCH:
        return not any(is_idle(c, t) for c in range(3))
    return True
first = None
eq_ticks = 0
for t in range(n):
    a, b = o_w[t], u_w[t]
    sa = [(x[0], x[1]) for x in a if x[0] >= STREAM and keep(t, x[0])]; sb = [(x[0], x[1]) for x in b if x[0] >= STREAM and keep(t, x[0])]
    ma = sorted((x[0], x[1]) for x in a if x[0] < STREAM and keep(t, x[0])); mb = sorted((x[0], x[1]) for x in b if x[0] < STREAM and keep(t, x[0]))
    if sa == sb and ma == mb:
        eq_ticks += 1
    elif first is None:
        first = t
        if sa != sb:
            k = 0
            while k < min(len(sa), len(sb)) and sa[k] == sb[k]: k += 1
            print('tick %d: output stream differs at %d of %d/%d: opera %s ours %s' %
                  (t, k, len(sa), len(sb), ' '.join('%03x=%04x' % x for x in sa[max(0,k-3):k+4]), ' '.join('%03x=%04x' % x for x in sb[max(0,k-3):k+4])))
        if ma != mb:
            only_o = sorted(set(ma) - set(mb)); only_u = sorted(set(mb) - set(ma))
            print('tick %d: I-memory writes differ: opera-only %s; ours-only %s' %
                  (t, ' '.join('%03x=%04x' % x for x in only_o[:8]), ' '.join('%03x=%04x' % x for x in only_u[:8])))
print('write sets equal in %d of %d ticks' % (eq_ticks, n))
# the differing ticks: which addresses differ, and whether the output FIFO streams do
from collections import Counter
diff_addr = Counter(); diff_ticks = []; stream_diff = []
for t in range(n):
    a, b = o_w[t], u_w[t]
    sa = [(x[0], x[1]) for x in a if x[0] >= STREAM and keep(t, x[0])]; sb = [(x[0], x[1]) for x in b if x[0] >= STREAM and keep(t, x[0])]
    ma = sorted((x[0], x[1]) for x in a if x[0] < STREAM and keep(t, x[0])); mb = sorted((x[0], x[1]) for x in b if x[0] < STREAM and keep(t, x[0]))
    if sa == sb and ma == mb: continue
    diff_ticks.append(t)
    for x in set(ma) ^ set(mb): diff_addr[x[0]] += 1
    for x, y in zip(sa, sb):
        if x != y: diff_addr[x[0]] += 1
    if len(sa) != len(sb): diff_addr['len'] += 1
    fa = [x for x in sa if 0x3F0 <= x[0] <= 0x3F3]; fb = [x for x in sb if 0x3F0 <= x[0] <= 0x3F3]
    if fa != fb: stream_diff.append(t)
if diff_ticks:
    rng = []
    for t in diff_ticks:
        if rng and t == rng[-1][1] + 1: rng[-1][1] = t
        else: rng.append([t, t])
    print('differing ticks: %d, in ranges %s' % (len(diff_ticks), ' '.join('%d-%d' % (a, b) if a != b else '%d' % a for a, b in rng[:12])))
    print('addresses differing (ticks): %s' % ' '.join('%s:%d' % (k if isinstance(k, str) else '%03x' % k, v) for k, v in diff_addr.most_common(16)))
    print('ticks whose output FIFO words (0x3F0-0x3F3) differ: %d%s' % (len(stream_diff), '' if not stream_diff else ' first %s' % stream_diff[:8]))
if first is not None:
    t = first
    a, b = o_w[t], u_w[t]
    print('first differing tick %d: opera %d writes, ours %d' % (t, len(a), len(b)))
    k = 0
    while k < min(len(a), len(b)) and a[k][0] == b[k][0] and a[k][1] == b[k][1]:
        k += 1
    print('  first differing write index %d' % k)
    lo = max(0, k - 6)
    for i in range(lo, min(max(len(a), len(b)), k + 6)):
        oa = '%03x=%04x (insn %d pc %03x op %04x)' % (a[i][0], a[i][1], a[i][2], it[a[i][2], 1] & 0xFFFF, it[a[i][2], 1] >> 16) if i < len(a) else '-'
        ub = '%03x=%04x (pc %03x)' % (b[i][0], b[i][1], b[i][2]) if i < len(b) else '-'
        print('  %s %3d: opera %-44s ours %s' % ('>>' if i == k else '  ', i, oa, ub))
    # Opera's instructions of that tick around the differing write
    if k < len(a):
        idx = a[k][2]
        t0 = tk[t]
        print('  Opera instructions %d..%d of tick %d:' % (max(t0[2], idx - 12), idx + 2, t))
        for j in range(max(int(t0[2]), idx - 12), min(int(t0[2] + t0[3]), idx + 3)):
            fl = it[j, 3]
            print('    insn %d pc %03x op %04x Y %08x flags z%d n%d c%d v%d x%d wb %03x' %
                  (j, it[j, 1] & 0xFFFF, it[j, 1] >> 16, it[j, 2], fl & 1, (fl >> 1) & 1, (fl >> 2) & 1, (fl >> 3) & 1, (fl >> 4) & 1, (fl >> 16) & 0x3FF))
sys.exit(0 if first is None else 1)
