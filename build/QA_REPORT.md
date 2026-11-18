# QA_REPORT.md — Agent E (QA & Build), Fase 1

Date: 2026-11-19 | Tree: `/data/workspace/netsim` @ VM instabox | Sources: 21 .luau, 8,996 lines

**Overall verdict: SHIP-READY AFTER ONE FIX.** Syntax 21/21, unit tests 93/93, catalog
static checks 294/294, cross-file audit 135/136, rbxlx build 5/5 validations.
The single audit failure is a real P0 runtime bug (`workbench.cpuCores` never
initialized — breaks the workbench CPU-install flow). Details: `BUGS.md` BUG-001.

---

## 1. Independent syntax sweep

Command: `tools/luau-compile --binary <f> >/dev/null` over all 21 `.luau` under `src/`
(run fresh by Agent E; prior agents' results not trusted).

| # | File | Compile |
|---|------|---------|
| 1 | ReplicatedStorage/Shared/HardwareCatalog.luau | PASS |
| 2 | ReplicatedStorage/Shared/ModelFactory.luau | PASS |
| 3 | ReplicatedStorage/Shared/NetworkTypes.luau | PASS |
| 4 | ReplicatedStorage/Shared/NetworkUtils.luau | PASS |
| 5 | ReplicatedStorage/Shared/PlotConstants.luau | PASS |
| 6 | ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau | PASS |
| 7 | ServerScriptService/Core/CommandExecutor.luau | PASS |
| 8 | ServerScriptService/Core/NetworkGraph.luau | PASS |
| 9 | ServerScriptService/Core/SessionManager.luau | PASS |
| 10 | ServerScriptService/Gameplay/ContractAndIncidentManager.luau | PASS |
| 11 | ServerScriptService/Gameplay/DataPersistenceManager.luau | PASS |
| 12 | ServerScriptService/Gameplay/ShiftAndEconomyManager.luau | PASS |
| 13 | ServerScriptService/MainServer.server.luau | PASS |
| 14 | ServerScriptService/Physical/PlacementSystem.luau | PASS |
| 15 | ServerScriptService/Physical/RackAndCablingSystem.luau | PASS |
| 16 | ServerScriptService/Physical/WorkbenchBuilderSystem.luau | PASS |
| 17 | StarterPlayer/StarterPlayerScripts/AudioAndEffectsClient.client.luau | PASS |
| 18 | StarterPlayer/StarterPlayerScripts/CatalogAndBuilderClient.client.luau | PASS |
| 19 | StarterPlayer/StarterPlayerScripts/HudClient.client.luau | PASS |
| 20 | StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau | PASS |
| 21 | StarterPlayer/StarterPlayerScripts/TerminalClient.client.luau | PASS |

**21/21 PASS, 0 compile errors. No syntax fixes were applied by Agent E (0 source edits).**

### Forbidden markers scan

| Check | Result |
|---|---|
| `TODO` / `FIXME` / `STUB` / `XXX` / `HACK` (case-insensitive) in all 21 files | 0 hits |
| `...` placeholder patterns | All 13 occurrences legitimate: progress-bar/UI strings ("[ 55%] partitioning storage ..."), comments, and one Luau type annotation `{ VMData... }` (DataPersistenceManager:23). No `... --` placeholders. |
| `--!strict` first line | 21/21 OK |

### Non-ASCII scan (`grep -P '[^\x00-\x7F]'`) — 4 lines in 3 files

| File:line | Char | Context |
|---|---|---|
| Core/CommandExecutor.luau:832 | `±` (U+00B1) | terminal output string "hasil akan muncul dalam ±5 detik ..." |
| StarterPlayerScripts/HudClient.client.luau:315 | `°` (U+00B0) | HUD temp "%.1f °C" |
| StarterPlayerScripts/NOCMonitorClient.client.luau:635 | `✓` (U+2713) | objective checkbox glyph |
| StarterPlayerScripts/NOCMonitorClient.client.luau:729 | `°` (U+00B0) | NOC telemetry "%.1f °C" |

All are valid UTF-8 inside string literals (contract allows Indonesian GUI strings).
Roblox renders these glyphs; the .rbxlx is emitted as UTF-8 XML, so they are safe.
Logged as BUG-002 (P2, optional pure-ASCII cleanup). Builder policy decision: see
BUILD_REPORT.md "Decisions" D1.

---

## 2. Unit tests (real execution, luau CLI)

### 2a. NetworkUtils — `tools/luau tests/test_networkutils.luau`

Real execution requiring `tests/NetworkUtils.luau` (byte-identical copy of
`src/.../NetworkUtils.luau`, verified by `diff` — no Color3/Roblox API in the module).

**Result: 93 passed / 0 failed, exit 0.**

| Group | Assertions | Result |
|---|---|---|
| IsValidIPv4 | 23 (valid, leading zero, out-of-range 256/999/300, non-numeric letters/hex/mixed, negative octet, 3 or 5 octets, empty string/octet, leading/trailing/inner whitespace, nil, length cap 15, exactly-15) | 23/23 PASS |
| IPToNumber / NumberToIP | 10 (0.0.0.0↔0, 255.255.255.255↔4294967295, 192.168.1.1↔3232235777, 10.0.0.2↔167772162, 3 roundtrips incl. 8.8.8.8 / 172.16.5.200 / 203.0.113.99) | 10/10 PASS |
| MaskToPrefix | 7 (/8, /16, /24, /32, /0, /25, discontiguous-stops-at-zero) | 7/7 PASS |
| IsSameSubnet | 8 (same /24 true; 192.168.1.5 vs 192.168.2.5 /24 **false**; same pair /16 **true**; gateway-in-subnet; /8 cross-class; identical IPs; invalid ip arg false; invalid mask arg false; discontiguous-valid-mask bitwise lock) | 8/8 PASS |
| IsPrivateIP | 12 (10.x, 10.255.x, 127.x, 172.16, 172.31, 192.168 → true; 172.32, 172.15, 192.169, 8.8.8.8, 203.0.113.7, garbage → false) | 12/12 PASS |
| GenerateInternalIP | 7 (normal, clamp below 2 ×2, at 2, at 254, above 254 ×2) | 7/7 PASS |
| GenerateRandomPublicIP | 1 (200-sample range sanity: all 203.0.113.[2..254]) | 1/1 PASS |
| FormatCurrency | 8 (0→"$0", 999, 1000→"$1,000", 1234567→"$1,234,567", -250→"-$250", -0, 250.6→"$251", -1234567) | 8/8 PASS |
| FormatWatts | 3 (0, 450, rounding) | 3/3 PASS |
| FormatUptime | 7 (59s→"0m", 60s→"1m", 3600s→"1h 00m", 3661s→"1h 01m", 90000s→"1d 1h 00m", 86400s→"1d 0h 00m", negative→"0m") | 7/7 PASS |
| EscapeRich | 6 (amp, lt/gt, combined "a&b<c>d"→"a&amp;b&lt;c&gt;d", pre-escaped entity, plain, empty) | 6/6 PASS |

One initial test failure was my own test's fault (I asserted a *valid* IPv4 discontiguous
mask `255.255.2.0` should be rejected — the contract defines IsSameSubnet as pure
bitwise, so `true` is correct). Test corrected; behavior locked as a documented-case
assertion. Logged as BUG-003 (P2 informational).

