# BUILD_REPORT.md — Agent E (QA & Build), Fase 1

Date: 2026-11-19 | Output: `/data/workspace/netsim/build/NetworkSimulator.rbxlx`

## Final numbers

| Metric | Value |
|---|---|
| Source files built into the place | 21 (.luau) |
| Total source lines | 8,996 |
| Place structure | 36 Items: 15 ModuleScript, 1 Script (MainServer), 5 LocalScript, 6 Folder, Workspace+Part+SpawnLocation, Lighting, ReplicatedStorage, ServerScriptService, StarterPlayer, StarterGui, Players |
| rbxlx size | **296,017 bytes (289 KB)** |
| Referents | RBX0..RBX35, all unique |
| Build validations | 5/5 PASS (see QA_REPORT.md Section 4) |
| Syntax sweep | 21/21 PASS (0 source edits needed) |
| Unit/static tests | NetworkUtils 93/93, HardwareCatalog 294/294 |
| Cross-file audit | 135/136 (1 failure = BUG-001) |

## How to open

1. Download `NetworkSimulator.rbxlx` (VM `/data/workspace/netsim/build/` → instabox
   dashboard Files, or `scp -P 2222 ibssh_...@ssh.instabox.sh:/data/workspace/netsim/build/NetworkSimulator.rbxlx .`).
2. Roblox Studio → **File → Open from File…** → select `NetworkSimulator.rbxlx`
   (drag-and-drop onto Studio also works).
3. Press **Play (F5)**. On run: `MainServer` creates ReplicatedStorage.Remotes (10 remotes),
   configures Lighting, clones the TechnicianLaptop tool into StarterPack + Backpack,
   builds the player's lab plot, and starts economy/contract/autosave loops.
4. Optional: for persistence enable **Game Settings → Security → Enable Studio Access to
   API Services** (requires publishing the place). Without it, DataStore pcall-fails
   gracefully by design (one-time warning, session still playable, nothing saves).

## Fase 1 acceptance checklist (SPEC_GABUNGAN Section 6) — static verification state

QA performed on the VM is static analysis + real luau-CLI execution; **no Roblox runtime
playtest was possible** (no Studio/Roblox binary on the VM). Status below = "implemented
per contract, statically verified" unless noted.

| # | Acceptance step | Implementation verified | Status |
|---|---|---|---|
| 1 | Join → lab + laptop | SessionManager.ClaimNextPlot/CreateSession; WorldAndAssetBuilder.BuildFacility (room, rack_12u + starter kit U12/U10/U8, ISP uplink, workbench, NOC desk, dock, beacon, AC, sign); laptop cloned to StarterPack/Backpack; CharacterAdded teleport to facility.spawnCF | Implemented, static OK |
| 2 | Console cable | RackAndCablingSystem.AttachConsole (ProximityPrompt "Connect Console Cable", blue beam, >18 studs auto-detach), OpenTerminalEvent {action="open"} | Implemented, static OK |
| 3 | `ip set` | CommandExecutor.cmdIpSet: IPv4 validation, gateway same-subnet check ("Gateway not in subnet"), IP conflict check, LocalConsole/RemoteSSH guard | Implemented, static OK |
| 4 | `ping` WAN OK | NetworkGraph.CanReachIP BFS over linkUp edges, laptop bridge source "__laptop__", public targets via isp_uplink, jitter lines, flags.pingGateway on success | Implemented, static OK |
| 5 | `vm create` | cmdVm*: name sanitization ≤16 [alnum-_], capacity check, GenerateInternalIP via session.vmIpCounter (per-host keying per DECISIONS.md) | Implemented, static OK |
| 6 | Income jalan | ShiftAndEconomyManager 5s tick, 15s payout per VM on powered host (cpu*0.15+ram*0.02+disk*0.003), power cost live, thermal sim, StateSyncRemote snapshot | Implemented, static OK |
| 7 | Rakit server di bench | WorkbenchBuilderSystem.TryInstall order chassis→mobo→cpu→ram→storage→psu, RegisterBenchNode, Ship() → crate at dock | **BLOCKED by BUG-001** until coordinator applies the one-line `cpuCores = 0` fix |
| 8 | install OS | install-os (ubuntu-22.04/debian-12/rocky-9), 3s task.delay completion via TerminalPushOutput, BareMetal + not-installing guard | Implemented, static OK |
| 9 | stress test | stress-test 5s, temp = 30 + load*0.45 < 80 pass, sets workbench.tested, "cash" SFX | Implemented, static OK |
| 10 | Rejoin = state balik | DataPersistenceManager: DataStore NetSimDC_v1, autosave 120s + on-leave + BindToClose, Apply order (loadedFromSave first, workbench.ApplyState before link pass), ResetDataRemote wipe+rebuild | Implemented, static OK |

