#!/usr/bin/env python3
"""Put StockPilot's icon and version info into the Electron exe (replaces rcedit, runs on Linux/macOS too).

usage: set-exe-info.py <exe> <resources.res>
The .res comes from:  llvm-rc /FO resources.res exe.rc   (exe.rc is next to this script)
Every icon / icon group / version resource in the exe is replaced by the ones in the .res;
everything else (manifest etc.) is kept. Works for x64, x86 and arm64 PE files.
"""
import struct, sys

RT_ICON, RT_GROUP_ICON, RT_VERSION = 3, 14, 16


def align(v, a):
    return (v + a - 1) // a * a


def read_res(path):
    d = open(path, 'rb').read()
    out, p = [], 0
    while p + 8 <= len(d):
        size, hsize = struct.unpack_from('<II', d, p)
        q = p + 8

        def ident(q):
            if struct.unpack_from('<H', d, q)[0] == 0xFFFF:
                return struct.unpack_from('<H', d, q + 2)[0], q + 4
            e = q
            while struct.unpack_from('<H', d, e)[0] != 0:
                e += 2
            return d[q:e].decode('utf-16-le').upper(), e + 2
        typ, q = ident(q)
        name, q = ident(q)
        q = align(q, 4)
        lang = struct.unpack_from('<H', d, q + 6)[0]
        data = d[p + hsize:p + hsize + size]
        if size:
            out.append((typ, name, lang, data))
        p = align(p + hsize + size, 4)
    return out


def parse_tree(d, sec_off, sec_rva, rva_to_off):
    def walk(off, level):
        _, _, _, _, nnamed, nid = struct.unpack_from('<IIHHHH', d, sec_off + off)
        items = []
        for i in range(nnamed + nid):
            nm, od = struct.unpack_from('<II', d, sec_off + off + 16 + 8 * i)
            if nm & 0x80000000:
                so = sec_off + (nm & 0x7FFFFFFF)
                ln = struct.unpack_from('<H', d, so)[0]
                key = d[so + 2:so + 2 + 2 * ln].decode('utf-16-le')
            else:
                key = nm
            if od & 0x80000000:
                items.append((key, walk(od & 0x7FFFFFFF, level + 1)))
            else:
                rva, size, cp, _ = struct.unpack_from('<IIII', d, sec_off + od)
                fo = rva_to_off(rva)
                items.append((key, (d[fo:fo + size], cp)))
        return items
    return walk(0, 0)


def sort_items(items):
    named = sorted([i for i in items if isinstance(i[0], str)], key=lambda x: x[0].upper())
    ids = sorted([i for i in items if not isinstance(i[0], str)], key=lambda x: x[0])
    return named + ids


def build_tree(tree, base_rva):
    """tree: list of (key, list|tuple(data, codepage)), 3 levels."""
    dirs, strings, leaves = [], [], []

    # breadth first so every table is in one block
    root = {'items': sort_items(tree)}
    queue, order = [root], []
    while queue:
        n = queue.pop(0)
        order.append(n)
        for k, v in n['items']:
            if isinstance(k, str) and k not in strings:
                strings.append(k)
            if isinstance(v, list):
                child = {'items': sort_items(v)}
                n.setdefault('children', {})[id(v)] = child
                queue.append(child)
            else:
                leaves.append(v)
    off = 0
    for n in order:
        n['off'] = off
        off += 16 + 8 * len(n['items'])
    str_off = {}
    for s in strings:
        str_off[s] = off
        off += 2 + 2 * len(s)
    off = align(off, 4)
    leaf_off = {}
    for i, lv in enumerate(leaves):
        leaf_off[id(lv)] = off
        off += 16
    data_off = {}
    for lv in leaves:
        off = align(off, 8)
        data_off[id(lv)] = off
        off += len(lv[0])
    buf = bytearray(align(off, 8))
    for n in order:
        nn = sum(1 for k, _ in n['items'] if isinstance(k, str))
        struct.pack_into('<IIHHHH', buf, n['off'], 0, 0, 0, 0, nn, len(n['items']) - nn)
        for i, (k, v) in enumerate(n['items']):
            nm = (0x80000000 | str_off[k]) if isinstance(k, str) else k
            if isinstance(v, list):
                od = 0x80000000 | n['children'][id(v)]['off']
            else:
                od = leaf_off[id(v)]
            struct.pack_into('<II', buf, n['off'] + 16 + 8 * i, nm, od)
    for s, o in str_off.items():
        struct.pack_into('<H', buf, o, len(s))
        buf[o + 2:o + 2 + 2 * len(s)] = s.encode('utf-16-le')
    for lv in leaves:
        struct.pack_into('<IIII', buf, leaf_off[id(lv)], base_rva + data_off[id(lv)], len(lv[0]), lv[1], 0)
        o = data_off[id(lv)]
        buf[o:o + len(lv[0])] = lv[0]
    return bytes(buf)