### 2b. HardwareCatalog static invariant checker — `python3 tests/check_catalog_static.py`

Catalog uses `Color3` (Roblox global), so it cannot run in the CLI. The checker parses
`addItem({...})` blocks (string-aware balanced braces) and asserts structure + contract values.

**Result: 294 passed / 0 failed, exit 0.**

| Check | Count | Result |
|---|---|---|
| addItem block count == 21 | 1 | PASS |
| Item ids unique | 1 | PASS |
| Required fields per block (id, name, category, price, uSize, description, specs, visualColor) | 21 × 8 = 168 | PASS |
| price parses + price > 0 per item | 42 | PASS |
| id set == contract id set | 1 | PASS |
| category == contract per item | 21 | PASS |
| price == contract per item | 21 | PASS |
| pinned spec values per item (e.g. bm_starter cpu/ram/disk/watts/ports=1, bm_enterprise ports=2 per DECISIONS.md, mobo sockets/ramSlots/bays, cpu cores, ram ramGb, nvme storageGb, psu watts, switch ports/sfp, router wanPorts) | 44 | PASS |
| API surface (Get / IsPlaceable / ListByCategory / StoreCategories / Rack-Network-Server categories) | 5 | PASS |

---

## 3. Cross-file consistency audit — `python3 tests/audit_consistency.py`

Static audit mapping the rbxlx instance tree and checking every require path, remote
binding, session field, facility key and CLI command.

**Result: 135 passed / 1 failed (136 total), exit 1.** The 1 failure is BUG-001 below.

