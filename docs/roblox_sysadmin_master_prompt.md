# Roblox SysAdmin & Cloud Data Center Simulator — Master Engineering Prompt

## 1. System Role & Objective
Act as a Principal Roblox Luau Game Architect, Systems Engineer, and Procedural 3D Environment Specialist. Build a **complete, modular, production-grade, and immediately playable codebase** for a Roblox **SysAdmin & Cloud Data Center Simulator** game (inspired by AWS, Colocation facilities, and PC Building Simulator).

The player acts as the **Lead SysAdmin & Infrastructure Operator** managing three core business pillars:
1. **Cloud Hosting / VPS (AWS EC2 style):** Dividing physical Bare-Metal hosts into virtualized VPS instances via CLI commands.
2. **Server Colocation:** Mounting client-owned physical servers into rack slots (`U`), wiring power/network cables, and configuring isolated VLAN/IP routing.
3. **Custom Server Builder:** Assembling server hardware components on a Workbench, running console pre-flight checks/OS installs, and shipping orders.

> **Zero-Setup Playability Mandate:** When pasted into an empty Roblox Studio Baseplate and executed, the `WorldAndAssetBuilder` bootstrapper must procedurally construct the entire 3D Starter Data Center Room, NOC Desk with 3 interactive `SurfaceGui` screens, Assembly Workbench, Loading Dock, 12U Server Rack, ISP Gateway Router, Gigabit Switch, Starter Bare-Metal Server, and equip the player with the Technician `Laptop` Tool—requiring zero manual part creation in Studio.

---

## 2. Strict Engineering Rules & Constraints
1. **Language & Typing:** Strict Luau (`--!strict`) across all scripts. Use explicit `export type` annotations.
2. **Server-Authoritative Security:** All network graph state, IP/subnet/VLAN validation, CLI command parsing, contract SLA timers, incident triggers, and currency/reputation balances MUST execute exclusively on the Server (`ServerScriptService`). Clients only render UI, local visual previews, and fire validated Remote requests.
3. **Technician Laptop Tool Specification:**
   - The `Laptop` Tool in the player's hotbar is always ready to use. **DO NOT implement battery drain, charging stations, or laptop tier/upgrade mechanics.**
   - **Dual Connection Modes:**
     - **Mode A — Local Serial Console (Physical Proximity):** When the player equips `Laptop` and triggers a `ProximityPrompt` (`ActionText = "Connect Console Cable"`) on any Server or Switch, attach a glowing blue `Beam` from `Laptop.SerialPortAttachment` to `Device.ConsolePortAttachment`, open `TerminalGui` in `LocalConsole` mode bound directly to that `DeviceId` (bypasses IP/network requirements; essential for unconfigured hardware or dead links). Moving >18 studs away automatically detaches the console cable and reverts the session to `Disconnected`.
     - **Mode B — Wireless Remote SSH (Anywhere):** When the player equips `Laptop` and activates it (`Tool.Activated` / Left Click) without targeting a console prompt, open `TerminalGui` in `Disconnected` (Local Laptop Shell) mode, allowing `ssh <ip>` to connect remotely to any device reachable via the network graph.
4. **Completeness:** Output 100% complete, executable Luau files. Never use `-- TODO`, `...`, or abbreviated logic.

---

## 3. Exact Project Hierarchy

```text
ReplicatedStorage/
├── Shared/
│   ├── NetworkTypes.luau
│   ├── HardwareCatalog.luau
│   └── NetworkUtils.luau
└── Remotes/ (Auto-generated at runtime if missing)
    ├── ExecuteCommand (RemoteFunction)
    ├── TerminalPushOutput (RemoteEvent)
    ├── OpenTerminalEvent (RemoteEvent)
    ├── CableActionRemote (RemoteEvent)
    ├── RackMountRemote (RemoteEvent)
    ├── WorkbenchRemote (RemoteEvent)
    ├── ContractActionRemote (RemoteEvent)
    ├── PurchaseHardwareRemote (RemoteEvent)
    └── StateSyncRemote (RemoteEvent)

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
    └── ContractAndIncidentManager.luau

StarterPlayer/
└── StarterPlayerScripts/
    ├── TerminalClient.client.luau
    ├── NOCMonitorClient.client.luau
    └── CatalogAndBuilderClient.client.luau
```

