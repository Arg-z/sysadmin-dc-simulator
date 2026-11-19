#!/usr/bin/env python3
"""Cross-file consistency audit for the netsim Fase 1 source tree (static).

Checks (each printed as PASS/FAIL, exit non-zero if any FAIL):
  A. Every require(...) path resolves to an existing file in the virtual rbxlx tree.
  B. Exactly one binder per remote, in the contract owner file; no duplicates.
  C. WorldAndAssetBuilder.REMOTE_DEFS == exactly the 10 contract Section 3 names.
  D. Every remote referenced (FindFirstChild/WaitForChild/FireClient/FireServer) exists in REMOTE_DEFS.
  E. SessionManager.CreateSession includes every CONTRACT Section 4 field
     (incl. workbench.cpuCores) and exact starter values.
  F. BuildFacility sets all 20 CONTRACT Section 5 keys.
  G. All CLI commands from CONTRACT Section 6 exist in CommandExecutor.
  H. Client scripts reference only existing shared modules + contract remotes.
Run: python3 tests/audit_consistency.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

passed = 0
failed = 0
failures = []


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {name}")
    else:
        failed += 1
        failures.append(f"{name}  {detail}")
        print(f"FAIL  {name}  {detail}")


def read(rel):
    with open(os.path.join(SRC, rel), "r", encoding="utf-8") as f:
        return f.read()


def find_balanced(text, start):
    """text[start] == opener; return index of matching closer (string-aware)."""
    open_ch = text[start]
    close_ch = {"(": ")", "{": "}", "[": "]"}[open_ch]
    depth = 0
    in_str = None
    i = start
    while i < len(text):
        c = text[i]
        if in_str:
            if c == in_str and text[i - 1] != "\\":
                in_str = None
        elif c in "\"'":
            in_str = c
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def block_after(text, prefix):
    """Contents between the braces that follow `prefix` (search starts after the prefix text)."""
    pos = text.find(prefix)
    if pos < 0:
        return None
    brace = text.find("{", pos + len(prefix) - 1)
    end = find_balanced(text, brace)
    if end < 0:
        return None
    return text[brace + 1 : end]


# Virtual instance tree: instance path -> source file (None = container only)
TREE = {
    ("ReplicatedStorage",): None,
    ("ReplicatedStorage", "Shared"): None,
    ("ReplicatedStorage", "Shared", "NetworkTypes"): "ReplicatedStorage/Shared/NetworkTypes.luau",
    ("ReplicatedStorage", "Shared", "NetworkUtils"): "ReplicatedStorage/Shared/NetworkUtils.luau",
    ("ReplicatedStorage", "Shared", "HardwareCatalog"): "ReplicatedStorage/Shared/HardwareCatalog.luau",
    ("ReplicatedStorage", "Shared", "PlotConstants"): "ReplicatedStorage/Shared/PlotConstants.luau",
    ("ReplicatedStorage", "Shared", "ModelFactory"): "ReplicatedStorage/Shared/ModelFactory.luau",
    ("ServerScriptService",): None,
    ("ServerScriptService", "MainServer"): "ServerScriptService/MainServer.server.luau",
    ("ServerScriptService", "Bootstrap"): None,
    ("ServerScriptService", "Bootstrap", "WorldAndAssetBuilder"): "ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau",
    ("ServerScriptService", "Core"): None,
    ("ServerScriptService", "Core", "SessionManager"): "ServerScriptService/Core/SessionManager.luau",
    ("ServerScriptService", "Core", "NetworkGraph"): "ServerScriptService/Core/NetworkGraph.luau",
    ("ServerScriptService", "Core", "CommandExecutor"): "ServerScriptService/Core/CommandExecutor.luau",
    ("ServerScriptService", "Physical"): None,
    ("ServerScriptService", "Physical", "RackAndCablingSystem"): "ServerScriptService/Physical/RackAndCablingSystem.luau",
    ("ServerScriptService", "Physical", "PlacementSystem"): "ServerScriptService/Physical/PlacementSystem.luau",
    ("ServerScriptService", "Physical", "WorkbenchBuilderSystem"): "ServerScriptService/Physical/WorkbenchBuilderSystem.luau",
    ("ServerScriptService", "Physical", "CarryAndMountSystem"): "ServerScriptService/Physical/CarryAndMountSystem.luau",
    ("ServerScriptService", "Gameplay"): None,
    ("ServerScriptService", "Gameplay", "ShiftAndEconomyManager"): "ServerScriptService/Gameplay/ShiftAndEconomyManager.luau",
    ("ServerScriptService", "Gameplay", "ContractAndIncidentManager"): "ServerScriptService/Gameplay/ContractAndIncidentManager.luau",
    ("ServerScriptService", "Gameplay", "DataPersistenceManager"): "ServerScriptService/Gameplay/DataPersistenceManager.luau",
    ("StarterPlayer",): None,
    ("StarterPlayer", "StarterPlayerScripts"): None,
    ("StarterPlayer", "StarterPlayerScripts", "TerminalClient"): "StarterPlayer/StarterPlayerScripts/TerminalClient.client.luau",
    ("StarterPlayer", "StarterPlayerScripts", "NOCMonitorClient"): "StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau",
    ("StarterPlayer", "StarterPlayerScripts", "CatalogAndBuilderClient"): "StarterPlayer/StarterPlayerScripts/CatalogAndBuilderClient.client.luau",
    ("StarterPlayer", "StarterPlayerScripts", "HudClient"): "StarterPlayer/StarterPlayerScripts/HudClient.client.luau",
    ("StarterPlayer", "StarterPlayerScripts", "AudioAndEffectsClient"): "StarterPlayer/StarterPlayerScripts/AudioAndEffectsClient.client.luau",
    ("StarterGui",): None,
    ("Players",): None,
}

CONTRACT_REMOTES = {
    "ExecuteCommand": "RemoteFunction",
    "TerminalPushOutput": "RemoteEvent",
    "OpenTerminalEvent": "RemoteEvent",
    "CableActionRemote": "RemoteEvent",
    "WorkbenchRemote": "RemoteEvent",
    "ContractActionRemote": "RemoteEvent",
    "PurchaseHardwareRemote": "RemoteEvent",
    "StateSyncRemote": "RemoteEvent",
    "PlaySFXRemote": "RemoteEvent",
    "ResetDataRemote": "RemoteEvent",
}

# src-relative source file -> instance path tuple (rbxlx layout)
FILE_INSTANCE = {}
for _rel in [v for v in TREE.values() if v]:
    _inst = _rel.replace(".luau", "").replace(".client", "").replace(".server", "").split("/")
    FILE_INSTANCE[_rel] = tuple(_inst)


def resolve_require(rel, expr):
    """Resolve one require expression to an instance path tuple or None."""
    expr = expr.strip()
    if expr.startswith("script"):
        m = re.match(r"^script((?:\.Parent)*)((?:\.\w+)+)$", expr)
        if not m:
            return None
        ups = m.group(1).count(".Parent")
        names = m.group(2).lstrip(".").split(".")
        path = FILE_INSTANCE[rel]
        if ups > len(path) - 1:
            return None
        return path[: len(path) - ups] + tuple(names)
    if re.match(r"^ReplicatedStorage(?:\.\w+)+$", expr):
        return tuple(expr.split("."))
    if "sharedFolder" in expr:
        m2 = re.search(r'WaitForChild\("(\w+)"\)', expr)
        if m2:
            return ("ReplicatedStorage", "Shared", m2.group(1))
        return None
    if re.match(r"^Shared(?:\.\w+)+$", expr):
        return ("ReplicatedStorage",) + tuple(expr.split("."))
    return None


def audit_requires():
    total = 0
    bad = []
    for rel in sorted(FILE_INSTANCE.keys()):
        text = read(rel)
        for m in re.finditer(r"require\(", text):
            close = find_balanced(text, m.end() - 1)
            if close < 0:
                continue
            expr = text[m.end() : close].strip()
            if expr.startswith("./"):
                continue
            total += 1
            target = resolve_require(rel, expr)
            ok = target is not None and target in TREE
            if not ok:
                bad.append(f"{rel}: require({expr}) -> {target}")
    check(f"A: all {total} require() paths resolve in rbxlx tree", len(bad) == 0, "; ".join(bad[:8]))


def audit_remote_defs():
    block = block_after(read("ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau"), "local REMOTE_DEFS = ")
    check("C: REMOTE_DEFS table exists", block is not None)
    if block is None:
        return
    names = re.findall(r'name\s*=\s*"(\w+)"', block)
    classes = dict(re.findall(r'name\s*=\s*"(\w+)",\s*class\s*=\s*"(\w+)"', block))
    check("C: REMOTE_DEFS count == 10", len(names) == 10, f"got {len(names)}: {names}")
    check("C: REMOTE_DEFS names == contract Section 3 set", set(names) == set(CONTRACT_REMOTES.keys()),
          f"missing={set(CONTRACT_REMOTES) - set(names)} extra={set(names) - set(CONTRACT_REMOTES)}")
    check("C: REMOTE_DEFS classes match contract",
          all(classes.get(n) == c for n, c in CONTRACT_REMOTES.items()),
          str({n: classes.get(n) for n in CONTRACT_REMOTES}))


def audit_bindings():
    owners = {
        "ExecuteCommand": ["ServerScriptService/Core/CommandExecutor.luau"],
        "PurchaseHardwareRemote": ["ServerScriptService/Physical/PlacementSystem.luau"],
        "CableActionRemote": ["ServerScriptService/Physical/RackAndCablingSystem.luau"],
        "OpenTerminalEvent": ["ServerScriptService/Physical/RackAndCablingSystem.luau"],
        "WorkbenchRemote": ["ServerScriptService/Physical/WorkbenchBuilderSystem.luau"],
        "ContractActionRemote": ["ServerScriptService/Gameplay/ContractAndIncidentManager.luau"],
        "ResetDataRemote": ["ServerScriptService/MainServer.server.luau"],
        "TerminalPushOutput": [],
        "StateSyncRemote": [],
        "PlaySFXRemote": [],
    }
    all_files = sorted(FILE_INSTANCE.keys())
    binding_lines = {}
    for rel in all_files:
        text = read(rel)
        for i, line in enumerate(text.splitlines(), 1):
            clean = re.sub(r"\((\w+)\s*::\s*any\)", r"\1", line)  # "(var :: any)" -> "var"
            m = re.search(r"(\w+)\.OnServerEvent\s*:\s*Connect|(\w+)\.OnServerInvoke\s*=", clean)
            if m and not line.strip().startswith("--"):
                var = m.group(1) or m.group(2)
                kind = "OnServerEvent" if m.group(1) else "OnServerInvoke"
                binding_lines.setdefault(rel, []).append((var, kind, i))
    bound = {}
    for rel, binds in binding_lines.items():
        lines = read(rel).splitlines()
        for var, kind, lineno in binds:
            # nearest assignment of var from a remotes lookup ABOVE the binding line
            name = None
            pat = re.compile(re.escape(var) + r'\s*=\s*.*(?:FindFirstChild|WaitForChild)\("(\w+)"')
            for j in range(lineno - 1, -1, -1):
                m2 = pat.search(lines[j])
                if m2:
                    name = m2.group(1)
                    break
            bound.setdefault(name or f"<UNRESOLVED:{var}>", []).append((rel, kind))
    for remote, expected_files in owners.items():
        got = bound.get(remote, [])
        got_files = sorted({f for f, _ in got})
        if expected_files:
            check(f"B: {remote} bound exactly once in {expected_files}",
                  len(got) == 1 and got_files == sorted(expected_files), f"bindings={got}")
        else:
            check(f"B: {remote} never bound server-side (FireClient only)", len(got) == 0, f"bindings={got}")
    check("B: no unresolved binder variables", not [k for k in bound if k.startswith("<UNRESOLVED")],
          str(bound))
    owner_files = sorted({x for fl in owners.values() for x in fl})
    check("B: no OnServerEvent/OnServerInvoke outside owner files",
          all(f in owner_files for f in binding_lines), str(sorted(binding_lines.keys())))


def audit_remote_references():
    all_files = sorted(FILE_INSTANCE.keys())
    used = {}
    for rel in all_files:
        text = read(rel)
        for m in re.finditer(r"(\w*(?:[Ee]mote)\w*)\s*(?::FindFirstChild|:WaitForChild)\(\"(\w+)\"", text):
            used.setdefault(m.group(2), set()).add(rel)
        assigns = {}
        for m in re.finditer(r"local\s+(\w+)\s*=[^\n]*?(?:FindFirstChild|WaitForChild)\(\"(\w+)\"\)", text):
            assigns[m.group(1)] = m.group(2)
        for m in re.finditer(r"(\w+):(FireClient|FireServer)\(", text):
            var = m.group(1)
            if var in assigns:
                used.setdefault(assigns[var], set()).add(rel)
    unknown = sorted(set(used.keys()) - set(CONTRACT_REMOTES.keys()))
    check("D: every referenced remote name is one of the 10 contract remotes", not unknown,
          f"unknown={unknown}")
    for name in sorted(used):
        check(f"D: remote '{name}' referenced (valid, {len(used[name])} file(s))", name in CONTRACT_REMOTES)


def audit_session():
    text = read("ServerScriptService/Core/SessionManager.luau")
    m = re.search(r"function SessionManager\.CreateSession", text)
    check("E: CreateSession function found", m is not None)
    if not m:
        return
    tbl = text.find("local session = {", m.end())
    start = text.find("{", tbl)
    end = find_balanced(text, start)
    body = text[start + 1 : end]
    required_top = ["player", "plotIndex", "balance", "reputation", "day", "terminal", "devices",
                    "deviceModels", "racks", "rackModels", "cables", "pendingCableDeviceId",
                    "pendingCablePortId", "pendingCableHighlight", "consoleLink",
                    "pendingPlacementItemId", "workbench", "facility", "flags", "hookedDevices",
                    "vmIpCounter", "cableCounter", "deviceCounter", "broadcastStorm",
                    "loadedFromSave", "noSaveWarned", "tickets"]
    for k in required_top:
        check(f"E: session.{k} present", re.search(rf"\b{k}\s*=", body) is not None)
    for k, v in [("cableCounter", "0"), ("deviceCounter", "0"), ("broadcastStorm", "false"),
                 ("loadedFromSave", "false"), ("noSaveWarned", "false")]:
        check(f"E: session.{k} == {v} at start", re.search(rf"\b{k}\s*=\s*{v}\b", body) is not None)
    wbblock = block_after(body, "workbench = ")
    check("E: workbench sub-table found", wbblock is not None)
    if wbblock:
        for k in ["chassis", "mobo", "cpuCount", "cpuSockets", "cpuCores", "ramSlotsUsed", "ramSlots",
                  "ramGb", "storageBaysUsed", "storageBays", "storageGb", "psu", "powered",
                  "osInstalled", "installing", "stressRunning", "tested", "shipped", "deviceId",
                  "totalSpent", "snapIndex", "benchModel", "lastCpuId", "lastRamId"]:
            check(f"E: workbench.{k} present in CreateSession", re.search(rf"\b{k}\s*=", wbblock) is not None)
    termblock = block_after(body, "terminal = ")
    if termblock is not None:
        for k in ["mode", "targetDeviceId", "sshStack"]:
            check(f"E: terminal.{k} present", re.search(rf"\b{k}\s*=", termblock) is not None)


def audit_facility():
    text = read("ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau")
    body = block_after(text, "local refs: { [string]: any } = ")
    check("F: facility refs table found", body is not None)
    if body is None:
        return
    keys = ["root", "facility", "devices", "cables", "crates", "rackModel", "rackSlots", "pduPart",
            "pduParts", "workbenchModel", "benchSnaps", "benchSwitch", "benchLed", "nocMonitors",
            "dockCF", "beaconLens", "beaconLight", "fan", "spawnCF", "ispWanLed"]
    for k in keys:
        check(f"F: facility ref '{k}' set", re.search(rf"\b{k}\s*=", body) is not None)
    nkeys = len(re.findall(r"^\t\t\w+\s*=", body, re.M))
    check("F: exactly 20 keys in refs table", nkeys == 20, f"got {nkeys}")
    check("F: session.facility = refs assignment", re.search(r"session\.facility\s*=\s*refs", text) is not None)
    check("F: root parented under EnsurePlotsFolder", re.search(r"root\.Parent\s*=\s*\w*\.?EnsurePlotsFolder\(\)", text) is not None)


def audit_cli():
    text = read("ServerScriptService/Core/CommandExecutor.luau")
    for c in ["help", "clear", "ping", "traceroute", "ip", "ssh", "exit", "top", "vm", "install-os", "stress-test", "cable", "vlan", "switch", "mount"]:
        check(f"G: command '{c}' dispatched", re.search(r'cmd == "' + re.escape(c) + r'"', text) is not None)
    for sub in ['"a"', '"addr"', '"set"']:
        check(f"G: ip subcommand {sub}", re.search(r"sub == " + sub, text) is not None)
    for sub in ["create", "list", "throttle", "delete"]:
        check(f"G: vm subcommand '{sub}'", re.search(r'sub == "' + sub + r'"', text) is not None)
    check("G: os variants ubuntu-22.04/debian-12/rocky-9",
          all(s in text for s in ["ubuntu-22.04", "debian-12", "rocky-9"]))
    check("G: throttle limit clamped to 5..100", re.search(r"math\.clamp\([^\n]*5,\s*100\)", text) is not None)
    check("G: raw input length cap <=240", re.search(r"240", text) is not None)


def audit_client_refs():
    client_files = [rel for rel in sorted(FILE_INSTANCE.keys()) if "/StarterPlayerScripts/" in rel]
    ok = True
    detail = []
    for rel in client_files:
        text = read(rel)
        for m in re.finditer(r'sharedFolder:WaitForChild\("(\w+)"\)', text):
            if ("ReplicatedStorage", "Shared", m.group(1)) not in TREE:
                ok = False
                detail.append(f"{rel}: shared module {m.group(1)} missing")
        for m in re.finditer(r'remotesFolder:WaitForChild\("(\w+)"', text):
            if m.group(1) not in CONTRACT_REMOTES:
                ok = False
                detail.append(f"{rel}: remote {m.group(1)} not in REMOTE_DEFS")
    check("H: client scripts reference only existing shared modules + contract remotes", ok, "; ".join(detail))
    check("H: 5 client LocalScripts present", len(client_files) == 5, str(client_files))


def audit_fase2():
    """Fase 2 surface: VLAN/trunk, colored spools, carry & mount, colocation."""
    graph = read("ServerScriptService/Core/NetworkGraph.luau")
    check("F2: NetworkGraph.SetPortVlan exists", "function NetworkGraph.SetPortVlan" in graph)
    check("F2: NetworkGraph.SetPortTrunk exists", "function NetworkGraph.SetPortTrunk" in graph)
    check("F2: BFS honours trunks", "isTrunk" in graph and "trunked" in graph)
    check("F2: router inter-VLAN routing flag", "interVlanRouting" in graph)

    placement = read("ServerScriptService/Physical/PlacementSystem.luau")
    for api in ["MountDevice", "UnmountDevice", "FindFreeUSlot", "RestoreRack"]:
        check(f"F2: PlacementSystem.{api} exists", f"function PlacementSystem.{api}" in placement)

    carry = read("ServerScriptService/Physical/CarryAndMountSystem.luau")
    for api in ["SpawnCrate", "BeginCarry", "MountCarried", "DropCarried", "EvaluateColo", "CleanupTicket"]:
        check(f"F2: CarryAndMountSystem.{api} exists", f"function CarryAndMountSystem.{api}" in carry)

    contract = read("ServerScriptService/Gameplay/ContractAndIncidentManager.luau")
    check("F2: Colocation ticket factory", "makeColocationTicket" in contract)
    check("F2: colocation payout interval", "payoutIntervalSec" in contract)
    check("F2: SLA failure path", "failColocation" in contract)

    session = read("ServerScriptService/Core/SessionManager.luau")
    check("F2: session cableSpools", "cableSpools" in session)
    check("F2: session colocation state", "colocation" in session)

    persistence = read("ServerScriptService/Gameplay/DataPersistenceManager.luau")
    check("F2: persistence saves racks", "racks = racks" in persistence)
    check("F2: persistence restores rack devices", "placement.MountDevice" in persistence)
    check("F2: persistence saves port VLANs", "trunk = port.isTrunk" in persistence)


def main():
    print("=== Cross-file consistency audit (static) ===")
    audit_requires()
    audit_remote_defs()
    audit_bindings()
    audit_remote_references()
    audit_session()
    audit_facility()
    audit_cli()
    audit_client_refs()
    audit_fase2()
    print()
    print(f"SUMMARY: {passed} passed, {failed} failed, {passed + failed} total")
    if failed > 0:
        print("FAILED CHECKS:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("AUDIT PASSED")


if __name__ == "__main__":
    main()
