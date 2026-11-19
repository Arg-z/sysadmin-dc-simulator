#!/usr/bin/env python3
"""Build NetworkSimulator.rbxlx for the SysAdmin & Cloud DC Simulator (Fase 1).

Reads all 21 .luau sources under /data/workspace/netsim/src, guards them
(no forbidden markers, valid UTF-8, ASCII policy with warnings), XML-escapes
each source into a ProtectedString and emits a valid Roblox XML place file:
  <roblox version="4"> with unique referents RBX0..N

Tree emitted:
  Workspace (Baseplate Part + SpawnLocation)
  Lighting (empty)
  ReplicatedStorage > Folder "Shared" > 5 ModuleScripts
  ServerScriptService > Script MainServer + Folders Bootstrap/Core/Physical/Gameplay
  StarterPlayer > StarterPlayerScripts > 5 LocalScripts
  StarterGui, Players

Validations after write:
  V1 xml.etree parses the output (well-formed XML)
  V2 all Item referent attributes unique
  V3 every ProtectedString unescaped == source text (byte-equal)
  V4 all expected scripts/folders present with correct classes; Disabled=false everywhere
Run: python3 build/build_place.py
"""

import os
import re
import sys
from xml.sax.saxutils import escape
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "build", "NetworkSimulator.rbxlx")

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


# (class, instance name, source file)
SHARED_MODULES = [
    ("ModuleScript", "NetworkTypes", "ReplicatedStorage/Shared/NetworkTypes.luau"),
    ("ModuleScript", "NetworkUtils", "ReplicatedStorage/Shared/NetworkUtils.luau"),
    ("ModuleScript", "HardwareCatalog", "ReplicatedStorage/Shared/HardwareCatalog.luau"),
    ("ModuleScript", "PlotConstants", "ReplicatedStorage/Shared/PlotConstants.luau"),
    ("ModuleScript", "ModelFactory", "ReplicatedStorage/Shared/ModelFactory.luau"),
]
SSS_TREE = [
    ("Script", "MainServer", "ServerScriptService/MainServer.server.luau", None),
    ("Folder", "Bootstrap", None, [
        ("ModuleScript", "WorldAndAssetBuilder", "ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau"),
    ]),
    ("Folder", "Core", None, [
        ("ModuleScript", "SessionManager", "ServerScriptService/Core/SessionManager.luau"),
        ("ModuleScript", "NetworkGraph", "ServerScriptService/Core/NetworkGraph.luau"),
        ("ModuleScript", "CommandExecutor", "ServerScriptService/Core/CommandExecutor.luau"),
    ]),
    ("Folder", "Physical", None, [
        ("ModuleScript", "RackAndCablingSystem", "ServerScriptService/Physical/RackAndCablingSystem.luau"),
        ("ModuleScript", "PlacementSystem", "ServerScriptService/Physical/PlacementSystem.luau"),
        ("ModuleScript", "WorkbenchBuilderSystem", "ServerScriptService/Physical/WorkbenchBuilderSystem.luau"),
    ]),
    ("Folder", "Gameplay", None, [
        ("ModuleScript", "ShiftAndEconomyManager", "ServerScriptService/Gameplay/ShiftAndEconomyManager.luau"),
        ("ModuleScript", "ContractAndIncidentManager", "ServerScriptService/Gameplay/ContractAndIncidentManager.luau"),
        ("ModuleScript", "DataPersistenceManager", "ServerScriptService/Gameplay/DataPersistenceManager.luau"),
    ]),
]
CLIENT_SCRIPTS = [
    ("LocalScript", "TerminalClient", "StarterPlayer/StarterPlayerScripts/TerminalClient.client.luau"),
    ("LocalScript", "NOCMonitorClient", "StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau"),
    ("LocalScript", "CatalogAndBuilderClient", "StarterPlayer/StarterPlayerScripts/CatalogAndBuilderClient.client.luau"),
    ("LocalScript", "HudClient", "StarterPlayer/StarterPlayerScripts/HudClient.client.luau"),
    ("LocalScript", "AudioAndEffectsClient", "StarterPlayer/StarterPlayerScripts/AudioAndEffectsClient.client.luau"),
]

FORBIDDEN = re.compile(r"TODO|FIXME|STUB|XXX|HACK", re.I)


def load_source(rel):
    path = os.path.join(SRC, rel)
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except UnicodeDecodeError as e:
        print(f"FAIL  source {rel}: invalid UTF-8 ({e})")
        sys.exit(1)
    bad_ctrl = [f"0x{ord(c):02x}@{i}" for i, c in enumerate(text) if ord(c) < 0x20 and c not in "\t\n\r"]
    if bad_ctrl:
        print(f"FAIL  source {rel}: control characters {bad_ctrl[:5]}")
        sys.exit(1)
    m = FORBIDDEN.search(text)
    if m:
        line = text[: m.start()].count("\n") + 1
        print(f"FAIL  source {rel}: forbidden marker '{m.group(0)}' at line {line}")
        sys.exit(1)
    for i, c in enumerate(text):
        if ord(c) > 0x7E:
            ln = text[: i].count("\n") + 1
            print(f"WARN  non-ASCII in {rel}:{ln} -> U+{ord(c):04X} '{c}' (valid UTF-8, allowed)")
    return text


