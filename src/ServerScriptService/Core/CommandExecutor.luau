--!strict
--[[
	CommandExecutor (ModuleScript, ServerScriptService/Core)
	Server-side handler of the terminal. Binds ExecuteCommand.OnServerInvoke
	(CONTRACT section 3) and implements the Fase 1 CLI:
		help, clear, ping, traceroute, ip a/addr/set, ssh, exit, top,
		vm create/list/throttle/delete, install-os, stress-test.
	Terminal context: Disconnected mode runs against the laptop management
	bridge ("__laptop__"); LocalConsole / RemoteSSH run against
	session.terminal.targetDeviceId.
	Every user-derived string is escaped with NetworkUtils.EscapeRich before
	it is embedded into RichText output. Async commands (install-os,
	stress-test) complete after a task.delay and push their result lines via
	TerminalPushOutput, plus the "cash" SFX through PlaySFXRemote.
]]

local CommandExecutor = {}

---------------------------------------------------------------------
-- Injected dependencies (set in Init)
---------------------------------------------------------------------

local Sessions: any = nil -- SessionManager module
local Graph: any = nil -- NetworkGraph module
local Utils: any = nil -- NetworkUtils module
local Catalog: any = nil -- HardwareCatalog module (kept for future expansion)
local Constants: any = nil -- PlotConstants module
local Workbench: any = nil -- WorkbenchBuilderSystem module (bench state lives on session)
local Cabling: any = nil -- RackAndCablingSystem module (DetachConsole)
local Remotes: any = nil -- ReplicatedStorage.Remotes folder