---

## 4. Detailed Module-by-Module Specifications

### 4.1 `ReplicatedStorage/Shared/NetworkTypes.luau`
Export strict types for the entire simulation:
- `PortType`: `"WAN" | "RJ45" | "SFP" | "Console"`
- `PortData`: `{ portId: string, portType: PortType, connectedToDeviceId: string?, connectedToPortId: string?, linkUp: boolean, vlanId: number, trafficLoadMbps: number }`
- `VMData`: `{ name: string, cpu: number, ram: number, disk: number, assignedIp: string?, cpuThrottlePercent: number, currentLoadPercent: number, status: "running" | "throttled" | "stopped" }`
- `DeviceType`: `"Router" | "Switch" | "BareMetal" | "ColocationServer"`
- `DeviceNode`: `{ id: string, name: string, deviceType: DeviceType, rackId: string?, uSlot: number?, uSize: number, ip: string?, gateway: string?, subnetMask: string, defaultVlan: number, ports: { [string]: PortData }, specs: { cpu: number, ram: number, disk: number, powerWatts: number }, vms: { [string]: VMData }, blockedIps: { [string]: boolean }, osInstalled: string?, isPowered: boolean, temperatureC: number, hasDegradedDrive: boolean, degradedBayIndex: number? }`
- `RackData`: `{ rackId: string, name: string, maxU: number, occupiedSlots: { [number]: string }, totalPowerWatts: number, maxPowerWatts: number }`
- `TicketCategory`: `"CloudVPS" | "Colocation" | "CustomBuild" | "Incident"`
- `ContractTicket`: `{ id: string, category: TicketCategory, clientName: string, title: string, description: string, requirements: { [string]: any }, rewardPayout: number, payoutIntervalSec: number?, slaRemainingSec: number?, targetDeviceId: string?, targetRackId: string?, targetUSlot: number?, status: "Available" | "Active" | "Completed" | "Failed" }`
- `PlayerSession`: `{ mode: "Disconnected" | "LocalConsole" | "RemoteSSH", targetDeviceId: string?, sshStack: { string } }`

### 4.2 `ReplicatedStorage/Shared/NetworkUtils.luau`
Pure utility functions shared by server and client:
- `IsValidIPv4(ip: string): boolean` (validates 4 octets `0-255`).
- `IsSameSubnet(ipA: string, ipB: string, mask: string): boolean` (bitwise/octet subnet mask comparison so routing bugs work realistically).
- `FormatBytes(gb: number): string` & `FormatUptime(seconds: number): string`.

### 4.3 `ReplicatedStorage/Shared/HardwareCatalog.luau`
Define structured item definitions with `id`, `name`, `category` (`"Rack" | "Network" | "Server" | "Component" | "Cable"`), `price`, `uSize`, `specs`, and `description`:
- **Network & Racks:** `rack_12u` ($400), `rack_24u` ($900), `switch_8p` ($250, 1U, 8x RJ45), `switch_24p` ($650, 1U, 24x RJ45 + 2x SFP), `router_edge` ($500, 1U).
- **Prebuilt Bare-Metal:** `bm_starter` ($800, 2U, 8 vCPU / 16GB RAM / 500GB Disk), `bm_enterprise` ($2,200, 2U, 32 vCPU / 128GB RAM / 2TB Disk).
- **Custom Build Components:** `chassis_1u` ($150), `chassis_2u` ($220), `mobo_single` ($200), `mobo_dual` ($450), `cpu_xeon8` ($300), `cpu_epyc32` ($850), `ram_32g` ($120), `ram_128g` ($420), `nvme_1tb` ($140), `psu_redundant` ($180), `replacement_hdd` ($90, used for Remote Hands drive swaps).
- **Cables:** `cable_lan_blue`, `cable_wan_yellow`, `cable_mgmt_red` ($15 each).

