"""Read and write Total War: ATTILA .pack files (PFH4) and key/value db tables.

The formats here were checked against the game's own data.pack, not taken from memory:
reading the index lands exactly on the file size, and re-writing the vanilla _kv_rules and
cai_variables tables reproduces them byte for byte (`python3 siegemod.py selftest`).
"""
import struct
from pathlib import Path

GAME_DATA = Path.home() / "Library/Application Support/Steam/steamapps/common/Total War Attila/TotalWarAttilaData/data"
LOCAL_MODS = Path.home() / "Library/Application Support/Feral Interactive/Total War ATTILA/VFS/Local/local_mods"

PACK_TYPE_MOD = 3
GUID_MARKER = b"\xfd\xfe\xfc\xff"
VERSION_MARKER = b"\xfc\xfd\xfe\xff"


# ---------- packs ----------

def read_index(path):
    """Return (pack_type, [(name, offset, size)], end_offset) for a PFH4 pack."""
    with open(path, "rb") as f:
        magic, ptype, _pic, pis, count, fis, _ts = struct.unpack("<4s6I", f.read(28))
        if magic != b"PFH4":
            raise ValueError(f"{path}: not a PFH4 pack ({magic!r})")
        f.seek(28 + pis)
        buf = f.read(fis)
    flags = ptype & 0xFFFFFF00
    entries, i, off = [], 0, 28 + pis + fis
    for _ in range(count):
        size = struct.unpack_from("<I", buf, i)[0]
        i += 4
        if flags & 0x40:  # per-file timestamps
            i += 4
        if flags & 0x80:  # per-file compression byte
            i += 1
        j = buf.index(b"\0", i)
        entries.append((buf[i:j].decode("latin1"), off, size))
        i = j + 1
        off += size
    return ptype, entries, off


def read_file(path, entry):
    _name, off, size = entry
    with open(path, "rb") as f:
        f.seek(off)
        return f.read(size)


def write_pack(path, files, timestamp):
    """Write a mod pack. files: [(name with backslashes, bytes)]."""
    index = b"".join(struct.pack("<I", len(data)) + name.encode("latin1") + b"\0" for name, data in files)
    header = struct.pack("<4s6I", b"PFH4", PACK_TYPE_MOD, 0, 0, len(files), len(index), timestamp)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(header + index + b"".join(data for _name, data in files))


def vanilla_tables(table):
    """Every vanilla file of one db table across the game's packs: [(pack_path, entry)]."""
    found = []
    for pack in sorted(GAME_DATA.glob("*.pack")):
        _t, entries, _end = read_index(pack)
        found += [(pack, e) for e in entries if e[0].split("\\")[:2] == ["db", table]]
    return found


# ---------- key/value tables ----------

def _read_str(data, i):
    n = struct.unpack_from("<H", data, i)[0]
    return data[i + 2:i + 2 + n].decode("latin1"), i + 2 + n


def _str(s):
    b = s.encode("latin1")
    return struct.pack("<H", len(b)) + b


def parse_kv_table(data):
    """Parse a table whose rows are (key, float) or (key, float, description).

    The layout is accepted only if it consumes the bytes exactly, so a wrong guess fails loudly.
    """
    i, guid, version = 0, None, None
    if data[:4] == GUID_MARKER:
        n = struct.unpack_from("<H", data, 4)[0]
        guid = data[6:6 + 2 * n].decode("utf-16-le")
        i = 6 + 2 * n
    if data[i:i + 4] == VERSION_MARKER:
        version = struct.unpack_from("<I", data, i + 4)[0]
        i += 8
    flag = data[i]
    count = struct.unpack_from("<I", data, i + 1)[0]
    start = i + 5
    for has_desc in (False, True):
        rows, i = [], start
        try:
            for _ in range(count):
                key, i = _read_str(data, i)
                val = struct.unpack_from("<f", data, i)[0]
                i += 4
                desc = None
                if has_desc:
                    desc, i = _read_str(data, i)
                rows.append((key, val, desc))
        except struct.error:
            continue
        if i == len(data):
            return {"guid": guid, "version": version, "flag": flag, "has_desc": has_desc, "rows": rows}
    raise ValueError("not a key/value table: no layout consumed the bytes exactly")


def write_kv_table(t):
    out = b""
    if t["guid"] is not None:
        out += GUID_MARKER + struct.pack("<H", len(t["guid"])) + t["guid"].encode("utf-16-le")
    if t["version"] is not None:
        out += VERSION_MARKER + struct.pack("<I", t["version"])
    out += bytes([t["flag"]]) + struct.pack("<I", len(t["rows"]))
    for key, val, desc in t["rows"]:
        out += _str(key) + struct.pack("<f", val)
        if t["has_desc"]:
            out += _str(desc)
    return out


def f32(x):
    """The value as the game stores it (32-bit float)."""
    return struct.unpack("<f", struct.pack("<f", x))[0]
