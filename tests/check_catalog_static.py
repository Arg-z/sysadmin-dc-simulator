#!/usr/bin/env python3
"""Static checker for HardwareCatalog.luau.

The catalog module uses Color3 (Roblox global) so it cannot run in the luau CLI.
This script parses the source text and asserts, per addItem block:
  - required fields present: id, name, category, price, uSize, description, specs, visualColor
  - price > 0
  - item ids unique
  - ids and key prices/specs match the CONTRACT (Section 2, HardwareCatalog)
Run: python3 tests/check_catalog_static.py  (exit non-zero on failure)
"""

import re
import sys

SRC = "/data/workspace/netsim/src/ReplicatedStorage/Shared/HardwareCatalog.luau"

# (id, category, price, required spec keys) from CONTRACT.md HardwareCatalog section.
# specs values checked where the contract pins them.
CONTRACT_EXPECT = {
    "rack_12u": ("Rack", 400, {"maxU": 12, "maxPowerWatts": 3000}),
    "rack_24u": ("Rack", 950, {"maxU": 24, "maxPowerWatts": 6000}),
    "switch_8p": ("Network", 250, {"ports": 8}),
    "switch_24p": ("Network", 650, {"ports": 24, "sfpPorts": 2}),
    "router_edge": ("Network", 500, {"ports": 4, "wanPorts": 2}),
    "bm_starter": ("Server", 800, {"cpu": 8, "ram": 16, "disk": 500, "powerWatts": 450, "ports": 1}),
    "bm_enterprise": ("Server", 2200, {"cpu": 32, "ram": 128, "disk": 2000, "powerWatts": 750, "ports": 2}),
    "chassis_1u": ("Component", 150, {"ports": 1}),
    "chassis_2u": ("Component", 220, {"ports": 1}),
    "mobo_single": ("Component", 200, {"sockets": 1, "ramSlots": 2, "storageBays": 2}),
    "mobo_dual": ("Component", 450, {"sockets": 2, "ramSlots": 4, "storageBays": 3}),
    "cpu_xeon8": ("Component", 300, {"cores": 8}),
    "cpu_epyc32": ("Component", 850, {"cores": 32}),
    "ram_32g": ("Component", 120, {"ramGb": 32}),
    "ram_128g": ("Component", 420, {"ramGb": 128}),
    "nvme_1tb": ("Component", 140, {"storageGb": 1000}),
    "psu_redundant": ("Component", 180, {"powerWatts": 750}),
    "replacement_hdd": ("Component", 90, {"storageGb": 500}),
    "cable_lan_blue": ("Cable", 15, {}),
    "cable_wan_yellow": ("Cable", 15, {}),
    "cable_mgmt_red": ("Cable", 15, {}),
}

REQUIRED_FIELDS = ["id", "name", "category", "price", "uSize", "description", "specs", "visualColor"]

passed = 0
failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {name}")
    else:
        failed += 1
        print(f"FAIL  {name}  {detail}")


def parse_blocks(text):
    """Split source into addItem({...}) blocks."""
    blocks = []
    idx = 0
    while True:
        start = text.find("addItem({", idx)
        if start < 0:
            break
        # find matching close paren: track brace depth starting at the '{' after 'addItem('
        open_brace = text.index("{", start)
        depth = 0
        end = None
        in_str = None
        i = open_brace
        while i < len(text):
            c = text[i]
            if in_str:
                if c == in_str and text[i - 1] != "\\":
                    in_str = None
            elif c in "\"'":
                in_str = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        if end is None:
            break
        blocks.append(text[open_brace + 1 : end])
        idx = end
    return blocks


def get_field(block, key):
    m = re.search(rf"\b{key}\s*=\s*", block)
    return m is not None


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        text = f.read()

    blocks = parse_blocks(text)
    check("addItem block count == 21 (contract item list)", len(blocks) == len(CONTRACT_EXPECT),
          f"found {len(blocks)} expected {len(CONTRACT_EXPECT)}")

    ids = []
    seen_dup = False
    parsed = {}
    for i, b in enumerate(blocks):
        m = re.search(r'\bid\s*=\s*"([^"]+)"', b)
        item_id = m.group(1) if m else f"<block {i} missing id>"
        if m:
            ids.append(item_id)
        if item_id in parsed:
            seen_dup = True
        parsed[item_id] = b

    check("item ids unique", not seen_dup, f"ids={ids}")

    for item_id, b in parsed.items():
        for fld in REQUIRED_FIELDS:
            check(f"{item_id}: has {fld}", get_field(b, fld))
        pm = re.search(r"\bprice\s*=\s*(\d+)", b)
        check(f"{item_id}: price parses", pm is not None)
        if pm:
            price = int(pm.group(1))
            check(f"{item_id}: price > 0", price > 0, f"price={price}")

    # Contract cross-check
    check("catalog id set == contract id set", set(parsed.keys()) == set(CONTRACT_EXPECT.keys()),
          f"missing={set(CONTRACT_EXPECT.keys()) - set(parsed.keys())} extra={set(parsed.keys()) - set(CONTRACT_EXPECT.keys())}")

    for item_id, (cat, price, specs) in CONTRACT_EXPECT.items():
        b = parsed.get(item_id)
        if b is None:
            continue
        cm = re.search(r'\bcategory\s*=\s*"([^"]+)"', b)
        check(f"{item_id}: category == {cat}", cm is not None and cm.group(1) == cat,
              f"got {cm.group(1) if cm else None}")
        pm = re.search(r"\bprice\s*=\s*(\d+)", b)
        if pm:
            check(f"{item_id}: price == {price}", int(pm.group(1)) == price, f"got {pm.group(1)}")
        for k, v in specs.items():
            sm = re.search(rf"\b{k}\s*=\s*([\d.]+)", b)
            check(f"{item_id}: spec {k} == {v}", sm is not None and float(sm.group(1)) == v,
                  f"got {sm.group(1) if sm else None}")

    # API surface required by contract
    for api in ["function Catalog.Get(", "function Catalog.IsPlaceable(", "function Catalog.ListByCategory(", "Catalog.StoreCategories"]:
        check(f"catalog API present: {api}", api in text)
    check("IsPlaceable covers Rack/Network/Server", all(c in text for c in ['"Rack"', '"Network"', '"Server"']))

    print()
    print(f"SUMMARY: {passed} passed, {failed} failed, {passed + failed} total")
    if failed > 0:
        print("CATALOG STATIC CHECK FAILED")
        sys.exit(1)
    print("CATALOG STATIC CHECK PASSED")


if __name__ == "__main__":
    main()
