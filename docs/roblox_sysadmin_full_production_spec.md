# Roblox SysAdmin & Cloud Data Center Simulator — Full-Depth Production Engineering Specification

## 1. System Role & Architectural Vision
Act as a Principal Roblox Luau Systems Architect, Network Simulation Engineer, Procedural 3D Artist, and UI/UX Designer. Build a **complete, feature-rich, production-grade, and immediately playable codebase** for a Roblox **SysAdmin & Cloud Data Center Simulator** (inspired by AWS EC2, Equinix Colocation facilities, and PC Building Simulator).

The player acts as the **Lead SysAdmin & Infrastructure Operator** running a growing data center across three intertwined business pillars:
1. **Cloud Hosting / VPS (AWS EC2 style):** Partitioning physical Bare-Metal hosts into virtualized VPS instances via CLI commands, managing resource contention, and defending against DDoS attacks.
2. **Server Colocation:** Mounting client-owned physical servers into rack slots (`U`), wiring power and color-coded network cables, configuring isolated VLAN/IP routing, and performing physical "Remote Hands" hardware swaps.
3. **Custom Server Builder:** Assembling server hardware components step-by-step on an Assembly Workbench, booting via serial console to install an OS and run thermal burn-in stress tests, and shipping orders via the Loading Dock.

> **Zero-Setup Playability Mandate:** When placed into an empty Roblox Studio Baseplate and executed, the `WorldAndAssetBuilder` bootstrapper must procedurally construct the entire 3D Data Center Facility, atmospheric `Future` lighting, NOC Desk with 3 interactive `SurfaceGui` screens, Assembly Workbench, Loading Dock, 12U Server Rack, ISP Gateway Router, Gigabit Switch, Starter Bare-Metal Server, procedural sound effects, and equip the player with the Technician `Laptop` Tool—requiring zero manual part building in Studio.

---

## 2. Strict Engineering Rules & Constraints
1. **Language & Typing:** Strict Luau (`--!strict`) across all scripts. Use explicit `export type` definitions and zero `any` types unless strictly required for dynamic dictionary payloads.
2. **Server-Authoritative Security:** All network graph state, IP/subnet/VLAN validation, CLI command parsing, contract SLA timers, incident triggers, DataStore persistence, and currency/reputation balances MUST execute exclusively on the Server (`ServerScriptService`). Clients only render UI, local visual/audio feedback, and fire validated Remote requests.
3. **Technician Laptop Tool Specification:**
   - The `Laptop` Tool in the player's hotbar is always ready to use. **DO NOT implement battery drain, charging stations, or laptop tier/upgrade mechanics.**
   - **Dual Connection Modes:**
     - **Mode A — Local Serial Console (Physical Proximity):** Equipping `Laptop` and triggering a `ProximityPrompt` (`ActionText = "Connect Console Cable"`) on any Server or Switch attaches a glowing blue `Beam` from `Laptop.SerialPortAttachment` to `Device.ConsolePortAttachment`, plays a cable-plug SFX, plays a custom/procedural typing pose on the character's arms, and opens `TerminalGui` in `LocalConsole` mode bound directly to that `DeviceId` (bypasses IP/network requirements; essential for unconfigured hardware or dead links). Moving >18 studs away automatically detaches the console cable and reverts the session to `Disconnected`.
     - **Mode B — Wireless Remote SSH (Anywhere):** Equipping `Laptop` and activating it (`Tool.Activated` / Left Click) without targeting a console prompt opens `TerminalGui` in `Disconnected` (Local Laptop Shell) mode, allowing `ssh <ip>` to connect remotely to any device reachable via the network graph.
4. **Zero Placeholders:** Every single file must be 100% complete, bug-free, and copy-paste-ready. Never use `-- TODO`, `...`, or stubbed functions.

---

## 3. Complete Project Hierarchy

```text
ReplicatedStorage/
├── Shared/
│   ├── NetworkTypes.luau
│   ├── HardwareCatalog.luau
│   └── NetworkUtils.luau
└── Remotes/ (Auto-generated at runtime by WorldAndAssetBuilder)
    ├── ExecuteCommand (RemoteFunction)
    ├── TerminalPushOutput (RemoteEvent)
    ├── OpenTerminalEvent (RemoteEvent)
    ├── CableActionRemote (RemoteEvent)
    ├── RackMountRemote (RemoteEvent)
    ├── WorkbenchRemote (RemoteEvent)
    ├── ContractActionRemote (RemoteEvent)
    ├── PurchaseHardwareRemote (RemoteEvent)
    ├── StateSyncRemote (RemoteEvent)
    └── PlaySFXRemote (RemoteEvent)

ServerScriptService/
├── MainServer.server.luau
├── Bootstrap/
│   └── WorldAndAssetBuilder.luau
├── Core/
│   ├── NetworkGraph.luau
│   └── CommandExecutor.luau
├── Physical/
│   ├── RackAndCablingSystem.luau
│   └── WorkbenchBuilderSystem.luau
└── Gameplay/
    ├── ShiftAndEconomyManager.luau
    ├── ContractAndIncidentManager.luau
    └── DataPersistenceManager.luau

StarterPlayer/
└── StarterPlayerScripts/
    ├── TerminalClient.client.luau
    ├── NOCMonitorClient.client.luau
    ├── CatalogAndBuilderClient.client.luau
    └── AudioAndEffectsClient.client.luau
```