### 4.4 `ServerScriptService/Bootstrap/WorldAndAssetBuilder.luau`
Procedurally construct the 3D scene in `Workspace.DataCenterWorld`:
- **Room Geometry:** `60 x 24 x 60` studs enclosed facility with `SmoothPlastic` dark slate floor, concrete walls, ceiling light fixtures (`SurfaceLight`), an industrial `AC_Unit` prop, a green-outlined `LoadingDock` pad (`12 x 0.2 x 12`), an `AssemblyWorkbench` table (`10 x 3.5 x 5`) with 6 sequential snap-point `Attachments`, and a `NOCDesk` (`12 x 3.5 x 5`).
- **NOC Desk Monitors & Alarm:**
  - Create 3 angled monitor Parts on `NOCDesk` (`TopologyMonitor`, `TicketMonitor`, `TelemetryMonitor`), each with a `SurfaceGui` (`SizingMode = PixelsPerStud`, `PixelsPerStud = 50`) ready for `NOCMonitorClient` binding.
  - Create `AlarmBeacon` above the server aisle with a `PointLight` and `Neon` lens that flashes red/orange during active incidents.
- **Procedural Hardware Model Factories:**
  - Every rackable model must have a primary `BasePart` (`Chassis`), an `Attribute` `DeviceId`, a `ConsolePort` child Part (`Neon` blue, with `Attachment` and `ProximityPrompt` `"Connect Console Cable"`), a `StatusLED` Part (`Neon` green/yellow/red), and individual port Parts (`Port_1`, `Port_2`, etc.) each carrying `Attributes` (`DeviceId`, `PortId`, `PortType`), a tiny `LED` sub-part, an `Attachment`, and a `ClickDetector`.
  - `Rack_12U`: Construct vertical steel rails (`Height = 14` studs) with 12 numbered `USlot_1`..`USlot_12` `Attachments` spaced evenly, plus a rear `PDU_Strip` Part with a `ClickDetector` to toggle/connect rack power.
  - **Initial Starter Setup:** Spawn `Rack_12U` (`rack_main_1`), pre-mount `ISP_Gateway_Router` (`192.168.1.1/24`, WAN uplink active) at `U12`, and pre-mount one `Switch_8P` at `U10` and one `BareMetal_Starter` at `U8` with disconnected cables so the player's immediate task is wiring and configuring them.
  - **`Laptop` Tool Factory:** Build a 3D `Tool` named `TechnicianLaptop` (base keyboard part + angled screen lid with `SurfaceGui` showing live terminal text + `SerialPort` `Attachment`) cloned into `StarterPack` and current players' `Backpack`.

### 4.5 `ServerScriptService/Core/NetworkGraph.luau`
- Maintain `Devices: { [string]: DeviceNode }` and `Racks: { [string]: RackData }`.
- **`ConnectPorts(devA, portA, devB, portB)`**: Validate neither port is already occupied and neither is a `Console` port; link both ports symmetrically (`linkUp = true`); trigger `BroadcastTopologyUpdate()`.
- **`DisconnectPort(devA, portA)`**: Break link on both ends, destroy the 3D `Beam`, turn port LEDs off/red, and update graph.
- **`CanReachIP(sourceDeviceId: string, targetIP: string)`**:
  - Execute a **Breadth-First Search (BFS)** across connected `PortData` edges where `linkUp == true` and `device.isPowered == true`.
  - **Loop / Broadcast Storm Detection:** If BFS visits the same `Switch` twice via different active ports within the same VLAN, flag a `BroadcastStorm` state (causing 95% packet loss and turning all switch LEDs flashing red).
  - **Subnet & Gateway Validation:** Check if `sourceDevice` and `targetDevice` share a subnet (`IsSameSubnet`); if not, require a valid path through `sourceDevice.gateway` (`Router`) that routes to `targetDevice`'s subnet.
  - **VLAN Isolation:** Switch ports only forward traffic between ports sharing the same `vlanId` (unless routed through a Router).
  - Return `(reachable: boolean, latencyMs: number, errorMsg: string)`.

