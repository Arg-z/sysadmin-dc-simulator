# SPEC GABUNGAN — SysAdmin & Cloud Data Center Simulator (Roblox)

> **Sumber dokumen:**
> 1. `roblox_sysadmin_full_production_spec.md` — Full-Depth Production Spec (**UTAMA**, menang kalau beda dengan #2)
> 2. `roblox_sysadmin_master_prompt.md` — Master Engineering Prompt (base awal, referensi teknis 4.1–4.9)
> 3. Diskusi desain — keputusan user (plot per pemain, toolbar+ghost, scope bertahap, save/reset, kerja di VM)
>
> Kalau ada konflik antara dokumen: Full-Depth Spec > Master Prompt > diskusi awal yang sudah di-override di Section 3.

---

## 1. Visi (fantasi yang dituju)

Player = **Lead SysAdmin & Infrastructure Operator** yang punya lab/data center sendiri.
Fantasi inti dari diskusi:

- **Jadi teknisi server** — pakai Technician Laptop Tool: sambung kabel console fisik
  ke device, atau SSH wireless dari mana aja.
- **Hosting di tempat sendiri** — server pribadi di lab menghasilkan income
  (pilar Cloud VPS & Colocation).
- **Ngerakit komputer server** — beli komponen, rakit di Workbench, install OS,
  stress test, kirim (pilar Custom Build).

Tiga pilar dari MD dipertahankan semua:

1. **Cloud Hosting / VPS** — pecah bare-metal jadi VM via CLI (`vm create`, dst),
   atur resource contention, bertahan dari DDoS.
2. **Server Colocation** — mount server klien ke rack slot `U`, kabel color-coded,
   VLAN/IP routing, "Remote Hands" hardware swap.
3. **Custom Server Builder** — rakit hardware di Workbench step-by-step, boot via
   serial console, install OS, thermal burn-in stress test, shipping via Loading Dock.

---

## 2. Model dunia & kepemilikan (adaptasi dari diskusi)

- **Personal lab per pemain.** Setiap player yang join dapet plot lab sendiri
  (facility ±64x24x64 studs + yard belakang). Multiplayer-safe: semua state
  (device, network graph, kontrak, uang, reputasi) di-scope per player session.
- **Furniture lab fixed** (di-clone per plot oleh `WorldAndAssetBuilder`):
  `AssemblyWorkbench` (6 snap point + power switch), `Rack_12U`, `NOCDesk` (3 monitor
  `SurfaceGui`, PixelsPerStud=60), `LoadingDock` (zone hijau 12x0.2x12), `ISP Gateway
  uplink` (WAN junction), `AlarmBeacon` (lens Neon merah + PointLight), `AC_Unit`
  (fan berputar + ParticleEmitter udara dingin).
- **Device tambahan freeform.** Rack ekstra, switch, bare-metal, router — dibeli via
  Hardware Store HUD (`[B]`), lalu dipasang pakai **toolbar + ghost preview + klik
  lantai** (sesuai keputusan diskusi). Validasi bounds plot + tabrakan
  **server-authoritative**.
- **Starter kit** (dari MD): rack utuh ter-mount — ISP router (192.168.1.1/24, WAN
  aktif) di U12, Switch_8P di U10, BareMetal_Starter di U8, IP belum diset & kabel
  belum nyambung — tugas pertama player: wiring + konfigurasi.

---

## 3. Keputusan merge (MD vs diskusi) — bagian yang menang kalau konflik

| # | Topik | MD | Diskusi kita | Keputusan |
|---|-------|----|--------------|-----------|
| 1 | Struktur dunia | 1 DC room single-player | Plot per pemain | **Plot/lab per pemain**, facility di-clone per plot, semua modul state di-scope per session |
| 2 | Penempatan device | Semua fixed oleh builder | Toolbar + ghost + klik tanah | **Hybrid**: furniture inti fixed; device beli-an freeform via ghost placement |
| 3 | Kabel | Manual dua-klik antar port + VLAN + color-coded | Auto-connect | **Bertahap**: Fase 1 auto-cable smart-port (Beam + LED); Fase 2 manual dua-klik wajib buat Colocation/VLAN dengan kabel color-coded (`LAN_Blue`/`WAN_Yellow`/`Mgmt_Red`); auto-cable tetap ada sebagai "Quick Connect" |
| 4 | Mata uang | $ (harga katalog MD) | Rp | **Ikut MD ($)** supaya harga katalog konsisten. Ganti ke Rp nanti = ubah fungsi `FormatCurrency` + daftar harga |
| 5 | Ekonomi | Shift clock 08:00–18:00, SLA, reputasi, power harian, thermal sim | Income pasif sederhana | **Bertahap**: Fase 1 payout per 15 dtk - power live + thermal sim dasar (dibutuhkan stress-test); Fase 3 shift clock + SLA bonus + reputasi + settlement harian penuh |
| 6 | Persistensi | `DataPersistenceManager` (MD penuh) | Save/load + reset wajib | **Pakai modul MD** (`DataPersistenceManager`) + tambahan tombol reset (konfirmasi 2x klik) dari diskusi |
| 7 | Laptop Tool | Dual-mode (console fisik + SSH), tanpa baterai | Belum ada | **Diadopsi penuh sejak Fase 1** — inti fantasi teknisi. Tanpa baterai/upgrade sesuai MD |
| 8 | CLI | Lengkap | Belum ada | **Diadopsi penuh**, dipecah per fase (lihat Section 6) |
| 9 | Audio/SFX | Procedural SFX + arm-typing pose | Belum ada | **Diadopsi** — struktur remote (`PlaySFXRemote`) sejak Fase 1, konten SFX penuh di Fase 3 |
| 10 | Engineering standard | `--!strict`, server-authoritative, zero placeholder | — | **Diadopsi penuh** |

---

## 4. Struktur project

Hierarchy MD (Full-Depth) + modul tambahan dari diskusi (ditandai `// BARU`):

```text
ReplicatedStorage/
├── Shared/
│   ├── NetworkTypes.luau             (+ type PlotConstants & placement, lihat PlotConstants)
│   ├── HardwareCatalog.luau
│   ├── NetworkUtils.luau
│   └── PlotConstants.luau            // BARU: layout plot, bounds placement, snap grid
└── Remotes/                          (auto-generate runtime; sesuai MD + PlaySFXRemote)

ServerScriptService/
├── MainServer.server.luau
├── Bootstrap/
│   └── WorldAndAssetBuilder.luau     (+ PlotBuilder: clone facility per pemain)
├── Core/
│   ├── NetworkGraph.luau
│   ├── CommandExecutor.luau
│   └── SessionManager.luau           // BARU: session per pemain, mode terminal, sshStack
├── Physical/
│   ├── PlacementSystem.luau          // BARU: validasi ghost placement, freeform plot
│   ├── RackAndCablingSystem.luau
│   └── WorkbenchBuilderSystem.luau
└── Gameplay/
    ├── ShiftAndEconomyManager.luau
    ├── ContractAndIncidentManager.luau
    └── DataPersistenceManager.luau   (dari MD penuh; + tombol reset dari diskusi)

StarterPlayer/StarterPlayerScripts/
├── TerminalClient.client.luau
├── NOCMonitorClient.client.luau
├── CatalogAndBuilderClient.client.luau   (+ Hardware Store `[B]` & toolbar ghost UI)
├── AudioAndEffectsClient.client.luau
└── HudClient.client.luau             // BARU: uang/income, hint, tombol reset
```

---

## 5. Sistem inti (ringkasan; detail teknis = Full-Depth Spec 4.1–4.9)

- **NetworkTypes** (MD 4.1): PortType, CableColorType, PortData, VMData, DeviceNode
  (termasuk `isUnderDDoS`, `hasDegradedDrive`), RackData (+`pduPowered`), ContractTicket,
  PlayerSession, FacilityStateSnapshot.
- **NetworkUtils** (MD 4.2): `IsValidIPv4`, `IPToNumber` + `bit32.band` subnet math,
  `IsSameSubnet`, `GenerateRandomPublicIP`, `GenerateInternalIP`, `FormatCurrency`,
  `FormatWatts`, `FormatUptime`.
- **HardwareCatalog** (MD 4.3): rack 12U/24U, switch 8p/24p, router_edge, bm_starter,
  bm_enterprise, komponen build (chassis/mobo/cpu/ram/nvme/psu), `replacement_hdd`,
  cable spools.
- **WorldAndAssetBuilder** (MD 4.4): lighting `Future` + Bloom + ColorCorrection, room
  atmosferik, NOC desk 3 monitor, workbench, dock, AC unit, alarm beacon, factory model
  hardware lengkap (Chassis, grill, StatusLED, smoke `ParticleEmitter` overheat >=80°C,
  ConsolePort + ProximityPrompt, port parts + PortLED + ClickDetector, rack rails +
  USlot attachments + PDU_Strip), TechnicianLaptop tool (lid SurfaceGui mini-terminal,
  SerialPortAttachment) — semuanya prosedural, zero-setup.
- **NetworkGraph** (MD 4.5): `ConnectPorts` (Beam slack `CurveSize0/1 = -0.6`),
  `DisconnectPort`, BFS `CanReachIP`, broadcast storm detection, VLAN isolation,
  subnet/gateway routing. *Adaptasi: graph per-session pemain.*
- **CommandExecutor** (MD 4.6): CLI lengkap + RichText color. *Pemecahan fase di
  Section 6.*
- **Laptop Tool** (MD rule 3): Mode A serial console via ProximityPrompt + Beam biru +
  plug SFX + arm-typing pose, detach >18 studs; Mode B `Tool.Activated` → local shell →
  `ssh <ip>` via management bridge `192.168.1.254`.
- **PlacementSystem** (BARU): request dari client (tipe device, posisi, rotasi) →
  server validasi bounds/tabrakan/uang → deduct → spawn model (+ auto-cable fase 1).
- **RackAndCablingSystem** (MD 4.7): cabling dua-klik + wire cutter, carry & mount
  dari dock ke U-slot (cek `uSize` clearance), PDU power, hot-swap `replacement_hdd`.
- **WorkbenchBuilderSystem** (MD 4.7): urutan Chassis → Mobo → CPU → RAM → Storage →
  PSU, visual sub-parts, power on, `install-os`, `stress-test`, crate ke dock.
- **ShiftAndEconomyManager** (MD 4.8): fase 1 = payout VPS per 15 dtk - power live +
  thermal sim dasar; fase 3 = shift clock, uptime %, SLA bonus, settlement harian,
  reputasi.
- **ContractAndIncidentManager** (MD 4.8): fase 2 = pool kontrak 3 pilar + SLA timer;
  fase 3 = 4 jenis incident (Cable Fault, DDoS, Noisy Neighbor, Remote Hands Drive
  Failure) di jam sibuk 11:00–17:00.
- **DataPersistenceManager** (MD 4.8): DataStore `pcall`-guarded — cash, reputasi,
  shift day, rack, device ter-mount, config IP/VLAN, VM aktif; autosave + on-leave +
  `BindToClose`; + tombol reset (konfirmasi 2x klik).
- **Client UI** (MD 4.9): TerminalGui (`#0D1117`, RichText, RobotoMono, Tab complete,
  history, session bar), 3 monitor NOC (topology interaktif, ticket board, telemetry),
  Hardware Store + checklist workbench, AudioAndEffectsClient (fan hum, keyboard
  clicks, cable plug, klaxon, arm pose tween), HUD.

---

## 6. Roadmap fase

### Fase 1 — Inti (sesuai scope "inti dulu" yang disepakati)
Tujuan: loop dasar end-to-end bisa dimainkan.

- PlotBuilder per pemain + starter kit (router/switch/bare-metal ter-mount, kabel lepas)
- Atmosphere dasar: lighting Future + bloom, room, workbench, NOC desk, dock, AC,
  alarm beacon (visual semua; fungsi alarm nanti)
- Laptop Tool dual-mode + TerminalGui penuh (RichText, history, Tab complete,
  session bar)
- CLI fase 1: `help`, `clear`, `ping`, `traceroute`, `ip a`, `ip set`, `ssh`, `exit`,
  `top`, `vm create/list/delete`, `install-os`, `stress-test`
- NetworkGraph: port model + BFS + subnet/gateway + thermal sim dasar (stress-test
  butuh temperatureC); field VLAN ada (default 1, validasi VLAN aktif di fase 2)
- Auto-cable smart-port + Beam droop + LED status
- Hardware Store HUD + ghost placement freeform
- Workbench assembly + OS install + stress test + crate shipping (jual manual)
- Economy: mulai $2,500; payout VM per 15 dtk dikurangi power live
- DataPersistenceManager: autosave + on-leave + reset
- **Acceptance:** join → dapat lab + laptop → kabel console → `ip set` → `ping` WAN OK →
  `vm create` → income jalan → rakit server di bench → install OS → stress test →
  keluar-masuk game = state balik semua.

### Fase 2 — Colocation, VLAN & kontrak
- Manual cabling dua-klik + wire cutter + kabel color-coded; `switch port <id> vlan <id>`;
  routing lintar-VLAN via router
- Carry & mount dari dock ke U-slot, PDU power
- Pool kontrak CloudVPS + Colocation + CustomBuild dengan SLA; TicketMonitor penuh
- TopologyMonitor interaktif
- **Acceptance:** kontrak colo: terima crate → mount → VLAN match → reachable dari
  gateway → payout interval jalan.

### Fase 3 — Incident, shift, audio & polish
- Incident engine 4 jenis + AlarmBeacon aktif + SLA countdown (11:00–17:00)
- Shift clock 08:00–18:00, settlement harian, SLA bonus, reputasi
- Broadcast storm detection + flashing LED
- AudioAndEffectsClient penuh (fan hum spatial, keyboard clicks, cable plug, klaxon,
  arm-typing pose), smoke overheat, particle AC
- TelemetryMonitor gauge penuh, leaderboard, polish
- **Acceptance:** satu shift penuh jalan; semua jenis incident bisa ke-resolve.

---

## 7. Standar engineering (dari MD, wajib)

1. `--!strict` + `export type` di semua file Luau; zero `any` kecuali payload dinamis.
2. Server-authoritative: network graph, validasi CLI, SLA, ekonomi, persistence —
   semua di server; client cuma render + kirim request tervalidasi.
3. File 100% lengkap — no `-- TODO`, no stub.
4. Laptop tanpa baterai/upgrade.
5. Zero-setup: `WorldAndAssetBuilder` membangun seluruh dunia runtime
   (file `.rbxlx` jadi ringan; place kosong pun jalan).

---

## 8. Tooling & deliverable (VM instabox)

- Dikerjakan di **VM instabox**, folder kerja: `/data/workspace/netsim`.
- Validasi sintaks Luau typed per file (parser full-moon via `stylua` / review manual)
  sebelum digenerate.
- Output utama: **`NetworkSimulator.rbxlx`** — place siap dibuka Roblox Studio.
- Source `.luau` terpisah per modul tetap disertakan (bisa dipaste manual kalau mau).
- Hasil diambil dari VM: dashboard instabox → Files, atau scp.
