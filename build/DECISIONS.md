# DECISIONS.md — Keputusan koordinasi & resolusi kontrak (Fase 1)

Diisi koordinator saat integrasi. Sumber: laporan Agent A/B/C/D + keputusan koordinator.

## Perubahan kontrak (file shared/locked — dilakukan koordinator)

1. **HardwareCatalog**: `bm_starter` specs += `ports=1`, `bm_enterprise` += `ports=2` (permintaan Agent A). Tanpa ini, bare-metal starter tidak punya port fisik -> tidak bisa dikabel, objective `cableWired` mustahil. Fallback di NetworkGraph.MakePortsForItem (server kategori tanpa ports eksplisit -> 1 RJ45) tetap ada sebagai lapisan kedua.
2. **NetworkTypes.DeviceNode** += `loadPercent: number` (dipakai ShiftAndEconomyManager per kontrak; sebelumnya tidak ada di type).
3. **NetworkTypes.Session** += `tickets: {any}` (Section 4 kontrak menuntut `tickets={}` di CreateSession; type sebelumnya lupa).
4. **Remote `ContractActionRemote`** ditambahkan ke daftar REMOTE_DEFS WorldAndAssetBuilder (dikontrak Section 3, tapi daftar awal builder hanya 9; total kini 10).

## Binding remote — pemilik final

| Remote | Binder |
|---|---|
| ExecuteCommand (OnServerInvoke) | CommandExecutor (A) |
| PurchaseHardwareRemote | PlacementSystem (B) |
| CableActionRemote + OpenTerminalEvent (server-side: request_shell + disconnect_all) | RackAndCablingSystem (B) |
| WorkbenchRemote | WorkbenchBuilderSystem (B) |
| ContractActionRemote | ContractAndIncidentManager (C) |
| ResetDataRemote | MainServer (koordinator) |
| StateSyncRemote / PlaySFXRemote / TerminalPushOutput | FireClient only (C / B / A) |

Tidak ada double-binding; verifikasi via grep OnServerEvent/OnServerInvoke saat integrasi.

## Keputusan agent yang di-accept koordinator

- **A (Core)**: deteksi broadcast storm via non-tree-edge BFS (bukan re-enter switch) — akurat & bebas false-positive; error string "Network is unreachable" (publik) vs "Destination Host Unreachable" (privat); AutoCable pilih peer dengan tipe port kompatibel; OpenTerminalEvent {action="open"} juga di-fire saat ssh/exit agar bar terminal client sinkron; beam starter WAN di-parent ke model device saat facility.cables belum ada.
- **B (World/Physical)**: node.posX/posZ memakai **koordinat dunia absolut** (konsisten dengan restore path Agent C; draft lama campur absolut/relatif — bug diperbaiki); AutoCable di-skip saat loadedFromSave pada RegisterBenchNode (cegah kabel ganda saat restore); request_shell dijawab dengan mode terminal SAAT INI; Workbench Serialize/Ship men-sync wb.osInstalled dari node bench; "place" tanpa "prepare" ditoleransi (server tetap otoritatif); fan di-rotate via os.clock() kontinu.
- **C (Gameplay)**: `vmIpCounter` di-key per host deviceId + restore counter = maxOctet+1 (Agent A memakai keying sama — kompatibel); `workbench.ApplyState` dijalankan SEBELUM link pass saat Apply (bench_1 harus ada sebelum kabelnya direstore); smoke overheat aktif di >= 80C; tiket selesai tetap tampil 8 detik sebelum dibuang; rack-mounted non-starter tidak direstore (carry/mount Fase 2) — di-skip dengan aman.
- **D (Client)**: tombol "STORE [B]" di HudClient berkomunikasi dengan window store CatalogAndBuilderClient via BindableEvent client-only `NetSimToggleStore` (mencegah tombol dobel); TextBox terminal dinamai `InputBox` (kontrak dengan typing-blip AudioAndEffectsClient); rotasi garis topologi memakai `+math.deg(atan2(dy,dx))` (sumbu Y GUI ke bawah); konten dinamis NOC rebuild per snapshot, shell build-once (attribute guard).

## Keputusan koordinator saat integrasi

- MainServer binds HANYA ResetDataRemote; sisanya milik modul masing-masing.
- Init order: EnsureRemotes -> SetupLighting -> SessionManager -> NetworkGraph -> RackAndCabling -> Workbench -> Placement -> Economy -> Contracts -> Persistence -> CommandExecutor (karena Placement butuh Workbench+Flowcharts; CommandExecutor terakhir, butuh semua).
- Laptop tool di-clone ke StarterPack sekali di startup (respawn otomatis) + clone langsung ke Backpack saat join.
- CharacterAdded teleport ke facility.spawnCF (plot depan pintu) dengan delay 0.3s.
- Fan AC di-rotate dari satu koneksi Heartbeat di MainServer (bukan per-facility spawn loop).

## Fase 1 — eksklusi (terdokumentasi, dijadwalkan Fase 2/3)

VLAN commands, kabel spool manual color-coded, carry & rack-mount, hot-swap HDD,
incident engine (Cable Fault/DDoS/Noisy Neighbor/Drive Failure), shift clock +
SLA settlement, leaderboard. Struktur data (VLAN field, CableColorType, blockedIps,
dsb.) sudah ada di kontrak sehingga Fase 2/3 tidak perlu migrasi.