---------------------------------------------------------------------
-- RichText palette (CONTRACT: green #00FF66, blue #58A6FF, red #FF5555,
-- grey #8B949E) and small formatting helpers
---------------------------------------------------------------------

local HEX_GREEN = "#00FF66"
local HEX_BLUE = "#58A6FF"
local HEX_RED = "#FF5555"
local HEX_GREY = "#8B949E"

local function rich(hex: string, text: string): string
	local payload = text
	if Utils ~= nil then
		payload = Utils.EscapeRich(text)
	end
	return string.format('<font color="%s">%s</font>', hex, payload)
end

local function g(text: string): string -- green
	return rich(HEX_GREEN, text)
end

local function b(text: string): string -- blue
	return rich(HEX_BLUE, text)
end

local function r(text: string): string -- red
	return rich(HEX_RED, text)
end

local function gr(text: string): string -- grey
	return rich(HEX_GREY, text)
end

-- Left-pad text to a fixed width (terminal font is monospace).
local function pad(text: string, width: number): string
	if #text >= width then
		return text
	end
	return text .. string.rep(" ", width - #text)
end

-- Compact numeric formatting (no trailing ".0").
local function num(value: number): string
	return string.format("%g", value)
end

-- Sort key for stable port ordering: wan -> eth -> sfp, then numeric suffix.
local function portSortKey(portId: string): (number, number)
	local prefix = string.match(portId, "^[a-zA-Z]+") or ""
	local numPart = tonumber(string.match(portId, "%d+") or "") or 0
	local order = 4
	if prefix == "wan" then
		order = 1
	elseif prefix == "eth" then
		order = 2
	elseif prefix == "sfp" then
		order = 3
	end
	return order, numPart
end

local function sortedPortIds(node: any): { string }
	local ids: { string } = {}
	for portId in pairs(node.ports) do
		table.insert(ids, portId)
	end
	table.sort(ids, function(a, b)
		local oa, na = portSortKey(a)
		local ob, nb = portSortKey(b)
		if oa ~= ob then
			return oa < ob
		end
		return na < nb
	end)
	return ids
end

-- Value of "--flag <value>" in the token list, or nil.
local function parseFlag(tokens: { string }, flag: string): string?
	for i = 2, #tokens - 1 do
		if tokens[i] == flag then
			return tokens[i + 1]
		end
	end
	return nil
end

---------------------------------------------------------------------
-- Terminal context helpers
---------------------------------------------------------------------

-- Resolve the current source: "__laptop__" for Disconnected mode, otherwise
-- the target device id. Returns (sourceId, errorLine?).
local function resolveSource(session: any): (string, string?)
	local mode = session.terminal.mode
	if mode == "Disconnected" then
		return "__laptop__", nil
	end
	local targetId = session.terminal.targetDeviceId
	if targetId == nil then
		return "", "Not connected"
	end
	if session.devices[targetId] == nil then
		return "", "Not connected: device tidak ditemukan"
	end
	return targetId, nil
end

-- Commands that inspect/mutate a device require console or SSH context.
-- Returns (node, errorLine?).
local function requireDevice(session: any, commandName: string): (any, string?)
	if session.terminal.mode == "Disconnected" then
		return nil, commandName .. ": belum terhubung ke device (attach console / ssh <ip> dulu)"
	end
	local targetId = session.terminal.targetDeviceId
	local node = if targetId ~= nil then session.devices[targetId] else nil
	if node == nil then
		return nil, commandName .. ": Not connected"
	end
	return node, nil
end

-- Keep the client's terminal top bar in sync with the session mode
-- (CONTRACT section 3 OpenTerminalEvent {action="open", mode, ...}).
local function notifyMode(session: any, mode: string, device: any)
	local openRemote = if Remotes ~= nil then Remotes:FindFirstChild("OpenTerminalEvent") else nil
	if openRemote == nil then
		return
	end
	if device ~= nil then
		openRemote:FireClient(session.player, {
			action = "open",
			mode = mode,
			deviceName = device.name,
			deviceId = device.id,
		})
	else
		openRemote:FireClient(session.player, {
			action = "open",
			mode = mode,
			deviceName = "Technician Laptop",
			deviceId = "__laptop__",
		})
	end
end

---------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------

local function cmdHelp(): { string }
	local lines: { string } = {}
	table.insert(lines, b("=== NETSIM SHELL - DAFTAR PERINTAH ==="))
	table.insert(lines, b("-- Jaringan --"))
	table.insert(lines, "  " .. g("ping <ip>") .. gr("                  uji koneksi (4 packet ICMP)"))
	table.insert(lines, "  " .. g("traceroute <ip>") .. gr("              telusuri rute hop-per-hop"))
	table.insert(lines, b("-- Interface --"))
	table.insert(lines, "  " .. g("ip a | ip addr") .. gr("                info hostname, IP, mask, gateway, port"))
	table.insert(lines, "  " .. g("ip set <ip> <gw> [mask]") .. gr("      set IP statis device aktif"))
	table.insert(lines, b("-- Remote --"))
	table.insert(lines, "  " .. g("ssh <ip>") .. gr("                      SSH ke device via management bridge / LAN"))
	table.insert(lines, "  " .. g("exit") .. gr("                         keluar dari ssh / lepas console"))
	table.insert(lines, b("-- Sistem --"))
	table.insert(lines, "  " .. g("top") .. gr("                          monitor CPU/RAM/temp host aktif"))
	table.insert(lines, "  " .. g("install-os <os>") .. gr("              ubuntu-22.04 | debian-12 | rocky-9"))
	table.insert(lines, "  " .. g("stress-test") .. gr("                   burn-in 5 detik (validasi thermal)"))
	table.insert(lines, b("-- VM --"))
	table.insert(lines, "  " .. g("vm create --name <n> --cpu <n> --ram <n> --disk <n>"))
	table.insert(lines, "  " .. g("vm list") .. gr("                       daftar VM di host aktif"))
	table.insert(lines, "  " .. g("vm throttle <name> --limit <pct>") .. gr("   batasi CPU VM (5-100)"))
	table.insert(lines, "  " .. g("vm delete <name>") .. gr("              hapus VM, resource kembali ke host"))
	table.insert(lines, b("-- Terminal --"))
	table.insert(lines, "  " .. g("clear") .. gr("                        bersihkan layar"))
	table.insert(lines, "  " .. g("help") .. gr("                         daftar ini"))
	return lines
end

local function cmdPing(session: any, tokens: { string }): { string }
	local targetIP = tokens[2]
	if targetIP == nil then
		return { r("ping: usage: ping <ip>") }
	end
	local sourceId, err = resolveSource(session)
	if err ~= nil then
		return { r(err) }
	end
	local reachable, latency, errMsg = Graph.CanReachIP(session, sourceId, targetIP)
	if not reachable then
		return { r(errMsg) }
	end
	-- objective flag: starter bare-metal successfully pings the gateway router
	if sourceId == "bm_starter_1" and targetIP == "192.168.1.1" then
		session.flags.pingGateway = true
	end
	local lines: { string } = {}
	table.insert(lines, gr("PING " .. targetIP .. " (" .. targetIP .. ") 56(84) bytes of data."))
	for i = 1, 4 do
		local t = latency + (math.random() - 0.5) * 0.4
		if t < 0.05 then
			t = 0.05
		end
		table.insert(lines, g(string.format("64 bytes from %s: icmp_seq=%d ttl=64 time=%.2f ms", targetIP, i, t)))
	end
	table.insert(
		lines,
		gr(string.format("--- %s ping statistics --- 4 packets transmitted, 4 received, 0%% packet loss", targetIP))
	)
	if session.broadcastStorm then
		table.insert(lines, r("PERINGATAN: broadcast storm terdeteksi (ada loop di topology)"))
	end
	return lines
end

local function cmdTraceroute(session: any, tokens: { string }): { string }
	local targetIP = tokens[2]
	if targetIP == nil then
		return { r("traceroute: usage: traceroute <ip>") }
	end
	local sourceId, err = resolveSource(session)
	if err ~= nil then
		return { r(err) }
	end

	local path: { string }? = nil
	if sourceId == "__laptop__" then
		-- the management bridge has no graph node: synthesize a 2-hop path
		local reachable, _, reachErr = Graph.CanReachIP(session, sourceId, targetIP)
		if not reachable then
			return { r(reachErr) }
		end
		local targetNode = Graph.FindDeviceByIP(session, targetIP)
		if targetNode ~= nil then
			path = { "__laptop__", targetNode.id }
		else
			path = { "__laptop__", "isp_uplink" }
		end
	else
		path = Graph.GetRoutePath(session, sourceId, targetIP)
	end
	if path == nil or #path < 2 then
		return { r("traceroute: no route to host") }
	end

	local lines: { string } = {}
	table.insert(lines, gr("traceroute ke " .. targetIP .. ", " .. num(#path - 1) .. " hop:"))
	local cumulative = 0
	for i = 2, #path do
		local nodeId = path[i]
		local node = session.devices[nodeId]
		local name = if node ~= nil then node.name else nodeId
		local ipDisplay = if node ~= nil and node.ip ~= nil then node.ip else "--"
		cumulative += 0.8 + math.random() * 1.4
		if node == nil or node.ip == nil then
			cumulative += 8 + math.random() * 6 -- WAN-side latency
		end
		table.insert(
			lines,
			gr(string.format("  %d  ", i - 1))
				.. g(name)
				.. gr(" (" .. ipDisplay .. ")  ")
				.. b(string.format("%.2f ms", cumulative))
		)
	end
	return lines
end

local function cmdIpAddr(session: any): { string }
	if session.terminal.mode == "Disconnected" then
		-- laptop itself: only the management bridge
		local lines: { string } = {}
		table.insert(lines, b("hostname:  ") .. g("technician-laptop"))
		table.insert(lines, b("inet:      ") .. g(Constants.LAPTOP_BRIDGE_IP .. "/24") .. gr("  (management bridge Wi-Fi)"))
		table.insert(lines, b("gateway:   ") .. gr("--"))
		table.insert(lines, gr("--- ports ---"))
		table.insert(lines, "  " .. g("wifi0") .. "  " .. g("UP") .. "    " .. gr("vlan 1  peer --"))
		table.insert(lines, gr("hint: klik port console device ('Connect Console Cable') untuk akses console"))
		return lines
	end
	local node, err = requireDevice(session, "ip a")
	if err ~= nil then
		return { r(err) }
	end
	local lines: { string } = {}
	table.insert(lines, b("hostname:  ") .. g(node.name) .. gr("  (" .. node.deviceType .. ")"))
	if node.ip ~= nil then
		table.insert(
			lines,
			b("inet:      ")
				.. g(string.format("%s/%d", node.ip, Utils.MaskToPrefix(node.subnetMask)))
				.. gr("  mask " .. node.subnetMask)
		)
		table.insert(lines, b("gateway:   ") .. g(node.gateway or "--"))
	else
		table.insert(lines, b("inet:      ") .. r("-- belum di-set") .. gr("  (ip set <ip> <gw>)"))
		table.insert(lines, b("gateway:   ") .. gr("--"))
	end
	table.insert(lines, b("vlan:      ") .. g(num(node.defaultVlan)))
	table.insert(lines, b("temp:      ") .. g(string.format("%.1fC", node.temperatureC)))
	table.insert(lines, gr("--- ports ---"))
	for _, portId in ipairs(sortedPortIds(node)) do
		local port = node.ports[portId]
		local state = if port.linkUp then g("UP") else gr("DOWN")
		local peerName = "--"
		if port.connectedToDeviceId ~= nil then
			local peer = session.devices[port.connectedToDeviceId]
			peerName = if peer ~= nil then peer.name else (port.connectedToDeviceId :: string)
		end
		table.insert(
			lines,
			"  "
				.. g(portId)
				.. "  "
				.. state
				.. "  "
				.. gr(string.format("vlan %d  peer %s", port.vlanId, peerName))
		)
	end
	return lines
end

local function cmdIpSet(session: any, tokens: { string }): { string }
	local node, err = requireDevice(session, "ip set")
	if err ~= nil then
		return { r(err) }
	end
	-- tokens: { "ip", "set", ip, gateway, [mask] }
	local ip = tokens[3]
	local gateway = tokens[4]
	local mask = tokens[5] or "255.255.255.0"
	if ip == nil or gateway == nil then
		return { r("ip set: usage: ip set <ip> <gateway> [mask]") }
	end
	if not Utils.IsValidIPv4(ip) then
		return { r("ip set: invalid IPv4 address: " .. ip) }
	end
	if not Utils.IsValidIPv4(gateway) then
		return { r("ip set: invalid gateway IPv4: " .. gateway) }
	end
	if not Utils.IsValidIPv4(mask) then
		return { r("ip set: invalid subnet mask: " .. mask) }
	end
	if not Utils.IsSameSubnet(ip, gateway, mask) then
		return { r("Gateway not in subnet") }
	end
	if ip == Constants.LAPTOP_BRIDGE_IP then
		return { r("IP conflict: " .. ip .. " dipakai bridge laptop") }
	end
	if Graph.IsIPUsedByOther(session, ip, node.id) then
		local holder = Graph.FindDeviceByIP(session, ip)
		local holderName = if holder ~= nil then holder.name else "?"
		return { r("IP conflict: " .. ip .. " sudah dipakai " .. holderName) }
	end
	node.ip = ip
	node.gateway = gateway
	node.subnetMask = mask
	local lines: { string } = {}
	table.insert(lines, g(string.format("IP configured: %s/%d", ip, Utils.MaskToPrefix(mask))))
	table.insert(lines, gr("gateway " .. gateway .. " | device " .. node.name))
	return lines
end

local function cmdIp(session: any, tokens: { string }): { string }
	local sub = string.lower(tokens[2] or "")
	if sub == "a" or sub == "addr" then
		return cmdIpAddr(session)
	elseif sub == "set" then
		return cmdIpSet(session, tokens)
	end
	return { r("ip: usage: ip a | ip addr | ip set <ip> <gateway> [mask]") }
end

local function cmdSsh(session: any, tokens: { string }): { string }
	local targetIP = tokens[2]
	if targetIP == nil then
		return { r("ssh: usage: ssh <ip>") }
	end
	local term = session.terminal
	local targetNode: any = nil

	if term.mode == "Disconnected" then
		-- laptop management bridge: device must exist, be powered and have an ip
		targetNode = Graph.FindDeviceByIP(session, targetIP)
		if targetNode == nil then
			return { r("ssh: connect to host " .. targetIP .. " port 22: No route to host") }
		end
		if not targetNode.isPowered then
			return { r("ssh: connect to host " .. targetIP .. " port 22: Connection refused (device mati)") }
		end
	else
		local sourceId, err = resolveSource(session)
		if err ~= nil then
			return { r(err) }
		end
		targetNode = Graph.FindDeviceByIP(session, targetIP)
		if targetNode == nil then
			return { r("ssh: connect to host " .. targetIP .. " port 22: No route to host") }
		end
		if targetNode.id == sourceId then
			return { r("ssh: sudah berada di device ini") }
		end
		local reachable, _, reachErr = Graph.CanReachIP(session, sourceId, targetIP)
		if not reachable then
			return { r("ssh: connect to host " .. targetIP .. " port 22: " .. reachErr) }
		end
	end

	-- push the SSH chain; from the console, remember it first via the sentinel
	if term.mode == "LocalConsole" and term.sshStack[#term.sshStack] ~= "__console__" then
		table.insert(term.sshStack, "__console__")
	end
	table.insert(term.sshStack, targetNode.id)
	term.mode = "RemoteSSH"
	term.targetDeviceId = targetNode.id
	notifyMode(session, "RemoteSSH", targetNode)

	local lines: { string } = {}
	table.insert(lines, b("SSH session established -> ") .. g(targetNode.name) .. gr(" (" .. (targetNode.ip or "?") .. ")"))
	table.insert(lines, gr("ketik 'exit' untuk kembali"))
	return lines
end

local function cmdExit(session: any): { string }
	local term = session.terminal
	if term.mode == "Disconnected" then
		return { gr("Sudah di local shell (laptop).") }
	end
	if term.mode == "LocalConsole" then
		-- detach the physical console cable (RackAndCablingSystem notifies client)
		if Cabling ~= nil and Cabling.DetachConsole ~= nil then
			Cabling.DetachConsole(session, session.player, true)
		end
		return { gr("Console cable detached.") }
	end

	-- RemoteSSH: pop one level of the SSH stack
	table.remove(term.sshStack)
	local top = term.sshStack[#term.sshStack]
	if top == "__console__" and session.consoleLink ~= nil and session.devices[session.consoleLink.deviceId] ~= nil then
		table.remove(term.sshStack) -- consume the sentinel
		local consoleNode = session.devices[session.consoleLink.deviceId]
		term.mode = "LocalConsole"
		term.targetDeviceId = consoleNode.id
		notifyMode(session, "LocalConsole", consoleNode)
		return { gr("Kembali ke console ") .. g(consoleNode.name) }
	elseif top ~= nil and session.devices[top] ~= nil then
		term.mode = "RemoteSSH"
		term.targetDeviceId = top
		local node = session.devices[top]
		notifyMode(session, "RemoteSSH", node)
		return { gr("Kembali ke ") .. g(node.name) .. gr(" (" .. (node.ip or "?") .. ")") }
	else
		term.mode = "Disconnected"
		term.targetDeviceId = nil
		term.sshStack = {}
		notifyMode(session, "Disconnected", nil)
		return { gr("Kembali ke local shell (laptop).") }
	end
end

local function cmdTop(session: any): { string }
	local node, err = requireDevice(session, "top")
	if err ~= nil then
		return { r(err) }
	end
	local specs = node.specs
	local cpuUsed, ramUsed, diskUsed = 0, 0, 0
	for _, vm in pairs(node.vms) do
		cpuUsed += vm.cpu * (vm.currentLoadPercent or 0) / 100
		ramUsed += vm.ram
		diskUsed += vm.disk
	end
	local cpuPct = 0
	if specs.cpu > 0 then
		cpuPct = cpuUsed / specs.cpu * 100
	end
	local lines: { string } = {}
	table.insert(lines, b("top - ") .. g(node.name) .. gr("  (" .. node.deviceType .. ")"))
	table.insert(
		lines,
		b("cpu:  ")
			.. g(string.format("%.1f/%s vCPU (%.1f%%)", cpuUsed, num(specs.cpu), cpuPct))
			.. gr("   ")
			.. b("ram:  ")
			.. g(string.format("%s/%s GB", num(ramUsed), num(specs.ram)))
			.. gr("   ")
			.. b("disk: ")
			.. g(string.format("%s/%s GB", num(diskUsed), num(specs.disk)))
	)
	table.insert(lines, b("temp: ") .. g(string.format("%.1fC", node.temperatureC)) .. gr("   ") .. b("power: ") .. g(num(specs.powerWatts) .. "W"))
	if node.isUnderDDoS then
		table.insert(lines, r("[DDoS] UNDER ATTACK from " .. (node.ddosAttackerIp or "unknown")))
	end
	if next(node.vms) == nil then
		table.insert(lines, gr("  (belum ada VM - coba: vm create --name web-1 --cpu 2 --ram 4 --disk 50)"))
		return lines
	end
	table.insert(
		lines,
		gr(pad("NAME", 16) .. pad("CPU", 5) .. pad("RAM", 7) .. pad("DISK", 7) .. pad("IP", 12) .. pad("LOAD", 7) .. "STATUS")
	)
	local names: { string } = {}
	for name in pairs(node.vms) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local vm = node.vms[name]
		local ipDisplay = if vm.assignedIp ~= nil then vm.assignedIp else "--"
		local statusText = vm.status or "running"
		if vm.status == "throttled" then
			statusText = string.format("throttled(%s%%)", num(vm.cpuThrottlePercent or 100))
		end
		table.insert(
			lines,
			g(pad(name, 16))
				.. gr(
					pad(num(vm.cpu), 5)
						.. pad(num(vm.ram) .. "G", 7)
						.. pad(num(vm.disk) .. "G", 7)
						.. pad(ipDisplay, 12)
						.. pad(string.format("%.0f%%", vm.currentLoadPercent or 0), 7)
				)
				.. b(statusText)
		)
	end
	return lines
end

---------------------------------------------------------------------
-- vm commands
---------------------------------------------------------------------

local function requireBareMetal(session: any, commandName: string): (any, string?)
	local node, err = requireDevice(session, commandName)
	if err ~= nil then
		return nil, err
	end
	if node.deviceType ~= "BareMetal" then
		return nil, commandName .. ": device bukan BareMetal (" .. node.deviceType .. ")"
	end
	return node, nil
end

local function vmHeader(node: any): string
	return b("VMs on ") .. g(node.name) .. gr("  (" .. node.deviceType .. ")")
end

local function cmdVmCreate(session: any, tokens: { string }): { string }
	local node, err = requireBareMetal(session, "vm create")
	if err ~= nil then
		return { r(err) }
	end
	if node.osInstalled == nil then
		return { r("vm create: OS belum terinstall (install-os dulu)") }
	end
	if not node.isPowered then
		return { r("vm create: device mati (nyalakan dulu)") }
	end
	local name = parseFlag(tokens, "--name")
	local cpu = tonumber(parseFlag(tokens, "--cpu") or "")
	local ram = tonumber(parseFlag(tokens, "--ram") or "")
	local disk = tonumber(parseFlag(tokens, "--disk") or "")
	if name == nil or cpu == nil or ram == nil or disk == nil then
		return { r("vm create: usage: vm create --name <n> --cpu <n> --ram <n> --disk <n>") }
	end
	if cpu <= 0 or ram <= 0 or disk <= 0 then
		return { r("vm create: --cpu / --ram / --disk harus > 0") }
	end
	-- sanitize VM name: 1-16 chars of [A-Za-z0-9_-]
	if #name > 16 or string.match(name, "^[%w%-_]+$") == nil then
		return { r("vm create: nama VM invalid (1-16 huruf/angka/-/_): '" .. name .. "'") }
	end
	if node.vms[name] ~= nil then
		return { r("vm create: nama VM '" .. name .. "' sudah dipakai di host ini") }
	end
	-- capacity check against the host specs
	local usedCpu, usedRam, usedDisk = 0, 0, 0
	for _, vm in pairs(node.vms) do
		usedCpu += vm.cpu
		usedRam += vm.ram
		usedDisk += vm.disk
	end
	local specs = node.specs
	if usedCpu + cpu > specs.cpu then
		return { r(string.format("vm create: CPU penuh (%s/%s terpakai, diminta %s)", num(usedCpu), num(specs.cpu), num(cpu))) }
	end
	if usedRam + ram > specs.ram then
		return { r(string.format("vm create: RAM penuh (%s/%s GB terpakai, diminta %s GB)", num(usedRam), num(specs.ram), num(ram))) }
	end
	if usedDisk + disk > specs.disk then
		return { r(string.format("vm create: disk penuh (%s/%s GB terpakai, diminta %s GB)", num(usedDisk), num(specs.disk), num(disk))) }
	end
	-- assign an internal IP from the per-host counter (10.0.0.x)
	local nextIndex = (session.vmIpCounter[node.id] or 1) + 1
	while nextIndex < 254 and Graph.IsIPUsedByOther(session, Utils.GenerateInternalIP(nextIndex), node.id) do
		nextIndex += 1
	end
	session.vmIpCounter[node.id] = nextIndex
	local assignedIp = Utils.GenerateInternalIP(nextIndex)

	node.vms[name] = {
		name = name,
		cpu = cpu,
		ram = ram,
		disk = disk,
		assignedIp = assignedIp,
		cpuThrottlePercent = 100,
		currentLoadPercent = 0,
		status = "running",
	}
	-- no notification needed: the economy loop reads device state
	local lines: { string } = {}
	table.insert(lines, g(string.format("VM '%s' created on %s", name, node.name)))
	table.insert(lines, gr(string.format("allocated %s vCPU / %s GB RAM / %s GB disk", num(cpu), num(ram), num(disk))))
	table.insert(lines, b("assigned IP: ") .. g(assignedIp))
	return lines
end

local function cmdVmList(session: any): { string }
	local node, err = requireBareMetal(session, "vm list")
	if err ~= nil then
		return { r(err) }
	end
	if next(node.vms) == nil then
		return { gr("(kosong) Belum ada VM di " .. node.name) }
	end
	local lines: { string } = {}
	table.insert(lines, vmHeader(node))
	table.insert(
		lines,
		gr(pad("NAME", 16) .. pad("CPU", 5) .. pad("RAM", 7) .. pad("DISK", 7) .. pad("IP", 12) .. pad("LOAD", 7) .. "STATUS")
	)
	local names: { string } = {}
	for name in pairs(node.vms) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local vm = node.vms[name]
		local ipDisplay = if vm.assignedIp ~= nil then vm.assignedIp else "--"
		local statusText = vm.status or "running"
		if vm.status == "throttled" then
			statusText = string.format("throttled(%s%%)", num(vm.cpuThrottlePercent or 100))
		end
		table.insert(
			lines,
			g(pad(name, 16))
				.. gr(
					pad(num(vm.cpu), 5)
						.. pad(num(vm.ram) .. "G", 7)
						.. pad(num(vm.disk) .. "G", 7)
						.. pad(ipDisplay, 12)
						.. pad(string.format("%.0f%%", vm.currentLoadPercent or 0), 7)
				)
				.. b(statusText)
		)
	end
	return lines
end

local function cmdVmThrottle(session: any, tokens: { string }): { string }
	local node, err = requireBareMetal(session, "vm throttle")
	if err ~= nil then
		return { r(err) }
	end
	local name = tokens[3]
	local limitRaw = parseFlag(tokens, "--limit")
	if name == nil or limitRaw == nil then
		return { r("vm throttle: usage: vm throttle <name> --limit <pct>") }
	end
	local limit = tonumber(limitRaw)
	if limit == nil then
		return { r("vm throttle: limit harus angka (5-100)") }
	end
	limit = math.clamp(math.floor(limit + 0.5), 5, 100)
	local vm = node.vms[name]
	if vm == nil then
		return { r("vm throttle: VM '" .. name .. "' tidak ditemukan") }
	end
	vm.cpuThrottlePercent = limit
	vm.status = if limit < 100 then "throttled" else "running"
	return { g(string.format("VM '%s' throttle -> %s%%", name, num(limit))) .. gr("  (status: " .. vm.status .. ")") }
end

local function cmdVmDelete(session: any, tokens: { string }): { string }
	local node, err = requireBareMetal(session, "vm delete")
	if err ~= nil then
		return { r(err) }
	end
	local name = tokens[3]
	if name == nil then
		return { r("vm delete: usage: vm delete <name>") }
	end
	if node.vms[name] == nil then
		return { r("vm delete: VM '" .. name .. "' tidak ditemukan") }
	end
	node.vms[name] = nil
	return { g("VM '" .. name .. "' deleted, resource dikembalikan ke host") }
end

local function cmdVm(session: any, tokens: { string }): { string }
	local sub = string.lower(tokens[2] or "")
	if sub == "create" then
		return cmdVmCreate(session, tokens)
	elseif sub == "list" then
		return cmdVmList(session)
	elseif sub == "throttle" then
		return cmdVmThrottle(session, tokens)
	elseif sub == "delete" then
		return cmdVmDelete(session, tokens)
	end
	return { r("vm: usage: vm create | vm list | vm throttle <name> --limit <pct> | vm delete <name>") }
end

---------------------------------------------------------------------
-- install-os / stress-test (async, complete via TerminalPushOutput)
---------------------------------------------------------------------

local VALID_OS: { [string]: boolean } = {
	["ubuntu-22.04"] = true,
	["debian-12"] = true,
	["rocky-9"] = true,
}

local function pushLines(player: Player, lines: { string })
	local pushRemote = if Remotes ~= nil then Remotes:FindFirstChild("TerminalPushOutput") else nil
	if pushRemote ~= nil then
		pushRemote:FireClient(player, { lines = lines })
	end
end

local function playSfx(player: Player, name: string)
	local sfxRemote = if Remotes ~= nil then Remotes:FindFirstChild("PlaySFXRemote") else nil
	if sfxRemote ~= nil then
		sfxRemote:FireClient(player, name)
	end
end

local function cmdInstallOs(player: Player, session: any, tokens: { string }): { string }
	local node, err = requireBareMetal(session, "install-os")
	if err ~= nil then
		return { r(err) }
	end
	local osName = string.lower(tokens[2] or "")
	if not VALID_OS[osName] then
		return { r("install-os: pilih salah satu: install-os ubuntu-22.04 | debian-12 | rocky-9") }
	end
	local deviceId = node.id
	local guardKey = "installing_" .. deviceId
	if session.flags[guardKey] then
		return { r("install-os: instalasi sudah berjalan di " .. node.name) }
	end
	session.flags[guardKey] = true

	local lines: { string } = {}
	table.insert(lines, gr("install-os: installing " .. osName .. " on ") .. g(node.name) .. gr(" ..."))
	table.insert(lines, gr("[ 20%] retrieving packages ..."))
	table.insert(lines, gr("[ 55%] partitioning storage ..."))
	table.insert(lines, gr("[ 85%] writing bootloader ..."))

	-- finish asynchronously; guard against a deleted session / device
	task.delay(3, function()
		local liveSession = if Sessions ~= nil then Sessions.GetSession(player) else nil
		if liveSession ~= session then
			return -- player left or session was rebuilt
		end
		local liveNode = liveSession.devices[deviceId]
		if liveNode == nil then
			return -- device removed mid-install
		end
		liveSession.flags["installing_" .. deviceId] = nil
		liveNode.osInstalled = osName
		pushLines(player, {
			g("[ ok ] OS terinstall: " .. osName .. " on " .. liveNode.name),
			gr("Lanjut: vm create --name <n> --cpu <n> --ram <n> --disk <n>"),
		})
		playSfx(player, "cash")
	end)
	return lines
end

local function cmdStressTest(player: Player, session: any, _tokens: { string }): { string }
	local node, err = requireBareMetal(session, "stress-test")
	if err ~= nil then
		return { r(err) }
	end
	if node.osInstalled == nil then
		return { r("stress-test: OS belum terinstall (install-os dulu)") }
	end
	local deviceId = node.id
	local guardKey = "stress_" .. deviceId
	if session.flags[guardKey] then
		return { r("stress-test: sudah berjalan di " .. node.name) }
	end
	session.flags[guardKey] = true

	local lines: { string } = {}
	table.insert(lines, gr("stress-test: running burn-in on ") .. g(node.name) .. gr(" ..."))
	table.insert(lines, gr("  cpu: 100% semua core | ram sweep | nvme seq+rand"))
	table.insert(lines, gr("  hasil akan muncul dalam ±5 detik ..."))

	task.delay(5, function()
		local liveSession = if Sessions ~= nil then Sessions.GetSession(player) else nil
		if liveSession ~= session then
			return
		end
		local liveNode = liveSession.devices[deviceId]
		if liveNode == nil then
			return
		end
		liveSession.flags["stress_" .. deviceId] = nil
		-- burn-in drives load to 95%: temp = 30 + 95 * 0.45 = 72.75 (< 80 limit)
		local peakTemp = 30 + 95 * 0.45
		liveNode.temperatureC = peakTemp
		local resultLines: { string } = {}
		if peakTemp < 80 then
			table.insert(resultLines, g(string.format("[PASS] stress-test 5s: temp peak %.1fC (limit 80C)", peakTemp)))
			table.insert(resultLines, gr("CPU / RAM / storage: semua OK - server tervalidasi"))
			if deviceId == "bench_1" and liveSession.workbench ~= nil then
				liveSession.workbench.tested = true
				table.insert(resultLines, g("Custom build validated - siap di-ship dari workbench"))
			end
			playSfx(player, "cash")
		else
			table.insert(resultLines, r(string.format("[FAIL] stress-test: temp peak %.1fC (>= 80C)", peakTemp)))
		end
		pushLines(player, resultLines)
	end)
	return lines
end

---------------------------------------------------------------------
-- Dispatcher & remote binding
---------------------------------------------------------------------

local function dispatch(player: Player, session: any, tokens: { string }): { string }
	local cmd = string.lower(tokens[1] or "")
	if cmd == "help" or cmd == "?" then
		return cmdHelp()
	elseif cmd == "clear" then
		return { "__CLEAR__" } -- sentinel: client wipes the output buffer
	elseif cmd == "ping" then
		return cmdPing(session, tokens)
	elseif cmd == "traceroute" then
		return cmdTraceroute(session, tokens)
	elseif cmd == "ip" then
		return cmdIp(session, tokens)
	elseif cmd == "ssh" then
		return cmdSsh(session, tokens)
	elseif cmd == "exit" then
		return cmdExit(session)
	elseif cmd == "top" then
		return cmdTop(session)
	elseif cmd == "vm" then
		return cmdVm(session, tokens)
	elseif cmd == "install-os" then
		return cmdInstallOs(player, session, tokens)
	elseif cmd == "stress-test" then
		return cmdStressTest(player, session, tokens)
	end
	return { r("command not found: " .. cmd) .. gr("  (ketik 'help')") }
end

-- ExecuteCommand.OnServerInvoke(player, rawText) -> {lines = {string}}
local function onInvoke(player: Player, rawText: any): { lines: { string } }
	local session = if Sessions ~= nil then Sessions.GetSession(player) else nil
	if session == nil then
		return { lines = { r("Session belum siap. Tunggu sebentar ...") } }
	end
	if type(rawText) ~= "string" or #rawText == 0 then
		return { lines = {} }
	end
	if #rawText > 240 then
		return { lines = { r("command terlalu panjang (max 240 karakter)") } }
	end
	local tokens: { string } = {}
	for token in string.gmatch(rawText, "%S+") do
		table.insert(tokens, token)
	end
	if #tokens == 0 then
		return { lines = {} }
	end
	local ok, result = pcall(dispatch, player, session, tokens)
	if not ok then
		return { lines = { r("internal error: " .. tostring(result)) } }
	end
	return { lines = result }
end

-- Init(deps) per CONTRACT section 6 AGENT A. Binds ExecuteCommand.
function CommandExecutor.Init(deps: { [string]: any })
	Sessions = deps.sessions
	Graph = deps.graph
	Utils = deps.utils
	Catalog = deps.catalog
	Constants = deps.constants
	Workbench = deps.workbench
	Cabling = deps.cabling
	Remotes = deps.remotesFolder

	local executeRemote = Remotes:FindFirstChild("ExecuteCommand")
	if executeRemote == nil then
		executeRemote = Remotes:WaitForChild("ExecuteCommand", 60)
	end
	if executeRemote ~= nil then
		(executeRemote :: any).OnServerInvoke = onInvoke
	else
		warn("[CommandExecutor] ExecuteCommand remote not found - terminal disabled")
	end
end

return CommandExecutor
