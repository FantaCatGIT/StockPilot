#!/usr/bin/env python3
"""Makes a compressed macOS .dmg from a folder - no Mac needed.

usage: make-dmg.py <folder> <out.dmg> [volume name]

The disk inside is ISO 9660 with Rock Ridge (macOS mounts it read-only like any DMG, with real file names,
permissions and symlinks). It is wrapped in Apple's UDIF format with XZ/LZMA-compressed 1 MiB chunks
(the same as `hdiutil convert -format ULMO`, macOS 10.15+). An "Applications" link is added for drag-installing.
"""
import os, sys, stat, struct, time, zlib, lzma, uuid, plistlib

BS = 2048  # ISO block size


def both16(v): return struct.pack('<H', v) + struct.pack('>H', v)
def both32(v): return struct.pack('<I', v) + struct.pack('>I', v)


def dr_date(t):
    g = time.gmtime(t)
    return bytes([g.tm_year - 1900, g.tm_mon, g.tm_mday, g.tm_hour, g.tm_min, g.tm_sec, 0])


def vd_date(t):
    g = time.gmtime(t)
    return time.strftime('%Y%m%d%H%M%S', g).encode() + b'00' + b'\0'


class Node:
    def __init__(self, name, path, kind, mode, target=None, size=0, parent=None):
        self.name, self.path, self.kind, self.mode, self.target, self.size, self.parent = name, path, kind, mode, target, size, parent
        self.children, self.iso_name, self.lba, self.dsize, self.num = [], b'', 0, 0, 0


def scan(path, name='', parent=None):
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return Node(name, path, 'link', 0o120777, target=os.readlink(path), parent=parent)
    if stat.S_ISDIR(st.st_mode):
        n = Node(name, path, 'dir', 0o40755, parent=parent)
        for c in sorted(os.listdir(path)):
            n.children.append(scan(os.path.join(path, c), c, n))
        return n
    return Node(name, path, 'file', 0o100755 if st.st_mode & 0o111 else 0o100644, size=st.st_size, parent=parent)


def susp(node, is_dot=False, root_dot=False):
    out = b''
    if root_dot:
        out += b'SP\x07\x01\xbe\xef\x00'
    mode = node.mode
    nlink = 2 if node.kind == 'dir' else 1
    out += b'PX\x24\x01' + both32(mode) + both32(nlink) + both32(0) + both32(0)
    if root_dot:
        i, d, s = b'RRIP_1991A', b'ROCK RIDGE', b'ROCK RIDGE'
        out += b'ER' + bytes([8 + len(i) + len(d) + len(s), 1, len(i), len(d), len(s), 1]) + i + d + s
    if not is_dot:
        nm = node.name.encode('utf-8')
        assert len(nm) <= 250
        out += b'NM' + bytes([5 + len(nm), 1, 0]) + nm
        if node.kind == 'link':
            comps = b''
            t = node.target
            if t.startswith('/'):
                comps += bytes([0x08, 0]); t = t.lstrip('/')
            for c in [c for c in t.split('/') if c != '']:
                if c == '.': comps += bytes([0x02, 0])
                elif c == '..': comps += bytes([0x04, 0])
                else: cb = c.encode('utf-8'); comps += bytes([0, len(cb)]) + cb
            out += b'SL' + bytes([5 + len(comps), 1, 0]) + comps
    return out


def drec(lba, size, flags, fid, su, t):
    ln = 33 + len(fid) + (1 if len(fid) % 2 == 0 else 0)
    rec = bytes([0, 0]) + both32(lba) + both32(size) + dr_date(t) + bytes([flags, 0, 0]) + both16(1) + bytes([len(fid)]) + fid
    if len(fid) % 2 == 0:
        rec += b'\0'
    rec += su
    if len(rec) % 2:
        rec += b'\0'
    assert len(rec) <= 255, 'directory record too long'
    return bytes([len(rec)]) + rec[1:]