## Decisions made by Agent E (independent, as instructed)

- **D1 — Non-ASCII policy in the builder:** `build_place.py` hard-fails on invalid UTF-8
  or control characters and on forbidden markers (TODO/FIXME/STUB/XXX/HACK), but only
  *warns* on valid-UTF-8 non-ASCII glyphs (4 lines, BUG-002). Rationale: the sources are
  not mine to cosmetically edit, the glyphs are contract-legal Indonesian GUI strings,
  and rbxlx is UTF-8 XML that Studio reads correctly. A hard ASCII assert would have
  blocked the deliverable over 4 display characters.
- **D2 — Zero source edits:** the "syntax-only fix" allowance was not needed; all 21
  files compiled clean on my own sweep. BUG-001 is a semantic fix and stays with the
  coordinator.
- **D3 — ProtectedString encoding:** sources are XML-entity-escaped (`&`, `<`, `>`)
  inside `<ProtectedString name="Source">` (per task instruction, not CDATA); byte-equal
  roundtrip is validated by re-parsing the output and unescaping (V3).
- **D4 — Empty services:** Lighting, StarterGui, Players are emitted as empty service
  containers; WorldAndAssetBuilder.SetupLighting() populates Lighting properties at
  runtime per contract (Technology Future, Bloom, ColorCorrection).
- **D5 — Name mapping:** `MainServer.server.luau` → Script "MainServer"; `*.client.luau`
  → LocalScript minus suffix; shared modules → ModuleScript minus `.luau`; folders
  Bootstrap/Core/Physical/Gameplay + StarterPlayerScripts mirror the src tree exactly,
  so every `require(script.Parent...*)` path resolves (audit check A).
- **D6 — Test module copy:** `tests/NetworkUtils.luau` is a byte-identical copy of the
  src module (verified by diff) used by the luau-CLI tests; re-copy it if the source
  changes.
- **D7 — Build idempotence:** `build_place.py` rebuilds the rbxlx from scratch each run,
  asserts exactly 21 sources, and exits non-zero on any failed validation.

## Known limitations

- **BUG-001 (P0)** must be fixed before the Custom Build pillar is playable end-to-end
  (see BUGS.md). After the coordinator applies it, re-run
  `python3 build/build_place.py` to regenerate the rbxlx (the fix changes the source
  bytes embedded in the place).
- Fase 1 exclusions per CONTRACT Section 9 are intentionally absent: VLAN commands,
  manual color-coded cable spool purchase (cable items show "Fase 2"), carry/rack-mount,
  hot-swap HDD, incident engine, shift-clock settlement/SLA, leaderboard. Data structure
  placeholders (vlanId, CableColorType) exist for Fase 2/3.
- Broadcast storm is flag + message only (no LED flashing) per Fase 1 scope.
- Persistence needs API services enabled (published place) or it no-ops gracefully.
- DataStore budget: autosave every 120s + on-leave; standard Roblox DataStore limits apply.
- Runtime behaviors (physics, GUI rendering, SFX, DataStore) verified only statically —
  recommend a Studio playtest pass after BUG-001 is fixed.

## Artifacts owned by Agent E

- `tests/test_networkutils.luau`, `tests/check_catalog_static.py`,
  `tests/audit_consistency.py` (+ pre-existing `tests/NetworkUtils.luau` copy)
- `build/build_place.py`
- `build/NetworkSimulator.rbxlx` (296,017 bytes)
- `build/QA_REPORT.md`, `build/BUGS.md`, `build/BUILD_REPORT.md`

---
## COORDINATOR FINAL NOTE
- Fase 1 build complete: 21 files / 9,015 lines -> build/NetworkSimulator.rbxlx (296,034 bytes).
- BUG-001 (P0) fixed after QA; rbxlx regenerated; all build validations pass.
- Verification depth: static (syntax compile all files), functional (93 unit assertions on NetworkUtils, 127 logic assertions by Agent A harness), cross-file audit (135/136 checks, 1 P0 found and fixed), XML structural validation. NOT verified: live runtime inside Roblox Studio (no Studio on this VM) - first Studio run may surface runtime issues; report them for a fix pass.
