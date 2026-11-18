# BUGS.md — Agent E (QA & Build) findings, Fase 1

Legend: severity P0 = blockship / P1 = should-fix / P2 = nice-to-have or informational.
Agent E edits to source files: **none** (0 syntax fixes were needed — all 21 files
compiled clean on the first independent sweep). Every entry below therefore needs a
coordinator action or is informational only.

---

## BUG-001 — `workbench.cpuCores` never initialized → CPU install crashes and charges the player

- **Severity:** P0 (blocks the Fase 1 acceptance flow "rakit server di bench → install OS → stress test")
- **Files/lines:**
  - `src/ServerScriptService/Core/SessionManager.luau:75-102` — `CreateSession` builds the
    `workbench` table with `cpuCount = 0` (line 78) but **no `cpuCores = 0`**.
  - `src/ServerScriptService/Physical/WorkbenchBuilderSystem.luau:288` —
    `wb.cpuCores += specs.cores or 8` (inside `TryInstall`, CPU branch).
  - `src/ReplicatedStorage/Shared/NetworkTypes.luau:125-127` — `WorkbenchState` type
    requires BOTH `cpuCount: number` AND `cpuCores: number`.
- **Description:** Fresh sessions have `session.workbench.cpuCores == nil`. The first CPU
  install executes `wb.cpuCount += 1` (ok) then `wb.cpuCores += specs.cores or 8` →
  "attempt to perform arithmetic on a nil value". `Workbench.TryInstall` is called
  directly from `PlacementSystem.OnPurchase` (`PlacementSystem.luau:256`) with **no
  pcall**, so the remote handler errors out. The balance deduction
  (`session.balance -= def.price`, WorkbenchBuilderSystem.luau:273-274) happens BEFORE
  the crash line, so the player is charged and receives no CPU. Downstream readers of
  `wb.cpuCores` (node.specs.cpu at :313/:357, Serialize at :485, ApplyState defaults it)
  are only safe because they read/`tonumber`-guard, but the increment itself is fatal.
- **Reproduction:** Join → buy `cpu_xeon8` ($300) at the workbench → install. Balance
  drops by 300, no CPU installed, server console shows the arithmetic-on-nil error.
- **Fix needed (coordinator; one line, either of):**
  1. Preferred — in `SessionManager.CreateSession`, add `cpuCores = 0,` immediately after
     `cpuCount = 0,` (matches the `WorkbenchState` type exactly).
  2. Alternative (defense in depth) — in `WorkbenchBuilderSystem.TryInstall`:
     `wb.cpuCores = (wb.cpuCores or 0) + (specs.cores or 8)`.
- **Fixed by Agent E:** NO (semantic change in an Agent A / Agent B owned file).

---

## BUG-002 — Non-ASCII UTF-8 glyphs in user-facing strings (4 lines)

- **Severity:** P2 (cosmetic / pure-ASCII discipline; everything works as-is)
- **File:line:**
  - `src/ServerScriptService/Core/CommandExecutor.luau:832` — `±` in "hasil akan muncul dalam ±5 detik ..."
  - `src/StarterPlayer/StarterPlayerScripts/HudClient.client.luau:315` — `°` in "%.1f °C"
  - `src/StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau:635` — `✓` objective check glyph
  - `src/StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau:729` — `°` in "%.1f °C"
- **Description:** Valid UTF-8 inside string literals; Roblox TextLabels render these
  glyphs fine and the generated `.rbxlx` is UTF-8 XML, so there is no runtime risk.
  Flagged only because the build contract prefers ASCII-only sources and the build
  script now carries a documented exception (BUILD_REPORT.md D1).
- **Suggested fix (optional):** replace with ASCII equivalents (`+-`, `deg C`, `v`) or
  formally bless UTF-8 GUI strings in the contract.
- **Fixed by Agent E:** NO (string content edits in C/D-owned files).

---

## BUG-003 — Discontiguous subnet masks accepted in mask-validating paths (informational)

- **Severity:** P2 (edge case; behavior is per contract, no crash)
- **Files/lines:**
  - `src/ReplicatedStorage/Shared/NetworkUtils.luau` — `IsSameSubnet` validates inputs
    with `IsValidIPv4` only; a mask like `255.255.2.0` is a *valid IPv4* so it passes and
    the comparison is pure bitwise (`bit32.band`). `MaskToPrefix("255.0.255.0")` returns
    8 (stops at first zero bit). Locked by test "discontiguous valid mask -> bitwise
    semantics" in `tests/test_networkutils.luau`.
  - `src/ServerScriptService/Core/CommandExecutor.luau:371-376` — `ip set <ip> <gw> [mask]`
    accepts any IsValidIPv4 mask, including non-contiguous ones (e.g. `255.255.2.0`),
    giving surprising "Gateway not in subnet" / routing semantics.
- **Description:** Contract Section 2 defines IsSameSubnet as bitwise band — so this is
  compliant behavior, recorded so Fase 2 (VLAN/routing) can tighten it deliberately.
- **Suggested fix (Fase 2):** add a contiguity check, e.g.
  `NetworkUtils.MaskToPrefix(mask)` re-expanded via `NumberToIP` must equal `mask`
  (or `popcount(mask) == MaskToPrefix(mask)`), and reject with "invalid subnet mask".
- **Fixed by Agent E:** N/A (informational).

---

## Non-bug observations

1. **Zero compile errors across 21 files** on the independent sweep; no Agent E syntax
   fixes applied (the "fix syntax only" allowance ended up unused).
2. All 13 `...` occurrences are legitimate (UI progress strings, comments, one
   `{ VMData... }` type annotation) — no placeholder-style ellipses.
3. `tests/NetworkUtils.luau` (pre-existing) verified byte-identical to
   `src/ReplicatedStorage/Shared/NetworkUtils.luau` via `diff`; the luau-CLI test
   requires this copy. If the source changes, re-copy before re-running tests.
4. Remote binding audit matches DECISIONS.md exactly: 7 server bindings, one per remote,
   no `OnServerEvent`/`OnServerInvoke` outside the owner files, and the three
   FireClient-only remotes are never bound.

---
## COORDINATOR RESOLUTION (post-QA)
- BUG-001 [P0]: FIXED by coordinator at integration. SessionManager.luau workbench table now includes `cpuCores = 0` (line 79). Re-compiled (luau-compile OK) and rbxlx regenerated (296,034 bytes, validations 5/5 PASS).
- BUG-002 [P2]: ACCEPTED as-is (4 valid-UTF-8 display glyphs; harmless in Roblox).
- BUG-003 [P2]: Deferred to Fase 2 (mask contiguity validation) per contract scope.
