# SysAdmin & Cloud Data Center Simulator (Roblox) — Fase 1

Game Roblox: jadi teknisi/sysadmin yang punya lab server sendiri — rakit PC server,
hosting VPS via terminal CLI, kabel jaringan, income & kontrak. Dibangun dari spec
`docs/roblox_sysadmin_full_production_spec.md` + keputusan desain di `docs/SPEC_GABUNGAN.md`.

## Cara main (dev)

1. Buka **`build/NetworkSimulator.rbxlx`** di Roblox Studio (File > Open from File).
2. **Play (F5)**. Lu langsung dapat: lab pribadi + laptop (hotbar) + starter kit di rack.
3. Loop dasar:
   - Dua-klik port = kabel LAN (switch -> router, server -> switch).
   - Dekati device + `ProximityPrompt` = kabel console laptop (atau klik laptop = SSH).
   - Terminal: `help`, `ip set <ip> <gw>`, `install-os ubuntu-22.04`, `ping 8.8.8.8`,
     `vm create --name web1 --cpu 4 --ram 8 --disk 200`, `stress-test`, dst.
   - `[B]` = Hardware Store (beli + ghost placement freeform).
   - Rakit server di Workbench (Chassis -> Mobo -> CPU -> RAM -> Storage -> PSU),
     nyalakan bench, install OS + stress test, ship crate.
   - Income VPS jalan per 15 detik; kontrak (CloudVPS / CustomBuild) bisa di-accept
     di NOC desk. Save otomatis (DataStore; butuh publish + Studio API access).

## Struktur

```
src/
├── ReplicatedStorage/Shared/     # kontrak shared: types, utils, katalog, konstanta, model factory
├── ServerScriptService/
│   ├── MainServer.server.luau    # orkestrasi + lifecycle + wiring remote
│   ├── Bootstrap/                # WorldAndAssetBuilder (procedural world, zero-setup)
│   ├── Core/                     # SessionManager, NetworkGraph (BFS/VLAN/storm), CommandExecutor (CLI)
│   ├── Physical/                 # cabling, placement ghost, workbench rakit server
│   └── Gameplay/                 # economy, kontrak, DataStore persistence
├── StarterPlayer/StarterPlayerScripts/  # Terminal, NOC monitors, Store, HUD, SFX (client)
build/
├── NetworkSimulator.rbxlx        # place siap buka di Studio
├── build_place.py                # generator rbxlx dari src/
├── QA_REPORT.md / BUGS.md / BUILD_REPORT.md / DECISIONS.md
tests/                            # unit test NetworkUtils (luau CLI) + audit konsistensi
docs/                             # spec lengkap (EN) + spec gabungan (ID)
CONTRACT.md                       # API binding antar modul (arsitektur)
```

## Status Fase 1

- 21 file / ~9.000 baris Luau strict, server-authoritative.
- Terverifikasi: sintaks 21/21, unit test 93 assertion + audit 135 cek, XML roundtrip.
- Belum: playtest live di Studio (laporin bug kalau ketemu).
- Fase 2/3 (dijadwalkan): Colocation + VLAN manual, incident engine (DDoS, dll),
  shift clock + SLA + reputasi.

## Tooling (opsional, tidak disertakan di repo)

Validator di VM: StyLua + luau CLI (`tools/`, di-.gitignore). Regenerasi place:
`python3 build/build_place.py` (butuh folder `src/`).