| Group | Checks | Result |
|---|---|---|
| A: all 37 `require(...)` paths resolve in the virtual rbxlx tree (script.Parent chains incl. `.Parent.Parent`, `ReplicatedStorage.Shared.*`, `Shared.*` alias, `sharedFolder:WaitForChild()`) | 1 aggregate | PASS |
| B: exactly one binder per remote in owner file — ExecuteCommand→CommandExecutor (OnServerInvoke), PurchaseHardwareRemote→PlacementSystem, CableActionRemote+OpenTerminalEvent→RackAndCablingSystem, WorkbenchRemote→WorkbenchBuilderSystem, ContractActionRemote→ContractAndIncidentManager, ResetDataRemote→MainServer; TerminalPushOutput/StateSyncRemote/PlaySFXRemote never bound (FireClient only); no unresolved binder vars; no bindings outside owner files | 11 | 11/11 PASS |
| C: REMOTE_DEFS == exactly 10 contract Section 3 names with correct classes | 4 | 4/4 PASS |
| D: every referenced remote (FindFirstChild/WaitForChild/FireClient/FireServer) is one of the 10 remotes — all 10 referenced, none unknown | 11 | 11/11 PASS |
| E: SessionManager.CreateSession — all 27 top-level Section 4 fields, starter values (cableCounter/deviceCounter=0, broadcastStorm/loadedFromSave/noSaveWarned=false), terminal sub-fields, all 24 workbench sub-fields | 39 | **38/39 — FAIL: workbench.cpuCores missing (BUG-001)** |
| F: BuildFacility sets all 20 CONTRACT Section 5 keys, exactly 20 entries, session.facility=refs, root under EnsurePlotsFolder | 23 | 23/23 PASS |
| G: CLI commands help/clear/ping/traceroute/ip(a,addr,set)/ssh/exit/top/vm(create,list,throttle,delete)/install-os/stress-test all dispatched; OS variants; throttle clamp 5..100; 240-char input cap | 21 | 21/21 PASS |
| H: client scripts reference only existing shared modules + contract remotes; 5 LocalScripts present | 2 | 2/2 PASS |

Remote binding map verified against DECISIONS.md — no duplicates, no orphan bindings.

---

## 4. Build — `python3 build/build_place.py` → `build/NetworkSimulator.rbxlx`

**Output: `/data/workspace/netsim/build/NetworkSimulator.rbxlx`, 296,017 bytes (289 KB).**

| Validation | Result |
|---|---|
| V1: output parses as well-formed XML (xml.etree) | PASS |
| V2: 36 Item referents (RBX0..RBX35) all unique | PASS |
| V3: 21 ProtectedString sources roundtrip byte-equal to originals after unescape | PASS |
| V4: all 25 expected scripts/folders present with correct classes (15 ModuleScript, 1 Script, 5 LocalScript, Folder Shared/Bootstrap/Core/Physical/Gameplay/StarterPlayerScripts; services Workspace/Lighting/ReplicatedStorage/ServerScriptService/StarterPlayer/StarterGui/Players; Workspace Part "Baseplate" 512×20×512 @Y-10 anchored+locked shape 1 Color 4283980123; SpawnLocation 12×1×12 @Y0.5 Z40 anchored shape 1 Color 4282818660) | PASS |
| V4b: every Script/LocalScript/ModuleScript has `Disabled=false` | PASS |
| Source guards inside builder: 21 files loaded, valid UTF-8, no control chars, no forbidden markers (hard fail); 4 non-ASCII warnings (BUG-002) | PASS (with warnings) |

Emission details: `<?xml version="1.0" encoding="utf-8"?><roblox version="4">`; sources
XML-entity-escaped (`&`, `<`, `>`) inside `<ProtectedString name="Source">`; Color3uint8
decimal = 0xFF<<24 | r<<16 | g<<8 | b; CFrame as Coordinate3D with identity rotation.
Name mapping: `MainServer.server.luau` → Script "MainServer"; `*.client.luau` → LocalScript
without suffix; ModuleScripts without `.luau`.

---

## 5. Known issues

See `BUGS.md` for full detail:

- **BUG-001 (P0, blockship for Fase 1 acceptance):** `workbench.cpuCores` missing from
  CreateSession → first CPU install crashes `wb.cpuCores += ...` on nil, after balance
  deduction. Needs coordinator (one-line fix in SessionManager.luau or
  WorkbenchBuilderSystem.luau).
- **BUG-002 (P2):** 4 non-ASCII UTF-8 glyphs in GUI/terminal strings — safe in Roblox,
  optional pure-ASCII cleanup.
- **BUG-003 (P2, informational):** discontiguous subnet masks are accepted by
  IsValidIPv4-guarded mask paths (`ip set` mask, IsSameSubnet) — bitwise semantics per
  contract; suggest contiguity validation in Fase 2.

Runtime playtest was **not** possible on the VM (no Roblox Studio/roblox CLI); all QA is
static + real luau-CLI execution. See BUILD_REPORT.md for the acceptance checklist state.