---

## 4. Exhaustive Module-by-Module Engineering Specifications

### 4.1 `ReplicatedStorage/Shared/NetworkTypes.luau`
Define and export strict Luau types:
- `PortType`: `"WAN" | "RJ45" | "SFP" | "Console"`
- `CableColorType`: `"LAN_Blue" | "WAN_Yellow" | "Mgmt_Red"`
- `PortData`: `{ portId: string, portType: PortType, connectedToDeviceId: string?, connectedToPortId: string?, cableColor: CableColorType?, linkUp: boolean, vlanId: number, trafficLoadMbps: number }`
- `VMData`: `{ name: string, cpu: number, ram: number, disk: number, assignedIp: string?, cpuThrottlePercent: number, currentLoadPercent: number, status: "running" | "throttled" | "stopped" }`
- `DeviceType`: `"Router" | "Switch" | "BareMetal" | "ColocationServer"`
- `DeviceNode`: `{ id: string, name: string, deviceType: DeviceType, rackId: string?, uSlot: number?, uSize: number, ip: string?, gateway: string?, subnetMask: string, defaultVlan: number, ports: { [string]: PortData }, specs: { cpu: number, ram: number, disk: number, powerWatts: number }, vms: { [string]: VMData }, blockedIps: { [string]: boolean }, osInstalled: string?, isPowered: boolean, temperatureC: number, hasDegradedDrive: boolean, degradedBayIndex: number?, isUnderDDoS: boolean, ddosAttackerIp: string? }`
- `RackData`: `{ rackId: string, name: string, maxU: number, occupiedSlots: { [number]: string }, totalPowerWatts: number, maxPowerWatts: number, pduPowered: boolean }`
- `TicketCategory`: `"CloudVPS" | "Colocation" | "CustomBuild" | "Incident"`
- `ContractTicket`: `{ id: string, category: TicketCategory, clientName: string, title: string, description: string, requirements: { [string]: any }, rewardPayout: number, payoutIntervalSec: number?, slaRemainingSec: number?, targetDeviceId: string?, targetRackId: string?, targetUSlot: number?, status: "Available" | "Active" | "Completed" | "Failed" }`
- `PlayerSession`: `{ mode: "Disconnected" | "LocalConsole" | "RemoteSSH", targetDeviceId: string?, sshStack: { string } }`
- `FacilityStateSnapshot`: Complete serializable table broadcast via `StateSyncRemote` to drive NOC monitors and HUDs.

### 4.2 `ReplicatedStorage/Shared/NetworkUtils.luau`
Pure, deterministic networking utilities:
- `IsValidIPv4(ip: string): boolean`: Strictly validates 4 dot-separated octets (`0–255`), rejecting leading/trailing whitespace or non-numeric characters.
- `IPToNumber(ip: string): number` & `IsSameSubnet(ipA: string, ipB: string, mask: string): boolean`: Bitwise `bit32.band` comparison of 32-bit IPv4 integers against subnet mask so misconfigured masks (`/24` vs `/16`) produce authentic routing failures.
- `GenerateRandomPublicIP(): string` & `GenerateInternalIP(index: number): string`.
- `FormatCurrency(amount: number): string`, `FormatWatts(watts: number): string`, `FormatUptime(seconds: number): string`.

