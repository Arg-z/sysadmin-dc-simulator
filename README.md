# SysAdmin & Cloud Data Center Simulator (Roblox) — Fase 1 + 2 + 3 (Full Production)

Game Roblox PC: jadi teknisi/sysadmin yang mengelola lab server & cloud data center sendiri —
rakit PC server di workbench, hosting VPS & Colocation via terminal CLI, manajemen VLAN/trunk &
kabel berwarna, serta mitigasi insiden live selama jam shift.

## Cara main (Roblox Studio - PC)

1. Buka **`build/NetworkSimulator.rbxlx`** di Roblox Studio (**File > Open from File**).
2. Tekan **Play (F5)**. Kamu langsung mendapat lab pribadi, `TechnicianLaptop` + `WireCutter` di hotbar, dan starter kit di rack.
3. **Kontrol PC & Loop Utama:**
   - **Terminal (`[~]` / `[F2]` / klik Laptop / tombol `TERMINAL [~]`):**
     - Tutup kapan saja dengan **`[~]`**, **`[F2]`**, **`Ctrl+W`**, klik **`X [~]`**, atau ketik **`close`**.
     - Jaringan & Sistem: `help`, `clear` (`Ctrl+L`), `ip a`, `ip set <ip> <gw> [mask]`, `ping <ip>`, `traceroute <ip>`, `ssh <ip>`, `exit`, `top`, `install-os <ubuntu-22.04|debian-12|rocky-9>`, `stress-test`, `ship`.
     - VM Hosting: `vm create --name <n> --cpu <n> --ram <n> --disk <n>`, `vm list`, `vm throttle <name> --limit <pct>`, `vm delete <name>`.
     - Kabel & VLAN (Fase 2): `cable`, `cable use <blue|yellow|red>`, `cable buy <warna>`, `cable cut <port>`, `vlan list`, `vlan set <port> <id>`, `switch port <port> trunk <on|off>`, `switch list`, `mount list`, `mount [rackId]`.
     - Insiden & Shift (Fase 3): `incident`, `ddos block <ip>`, `drive status`, `drive replace [bay]`, `shift`.
   - **Hardware Store (`[B]` / tombol `STORE [B]`):**
     - Beli Rack, Switch/Router, Bare-Metal Server (mode ghost placement: **`[R]`** putar 90°, **Klik Kiri** pasang, **Klik Kanan / `[Esc]`** batal).
     - Beli komponen custom build (urutan di Workbench: `Chassis -> Mobo -> CPU -> RAM -> Storage -> PSU`) atau `Replacement HDD` untuk cadangan Remote Hands.
     - Beli Cable Spools (`LAN Blue`, `WAN Yellow`, `Mgmt Red`).
   - **Kontrak & Insiden (NOC Desk 3 Monitor):**
     - **CloudVPS**, **CustomBuild**, dan **Colocation** (angkat crate di Loading Dock -> mount ke Rack -> pasang kabel VLAN -> nyalakan PDU).
     - **Shift Clock (08:00–18:00)** dengan **Jam Sibuk (11:00–17:00)** tempat 4 tipe insiden bisa muncul (*Kabel Putus*, *DDoS Flood*, *Noisy Neighbor*, *Drive Failure*) lengkap dengan alarm beacon merah, klaxon, kedip LED, dan **Daily Settlement** otomatis tiap pukul 18:00.
   - **Save Otomatis (DataStore)** + **Roblox Leaderboard (`Saldo` & `Reputasi`)** + tombol **RESET DATA**.

## Struktur

```
src/
├── ReplicatedStorage/Shared/     # kontrak shared: types, utils, katalog, konstanta, model factory 3D
├── ServerScriptService/
│   ├── MainServer.server.luau    # orkestrasi + lifecycle + leaderstats + wiring remote
│   ├── Bootstrap/                # WorldAndAssetBuilder (procedural Tier-4 data center lab)
│   ├── Core/                     # SessionManager, NetworkGraph (BFS/VLAN/trunk/storm/faults), CommandExecutor (CLI)
│   ├── Physical/                 # cabling, carry & mount, placement ghost, workbench rakit server
│   └── Gameplay/                 # shift & economy, kontrak & incident engine, DataStore persistence
├── StarterPlayer/StarterPlayerScripts/  # Terminal PC, NOC monitors, Store, HUD, SFX & typing pose (client)
build/
├── NetworkSimulator.rbxlx        # place siap buka & dimainkan di Roblox Studio
├── build_place.py                # generator & validator rbxlx dari src/
├── QA_REPORT.md / BUGS.md / BUILD_REPORT.md / DECISIONS.md
tests/                            # unit test NetworkUtils + static catalog check + audit konsistensi (Fase 1-3)
CONTRACT.md                       # spesifikasi arsitektur & kontrak antar modul
```

## Status Fase 1 + 2 + 3

- **Fase 1 (Selesai):** Core lab prosedural, cabling 2-klik & console laptop, CLI dasar, VM hosting, custom build workbench, store placement, ekonomi & persistence.
- **Fase 2 (Selesai):** VLAN & 802.1Q trunking + router inter-VLAN routing, cable spools berwarna + WireCutter, carry & rack-mount crate, kontrak Colocation ber-SLA.
- **Fase 3 (Selesai):** Incident Engine (Cable Fault, DDoS Flood, Noisy Neighbor, Drive Failure), Shift Clock (08:00–18:00) + Daily Settlement, Alarm Beacon + Klaxon + LED flashing, spatial AC hum + animasi mengetik, dan Roblox Leaderboard.
- **Build & Audit:** `python build/build_place.py`, `python tests/audit_consistency.py`, `python tests/check_catalog_static.py`.