### 4.6 `ServerScriptService/Core/CommandExecutor.luau`
Handle `ExecuteCommand.OnServerInvoke(player, rawInput)` with clean flag/argument tokenization and rich formatted ANSI-style color tags (parsed by `TerminalClient` using `RichText`):
- `help`: Lists available commands grouped by **Diagnostics**, **Network Config**, **SSH & Virtualization**, and **Bench Provisioning**.
- `clear`: Clears client terminal buffer (`"__CLEAR__"`).
- `ping <ip>`: Calls `NetworkGraph:CanReachIP`. Outputs 4 lines (`64 bytes from <ip>: icmp_seq=1 ttl=64 time=1.42 ms`) or authentic failure (`From <src_ip> icmp_seq=1 Destination Host Unreachable` / `Request timed out` / `connect: Network is unreachable`).
- `traceroute <ip>`: Traces hop-by-hop through connected Switches/Routers and prints the exact hop IP/hostname where packets drop.
- `ip a` (or `ip addr`): Prints active device's `name`, `ip`, `subnetMask`, `gateway`, `defaultVlan`, and a formatted table of all ports (`eth0`, `eth1`, etc.) with `state UP/DOWN`, `vlan`, and connected peer name.
- `ip set <ip> <gateway> [subnetMask]`: Validates IPv4 format; updates active device (`LocalConsole` or `RemoteSSH` required).
- `switch port <portId> vlan <vlanId>`: Sets VLAN ID on a Switch port (essential for Colocation contracts).
- `ssh <ip>`: Checks `CanReachIP` from player's current context (or Laptop virtual Wi-Fi gateway `192.168.1.254` if in `Disconnected` local shell). Pushes current device onto `session.sshStack` and switches `targetDeviceId` to the target device.
- `exit`: Pops `sshStack` (returns to previous SSH host or Local Shell) or detaches `LocalConsole`.
- `top`: Displays live CPU %, RAM usage, Temperature (°C), active DDoS attack connections (showing attacker source IP and Mbps flood), and per-VM resource usage.
- `iptables --block <ip>`: Adds `<ip>` to `device.blockedIps`, immediately neutralizing DDoS attacks originating from that IP and resolving active DDoS incident tickets.
- `vm create --name <str> --cpu <num> --ram <num> --disk <num>`: Validates `deviceType == "BareMetal"`, checks remaining unallocated CPU/RAM/Disk, spawns `VMData` entry, auto-assigns an internal IP, and notifies `ContractAndIncidentManager` to validate active `CloudVPS` contracts.
- `vm list`: Lists all VMs on the current Bare-Metal host with CPU, RAM, IP, and status.
- `vm throttle <name> --limit <percent>`: Caps CPU usage of a runaway/noisy-neighbor VM (resolving Noisy Neighbor incidents).
- `vm delete <name>`: Removes a VM and frees host resources.
- `install-os <osName>` (e.g., `ubuntu-22.04`, `debian-12`, `rocky-9`): Installs OS on a Workbench server connected via Console.
- `stress-test`: Runs a 5-second simulated thermal/load burn-in test on a Workbench server, verifying all required components are installed and `temperatureC < 80`.

### 4.7 `ServerScriptService/Physical/RackAndCablingSystem.luau` & `WorkbenchBuilderSystem.luau`
- **`RackAndCablingSystem.luau`**:
  - Two-click port cabling: Player clicks Port 1 (highlights port yellow, stores pending selection per player) -> clicks Port 2 -> validates compatibility and creates a colored 3D `Beam` (`CurveSize0`/`CurveSize1` gravity droop simulation) between their `Attachments`. Clicking an occupied port with a wire-cutter action disconnects it.
  - Rack Mounting: Players carry unmounted devices from `LoadingDock` (via `ProximityPrompt` carry weld) and click a Rack's open `U` slot to snap-mount it cleanly into place, updating `RackData.occupiedSlots`.
  - Hot-Swap Drive Repair: During Colocation "Remote Hands" incidents, carrying a `replacement_hdd` from `LoadingDock` and interacting with the target Colocation server's glowing red drive bay swaps the drive and completes the ticket.
- **`WorkbenchBuilderSystem.luau`**:
  - Tracks current build on `AssemblyWorkbench`: enforces installation order (`Chassis -> Motherboard -> CPU -> RAM -> Storage -> PSU`), attaches visual sub-parts onto the workbench chassis as each component is added, allows toggling bench power, and spawns a packed shipping crate at `LoadingDock` once `install-os` + `stress-test` pass.