### 4.3 `ReplicatedStorage/Shared/HardwareCatalog.luau`
Comprehensive catalog dictionary with `id`, `name`, `category` (`"Rack" | "Network" | "Server" | "Component" | "Cable"`), `price`, `uSize`, `specs`, `visualColor`, and `description`:
- **Racks:** `rack_12u` ($400, 12U, 3000W PDU), `rack_24u` ($950, 24U, 6000W PDU).
- **Networking:** `switch_8p` ($250, 1U, 8x RJ45), `switch_24p` ($650, 1U, 24x RJ45 + 2x SFP), `router_edge` ($500, 1U, 2x WAN + 4x RJ45).
- **Bare-Metal Hosts:** `bm_starter` ($800, 2U, 8 vCPU / 16GB RAM / 500GB Disk / 450W), `bm_enterprise` ($2,200, 2U, 32 vCPU / 128GB RAM / 2TB Disk / 750W).
- **Custom Build Components:** `chassis_1u` ($150), `chassis_2u` ($220), `mobo_single` ($200), `mobo_dual` ($450), `cpu_xeon8` ($300), `cpu_epyc32` ($850), `ram_32g` ($120), `ram_128g` ($420), `nvme_1tb` ($140), `psu_redundant` ($180), `replacement_hdd` ($90, for Remote Hands drive swaps).
- **Cable Spools:** `cable_lan_blue` ($15), `cable_wan_yellow` ($15), `cable_mgmt_red` ($15).

### 4.4 `ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau`
Procedurally construct a visually atmospheric, detailed 3D Data Center environment:
- **Lighting & Atmosphere:** Configure `Lighting` (`Technology = Enum.Technology.Future`, `Brightness = 1.5`, `Ambient = Color3.fromRGB(25, 30, 40)`, `OutdoorAmbient = Color3.fromRGB(20, 25, 35)`), add `BloomEffect` (`Intensity = 0.4`, `Size = 16`, `Threshold = 1.1`) and `ColorCorrectionEffect` for crisp LED glow.
- **Room Architecture (`Workspace.DataCenterWorld`):**
  - `64 x 24 x 64` studs enclosed facility: dark reflective server-room floor tiles (`Metal` / `SmoothPlastic`), concrete walls with industrial trim, ceiling LED light panels (`SurfaceLight`), a humming `AC_Unit` with rotating fan blades and cold-air `ParticleEmitter`, a glowing green `LoadingDock` zone (`12 x 0.2 x 12`), an `AssemblyWorkbench` (`10 x 3.5 x 5`) with 6 sequential snap-point `Attachments` and a bench power switch, and a `NOCDesk` (`14 x 3.5 x 5`).
- **NOC Desk & Alarm Beacon:**
  - Construct 3 angled widescreen monitors on `NOCDesk` (`TopologyMonitor`, `TicketMonitor`, `TelemetryMonitor`), each fitted with a high-DPI `SurfaceGui` (`SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud`, `PixelsPerStud = 60`).
  - Construct `AlarmBeacon` mounted above the server aisle with a spinning `Neon` red lens and `PointLight` that activates during SLA incidents.
- **Detailed Hardware Model Factories:**
  - Every rackable model features a brushed-metal `Chassis`, ventilation grill decal/stripes, a `StatusLED` (`Neon` green/yellow/red), an overheat smoke `ParticleEmitter` (`Enabled = false`, activates when `temperatureC >= 80`), a glowing blue `ConsolePort` Part (`Attachment` + `ProximityPrompt` `"Connect Console Cable"`), and individual protruding RJ45/SFP port Parts (`Port_1`..`Port_N`) each containing an `Attachment`, a micro `PortLED` part, and a `ClickDetector`.
  - `Rack_12U` / `Rack_24U`: Vertical steel posts with numbered `USlot_1`..`USlot_N` `Attachments`, side rails, and a rear `PDU_Strip` with a `ClickDetector` for rack power control.
  - **Initial Starter Room State:** Spawn `Rack_12U` (`rack_main_1`), pre-mount `ISP_Gateway_Router` (`192.168.1.1/24`, WAN uplink active) at `U12`, and pre-mount one `Switch_8P` at `U10` and one `BareMetal_Starter` at `U8` (unconfigured IP, cables disconnected so the player immediately experiences wiring and configuring their first server).
  - **`TechnicianLaptop` Tool:** Construct a sleek 3D `Tool` (dark matte chassis, glowing keyboard trim, angled lid with live `SurfaceGui` miniature terminal screen, and `SerialPortAttachment`) placed in `StarterPack` and given to players on spawn.

