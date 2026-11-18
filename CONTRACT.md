# CONTRACT — SysAdmin DC Simulator Fase 1 (BINDING FOR ALL AGENTS)

Version: 1.0 | Owner/coordinator: main session. All agents MUST conform exactly.
Specs: `/data/workspace/SPEC_GABUNGAN.md` (phases, decisions) and
`/data/workspace/roblox_sysadmin_full_production_spec.md` (technical detail).
Where this contract and the MD specs disagree, THIS CONTRACT WINS.

## 0. Environment & workflow

- VM access: `ssh -p 2222 ibssh_2mz2hybnizsew5qkeo55tizzee@ssh.instabox.sh`
- Work dir: `/data/workspace/netsim`
- Write files: create local temp file then `scp -P 2222 <local> <vm-path>`,
  or `ssh ... "cat > <path>" <<'LUAEOF' ... LUAEOF` (quoted delimiter, no expansion).
- Syntax validation (run after EVERY file you write):
  `/data/workspace/netsim/tools/luau-compile --binary <file.luau>` must exit 0.
  (Parses strict Luau incl. type annotations; no Roblox globals needed.)
- Rules: `--!strict` first line, 100% complete (NO TODO/stub), English comments,
  GUI strings may be Indonesian. Never modify a file you do not own.

## 1. File ownership map