def color3uint8(r, g, b):
    return (0xFF << 24) | (r << 16) | (g << 8) | b


def cframe_prop(name, x, y, z):
    return (
        f'<CoordinateFrame name="{name}">'
        f"<X>{x}</X><Y>{y}</Y><Z>{z}</Z>"
        "<R00>1</R00><R01>0</R01><R02>0</R02>"
        "<R10>0</R10><R11>1</R11><R12>0</R12>"
        "<R20>0</R20><R21>0</R21><R22>1</R22>"
        "</CoordinateFrame>"
    )


def vector3(name, x, y, z):
    return f'<Vector3 name="{name}"><X>{x}</X><Y>{y}</Y><Z>{z}</Z></Vector3>'


class Builder:
    """Serial XML emitter with unique referents and auto Properties blocks."""

    def __init__(self):
        self.count = 0
        self.parts = []
        self.props_open = False

    def ref(self):
        r = f"RBX{self.count}"
        self.count += 1
        return r

    def raw(self, s):
        self.parts.append(s)

    def prop(self, s):
        self.parts.append(s)

    def open_item(self, cls, name=None):
        r = self.ref()
        self.raw(f'<Item class="{cls}" referent="{r}">')
        self.props_open = False
        if name is not None:
            self.raw("<Properties>")
            self.props_open = True
            self.prop(f'<string name="Name">{escape(name)}</string>')
        return r

    def close_props(self):
        if self.props_open:
            self.raw("</Properties>")
            self.props_open = False

    def close_item(self):
        self.close_props()
        self.raw("</Item>")


def emit_script(b, cls, name, source_text):
    b.open_item(cls, name)
    if cls in ("Script", "LocalScript"):
        b.prop('<bool name="Disabled">false</bool>')
    if "]]>" not in source_text:
        b.prop(f'<ProtectedString name="Source"><![CDATA[{source_text}]]></ProtectedString>')
    else:
        b.prop(f'<ProtectedString name="Source">{escape(source_text)}</ProtectedString>')
    b.close_item()


def emit_folder(b, name, children):
    b.open_item("Folder", name)
    b.close_props()
    for fn in children:
        fn(b)
    b.close_item()


def script_node(cls, name, rel, sources):
    return lambda b: emit_script(b, cls, name, sources[rel])


def build_xml(sources):
    b = Builder()
    b.raw(
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" '
        'version="4">'
    )
    b.raw("<External>null</External>")
    b.raw("<External>nil</External>")

    # ---------- Workspace ----------
    b.open_item("Workspace", "Workspace")
    b.close_props()
    b.open_item("Part", "Baseplate")
    b.prop(vector3("size", 512, 20, 512))
    b.prop(cframe_prop("CFrame", 0, -10, 0))
    b.prop('<bool name="Anchored">true</bool>')
    b.prop('<bool name="Locked">true</bool>')
    b.prop('<token name="shape">1</token>')
    b.prop(f'<Color3uint8 name="Color3uint8">{color3uint8(172, 182, 196)}</Color3uint8>')
    b.close_item()
    b.open_item("SpawnLocation", "SpawnLocation")
    b.prop(vector3("size", 12, 1, 12))
    b.prop(cframe_prop("CFrame", 0, 0.5, 40))
    b.prop('<bool name="Anchored">true</bool>')
    b.prop('<token name="shape">1</token>')
    b.prop(f'<Color3uint8 name="Color3uint8">{color3uint8(56, 189, 148)}</Color3uint8>')
    b.close_item()
    b.close_item()

    # ---------- Lighting (Technology=Future set here; non-scriptable at runtime) ----------
    b.open_item("Lighting", "Lighting")
    b.prop('<token name="Technology">4</token>')
    b.close_item()

    # ---------- ReplicatedStorage ----------
    b.open_item("ReplicatedStorage", "ReplicatedStorage")
    b.close_props()
    emit_folder(b, "Shared", [script_node(c, n, s, sources) for c, n, s in SHARED_MODULES])
    b.close_item()

    # ---------- ServerScriptService ----------
    b.open_item("ServerScriptService", "ServerScriptService")
    b.close_props()
    for cls, name, src, kids in SSS_TREE:
        if kids is None:
            emit_script(b, cls, name, sources[src])
        else:
            emit_folder(b, name, [script_node(c, n, s, sources) for c, n, s in kids])
    b.close_item()

    # ---------- StarterPlayer ----------
    b.open_item("StarterPlayer", "StarterPlayer")
    b.close_props()
    b.open_item("StarterPlayerScripts", "StarterPlayerScripts")
    b.close_props()
    for c, n, s in CLIENT_SCRIPTS:
        emit_script(b, c, n, sources[s])
    b.close_item()
    b.close_item()

    # ---------- StarterPack / StarterGui / Players ----------
    b.open_item("StarterPack", "StarterPack")
    b.close_item()
    b.open_item("StarterGui", "StarterGui")
    b.close_item()
    b.open_item("Players", "Players")
    b.close_item()

    b.raw("</roblox>")
    return "\n".join(b.parts)


