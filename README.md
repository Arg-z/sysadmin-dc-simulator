# SysAdmin & Cloud Data Center Simulator (Roblox) — Fase 1 + 2

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
   - `[B]` = Hardware Store (beli + ghost placement freeform; kategori Cable = spool 5 kabel).
   - Kabel berwarna: port WAN otomatis pakai spool kuning, port data pakai biru/merah.
     `cable`, `cable use <warna>`, `cable buy <warna>`, `cable cut <port>`.
   - VLAN: `vlan list`, `vlan set <port> <id>`, `switch port <port> trunk on`
     (trunk 802.1Q ke router, access VLAN untuk server colocation).
   - Rakit server di Workbench (Chassis -> Mobo -> CPU -> RAM -> Storage -> PSU),
     nyalakan bench, install OS + stress test, ship crate.
   - Income VPS jalan per 15 detik; kontrak CloudVPS / Colocation / CustomBuild
     punya SLA dan bisa di-accept di NOC desk. Colocation: angkat crate di dock,
     mount ke rack, kabel ke switch, set VLAN, nyalakan PDU, lalu payout jalan.
   - Save otomatis (DataStore; butuh publish + Studio API access).

## Struktur

```
src/
├── ReplicatedStorage/Shared/     # kontrak shared: types, utils, katalog, konstanta, model factory
├── ServerScriptService/
│   ├── MainServer.server.luau    # orkestrasi + lifecycle + wiring remote
│   ├── Bootstrap/                # WorldAndAssetBuilder (procedural world, zero-setup)
│   ├── Core/                     # SessionManager, NetworkGraph (BFS/VLAN/storm), CommandExecutor (CLI)
│   ├── Physical/                 # cabling, carry & mount, placement ghost, workbench rakit server
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

## Status Fase 1 + 2

- 22 file / ~10.000 baris Luau strict, server-authoritative.
- Fase 2 selesai: spool kabel berwarna + wire cutter, VLAN/trunk + inter-VLAN
  routing di router, carry & mount crate ke U-slot (PDU), kontrak Colocation
  dengan SLA + payout interval, dan save/restore rack + device rack-mounted.
- Terverifikasi: sintaks 22/22 (luau-compile), audit konsistensi + katalog lulus,
  XML roundtrip build.
- Belum: playtest live di Studio (laporin bug kalau ketemu).
- Fase 3 (dijadwalkan): incident engine (DDoS, cable fault, noisy neighbor,
  drive failure), shift clock + settlement harian, alarm beacon aktif, audio penuh.

## Tooling (opsional, tidak disertakan di repo)

Validator di VM: StyLua + luau CLI (`tools/`, di-.gitignore). Regenerasi place:
`python3 build/build_place.py` (butuh folder `src/`).