| Path (under /data/workspace/netsim/src) | Owner |
|---|---|
| ReplicatedStorage/Shared/NetworkTypes.luau | COORDINATOR (locked) |
| ReplicatedStorage/Shared/NetworkUtils.luau | COORDINATOR (locked) |
| ReplicatedStorage/Shared/HardwareCatalog.luau | COORDINATOR (locked) |
| ReplicatedStorage/Shared/PlotConstants.luau | COORDINATOR (locked) |
| ReplicatedStorage/Shared/ModelFactory.luau | COORDINATOR (locked) |
| ServerScriptService/Core/SessionManager.luau | AGENT A |
| ServerScriptService/Core/NetworkGraph.luau | AGENT A |
| ServerScriptService/Core/CommandExecutor.luau | AGENT A |
| ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau | AGENT B |
| ServerScriptService/Physical/RackAndCablingSystem.luau | AGENT B |
| ServerScriptService/Physical/PlacementSystem.luau | AGENT B |
| ServerScriptService/Physical/WorkbenchBuilderSystem.luau | AGENT B |
| ServerScriptService/Gameplay/ShiftAndEconomyManager.luau | AGENT C |
| ServerScriptService/Gameplay/ContractAndIncidentManager.luau | AGENT C |
| ServerScriptService/Gameplay/DataPersistenceManager.luau | AGENT C |
| StarterPlayer/StarterPlayerScripts/TerminalClient.client.luau | AGENT D |
| StarterPlayer/StarterPlayerScripts/NOCMonitorClient.client.luau | AGENT D |
| StarterPlayer/StarterPlayerScripts/CatalogAndBuilderClient.client.luau | AGENT D |
| StarterPlayer/StarterPlayerScripts/HudClient.client.luau | AGENT D |
| StarterPlayer/StarterPlayerScripts/AudioAndEffectsClient.client.luau | AGENT D |
| ServerScriptService/MainServer.server.luau | COORDINATOR (written after A-D) |
| build/build_place.py, build/DECISIONS.md, build/QA_REPORT.md, tests/* | AGENT E |

Reference drafts (may study, may rewrite): `/data/workspace/netsim/reference_drafts/`.

## 2. Shared modules (locked contracts)

### PlotConstants
- `PLOT_POSITIONS: {Vector3}` (4 plots), `PLOT_COUNT`
- `ROOM = {halfX=32, halfZ=32, height=24, doorWidth=14, doorHeight=12, floorTopY=0.5, wallThickness=1}` (door on +Z side)
- `PLACEMENT_BOUNDS = {minX=-26,maxX=26,minZ=-26,maxZ=26}` (relative to plot center)
- `SNAP_GRID = 2`
- `FURNITURE_ZONES: { {name, position: Vector3, radius} }` (Rack/Workbench/NOCDesk/Dock/ISP)
- `RACK_POS=(-22,0,-20)`, `WORKBENCH_POS=(18,0,-12)`, `NOCDESK_POS=(18,0,16)`, `DOCK_POS=(0,0,-24)`, `ISP_POS=(-20,0,-28)`, `BEACON_OFFSET=(0,21,-6)`, `AC_OFFSET=(29,8,-10)`
- `STARTER`: ids `isp_uplink`, `isp_router_1` (U12, ip 192.168.1.1, gw 203.0.113.1, mask /24), `sw_main_1` (U10), `bm_starter_1` (U8)
- `LAPTOP_BRIDGE_IP = "192.168.1.254"`
- `ECONOMY = {startBalance=2500, startReputation=10, tickSeconds=5, payoutInterval=15, electricityPerWattPerTick=0.00015, vpsCpuRatePerPayout=0.15, vpsRamRatePerPayout=0.02, vpsDiskRatePerPayout=0.003}`
- `COLORS = {floor, wall, trim, lightPanel, ledGreen, ledYellow, ledRed, ledOff, consoleBlue}`

### NetworkTypes (type-only module, `return nil`)
Exports: PortType, CableColorType, VMStatus, DeviceType, TicketCategory, TicketStatus,
TerminalMode, PortData, VMData, DeviceSpecs, DeviceNode, RackData, ContractTicket,
TerminalSession, ActiveCable, ConsoleLink, WorkbenchState, DeviceSnapshot,
FacilitySnapshot, Session. Read the file for exact fields. KEY POINTS:
- `DeviceNode.freeform` (placed on floor) vs rack-mounted (`rackId`+`uSlot`).
- `Session.terminal = {mode: TerminalMode, targetDeviceId: string?, sshStack: {any}}`;
  sshStack entries are deviceId strings, sentinel `"__console__"` = return to console.
- `FacilitySnapshot.tickets` included (ContractAndIncidentManager fills it).

### NetworkUtils (pure; unit-testable)
`IsValidIPv4(ip)->bool` (no leading zeros, 0-255), `IPToNumber`, `NumberToIP`,
`MaskToPrefix`, `IsSameSubnet(a,b,mask)` (bit32.band), `IsPrivateIP(ip)` (10/127/172.16-31/192.168),
`GenerateRandomPublicIP()` (203.0.113.x), `GenerateInternalIP(index)` (10.0.0.x, clamp 2..254),
`FormatCurrency(n)` ($1,234 / -$12), `FormatWatts(w)`, `FormatUptime(sec)`, `EscapeRich(text)`.

### HardwareCatalog
`Items: {[id]: ItemDef}`; `Get(id)->ItemDef?`; `IsPlaceable(id)->bool` (Rack/Network/Server);
`ListByCategory(cat)->{ItemDef}` sorted by price; `StoreCategories = {"Rack","Network","Server","Component"}`.
Item ids: rack_12u(400), rack_24u(950), switch_8p(250), switch_24p(650), router_edge(500),
bm_starter(800: 8cpu/16ram/500disk/450W), bm_enterprise(2200: 32/128/2000/750W),
chassis_1u(150, ports=1), chassis_2u(220, ports=1), mobo_single(200: sockets=1,ramSlots=2,storageBays=2),
mobo_dual(450: sockets=2,ramSlots=4,storageBays=3), cpu_xeon8(300, cores=8), cpu_epyc32(850, cores=32),
ram_32g(120, ramGb=32), ram_128g(420, ramGb=128), nvme_1tb(140, storageGb=1000),
psu_redundant(180, powerWatts=750), replacement_hdd(90), cable_lan_blue/cable_wan_yellow/cable_mgmt_red(15).

### ModelFactory (shared geometry; server & client ghost)
- `BuildDeviceModel(itemId, deviceId) -> (model, ports{[portId]={portId,portType,part,attachment,led}}, consoleAttachment, statusLED Part, smoke ParticleEmitter)`
  Parts carry Attributes: model `DeviceId`,`ItemId`,`USize`; port parts `PortId`,`PortType`,`DeviceId`;
  port LEDs named `PortLED_<portId>`; console part named `ConsolePort` with child `ProximityPrompt`
  ("Connect Console Cable") + `ConsoleAttach` Attachment; status LED named `StatusLED`;
  smoke named `OverheatSmoke` (Enabled=false). Port ClickDetector named `Click`.
  Model pivot = bottom-center (`WorldPivot = CFrame.new(0,0,0)`), parent set by caller.
- `DeviceDimensions(itemId) -> (width, height, depth, uSize)`
- `ComputeFootprint(itemId) -> (halfX, halfZ)`
- `BuildRack(itemId, rackId) -> (model, slots{[u]: Attachment}, pduPart)` (PDU ClickDetector named `PDUClick`, LED `PDULed`; slots are front-face Attachments `USlot_<u>`; slot U1 = lowest)
- `BuildWorkbench() -> (model, snaps{[1..6]: Attachment}, powerSwitchPart, benchLedPart)` (switch ClickDetector `BenchPowerClick`)
- `BuildNOCDesk() -> (model, monitors{TopologyMonitor/TicketMonitor/TelemetryMonitor: Part})` (each part has `SurfaceGui` with empty `Root` Frame; Face=Front)
- `BuildDockPad() -> (model, crateLocalCF)`; `BuildISPUplink(deviceId) -> (model, wanAttachment, wanLed)`
- `BuildBeacon() -> (model, lens, pointLight)`; `BuildACUnit() -> (model, fanPart)`
- `BuildLaptop() -> Tool "TechnicianLaptop"` (Handle + Lid with SurfaceGui + `SerialPortAttachment`)
- `BuildCrate(label) -> model`; `BuildBenchComponentVisual(componentId) -> model`

## 3. Remote protocol (created by WorldAndAssetBuilder.EnsureRemotes)

Folder `ReplicatedStorage.Remotes`:
| Name | Class | Direction & payload |
|---|---|---|
| ExecuteCommand | RemoteFunction | client `InvokeServer(rawText)` -> `{lines = {string}}` (RichText allowed; single line `"__CLEAR__"` = clear buffer) |
| TerminalPushOutput | RemoteEvent | server->client `{lines = {string}}` (async command completion) |
| OpenTerminalEvent | RemoteEvent | server->client `{action="open", mode, deviceName, deviceId}` / `{action="detach"}` / `{action="hint", message}`; client->server `{action="request_shell"}` (laptop click) |
| CableActionRemote | RemoteEvent | client->server `{action="disconnect_all", deviceId}` (topology UI) |
| WorkbenchRemote | RemoteEvent | client->server `{action="register"}` (bench node register fallback) |
| ContractActionRemote | RemoteEvent | client->server `{action="accept", ticketId}` |
| PurchaseHardwareRemote | RemoteEvent | client->server `(itemId, action, cf?, rotY?)`; action: "prepare" | "place" | "cancel" (placeables), "buy" (components -> workbench) |
| StateSyncRemote | RemoteEvent | server->client `FacilitySnapshot` (every 5s) |
| PlaySFXRemote | RemoteEvent | server->client `name: string` ("plug"|"key"|"error"|"cash") |
| ResetDataRemote | RemoteEvent | client->server `()` (wipe save + rebuild session; confirm handled client-side) |

## 4. Session table (SessionManager.CreateSession must include ALL)

player, plotIndex, balance, reputation, day, terminal, devices{}, deviceModels{},
racks{}, rackModels{}, cables{}, pendingCableDeviceId, pendingCablePortId,
pendingCableHighlight, consoleLink, pendingPlacementItemId,
workbench (all WorkbenchState fields incl. cpuCores=0, snapIndex=nil, benchModel=nil,
lastCpuId=nil, lastRamId=nil), facility{}, flags{}, hookedDevices{}, vmIpCounter{},
cableCounter=0, deviceCounter=0, broadcastStorm=false, loadedFromSave=false,
noSaveWarned=false, tickets{}.

## 5. Facility refs (WorldAndAssetBuilder.BuildFacility(session) return)

Keys: root (Model "Plot<n>", parented under workspace.Plots), facility (Folder),
devices (Folder "Devices"), cables (Folder "Cables"), crates (Folder "Crates"),
rackModel, rackSlots {[u]: Attachment}, pduPart, pduParts {[rackId]: pduPart},
workbenchModel, benchSnaps, benchSwitch, benchLed, nocMonitors {[name]: Part},
dockCF (CFrame for crate spawn), beaconLens, beaconLight, fan, spawnCF, ispWanLed.

Build order inside BuildFacility: room geometry (floor slab top y=0.5, walls with
front door opening, ceiling, 6 light panels + SurfaceLight) -> rack_12u "rack_main_1"
(pduPowered=true) -> ISP uplink node (Router, isPowered=true, ports={wan1: WAN}) ->
mount starter devices at U12/U10/U8 (isPowered=true; router ip/gateway/mask from
PlotConstants; occupy occupiedSlots incl. uSize range; rack.totalPowerWatts += watts)
-> ConnectPorts("isp_router_1","wan1","isp_uplink","wan1","WAN_Yellow") ONLY
(switch & bare-metal stay UNWIRED - player wires them; that is the first objective)
-> workbench, NOC desk, dock, beacon, AC unit (register fan) -> sign billboard
("SERVER LAB #n | <DisplayName>") -> session.facility = refs -> root.Parent = EnsurePlotsFolder().

## 6. Server module API (exact signatures each agent implements)

### AGENT A — SessionManager
- `Init(deps: {constants})`
- `GetSession(player) -> session?`; `GetAllSessions() -> {[Player]: session}`
- `ClaimNextPlot() -> number?`; `CreateSession(player, plotIndex) -> session`; `DeleteSession(player)` (destroy facility root + console beam, release plot)
- `NextDeviceId(session, prefix) -> string` ("prefix_N"); `NextCableId(session) -> string` ("cbl_N")

### AGENT A — NetworkGraph
- `Init(deps)` (may ignore deps; require shared modules directly)
- `MakePortsForItem(itemId) -> {[string]: PortData}`; `DefaultNode(id, name, itemId) -> DeviceNode`
- `RegisterDevice(session, node, model?)`; `RemoveDevice(session, deviceId)`
- `UpdateDeviceLED(session, deviceId)` (StatusLED green/red; port LEDs green when linkUp else ledOff)
- `ConnectPorts(session, devAId, portAId, devBId, portBId, color) -> (bool, err)` — validates: devices/ports exist, not same device, not Console, both free, type-compatible (WAN-WAN, RJ45-RJ45, SFP-SFP, RJ45<->SFP); sets both sides linkUp; creates Beam (CurveSize0/1=-0.6, FaceCamera, Width 0.12, color per type) parented to session.facility.cables; registers session.cables[cableId]
- `DisconnectPort(session, deviceId, portId) -> bool` (severs both ends, destroys beam)
- `FindDeviceByIP(session, ip)`; `IsIPUsedByOther(session, ip, exceptId) -> bool`
- `CanReachIP(session, sourceDeviceId, targetIP) -> (reachable, latencyMs, err)` — BFS over linkUp edges; skips unpowered intermediate devices; VLAN isolation when passing through a Switch (in-port vlan == out-port vlan); sourceDeviceId=="__laptop__" = management bridge (any powered device with ip reachable, public IPs reachable, latency 2-6/12-25ms); public target = reach isp_uplink; ping to self = 0.1ms; unpowered source/target -> "Destination Host Unreachable (device mati)"; loop detection sets session.broadcastStorm -> "Request timed out (packet loss 95% - broadcast storm)"
- `GetRoutePath(session, sourceDeviceId, targetIP) -> {string}?` (BFS path incl. endpoints)
- `AutoCable(session, deviceId)` — nearest device (<=60 studs) with free non-Console port, else "sw_main_1"; skip isp_uplink

### AGENT A — CommandExecutor
- `Init(deps: {sessions, graph, utils, catalog, constants, workbench, cabling, remotesFolder})`; binds ExecuteCommand.OnServerInvoke
- Tokenize: raw<=240 chars, split whitespace, lowercase command; escape user strings with utils.EscapeRich before embedding in RichText
- Terminal context: mode Disconnected -> source "__laptop__"; LocalConsole/RemoteSSH -> session.terminal.targetDeviceId (nil -> error "Not connected")
- Commands (exact): `help` (grouped list), `clear`, `ping <ip>` (4 ICMP lines w/ jitter, or authentic errors), `traceroute <ip>` (hop list " 1  name (ip)  x.xx ms"; no route -> "traceroute: no route to host"), `ip a`/`ip addr` (hostname/ip/mask/gateway/vlan/temp + port table ethN/wanN/sfpN with UP-DOWN + peer), `ip set <ip> <gateway> [mask]` (IPv4 valid; gateway same subnet check via IsSameSubnet -> "Gateway not in subnet"; conflict via graph.IsIPUsedByOther -> "IP conflict"; requires LocalConsole/RemoteSSH), `ssh <ip>` (Disconnected: device exists+powered+has ip; else graph.CanReachIP from context; push sshStack, RemoteSSH; from LocalConsole push "__console__"), `exit` (pop sshStack / "__console__" back to LocalConsole / detach console via cabling.DetachConsole), `top` (cpu/ram used %, temp, per-VM table), `vm create --name <n> --cpu <n> --ram <n> --disk <n>` (BareMetal + osInstalled + powered + capacity check + unique sanitized name [alnum-_] <=16 + ip via utils.GenerateInternalIP(vmIpCounter)), `vm list`, `vm throttle <name> --limit <pct>` (5..100; status "throttled"), `vm delete <name>`, `install-os <ubuntu-22.04|debian-12|rocky-9>` (BareMetal, not installing; return "installing..." lines; after 3s task.delay set osInstalled, push completion via TerminalPushOutput; guard session still exists), `stress-test` (BareMetal + osInstalled; 5s; temp = 30 + 95*0.45 < 80 pass; if device is bench set workbench.tested=true; push result lines; success SFX "cash")
- Successful ping from starter bare-metal to 192.168.1.1 sets session.flags.pingGateway=true

### AGENT B — WorldAndAssetBuilder
- `EnsureRemotes() -> Folder` (exact 10 remotes incl. ContractActionRemote; idempotent)
- `SetupLighting()` (Technology Future, Brightness 1.5, Ambient (25,30,40), OutdoorAmbient (20,25,35), BloomEffect DCBloom 0.4/16/1.1, ColorCorrectionEffect DCColor 0.02/0.08/0.05)
- `EnsurePlotsFolder() -> Folder`; `UpdateFans(dt)`; `ClearFansOfRoot(root)`
- `BuildFacility(session) -> facility refs` (see Section 5; uses PlotConstants positions; all parts anchored; door on +Z)
- `DestroyFacility(session)`; `GetCatalog()`

### AGENT B — RackAndCablingSystem
- `Init(deps: {sessions, graph, remotesFolder})`
- `HandlePortClick(player, session, deviceId, portId)` — connected port -> DisconnectPort + "plug"; empty port -> two-click pending (SelectionBox yellow 15s timeout; second click -> ConnectPorts "LAN_Blue" + "plug"/"error"; same port -> cancel)
- `AttachConsole(player, session, deviceId)` — requires equipped "TechnicianLaptop" (character child) else hint via OpenTerminalEvent; toggles; Beam blue from laptop SerialPortAttachment to device ConsoleAttach; sets session.terminal LocalConsole + targetDeviceId; OpenTerminalEvent {action="open",...}
- `DetachConsole(session, player?, notify)` — destroy beam, mode Disconnected, sshStack={}; notify -> OpenTerminalEvent {action="detach"}
- `HookDevice(session, deviceId)` — once per device (session.hookedDevices): port ClickDetectors -> HandlePortClick; console ProximityPrompt -> AttachConsole; freeform devices get "PowerPrompt" ProximityPrompt on Chassis (HoldDuration 0.4, toggles isPowered + LED + SFX)
- `HookFacility(session)` — iterate facility.pduParts (guard ClickDetector attribute "Hooked"): toggle rack.pduPowered, set rack-mounted devices isPowered, PDULed color, SFX
- `Update(session)` — console cable distance >18 studs -> DetachConsole(notify=true)
- Also binds CableActionRemote.OnServerEvent: `{action="disconnect_all", deviceId}` -> disconnect every connected port of that device (validate session ownership)

### AGENT B — PlacementSystem
- `Init(deps: {sessions, graph, catalog, constants, modelFactory, workbench, cabling, remotesFolder})`; binds PurchaseHardwareRemote
- `ValidatePlacement(session, itemId, cf) -> (bool, reason, snappedCF)` — snap 2-grid, bounds, furniture zones (radius + max(halfX,halfZ)), freeform device overlap (sum halves + 0.5), y forced floorTopY
- `PlaceDevice(session, itemId, snappedCF, rotY, config?) -> id` — Rack: BuildRack + session.racks[id] (pduPowered=false) + facility.pduParts + cabling.HookFacility; else BuildDeviceModel + DefaultNode (freeform=true, posX/posZ/rotY) + RegisterDevice + AutoCable (skipped when session.loadedFromSave) + cabling.HookDevice; apply config (ip/gateway/subnetMask/osInstalled/isPowered/vms) when present
- `OnPurchase(player, itemId, action, cf, rotY)` — Cable category -> hint "Fase 2"; Component -> workbench.TryInstall; "prepare" -> balance check + pendingPlacementItemId; "place" -> ValidatePlacement + balance deduct + PlaceDevice + "cash" SFX + clear pending; "cancel" -> clear pending

### AGENT B — WorkbenchBuilderSystem
- `Init(deps: {sessions, graph, catalog, constants, modelFactory, cabling, remotesFolder})`; binds WorkbenchRemote ("register")
- `HookBenchSwitch(session)` (guard attribute; toggles workbench.powered, benchLed color, EnsureBenchNode/RegisterBenchNode, node.isPowered sync, SFX)
- `TryInstall(player, session, itemId)` — component only; near bench (<=16 studs of workbenchModel pivot); order: chassis -> mobo -> cpu* (cpuCount<cpuSockets) -> ram* (ramSlots) -> storage* (storageBays) -> psu; deduct price + totalSpent; chassis -> build bench device model via modelFactory.BuildDeviceModel(chassisId,"bench_1") at workbenchModel pivot * CFrame.new(0,3.5,0) (deviceId reserved, NOT registered yet); other components -> visual model attached relative bench (parent facility.devices); update node specs when registered; psu + powered -> RegisterBenchNode; hints + SFX on every path
- `RegisterBenchNode(session)` / `EnsureBenchNode(session)` — when chassis+mobo+psu present: DefaultNode("bench_1","Custom Server (<chassis>)",chassis), specs from components (cpu=cpuCores, ram=ramGb, disk=storageGb, powerWatts=psu), osInstalled sync, isPowered=wb.powered, RegisterDevice + HookDevice + AutoCable if powered
- `Ship(session) -> (bool, msg)` — requires complete+osInstalled+tested+not shipped; payout floor(totalSpent*0.3)+100; crate BuildCrate at facility.dockCF (despawn 20s); "cash" SFX; wb.shipped=true
- `ApplyState(session, data)` / `Serialize(session) -> table` (persistence; visuals list rebuilt; RegisterBenchNode when powered+complete)

### AGENT C — ShiftAndEconomyManager
- `Init(deps: {sessions, graph, constants, remotesFolder, cabling})`
- `Start()` — loop every ECONOMY.tickSeconds (5s) over sessions: VM load jitter (running: smoothed random 35..95, capped by cpuThrottlePercent; throttled status when capped), device loadPercent = sum(vm.cpu*load/100)/specs.cpu*100 (0 if specs.cpu==0), tempC = 30 + loadPercent*0.45 (rise; >80 -> smoke Enabled), power cost per tick (sum powered device powerWatts + 40W per pduPowered rack; balance -= watts*electricityPerWattPerTick, clamp >= 0), payout every 15s (counter): per VM on powered host with ip set: (cpu*0.15+ram*0.02+disk*0.003); uptimePercent = producing/total VMs (100 if none); cabling.Update(session); BuildSnapshot -> StateSyncRemote:FireClient
- `BuildSnapshot(session) -> FacilitySnapshot` (see type; devices incl. isp_uplink; peers = connected device names; objectives keys below; tickets from session.tickets)
- `ForceSync(session)` (immediate snapshot)
- Objective keys (booleans computed live): cableWired (bm_starter_1 has any connected RJ45), ipSetStarter (bm_starter_1.ip ~= nil), osInstalledStarter, pingGateway (flags.pingGateway), vmCreated (any vm), benchBuilt (workbench.psu ~= nil), benchOsInstalled (bench node osInstalled ~= nil), stressPassed (workbench.tested), shipped (workbench.shipped)

### AGENT C — ContractAndIncidentManager (Fase 1 scope: CloudVPS + CustomBuild tickets; NO incidents - fase 3)
- `Init(deps: {sessions, graph, constants, remotesFolder, workbench})`; binds ContractActionRemote ("accept": available ticket -> active, max 2 active)
- `Start()` loop 10s: keep up to 3 Available tickets per session (alternate CloudVPS / CustomBuild, random specs/client names); validate Active tickets each pass: CloudVPS done when any BareMetal (osInstalled, powered) hosts a VM with cpu>=req.cpu and ram>=req.ram and disk>=req.disk; CustomBuild done when workbench.shipped; on completion: balance += rewardPayout, reputation += 1, status Completed (remove from list after sync), SFX "cash"
- Tickets stored in session.tickets (array of ContractTicket-like tables); snapshot.tickets = {id, category, title, description, rewardPayout, status, requirementsText}

### AGENT C — DataPersistenceManager
- `Init(deps: {sessions, graph, constants, placement, workbench, remotesFolder})`
- `Load(player) -> table?` (DataStore "NetSimDC_v1", key "lab_"..UserId; pcall; nil on failure + one-time warning)
- `Save(session)` (serialize: balance, reputation, devices (all except isp_uplink: id,itemId,freeform,posX,posZ,rotY,rackId,uSlot,ip,gateway,subnetMask,osInstalled,isPowered,ports {[portId]={peer,peerPort,color}} for connected only, vms list; skip bench_1 model data - workbench covers it), workbench = workbench.Serialize(session), tickets (active only))
- `Apply(session, data)` — set loadedFromSave=true first; balance/rep; starter device config (bm_starter_1 ip/os/vms etc.); placed devices via placement.PlaceDevice(session, itemId, CFrame.new(pos), rotY, config); link pass (ConnectPorts for each recorded peer, dedupe by sorted pair key); workbench.ApplyState; tickets restore; ForceSync
- `WipeSave(player)` (RemoveAsync pcall); `SaveAll()`; `Start()` (autosave loop 120s)
- Reset flow: MainServer receives ResetDataRemote -> Persistence.WipeSave -> MainServer rebuilds session (document in code comment)

## 7. Client UI requirements (AGENT D, all LocalScripts under StarterPlayerScripts)

Shared: player:WaitForChild("PlayerGui"); ScreenGui ResetOnSpawn=false; Dark theme
(#0D1117 background, #00FF66/#58A6FF/#FF5555 accents, GothamBold/Gotham/RobotoMono);
listen StateSyncRemote snapshot; guard plot existence (workspace.Plots may lag).

- **TerminalClient**: window 560x340 center-right; top bar shows `[LOCAL SHELL]` /
  `[CONSOLE: <name>]` / `[SSH: <ip|name>]` per session mode (OpenTerminalEvent open/detach);
  output = ScrollingFrame + RichText TextLabel (AutomaticSize Y, Wrapped); input TextBox
  bottom (PlaceholderText "type help"); Enter (FocusLost enterPressed) -> InvokeServer;
  "__CLEAR__" clears; TerminalPushOutput appends; Up/Down history (UIS.InputBegan,
  works while TextBox focused by overriding Text); Tab autocomplete from local command
  list; X close button; laptop Tool.Activated (hook character ChildAdded for
  "TechnicianLaptop") -> OpenTerminalEvent:FireServer({action="request_shell"}).
  Server must respond request_shell -> FireClient open with mode "Disconnected".
- **NOCMonitorClient**: find own plot monitors via workspace.Plots["Plot"..snapshot.plotIndex]
  (descendant Parts named TopologyMonitor/TicketMonitor/TelemetryMonitor with SurfaceGui.Root);
  build content once (attribute guard), update on snapshot. Topology: node cards
  (Router/ISP top row, Switches middle, Servers bottom) + edge lines (thin rotated Frames,
  midpoint + atan2 rotation) colored by powered state; TextButton node -> info popup +
  "Disconnect all cables" button -> CableActionRemote:FireServer({action="disconnect_all", deviceId=...}).
  TicketMonitor: tickets list (Available w/ Accept button -> ContractActionRemote {action="accept", ticketId}; Active w/ reward) + objectives checklist (labels below, checkbox o/x). TelemetryMonitor: Balance, Reputation, Uptime %, Power W, Avg Temp, Day+clock, storm banner when snapshot.storm.
- **CatalogAndBuilderClient**: key B (UIS.InputBegan, gameProcessed false) + on-screen
  button toggles store window; categories Rack/Network/Server/Component via
  HardwareCatalog (client require shared OK); item rows (name/price/spec short + Buy);
  placeable Buy -> FireServer(itemId,"prepare") + ghost mode: ModelFactory.BuildDeviceModel
  or BuildRack (id "ghost"), tint all parts (green valid / red invalid, transparency .5,
  CanCollide/CanQuery/CanTouch false), RenderStepped mouse raycast (player:GetMouse(),
  TargetFilter=ghost, snap + local validation mirroring ValidatePlacement incl.
  PlotConstants), R rotate 90, LMB -> FireServer(itemId,"place",snappedCF,rotY), RMB/Esc
  -> "cancel"; component Buy -> FireServer(itemId,"buy"); cable items disabled "Fase 2";
  right panel = build guide checklist (Chassis -> Mobo -> CPU -> RAM -> Storage -> PSU,
  then install-os + stress-test + ship via terminal/bench).
- **HudClient**: top-right panel (Balance, Reputation, Uptime %, Power, Avg Temp, Day clock);
  hint label (listens OpenTerminalEvent hint + rotating tips); "Store [B]" button;
  Reset button (2-click confirm, 4s window) -> ResetDataRemote:FireServer().
- **AudioAndEffectsClient**: prebuild Sounds in SoundService (rbxasset://sounds/snap.mp3
  for plug, rbxasset://sounds/electronicpingshort.wav for key (pitch 1.6) / error (0.6) /
  cash (1.2)); PlaySFXRemote.OnClientEvent(name) -> play; typing blip on terminal input
  text change (throttle 80ms).

## 8. Cross-cutting rules

- Server-authoritative: client NEVER mutates state; all mutations via server handlers above.
- Anchored parts everywhere except laptop tool handle assembly.
- Beam/Cable visuals parented to session.facility.cables.
- Use task.wait/task.spawn/task.delay (no legacy wait/spawn).
- pcall DataStore access; never let DataStore failure break the session.
- Player isolation: every handler verifies sessions.GetSession(player) and ownership
  (devices/cables belong to that session only).
- No per-frame server work except Economy tick (5s) and fan rotation (Heartbeat in MainServer).

## 9. Fase 1 scope exclusions (do NOT implement)

VLAN commands (`switch port ... vlan ...`), manual color-coded cable spools purchase,
carry/rack-mount from dock, hot-swap HDD, incidents (Cable Fault/DDoS/Noisy Neighbor/
Drive Failure), shift clock day settlement, SLA timers, broadcast storm LED flashing
(flag+message only). Structure may reference them in comments only.