def all_source_files():
    out = [s for _, _, s in SHARED_MODULES]
    for _, _, s, kids in SSS_TREE:
        if s:
            out.append(s)
        if kids:
            out.extend(s2 for _, _, s2 in kids)
    out.extend(s for _, _, s in CLIENT_SCRIPTS)
    return out


def validate(xml_text, sources):
    try:
        root = ET.fromstring(xml_text)
        check("V1: output parses as well-formed XML", True)
    except ET.ParseError as e:
        check("V1: output parses as well-formed XML", False, str(e))
        return

    refs = [el.get("referent") for el in root.iter("Item")]
    dup = [r for r in refs if refs.count(r) > 1]
    check(f"V2: {len(refs)} Item referents all unique", len(refs) == len(set(refs)), f"dups={dup[:5]}")

    # name -> source file map
    by_name = {}
    for cls, nm, rel in SHARED_MODULES:
        by_name[nm] = rel
    for cls, nm, rel, kids in SSS_TREE:
        if kids is None:
            by_name[nm] = rel
        else:
            for c, n2, r2 in kids:
                by_name[n2] = r2
    for cls, nm, rel in CLIENT_SCRIPTS:
        by_name[nm] = rel

    total = 0
    mismatch = []
    seen = []
    for item in root.iter("Item"):
        props = item.find("Properties")
        name_el = props.find("string[@name='Name']") if props is not None else None
        if name_el is not None:
            seen.append((item.get("class"), name_el.text))
        src_el = props.find("ProtectedString[@name='Source']") if props is not None else None
        if src_el is None:
            continue
        name = name_el.text if name_el is not None else "?"
        total += 1
        rel = by_name.get(name)
        if rel is None:
            mismatch.append(f"{name}: no source mapping")
            continue
        if (src_el.text or "") != sources[rel]:
            mismatch.append(f"{name}: unescaped != source ({len(src_el.text or '')} vs {len(sources[rel])} chars)")
    check(f"V3: {total} ProtectedString sources roundtrip byte-equal to originals", not mismatch,
          "; ".join(mismatch[:5]))

    want = set()
    for cls, nm, _ in SHARED_MODULES:
        want.add((cls, nm))
    for cls, nm, rel, kids in SSS_TREE:
        if kids is None:
            want.add((cls, nm))
        else:
            want.add(("Folder", nm))
            for c, n2, _ in kids:
                want.add((c, n2))
    for cls, nm, _ in CLIENT_SCRIPTS:
        want.add((cls, nm))
    want.add(("StarterPlayerScripts", "StarterPlayerScripts"))
    got = set(seen)
    check(f"V4: all {len(want)} expected scripts/folders present with correct classes",
          want <= got, f"missing={sorted(want - got)} extra={sorted(got - want)}")

    disabled_bad = []
    for item in root.iter("Item"):
        if item.get("class") not in ("Script", "LocalScript"):
            continue
        props = item.find("Properties")
        d = props.find("bool[@name='Disabled']") if props is not None else None
        if d is None or d.text != "false":
            nm = props.find("string[@name='Name']").text if props is not None else "?"
            disabled_bad.append(nm)
    check("V4b: every Script/LocalScript has Disabled=false", not disabled_bad,
          str(disabled_bad))

    bad_c3d = list(root.iter("Coordinate3D"))
    good_cf = list(root.iter("CoordinateFrame"))
    check("V5: uses valid CoordinateFrame tags (zero Coordinate3D)",
          len(bad_c3d) == 0 and len(good_cf) >= 2,
          f"Coordinate3D={len(bad_c3d)} CoordinateFrame={len(good_cf)}")

    lighting_items = [it for it in root.iter("Item") if it.get("class") == "Lighting"]
    tech_ok = False
    if lighting_items:
        p = lighting_items[0].find("Properties")
        t = p.find("token[@name='Technology']") if p is not None else None
        tech_ok = t is not None and t.text == "4"
    check("V6: Lighting.Technology=4 (Future) set in XML", tech_ok)


def main():
    all_srcs = all_source_files()
    assert len(all_srcs) == 21, f"expected 21 sources, got {len(all_srcs)}"

    sources = {}
    print("=== Loading & guarding sources ===")
    for rel in all_srcs:
        text = load_source(rel)
        sources[rel] = text
        print(f"loaded  {rel}  ({len(text)} chars)")

    print()
    print("=== Emitting rbxlx ===")
    xml_text = build_xml(sources)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml_text)
    print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")

    print()
    print("=== Validations ===")
    validate(xml_text, sources)

    print()
    print("=== Size summary per script ===")
    for rel in sorted(sources):
        t = sources[rel]
        print(f"{t.count(chr(10)) + 1:>5} lines  {len(t.encode('utf-8')):>7} B  {rel}")

    print()
    print(f"SUMMARY: {passed} passed, {failed} failed, {passed + failed} total")
    if failed > 0:
        print("BUILD VALIDATION FAILED")
        sys.exit(1)
    print("BUILD OK")


if __name__ == "__main__":
    main()