def pe_checksum(d, csum_off):
    try:
        import numpy as np
        b = bytearray(d)
        b[csum_off:csum_off + 4] = b'\0\0\0\0'
        if len(b) % 2:
            b += b'\0'
        s = int(np.frombuffer(bytes(b), dtype='<u2').astype(np.uint64).sum())
        while s >> 16:
            s = (s & 0xFFFF) + (s >> 16)
        return (s + len(d)) & 0xFFFFFFFF
    except ImportError:
        pass
    s = 0
    n = len(d)
    padded = d + (b'\0' if n % 2 else b'')
    for i in range(0, len(padded), 2):
        if i == csum_off or i == csum_off + 2:
            continue
        s += padded[i] | (padded[i + 1] << 8)
        s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (s + n) & 0xFFFFFFFF


def main(exe, res):
    d = bytearray(open(exe, 'rb').read())
    pe = struct.unpack_from('<I', d, 0x3C)[0]
    assert d[pe:pe + 4] == b'PE\0\0', 'not a PE file'
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    optsz = struct.unpack_from('<H', d, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', d, opt)[0]
    assert magic in (0x10B, 0x20B), 'not a PE32 / PE32+ exe'
    sect_align, file_align = struct.unpack_from('<II', d, opt + 32)
    dd = opt + (112 if magic == 0x20B else 96)   # data directories (PE32+ / PE32)
    secs = []
    for i in range(nsec):
        o = opt + optsz + 40 * i
        name = bytes(d[o:o + 8]).rstrip(b'\0').decode()
        vs, va, rs, rp = struct.unpack_from('<IIII', d, o + 8)
        secs.append({'o': o, 'name': name, 'vs': vs, 'va': va, 'rs': rs, 'rp': rp})
    rsrc_rva, rsrc_size = struct.unpack_from('<II', d, dd + 8 * 2)
    idx = next(i for i, s in enumerate(secs) if s['va'] == rsrc_rva)
    rs_sec = secs[idx]
    later = secs[idx + 1:]
    end_of_sections = max(s['rp'] + s['rs'] for s in secs)
    overlay = bytes(d[end_of_sections:])
    sec_dir = struct.unpack_from('<II', d, dd + 8 * 4)
    assert sec_dir == (0, 0), 'signed exe - remove the signature first'

    def rva_to_off(rva):
        for s in secs:
            if s['va'] <= rva < s['va'] + max(s['vs'], s['rs']):
                return rva - s['va'] + s['rp']
        raise ValueError(hex(rva))
    tree = parse_tree(d, rs_sec['rp'], rs_sec['va'], rva_to_off)
    new = read_res(res)
    replace = {t for t, _, _, _ in new}
    tree = [(k, v) for k, v in tree if k not in replace]
    by_type = {}
    for t, n, l, data in new:
        by_type.setdefault(t, {}).setdefault(n, []).append((l, (data, 0)))
    for t, names in by_type.items():
        tree.append((t, [(n, langs) for n, langs in names.items()]))
    blob = build_tree(tree, rs_sec['va'])
    new_vs = len(blob)
    new_rs = align(new_vs, file_align)
    # move the sections after .rsrc (normally just .reloc) if it grew past them
    next_va = later[0]['va'] if later else None
    va_shift = 0
    if next_va is not None and rs_sec['va'] + new_vs > next_va:
        va_shift = align(rs_sec['va'] + new_vs, sect_align) - next_va
    rp_shift = new_rs - rs_sec['rs']
    out = bytearray(d[:rs_sec['rp']]) + blob + b'\0' * (new_rs - new_vs)
    for s in later:
        out += d[s['rp']:s['rp'] + s['rs']]
    out += overlay
    struct.pack_into('<II', out, rs_sec['o'] + 8, new_vs, rs_sec['va'])
    struct.pack_into('<II', out, rs_sec['o'] + 16, new_rs, rs_sec['rp'])
    for s in later:
        struct.pack_into('<I', out, s['o'] + 12, s['va'] + va_shift)
        struct.pack_into('<I', out, s['o'] + 20, s['rp'] + rp_shift)
        for i in range(16):
            r = struct.unpack_from('<I', d, dd + 8 * i)[0]
            if r and s['va'] <= r < s['va'] + max(s['vs'], 1):
                struct.pack_into('<I', out, dd + 8 * i, r + va_shift)
    struct.pack_into('<II', out, dd + 8 * 2, rs_sec['va'], new_vs)
    last = max(secs, key=lambda s: s['va'])
    last_va = last['va'] + (va_shift if last in later else 0)
    last_vs = new_vs if last is rs_sec else last['vs']
    struct.pack_into('<I', out, opt + 56, align(last_va + last_vs, sect_align))   # SizeOfImage
    init = struct.unpack_from('<I', out, opt + 8)[0]
    struct.pack_into('<I', out, opt + 8, init + (new_rs - rs_sec['rs']))          # SizeOfInitializedData
    struct.pack_into('<I', out, opt + 64, pe_checksum(bytes(out), opt + 64))      # CheckSum
    open(exe, 'wb').write(out)
    print('%s: resources %d -> %d bytes, later sections moved by %#x' % (exe, rsrc_size, new_vs, va_shift))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