def build_iso(root_dir, volname):
    t = time.time()
    root = scan(root_dir)
    root.children.append(Node('Applications', None, 'link', 0o120777, target='/Applications', parent=root))
    root.children.sort(key=lambda n: n.name)
    # BFS order of directories (path table order) + ISO names (sorted => sequential numbers keep order)
    dirs, q = [], [root]
    while q:
        d = q.pop(0); dirs.append(d)
        for i, c in enumerate(d.children):
            c.iso_name = (b'D%07d' % i) if c.kind == 'dir' else (b'F%07d.;1' % i)
        q += [c for c in d.children if c.kind == 'dir']
    for i, d in enumerate(dirs):
        d.num = i + 1
    # path tables
    def ptable(be):
        out = b''
        for d in dirs:
            ident = b'\0' if d is root else d.iso_name
            p = d.parent.num if d.parent else 1
            out += bytes([len(ident), 0]) + (struct.pack('>I', d.lba) if be else struct.pack('<I', d.lba)) + (struct.pack('>H', p) if be else struct.pack('<H', p)) + ident
            if len(ident) % 2: out += b'\0'
        return out
    pt_size = len(ptable(False))
    pt_blocks = (pt_size + BS - 1) // BS
    lba = 18
    l_pt, m_pt = lba, lba + pt_blocks
    lba += 2 * pt_blocks

    def dir_records(d):
        recs = [drec(d.lba, d.dsize, 2, b'\0', susp(d, True, d is root), t),
                drec((d.parent or d).lba, (d.parent or d).dsize, 2, b'\1', susp(d.parent or d, True), t)]
        for c in d.children:
            if c.kind == 'dir': recs.append(drec(c.lba, c.dsize, 2, c.iso_name, susp(c), t))
            elif c.kind == 'link': recs.append(drec(0, 0, 0, c.iso_name, susp(c), t))
            else: recs.append(drec(c.lba, c.size, 0, c.iso_name, susp(c), t))
        return recs

    def pack(recs):
        blocks, cur = [], b''
        for r in recs:
            if len(cur) + len(r) > BS: blocks.append(cur.ljust(BS, b'\0')); cur = b''
            cur += r
        blocks.append(cur.ljust(BS, b'\0'))
        return b''.join(blocks)
    # directory sizes don't depend on LBAs - lay out directories, then files
    for d in dirs:
        d.dsize = len(pack(dir_records(d)))
    for d in dirs:
        d.lba = lba; lba += d.dsize // BS
    files = []
    for d in dirs:
        for c in d.children:
            if c.kind == 'file':
                c.lba = lba if c.size else 0
                lba += (c.size + BS - 1) // BS
                files.append(c)
    total = lba
    # write
    img = bytearray(BS * 16)
    root_rec = drec(root.lba, root.dsize, 2, b'\0', b'', t)
    pvd = bytearray(BS)
    pvd[0:7] = b'\x01CD001\x01'
    pvd[8:40] = b'MACOS'.ljust(32)
    pvd[40:72] = volname.upper().encode()[:32].ljust(32)
    pvd[80:88] = both32(total)
    pvd[120:124] = both16(1); pvd[124:128] = both16(1); pvd[128:132] = both16(BS)
    pvd[132:140] = both32(pt_size)
    pvd[140:144] = struct.pack('<I', l_pt); pvd[148:152] = struct.pack('>I', m_pt)
    pvd[156:156 + 34] = root_rec
    pvd[190:318] = b''.ljust(128)
    pvd[318:446] = b'STOCKPILOT'.ljust(128)
    pvd[446:574] = b''.ljust(128)
    pvd[574:702] = b'STOCKPILOT MAKE-DMG'.ljust(128)
    pvd[702:813] = b''.ljust(111)
    pvd[813:830] = vd_date(t); pvd[830:847] = vd_date(t); pvd[847:864] = b'0' * 16 + b'\0'; pvd[864:881] = b'0' * 16 + b'\0'
    pvd[881] = 1
    img += pvd
    term = bytearray(BS); term[0:7] = b'\xffCD001\x01'
    img += term
    img += ptable(False).ljust(pt_blocks * BS, b'\0')
    img += ptable(True).ljust(pt_blocks * BS, b'\0')
    for d in dirs:
        assert len(img) == d.lba * BS
        img += pack(dir_records(d))
    return bytes(img), files, total