### 4.5 `ServerScriptService/Core/NetworkGraph.luau`
- Authoritative state store for `Devices`, `Racks`, and `ActiveCables`.
- **`ConnectPorts(devA, portA, devB, portB, cableColor)`**: Validates ports are free, non-console, and devices exist; links both ends (`linkUp = true`); spawns color-coded 3D `Beam` with realistic slack (`CurveSize0 = -0.6, CurveSize1 = -0.6`); updates port LEDs to bright green; triggers `StateSyncRemote`.
- **`DisconnectPort(devA, portA)`**: Cleanly severs both ends, destroys the 3D `Beam`, sets port LEDs to dark/red, and updates state.
- **`CanReachIP(sourceDeviceId: string, targetIP: string)`**:
  - Executes a **Breadth-First Search (BFS)** across physical edges where `port.linkUp == true` and `device.isPowered == true`.
  - **Broadcast Storm / Loop Detection:** Detects if BFS traverses two different active ports on the same `Switch` within the same `vlanId`, flagging `isBroadcastStorm = true` (95% packet loss, rapid red LED flashing on the looped switch).
  - **VLAN & Subnet/Gateway Routing:** Enforces `vlanId` isolation across Switch ports and requires valid `IsSameSubnet` or an active path through `sourceDevice.gateway` (`Router`) to reach foreign subnets.
  - Returns `(reachable: boolean, latencyMs: number, diagnosticError: string)`.

### 4.6 `ServerScriptService/Core/CommandExecutor.luau`
Processes `ExecuteCommand.OnServerInvoke(player, rawInput)` with flag/argument parsing and RichText color formatting (`<font color="#...">`):
- `help`: Context-aware command reference grouped by category.
- `clear`: Sends `"__CLEAR__"` control signal to wipe client terminal buffer.
- `ping <ip>`: Runs `NetworkGraph:CanReachIP`, returning 4 realistic ICMP lines (`64 bytes from <ip>: icmp_seq=1 ttl=64 time=1.38 ms`) or authentic errors (`Destination Host Unreachable`, `Request Timed Out`, `Network is unreachable`, `Packet loss (95%) - Broadcast Storm detected`).
- `traceroute <ip>`: Walks the BFS path hop-by-hop and prints each Router/Switch hop, pinpointing the exact hop where a link or route drops.
- `ip a` / `ip addr`: Displays hostname, IPv4, subnet mask, gateway, default VLAN, temperature, and a clean table of every physical port (`eth0`, `eth1`, etc.) with `UP/DOWN` state, VLAN tag, and connected peer device.
- `ip set <ip> <gateway> [subnetMask]`: Validates IPv4 addresses and configures the active device (requires `LocalConsole` or `RemoteSSH`).
- `switch port <portId> vlan <vlanId>`: Configures VLAN tagging on a Switch port (essential for Colocation client isolation).
- `ssh <ip>`: Validates reachability from current device (or Laptop Wi-Fi management bridge `192.168.1.254` when in `Disconnected` local shell); pushes onto `session.sshStack` and enters `RemoteSSH`.
- `exit`: Pops `sshStack` or disconnects `LocalConsole` cable.
- `top`: Displays live CPU %, RAM usage, Temperature (°C), active DDoS flood connections (source IP + Mbps), and per-VM resource load.
- `iptables --block <ip>`: Adds `<ip>` to `device.blockedIps`, mitigating DDoS floods and resolving active DDoS incident tickets.
- `vm create --name <str> --cpu <num> --ram <num> --disk <num>`: Allocates vCPU/RAM/Disk on a `BareMetal` host, creates a `VMData` entry with an internal IP, and triggers `ContractAndIncidentManager` validation.
- `vm list` / `vm throttle <name> --limit <percent>` / `vm delete <name>`: Lists, throttles noisy-neighbor VMs, or deletes VPS instances.
- `install-os <osName>` (`ubuntu-22.04`, `debian-12`, `rocky-9`) & `stress-test`: Installs OS and runs a 5-second thermal/load validation on a Workbench server connected via Console.

### 4.7 `ServerScriptService/Physical/RackAndCablingSystem.luau` & `WorkbenchBuilderSystem.luau`
- **`RackAndCablingSystem.luau`**:
  - Two-click port cabling: First click highlights Port 1 yellow and plays a click SFX; second click validates and connects Port 2 with a 3D `Beam` and plug SFX. Clicking an already-connected port while holding a wire-cutter key/mode disconnects it cleanly.
  - Carry & Rack-Mount System: Players pick up unmounted crates/devices at `LoadingDock` (welded neatly in front of character) and click any Rack's open `U` slot to snap-mount the device, checking `uSize` clearance and updating `RackData.occupiedSlots`.
  - Hot-Swap Drive Repair: During Colocation "Remote Hands" incidents, carrying `replacement_hdd` and interacting with the target server's flashing red drive bay swaps the drive and resolves the ticket.
- **`WorkbenchBuilderSystem.luau`**:
  - Manages sequential server assembly on `AssemblyWorkbench` (`Chassis -> Motherboard -> CPU -> RAM -> Storage -> PSU`), visually attaching 3D sub-components onto the workbench chassis at each step, powering on the bench unit, and packing completed builds into a shipping crate at `LoadingDock` once `install-os` and `stress-test` succeed.

