#!/usr/bin/env python3
"""Disassemble the 3DO DSP program in an Opera DSP snapshot (NMem words), with the
operand words decoded as Opera's opera_dsp.c reads them.  Lists the PCs executed
in the itrace (or all up to --max) and summarizes the data addresses used.
Usage: python3 -I dspdis.py dsp_snap.bin [dsp_itrace.bin]
"""
import sys
import numpy as np
from collections import Counter
snap = np.fromfile(sys.argv[1], dtype='<u2')
nmem = snap[:2048]; imem = snap[2048:3072]
pcs = None
if len(sys.argv) > 2:
    it = np.fromfile(sys.argv[2], dtype='<u4').reshape(-1, 4)
    pcs = Counter((it[:, 1] & 0xFFFF).tolist())
ALU = ['TRA', 'NEG', 'ADD', 'ADDC', 'SUB', 'SUBB', 'INC', 'DEC', 'TRL', 'NOT', 'AND', 'NAND', 'OR', 'NOR', 'XOR', 'XNOR']
BS = {0: '', 1: '<<1', 2: '<<2', 3: '<<3', 4: '<<4', 5: '<<5', 6: '<<8', 7: 'CLIP', 8: '<<OP', 9: '>>16', 10: '>>8', 11: '>>5', 12: '>>4', 13: '>>3', 14: '>>2', 15: '>>1'}
MUX = ['ACC', 'A1', 'A2', 'MUL']
addr_hist = Counter(); reg_hist = Counter(); imm_hist = Counter()
def operand(w):
    t = (w >> 13) & 7
    if t < 4:
        r1, d1, r2, d2, r3, d3 = w & 0xF, (w >> 4) & 1, (w >> 5) & 0xF, (w >> 9) & 1, (w >> 10) & 0xF, (w >> 14) & 1
        reg_hist[r1] += 1; reg_hist[r2] += 1; reg_hist[r3] += 1
        return 'R3 r%d%s r%d%s r%d%s' % (r3, '*' if d3 else '', r2, '*' if d2 else '', r1, '*' if d1 else ''), 3
    if t == 4:
        a, di, wb = w & 0x3FF, (w >> 10) & 1, (w >> 11) & 1
        addr_hist[a] += 1
        return 'ADDR %03x%s%s' % (a, '*' if di else '', ' WB' if wb else ''), 1
    if t == 5:
        r1, d1, r2, d2, n, wb1, wb2 = w & 0xF, (w >> 4) & 1, (w >> 5) & 0xF, (w >> 9) & 1, (w >> 10) & 1, (w >> 11) & 1, (w >> 12) & 1
        reg_hist[r1] += 1
        if n: reg_hist[r2] += 1
        return ('R2 r%d%s%s r%d%s%s' % (r2, '*' if d2 else '', ' WB' if wb2 else '', r1, '*' if d1 else '', ' WB' if wb1 else '')) if n else ('R1 r%d%s%s' % (r1, '*' if d1 else '', ' WB' if wb1 else '')), (2 if n else 1)
    imm = w & 0x1FFF; j = (w >> 13) & 1
    if imm & 0x1000: imm -= 0x2000
    imm_hist[imm] += 1
    return 'IMM %d%s' % (imm, ' <<3' if j else ''), 1
out = []
pc = 0
end = max(pcs) + 1 if pcs else 512
while pc < end:
    w = int(nmem[pc]); line = '%03x: %04x ' % (pc, w)
    n = 1
    if w & 0x8000:
        c = (w >> 7) & 0xFF
        bch = w & 0x3FF
        if c == 0: line += 'NOP'
        elif c == 1: line += 'BAC'
        elif c == 2: line += 'RBASE %d' % ((bch & 0x3F) << 2)
        elif c == 3: line += 'RMAP %d' % (bch & 7)
        elif c == 4: line += 'RTS'
        elif c == 5: line += 'OPMASK %02x' % (bch & 0x1F)
        elif c == 7: line += 'SLEEP'
        elif 8 <= c <= 15: line += 'JUMP %03x' % bch
        elif 16 <= c <= 23: line += 'JSR %03x' % bch
        elif 24 <= c <= 31: line += 'BFM %03x' % bch
        elif 32 <= c <= 47:
            r1, d1 = w & 0xF, (w >> 4) & 1; reg_hist[r1] += 1
            o, k = operand(int(nmem[pc + 1])); n = 2
            line += 'MOVEREG r%d%s <- %s' % (r1, '*' if d1 else '', o)
        elif 48 <= c <= 63:
            a, di = w & 0x3FF, (w >> 10) & 1; addr_hist[a] += 1
            o, k = operand(int(nmem[pc + 1])); n = 2
            line += 'MOVE %03x%s <- %s' % (a, '*' if di else '', o)
        else:
            line += 'BR%s mode%d flagsel%d mask%d%d -> %03x' % ('', (w >> 13) & 3, (w >> 12) & 1, (w >> 11) & 1, (w >> 10) & 1, bch)
    else:
        bs, alu, muxb, muxa, m2, nops = w & 0xF, (w >> 4) & 0xF, (w >> 8) & 3, (w >> 10) & 3, (w >> 12) & 1, (w >> 13) & 3
        line += '%-4s A=%s B=%s%s %s nops=%d' % (ALU[alu], MUX[muxa], MUX[muxb], ' M2' if m2 else '', BS[bs], nops)
        # operand words: Opera reads until op_cnt >= requests (requests = nops, or 4 if nops==0 and any request)
        req = nops
        need_bs = (bs == 8)
        uses = set()
        for m in (muxa, muxb):
            if m == 3: uses.add('M1'); uses.add('M2') if m2 else None
            elif m == 1: uses.add('A1')
            elif m == 2: uses.add('A2')
        if req == 0 and (uses or need_bs): req = 4
        cnt = 0; ops = []
        while cnt < req:
            o, k = operand(int(nmem[pc + n])); n += 1; cnt += k; ops.append(o)
        if ops: line += '  [' + '; '.join(ops) + ']'
    if pcs is not None:
        line += '   x%d' % pcs.get(pc, 0)
    out.append(line)
    pc += n
print('\n'.join(out))
print('\n== data addresses used (ADDR operands and MOVE targets):')
print(' '.join('%03x' % a for a in sorted(addr_hist)))
print('addresses >= 0x200:', ' '.join('%03x' % a for a in sorted(addr_hist) if 0x200 <= a < 0x300))
print('registers used:', sorted(reg_hist))