def write_dmg(root_dir, out, volname):
    head, files, total_blocks = build_iso(root_dir, volname)
    sectors = total_blocks * BS // 512
    CH = 2048  # 512-byte sectors per chunk (1 MiB)

    def stream():  # yields the ISO in 1 MiB pieces
        buf = bytearray(head)
        for f in files:
            pad = f.lba * BS - (len(head) if False else 0)
            with open(f.path, 'rb') as fh:
                while True:
                    b = fh.read(1 << 20)
                    if not b: break
                    buf += b
                    while len(buf) >= CH * 512:
                        yield bytes(buf[:CH * 512]); del buf[:CH * 512]
            r = f.size % BS
            if r: buf += b'\0' * (BS - r)
            while len(buf) >= CH * 512:
                yield bytes(buf[:CH * 512]); del buf[:CH * 512]
        if buf: yield bytes(buf)
    # sanity: files are laid out back to back right after the directories
    expect = len(head) // BS
    for f in files:
        if f.size:
            assert f.lba == expect, 'layout'
            expect += (f.size + BS - 1) // BS
    chunks, data_crc, raw_crc, off, sec = [], 0, 0, 0, 0
    with open(out, 'wb') as o:
        for piece in stream():
            raw_crc = zlib.crc32(piece, raw_crc)
            c = lzma.compress(piece, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, preset=9 | lzma.PRESET_EXTREME)
            o.write(c); data_crc = zlib.crc32(c, data_crc)
            n = len(piece) // 512
            chunks.append((0x80000008, sec, n, off, len(c)))
            sec += n; off += len(c)
        assert sec == sectors, (sec, sectors)
        mish = b'mish' + struct.pack('>IQQQII', 1, 0, sectors, 0, CH + 8, 0) + b'\0' * 24
        mish += struct.pack('>II', 2, 32) + struct.pack('>I', raw_crc & 0xffffffff) + b'\0' * 124
        mish += struct.pack('>I', len(chunks) + 1)
        for typ, s, n, co, cl in chunks:
            mish += struct.pack('>IIQQQQ', typ, 0, s, n, co, cl)
        mish += struct.pack('>IIQQQQ', 0xFFFFFFFF, 0, sectors, 0, off, 0)
        name = 'whole disk (ISO9660 : 0)'
        xml = plistlib.dumps({'resource-fork': {'blkx': [{'Attributes': '0x0050', 'CFName': name, 'Data': mish, 'ID': '0', 'Name': name}]}})
        xml_off = off
        o.write(xml)
        master = zlib.crc32(struct.pack('>I', raw_crc & 0xffffffff)) & 0xffffffff
        koly = b'koly' + struct.pack('>III', 4, 512, 1) + struct.pack('>QQQQQ', 0, 0, off, 0, 0) + struct.pack('>II', 1, 1) + uuid.uuid4().bytes
        koly += struct.pack('>II', 2, 32) + struct.pack('>I', data_crc & 0xffffffff) + b'\0' * 124
        koly += struct.pack('>QQ', xml_off, len(xml)) + b'\0' * 120
        koly += struct.pack('>II', 2, 32) + struct.pack('>I', master) + b'\0' * 124
        koly += struct.pack('>IQ', 1, sectors) + b'\0' * 12
        assert len(koly) == 512, len(koly)
        o.write(koly)
    print('%s: %d MB disk -> %d MB dmg' % (out, sectors * 512 >> 20, os.path.getsize(out) >> 20))


if __name__ == '__main__':
    write_dmg(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'StockPilot')