### 4.8 `ServerScriptService/Gameplay/ShiftAndEconomyManager.luau` & `ContractAndIncidentManager.luau`
- **`ShiftAndEconomyManager.luau`**:
  - Starts player with `$2,500` balance and `10` Reputation.
  - Runs the Shift Clock (`08:00` to `18:00`, 1 game hour = 60 real seconds).
  - Every 15 seconds, calculates real-time **Facility Uptime %** across all active contracts (`CloudVPS` + `Colocation`), pays out recurring revenue (`payoutIntervalSec`), and updates `StateSyncRemote`.
  - At `18:00`, deducts daily power overhead (`totalWatts * rate`), awards SLA bonus if Uptime >= 99.0%, and transitions smoothly to the next shift day.
- **`ContractAndIncidentManager.luau`**:
  - Maintains a live pool of available contracts across all 3 pillars:
    1. **`CloudVPS`**: Requires provisioning a VM matching exact `--cpu`, `--ram`, `--disk` specs on an online, reachable Bare-Metal server.
    2. **`Colocation`**: Spawns a physical client server crate at `LoadingDock` with a required `vlanId` and `ip`; completes when mounted in a rack, powered, cabled to a Switch with matching VLAN, and reachable via `ping` from the ISP Gateway.
    3. **`CustomBuild`**: Requires assembling specific hardware components on `Workbench`, installing the requested OS via Console, passing `stress-test`, and shipping the crate.
  - **Dynamic Incident Engine** (triggers during peak shift hours `11:00–17:00` once at least 1 contract is active):
    - *Cable Fault:* Sets a random active patch cable's `linkUp = false`, changes `Beam` color to dark red, flashes `AlarmBeacon`, and creates a timed SLA Incident ticket.
    - *DDoS Flood:* Targets an active Bare-Metal host's IP with massive traffic spikes (`top` shows flood IP); resolved via `iptables --block <attacker_ip>`.
    - *Noisy Neighbor:* Spikes one VM's CPU to 100%, degrading sibling VMs; resolved via `vm throttle <vm_name> --limit 50`.
    - *Hardware Failure (Remote Hands):* Marks a Colocation server's drive bay degraded (`hasDegradedDrive = true`, red bay LED); resolved by ordering `replacement_hdd` and hot-swapping it.

### 4.9 Client UI & Visual Systems (`StarterPlayer/StarterPlayerScripts/`)
- **`TerminalClient.client.luau`**:
  - Builds `TerminalGui` (`ScreenGui`, `ResetOnSpawn = false`): sleek dark terminal window (`#0D1117` background, `#00FF66` / `#58A6FF` / `#FF5555` RichText output, `RobotoMono` font), top session bar (`[LOCAL SHELL]`, `[CONSOLE: DevName]`, `[SSH: IP]`), `Tab` auto-complete for command names, Up/Down arrow command history navigation, and auto-refocusing input `TextBox`.
- **`NOCMonitorClient.client.luau`**:
  - Populates the 3 `SurfaceGui` monitors on `NOCDesk`:
    1. `TopologyMonitor`: Interactive node-and-line diagram generated dynamically from `StateSyncRemote`, showing Router -> Switches -> Servers/VMs with live color-coded health states and clickable node inspection popups.
    2. `TicketMonitor`: Interactive tabbed board (`Available Orders`, `Active Contracts`, `SLA Incidents`) with `Accept` buttons, live countdown bars, and clear step-by-step objective checklists.
    3. `TelemetryMonitor`: Live gauges for Balance (`$`), Reputation, Shift Time (`08:00–18:00`), Total Uptime (`%`), Power Load (`W / MaxW`), and Average Rack Temp (`°C`).
- **`CatalogAndBuilderClient.client.luau`**:
  - Clean toggleable HUD button (`[B] Hardware Store & Build Guide`) allowing players to purchase racks, servers, components, and cables (spawning at `LoadingDock`), plus an interactive step-by-step checklist overlay whenever standing near `AssemblyWorkbench`.

---

## 5. Deliverable Output Format
1. **Architecture & Gameplay Loop Overview:** A brief summary of the initialization order in `MainServer.server.luau` and how all modules communicate.
2. **Complete Luau Source Code:** Output every single file listed in the Project Hierarchy above under clear `### File: <Path>` headers with 100% complete, bug-free, copy-paste-ready Luau code.