"""Build and check Attila siege-AI mod packs from a JSON spec in mods/.

  python3 siegemod.py selftest            prove the table reader/writer is byte-exact on vanilla data
  python3 siegemod.py build mods/X.json   build dist/<pack> with only the rows the spec changes
  python3 siegemod.py check mods/X.json   file check of dist/<pack>; exit 1 on any FAIL
"""
import json
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

import packlib as pl

ROOT = Path(__file__).parent


def vanilla_file(name):
    """Bytes of one file from the game's data.pack (pack paths are case-insensitive in game)."""
    pack = pl.GAME_DATA / "data.pack"
    _t, entries, _end = pl.read_index(pack)
    for entry in entries:
        if entry[0].lower() == name.lower():
            return pl.read_file(pack, entry)
    raise SystemExit(f"FAIL: {name} is not in data.pack")


def expected_files(spec):
    """{pack path: bytes} for every non-table file the spec puts in the pack."""
    out = {}
    for name, src in spec.get("patch_vanilla", {}).items():
        out[name] = vanilla_file(name) + (ROOT / src).read_bytes()
    for name, src in spec.get("files", {}).items():
        out[name] = (ROOT / src).read_bytes()
    return out


def lua_syntax_error(data):
    """None if LuaJIT parses the script, else its error message."""
    r = subprocess.run(["luajit", "-e", "assert(loadstring(io.read('*a')))"], input=data, capture_output=True)
    return None if r.returncode == 0 else r.stderr.decode(errors="replace").strip().splitlines()[0]


def load_spec(path):
    spec = json.loads(Path(path).read_text())
    spec["_pack_path"] = ROOT / "dist" / spec["pack"]
    return spec


def vanilla_kv(table):
    """Merged vanilla rows of one table, plus its layout and every vanilla file name."""
    files = pl.vanilla_tables(table)
    if not files:
        raise SystemExit(f"FAIL: table {table} does not exist in the game")
    rows, layout, names = {}, None, set()
    for pack, entry in files:
        t = pl.parse_kv_table(pl.read_file(pack, entry))
        layout = layout or t
        names.add(entry[0].split("\\")[2])
        for key, val, desc in t["rows"]:
            rows.setdefault(key, (val, desc))
    return rows, layout, names


def selftest():
    ok = True
    for table in ("_kv_rules_tables", "cai_variables_tables", "campaign_variables_tables"):
        for pack, entry in pl.vanilla_tables(table):
            data = pl.read_file(pack, entry)
            same = pl.write_kv_table(pl.parse_kv_table(data)) == data
            ok &= same
            print(f"{'PASS' if same else 'FAIL'}  round-trip {entry[0]} ({len(data)} bytes)")
    _t, _entries, end = pl.read_index(pl.GAME_DATA / "data.pack")
    size = (pl.GAME_DATA / "data.pack").stat().st_size
    print(f"{'PASS' if end == size else 'FAIL'}  data.pack index ends at {end} = file size {size}")
    return ok and end == size


def build(spec):
    files = []
    if spec.get("changes"):
        print(f"{'table':24} {'key':55} {'vanilla':>10} {'new':>10}")
    for table, change in spec.get("changes", {}).items():
        vrows, layout, _names = vanilla_kv(table)
        rows = []
        for key, new in change["rows"].items():
            if key not in vrows:
                raise SystemExit(f"FAIL: {key} is not a row of {table} (typo?)")
            old, desc = vrows[key]
            rows.append((key, float(new), desc))
            print(f"{table:24} {key:55} {old:>10g} {pl.f32(new):>10g}")
        guid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"attila-siege-ai/{spec['pack']}/{table}"))
        t = {"guid": guid, "version": layout["version"], "flag": layout["flag"],
             "has_desc": layout["has_desc"], "rows": rows}
        files.append((f"db\\{table}\\{change['file']}", pl.write_kv_table(t)))
    for name, data in expected_files(spec).items():
        files.append((name, data))
        print(f"file  {name}  ({len(data)} bytes)")
    pl.write_pack(spec["_pack_path"], files, int(time.time()))
    print(f"built {spec['_pack_path']} ({spec['_pack_path'].stat().st_size} bytes)")


def check(spec):
    path = spec["_pack_path"]
    results = []

    def rec(ok, what):
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {what}")

    ptype, entries, end = pl.read_index(path)
    rec(ptype == pl.PACK_TYPE_MOD, f"pack type is mod (3): got {ptype}")
    rec(end == path.stat().st_size, f"index ends exactly at file size ({end} / {path.stat().st_size})")
    others = expected_files(spec)
    expected = {f"db\\{t}\\{c['file']}" for t, c in spec.get("changes", {}).items()} | set(others)
    rec({e[0] for e in entries} == expected, f"pack holds exactly the spec's files: {sorted(expected)}")
    have_luajit = shutil.which("luajit") is not None
    for entry in entries:
        if entry[0] in others:
            data = pl.read_file(path, entry)
            how = "the game's file + our appended hook" if entry[0] in spec.get("patch_vanilla", {}) else "our source file"
            rec(data == others[entry[0]], f"{entry[0]}: identical to {how}")
            if entry[0].endswith(".lua"):
                if have_luajit:
                    err = lua_syntax_error(data)
                    rec(err is None, f"{entry[0]}: Lua syntax " + (f"ERROR -- {err}" if err else "OK"))
                else:
                    print(f"NOT RUN  {entry[0]}: Lua syntax check (luajit not installed)")
            continue
        _db, table, fname = entry[0].split("\\")
        change = spec["changes"][table]
        vrows, layout, vnames = vanilla_kv(table)
        rec(fname not in vnames, f"{fname}: own file name, does not replace the game's whole table {sorted(vnames)}")
        if fname[-1:].isdigit():
            rec(False, f"{fname}: name ends in a digit (known to glitch)")
        t = pl.parse_kv_table(pl.read_file(path, entry))
        rec((t["version"], t["has_desc"]) == (layout["version"], layout["has_desc"]),
            f"{table}: same layout as vanilla (version {t['version']}, description column {t['has_desc']})")
        keys = [r[0] for r in t["rows"]]
        rec(len(keys) == len(set(keys)), f"{table}: no duplicate keys")
        rec(set(keys) == set(change["rows"]), f"{table}: rows are exactly the spec's {len(change['rows'])} keys")
        for key, val, _desc in t["rows"]:
            want = pl.f32(change["rows"].get(key, float("nan")))
            rec(key in vrows, f"{key}: exists in the game (a typo would silently do nothing)")
            rec(val == want, f"{key}: value {val:g} == spec {want:g}")
            rec(key in vrows and val != vrows[key][0], f"{key}: differs from vanilla {vrows.get(key, (None,))[0]}")
    print(f"\n{sum(results)}/{len(results)} checks passed")
    return all(results)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    if cmd in ("build", "check") and len(sys.argv) == 3:
        spec = load_spec(sys.argv[2])
        if cmd == "build":
            build(spec)
        else:
            sys.exit(0 if check(spec) else 1)
    else:
        sys.exit(__doc__)