### 4.8 `ServerScriptService/Gameplay/ShiftAndEconomyManager.luau`, `ContractAndIncidentManager.luau` & `DataPersistenceManager.luau`
- **`ShiftAndEconomyManager.luau`**:
  - Manages player balance (starts at `$2,500`), Provider Reputation (starts at `10`), and Shift Clock (`08:00` to `18:00`, 1 game hour = 60 real seconds).
  - Every 15 seconds, evaluates real-time **Uptime %** across all active contracts (`CloudVPS` + `Colocation`), distributes recurring revenue payouts, updates thermal simulation (`temperatureC` rises with load and drops with AC cooling; triggers smoke `ParticleEmitter` if `>= 80°C`), and broadcasts `StateSyncRemote`.
  - At `18:00`, deducts daily electricity costs (`totalWatts * rate`), awards SLA Reputation bonuses if Uptime >= 99.0%, and advances to the next shift day.
- **`ContractAndIncidentManager.luau`**:
  - Dynamically generates contracts across all 3 business pillars (`CloudVPS`, `Colocation` spawning physical client crates at `LoadingDock`, and `CustomBuild` orders).
  - **Dynamic Incident Engine** (triggers during peak hours `11:00–17:00` when >=1 contract is active):
    - *Cable Fault:* Severs a random active patch cable (`linkUp = false`), turns `Beam` dark red, flashes `AlarmBeacon`, and spawns a timed SLA Incident ticket.
    - *DDoS Flood:* Floods an active Bare-Metal host (`top` reveals attacker IP); resolved via `iptables --block <attacker_ip>`.
    - *Noisy Neighbor:* Spikes one VM's CPU to 100%, degrading sibling VMs; resolved via `vm throttle <vm_name> --limit 50`.
    - *Remote Hands Drive Failure:* Flags a Colocation server's drive bay (`hasDegradedDrive = true`, red bay LED); resolved by ordering `replacement_hdd` and hot-swapping it.
- **`DataPersistenceManager.luau`**:
  - Uses `DataStoreService` (wrapped safely in `pcall` with Studio API fallback) to save/load player cash, reputation, shift day, owned racks, mounted devices, IP/VLAN configurations, and active VMs on `PlayerRemoving` and auto-save intervals.

### 4.9 Client UI & Audio/Visual Polish (`StarterPlayer/StarterPlayerScripts/`)
- **`TerminalClient.client.luau`**:
  - Builds `TerminalGui` (`ScreenGui`, `ResetOnSpawn = false`): sleek dark-mode CLI (`#0D1117` background, RichText syntax colors, `RobotoMono` font), top connection status bar (`[LOCAL SHELL]`, `[CONSOLE: DevName]`, `[SSH: IP]`), `Tab` command auto-completion, Up/Down arrow command history, and persistent `TextBox` focus.
- **`NOCMonitorClient.client.luau`**:
  - Populates the 3 `SurfaceGui` monitors on `NOCDesk`:
    1. `TopologyMonitor`: Interactive node-and-edge graph showing Router -> Switches -> Servers/VMs with live color-coded health states and clickable node inspection cards.
    2. `TicketMonitor`: Interactive tabbed board (`Available Orders`, `Active Contracts`, `SLA Incidents`) with `Accept` buttons, live SLA countdown bars, and clear objective checklists.
    3. `TelemetryMonitor`: Live gauges for Balance (`$`), Reputation, Shift Clock (`08:00–18:00`), Total Uptime (`%`), Power Load (`W / MaxW`), and Average Rack Temp (`°C`).
- **`CatalogAndBuilderClient.client.luau`**:
  - Clean toggleable HUD (`[B] Hardware Store & Build Guide`) for ordering racks, servers, components, and cables (delivered to `LoadingDock`), plus a contextual step-by-step build checklist when standing near `AssemblyWorkbench`.
- **`AudioAndEffectsClient.client.luau`**:
  - Synthesizes/plays procedural sound effects (`Sound` instances with pitch/volume modulation) for ambient server rack fan hum (spatial `Sound` attached to racks), mechanical keyboard clicks while typing in `TerminalGui`, cable snap/plug clicks, and NOC alarm klaxons during active incidents, plus local character arm-typing pose tweens when `TechnicianLaptop` is equipped.

---

## 5. Deliverable Output Format
1. **System Boot & Dependency Map:** Concise overview of `MainServer.server.luau` initialization order and RemoteEvent contracts.
2. **Complete Luau Source Code:** Output every single file listed in Section 3 under clear `### File: <Path>` headers with 100% complete, bug-free, copy-paste-ready Luau code.