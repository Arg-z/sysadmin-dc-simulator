--!strict
--[[
	CommandExecutor (ModuleScript, ServerScriptService/Core)
	Server-side handler of the terminal. Binds ExecuteCommand.OnServerInvoke
	(CONTRACT section 3) and implements the Fase 1 + Fase 2 CLI:
		help, clear, ping, traceroute, ip a/addr/set, ssh, exit, top,
		vm create/list/throttle/delete, install-os, stress-test, ship,
		vlan list/set/trunk, switch port <p> vlan|trunk, cable
		list/use/buy/cut, mount list/<rackId>.
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
local Placement: any = nil -- PlacementSystem module (cable spool purchase, mount)
local Carry: any = nil -- CarryAndMountSystem module (colocation crate)
local Remotes: any = nil -- ReplicatedStorage.Remotes folder

---------------------------------------------------------------------
-- RichText palette (CONTRACT: green #00FF66, blue #58A6FF, red #FF5555,
-- grey #8B949E) and small formatting helpers
---------------------------------------------------------------------

local HEX_GREEN = "#00FF66"
local HEX_BLUE = "#58A6FF"
local HEX_RED = "#FF5555"
local HEX_GREY = "#8B949E"

-- Roblox RichText documents rgb(r, g, b); some clients treat hex
-- #RRGGBB as an invalid color and fall back to plain text.
local function hexToRgbCss(hex: string): string
	local r = tonumber(string.sub(hex, 2, 3), 16) or 0
	local g = tonumber(string.sub(hex, 4, 5), 16) or 0
	local b = tonumber(string.sub(hex, 6, 7), 16) or 0
	return string.format("rgb(%d, %d, %d)", r, g, b)
end
local function rich(hex: string, text: string): string
	local payload = text
	if Utils ~= nil then
		payload = Utils.EscapeRich(text)
	end
	return string.format('<font color="%s">%s</font>', hexToRgbCss(hex), payload)
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
		return "", "Not connected: device not found"
	end
	return targetId, nil
end

-- Commands that inspect/mutate a device require console or SSH context.
-- Returns (node, errorLine?).
local function requireDevice(session: any, commandName: string): (any, string?)
	if session.terminal.mode == "Disconnected" then
		return nil, commandName .. ": not connected to a device (attach console cable or 'ssh <ip>' first)"
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
	table.insert(lines, b("=== NETSIM SHELL - COMMAND REFERENCE ==="))
	table.insert(lines, b("-- Networking --"))
	table.insert(lines, "  " .. g("ping <ip>") .. gr("                  test reachability (4 ICMP packets)"))
	table.insert(lines, "  " .. g("traceroute <ip>") .. gr("              trace hop-by-hop network route"))
	table.insert(lines, "  " .. g("vlan list") .. gr("                    list port VLANs on active switch/router"))
	table.insert(lines, "  " .. g("vlan set <port> <id>") .. gr("        set port VLAN (e.g., vlan set eth2 20)"))
	table.insert(lines, "  " .. g("switch port <port> vlan <id>") .. gr("  switch port VLAN alias"))
	table.insert(lines, "  " .. g("switch port <port> trunk on") .. gr("    802.1Q trunk (carry all VLANs)"))
	table.insert(lines, b("-- Cabling --"))
	table.insert(lines, "  " .. g("cable") .. gr("                        show spool stock & active color"))
	table.insert(lines, "  " .. g("cable use <color>") .. gr("            LAN_Blue | WAN_Yellow | Mgmt_Red"))
	table.insert(lines, "  " .. g("cable buy <color>") .. gr("            buy 1 spool (5 cables)"))
	table.insert(lines, "  " .. g("cable cut <port>") .. gr("             cut cable on active device port"))
	table.insert(lines, b("-- Colocation --"))
	table.insert(lines, "  " .. g("mount list") .. gr("                   list racks & available U slots"))
	table.insert(lines, "  " .. g("mount [rackId]") .. gr("               mount carried colocation crate"))
	table.insert(lines, b("-- Incidents & Shift --"))
	table.insert(lines, "  " .. g("incident") .. gr("                      list active outages & resolution steps"))
	table.insert(lines, "  " .. g("ddos block <ip>") .. gr("             mitigate DDoS from router console"))
	table.insert(lines, "  " .. g("drive status") .. gr("                 check drive health on active host"))
	table.insert(lines, "  " .. g("drive replace [bay]") .. gr("         replace failed drive (needs replacement_hdd)"))
	table.insert(lines, "  " .. g("shift") .. gr("                         shift clock, stats & last settlement"))
	table.insert(lines, b("-- Interface --"))
	table.insert(lines, "  " .. g("ip a | ip addr") .. gr("                show hostname, IP, mask, gateway & ports"))
	table.insert(lines, "  " .. g("ip set <ip> <gw> [mask]") .. gr("      configure static IP on active device"))
	table.insert(lines, b("-- Remote --"))
	table.insert(lines, "  " .. g("ssh <ip>") .. gr("                      SSH into device via mgmt bridge / LAN"))
	table.insert(lines, "  " .. g("exit") .. gr("                         exit SSH session / detach console cable"))
	table.insert(lines, b("-- System --"))
	table.insert(lines, "  " .. g("top") .. gr("                          monitor CPU/RAM/temp on active host"))
	table.insert(lines, "  " .. g("install-os <os>") .. gr("              ubuntu-22.04 | debian-12 | rocky-9"))
	table.insert(lines, "  " .. g("stress-test") .. gr("                   5-second thermal burn-in validation"))
	table.insert(lines, "  " .. g("ship") .. gr("                          ship custom workbench server to dock"))
	table.insert(lines, b("-- Observability & Ops --"))
	table.insert(lines, "  " .. g("sensors") .. gr("                      CPU temp, fan RPM, thermal status"))
	table.insert(lines, "  " .. g("smartctl") .. gr("                     drive SMART health & predictive wear"))
	table.insert(lines, "  " .. g("journalctl [-n N]") .. gr("            system log (link events, incidents, ops)"))
	table.insert(lines, "  " .. g("iftop") .. gr("                        live interface traffic (rx/tx Mbps)"))
	table.insert(lines, "  " .. g("systemctl [restart <svc>]") .. gr("    service states; restart crashed units"))
	table.insert(lines, "  " .. g("uptime | df | free | uname") .. gr("   load, disk, memory, kernel info"))
	table.insert(lines, b("-- Virtual Machines --"))
	table.insert(lines, "  " .. g("vm create --name <n> --cpu <n> --ram <n> --disk <n>"))
	table.insert(lines, "  " .. g("vm list") .. gr("                       list VMs on active host"))
	table.insert(lines, "  " .. g("vm throttle <name> --limit <pct>") .. gr("   cap VM CPU usage (5-100)"))
	table.insert(lines, "  " .. g("vm delete <name>") .. gr("              delete VM and reclaim host resources"))
	table.insert(lines, b("-- Terminal --"))
	table.insert(lines, "  " .. g("clear") .. gr("                        clear terminal screen"))
	table.insert(lines, "  " .. g("help") .. gr("                         show this command list"))
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
		table.insert(lines, r("WARNING: broadcast storm detected (topology loop exists)"))
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
	table.insert(lines, gr("traceroute to " .. targetIP .. ", " .. num(#path - 1) .. " hops:"))
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
		table.insert(lines, b("inet:      ") .. g(Constants.LAPTOP_BRIDGE_IP .. "/24") .. gr("  (Wi-Fi management bridge)"))
		table.insert(lines, b("gateway:   ") .. gr("--"))
		table.insert(lines, gr("--- ports ---"))
		table.insert(lines, "  " .. g("wifi0") .. "  " .. g("UP") .. "    " .. gr("vlan 1  peer --"))
		table.insert(lines, gr("hint: equip laptop + press [E] on a device console port to connect"))
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
		table.insert(lines, b("inet:      ") .. r("-- not set") .. gr("  (ip set <ip> <gw>)"))
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
		return { r("IP conflict: " .. ip .. " is reserved for laptop bridge") }
	end
	if Graph.IsIPUsedByOther(session, ip, node.id) then
		local holder = Graph.FindDeviceByIP(session, ip)
		local holderName = if holder ~= nil then holder.name else "?"
		return { r("IP conflict: " .. ip .. " is already used by " .. holderName) }
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
			return { r("ssh: connect to host " .. targetIP .. " port 22: Connection refused (device powered off)") }
		end
		if targetNode.isUnderDDoS == true then
			return { r("ssh: connect to host " .. targetIP .. " port 22: Operation timed out (target under DDoS flood)") }
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
			return { r("ssh: already connected to this device") }
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
	table.insert(lines, gr("type 'exit' to return"))
	return lines
end

local function cmdExit(session: any): { string }
	local term = session.terminal
	if term.mode == "Disconnected" then
		return { gr("Already in local shell (laptop).") }
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
		return { gr("Returned to console ") .. g(consoleNode.name) }
	elseif top ~= nil and session.devices[top] ~= nil then
		term.mode = "RemoteSSH"
		term.targetDeviceId = top
		local node = session.devices[top]
		notifyMode(session, "RemoteSSH", node)
		return { gr("Returned to ") .. g(node.name) .. gr(" (" .. (node.ip or "?") .. ")") }
	else
		term.mode = "Disconnected"
		term.targetDeviceId = nil
		term.sshStack = {}
		notifyMode(session, "Disconnected", nil)
		return { gr("Returned to local shell (laptop).") }
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
		table.insert(lines, gr("  (no VMs yet - try: vm create --name web-1 --cpu 2 --ram 4 --disk 50)"))
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
		return nil, commandName .. ": device is not BareMetal (" .. node.deviceType .. ")"
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
		return { r("vm create: OS is not installed yet (run 'install-os' first)") }
	end
	if not node.isPowered then
		return { r("vm create: device is powered off (turn it on first)") }
	end
	local name = parseFlag(tokens, "--name")
	local cpu = tonumber(parseFlag(tokens, "--cpu") or "")
	local ram = tonumber(parseFlag(tokens, "--ram") or "")
	local disk = tonumber(parseFlag(tokens, "--disk") or "")
	if name == nil or cpu == nil or ram == nil or disk == nil then
		return { r("vm create: usage: vm create --name <n> --cpu <n> --ram <n> --disk <n>") }
	end
	if cpu <= 0 or ram <= 0 or disk <= 0 then
		return { r("vm create: --cpu / --ram / --disk must be > 0") }
	end
	-- sanitize VM name: 1-16 chars of [A-Za-z0-9_-]
	if #name > 16 or string.match(name, "^[%w%-_]+$") == nil then
		return { r("vm create: invalid VM name (1-16 letters/digits/-/_): '" .. name .. "'") }
	end
	if node.vms[name] ~= nil then
		return { r("vm create: VM name '" .. name .. "' already exists on this host") }
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
		return { r(string.format("vm create: insufficient CPU (%s/%s used, requested %s)", num(usedCpu), num(specs.cpu), num(cpu))) }
	end
	if usedRam + ram > specs.ram then
		return { r(string.format("vm create: insufficient RAM (%s/%s GB used, requested %s GB)", num(usedRam), num(specs.ram), num(ram))) }
	end
	if usedDisk + disk > specs.disk then
		return { r(string.format("vm create: insufficient disk (%s/%s GB used, requested %s GB)", num(usedDisk), num(specs.disk), num(disk))) }
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
		return { gr("(empty) No VMs running on " .. node.name) }
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
		return { r("vm throttle: limit must be a number (5-100)") }
	end
	limit = math.clamp(math.floor(limit + 0.5), 5, 100)
	local vm = node.vms[name]
	if vm == nil then
		return { r("vm throttle: VM '" .. name .. "' not found") }
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
		return { r("vm delete: VM '" .. name .. "' not found") }
	end
	node.vms[name] = nil
	return { g("VM '" .. name .. "' deleted, resources returned to host") }
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
		return { r("install-os: choose one: install-os ubuntu-22.04 | debian-12 | rocky-9") }
	end
	local deviceId = node.id
	local guardKey = "installing_" .. deviceId
	if session.flags[guardKey] then
		return { r("install-os: installation already running on " .. node.name) }
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
		Graph.Journal(liveSession, "info", "installer", liveNode.name .. ": OS installed (" .. osName .. ")")
		pushLines(player, {
			g("[ ok ] OS installed: " .. osName .. " on " .. liveNode.name),
			gr("Next: vm create --name <n> --cpu <n> --ram <n> --disk <n>"),
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
		return { r("stress-test: OS not installed yet (run 'install-os' first)") }
	end
	local deviceId = node.id
	local guardKey = "stress_" .. deviceId
	if session.flags[guardKey] then
		return { r("stress-test: already running on " .. node.name) }
	end
	session.flags[guardKey] = true

	local lines: { string } = {}
	table.insert(lines, gr("stress-test: running burn-in on ") .. g(node.name) .. gr(" ..."))
	table.insert(lines, gr("  cpu: 100% all cores | ram sweep | nvme seq+rand"))
	table.insert(lines, gr("  results will appear in ~5 seconds ..."))

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
			table.insert(resultLines, g(string.format("[PASS] stress-test 5s: peak temp %.1fC (limit 80C)", peakTemp)))
			table.insert(resultLines, gr("CPU / RAM / storage: all OK - server validated"))
			if deviceId == "bench_1" and liveSession.workbench ~= nil then
				liveSession.workbench.tested = true
				table.insert(resultLines, g("Custom build validated - type 'ship' to send crate to dock"))
			end
			playSfx(player, "cash")
		else
			table.insert(resultLines, r(string.format("[FAIL] stress-test: peak temp %.1fC (>= 80C)", peakTemp)))
		end
		pushLines(player, resultLines)
	end)
	return lines
end

local function cmdShip(session: any): { string }
	if Workbench == nil or type(Workbench.Ship) ~= "function" then
		return { r("ship: workbench system is not available") }
	end
	local ok, errMsg = Workbench.Ship(session)
	if not ok then
		return { r("ship: " .. tostring(errMsg)) }
	end
	return {
		g("[ ok ] Custom server shipped to Loading Dock!"),
		gr("Contract payout added to your lab balance."),
	}
end

---------------------------------------------------------------------
-- Fase 2: cable spools, VLAN, carry & mount
---------------------------------------------------------------------

local CABLE_ALIASES: { [string]: string } = {
	lan = "LAN_Blue",
	blue = "LAN_Blue",
	biru = "LAN_Blue",
	wan = "WAN_Yellow",
	yellow = "WAN_Yellow",
	kuning = "WAN_Yellow",
	mgmt = "Mgmt_Red",
	red = "Mgmt_Red",
	merah = "Mgmt_Red",
}

local function normalizeCableColor(raw: string?): string?
	if raw == nil then
		return nil
	end
	for _, color in ipairs(Constants.CABLES.colors) do
		if string.lower(color) == string.lower(raw) then
			return color
		end
	end
	return CABLE_ALIASES[string.lower(raw)]
end

local function vlanDeviceId(session: any): string
	local target = session.terminal.targetDeviceId
	if type(target) == "string" then
		local node = session.devices[target]
		if node ~= nil and (node.deviceType == "Switch" or node.deviceType == "Router") then
			return target
		end
	end
	return "sw_main_1"
end

local function cableStockLines(session: any): { string }
	local selected = session.selectedCableColor or "LAN_Blue"
	local lines: { string } = {
		b("=== CABLE SPOOLS ==="),
		string.format("  Active color : %s", selected),
	}
	for _, color in ipairs(Constants.CABLES.colors) do
		local label = Constants.CABLES.labels[color] or color
		local count = tonumber(session.cableSpools[color]) or 0
		table.insert(lines, string.format("  %-10s : %d cables (%s)", color, count, label))
	end
	table.insert(lines, gr("cable use <color> | cable buy <color> | cable cut <port>"))
	return lines
end

local function cmdCable(player: Player, session: any, tokens: { string }): { string }
	local sub = if tokens[2] ~= nil then string.lower(tokens[2]) else nil
	if sub == nil or sub == "list" or sub == "status" then
		return cableStockLines(session)
	end

	if sub == "use" then
		local color = normalizeCableColor(tokens[3])
		if color == nil then
			return { r("cable use: choose LAN_Blue | WAN_Yellow | Mgmt_Red") }
		end
		session.selectedCableColor = color
		playSfx(player, "key")
		return { g("Active cable color: " .. color .. " (" .. (Constants.CABLES.labels[color] or color) .. ")") }
	end

	if sub == "buy" then
		local color = normalizeCableColor(tokens[3]) or session.selectedCableColor or "LAN_Blue"
		local itemId = Constants.CABLES.itemByColor[color]
		if itemId == nil then
			return { r("cable buy: unknown cable color") }
		end
		if Placement == nil then
			return { r("cable buy: store system not available") }
		end
		Placement.OnPurchase(player, itemId, "buy", nil, nil)
		return { gr("Spool purchase for " .. color .. " processed.") }
	end

	if sub == "cut" then
		local deviceId = vlanDeviceId(session)
		local portId = tokens[3]
		if tokens[4] ~= nil then
			deviceId = tokens[3] :: string
			portId = tokens[4]
		end
		if portId == nil then
			return { r("cable cut: usage: cable cut <port>  |  cable cut <deviceId> <port>") }
		end
		local node = session.devices[deviceId]
		if node == nil then
			return { r("cable cut: device not found") }
		end
		local port = node.ports[portId]
		if port == nil then
			return { r("cable cut: port not found") }
		end
		if port.connectedToDeviceId == nil then
			return { r(string.format("%s:%s is not connected", node.name, portId)) }
		end
		Graph.DisconnectPort(session, deviceId, portId)
		playSfx(player, "plug")
		return { g(string.format("Cable on %s:%s disconnected.", node.name, portId)) }
	end

	return { r("cable: usage: cable | cable use <color> | cable buy <color> | cable cut <port>") }
end

local function vlanUsage(): { string }
	return { r("vlan: usage: vlan list | vlan set <port> <id> | vlan trunk <port> on|off | vlan set <deviceId> <port> <id>") }
end

local function cmdVlan(session: any, tokens: { string }): { string }
	local sub = if tokens[2] ~= nil then string.lower(tokens[2]) else nil
	if sub == nil or sub == "list" or sub == "show" then
		local deviceId = vlanDeviceId(session)
		local node = session.devices[deviceId]
		if node == nil then
			return { r("vlan: active device not found") }
		end
		local lines: { string } = { b(string.format("=== VLAN %s (%s) ===", node.name, deviceId)) }
		for _, line in ipairs(Graph.ListPortVlans(session, deviceId)) do
			table.insert(lines, "  " .. line)
		end
		table.insert(lines, gr("Set: vlan set <port> <id>   e.g.: vlan set eth2 20"))
		return lines
	end

	if sub == "trunk" then
		local deviceId = vlanDeviceId(session)
		local portId = tokens[3]
		local modeRaw = tokens[4]
		if tokens[5] ~= nil then
			deviceId = tokens[3] :: string
			portId = tokens[4]
			modeRaw = tokens[5]
		end
		if portId == nil then
			return { r("vlan trunk: usage: vlan trunk <port> on|off") }
		end
		local mode = string.lower(modeRaw or "on")
		local enabled = mode == "on" or mode == "true" or mode == "1"
		local okTrunk, trunkErr = Graph.SetPortTrunk(session, deviceId, portId, enabled)
		if not okTrunk then
			return { r("vlan trunk: " .. trunkErr) }
		end
		return { g(string.format("%s:%s trunk %s", deviceId, portId, if enabled then "ON" else "OFF")) }
	end

	if sub ~= "set" then
		return vlanUsage()
	end

	local deviceId = vlanDeviceId(session)
	local portId = tokens[3]
	local vlanRaw = tokens[4]
	if tokens[5] ~= nil then
		deviceId = tokens[3] :: string
		portId = tokens[4]
		vlanRaw = tokens[5]
	end
	if portId == nil or vlanRaw == nil then
		return vlanUsage()
	end
	local node = session.devices[deviceId]
	if node == nil then
		return { r("vlan: device not found") }
	end
	if node.deviceType ~= "Switch" and node.deviceType ~= "Router" then
		return { r("vlan: only switch/router ports support VLANs") }
	end
	local vlan = tonumber(vlanRaw)
	if vlan == nil then
		return { r("vlan: id must be a number 1..4094") }
	end
	local ok, err = Graph.SetPortVlan(session, deviceId, portId, vlan)
	if not ok then
		return { r("vlan: " .. err) }
	end
	return { g(string.format("VLAN %s:%s -> %d", node.name, portId, math.floor(vlan))) }
end

local function cmdSwitch(session: any, tokens: { string }): { string }
	local deviceId = vlanDeviceId(session)
	local index = 2
	local candidate = tokens[2]
	if candidate ~= nil and candidate ~= "port" and candidate ~= "list" and session.devices[candidate] ~= nil then
		deviceId = candidate
		index = 3
	end
	local node = session.devices[deviceId]
	if node == nil then
		return { r("switch: device not found") }
	end
	if node.deviceType ~= "Switch" and node.deviceType ~= "Router" then
		return { r("switch: command is only for switches/routers") }
	end

	local action = tokens[index]
	if action == nil or action == "list" then
		local lines: { string } = { b(string.format("=== PORTS %s (%s) ===", node.name, deviceId)) }
		for _, line in ipairs(Graph.ListPortVlans(session, deviceId)) do
			table.insert(lines, "  " .. line)
		end
		return lines
	end
	if action ~= "port" then
		return { r("switch: usage: switch [deviceId] port <port> vlan <id> | switch [deviceId] port <port> trunk on|off | switch [deviceId] list") }
	end
	local portId = tokens[index + 1]
	local keyword = tokens[index + 2]
	local value = tokens[index + 3]
	if portId == nil or keyword == nil then
		return { r("switch: usage: switch [deviceId] port <port> vlan <id> | switch [deviceId] port <port> trunk on|off") }
	end
	if keyword == "trunk" then
		local mode = string.lower(value or "on")
		local enabled = mode == "on" or mode == "true" or mode == "1"
		local okTrunk, trunkErr = Graph.SetPortTrunk(session, deviceId, portId, enabled)
		if not okTrunk then
			return { r("switch: " .. trunkErr) }
		end
		return { g(string.format("%s:%s trunk %s", node.name, portId, if enabled then "ON" else "OFF")) }
	end
	if keyword ~= "vlan" or value == nil then
		return { r("switch: usage: switch [deviceId] port <port> vlan <id> | switch [deviceId] port <port> trunk on|off") }
	end
	local vlan = tonumber(value)
	if vlan == nil then
		return { r("switch: VLAN id must be a number 1..4094") }
	end
	local ok, err = Graph.SetPortVlan(session, deviceId, portId, vlan)
	if not ok then
		return { r("switch: " .. err) }
	end
	return { g(string.format("VLAN %s:%s -> %d", node.name, portId, math.floor(vlan))) }
end

local function cmdMount(session: any, tokens: { string }): { string }
	local sub = tokens[2]
	if sub == "list" or sub == nil then
		local rackIds: { string } = {}
		for rackId in pairs(session.racks) do
			table.insert(rackIds, rackId)
		end
		table.sort(rackIds)
		local lines: { string } = { b("=== RACKS & SLOTS ===") }
		for _, rackId in ipairs(rackIds) do
			local rack = session.racks[rackId]
			local used = 0
			for _ in pairs(rack.occupiedSlots) do
				used += 1
			end
			local free = Placement.FindFreeUSlot(session, rackId, Constants.COLOCATION.uSize)
			table.insert(lines, string.format(
				"  %s  %s  %d/%dU  PDU %s  %s",
				rackId,
				rack.name,
				used,
				rack.maxU,
				if rack.pduPowered then "ON" else "OFF",
				if free ~= nil then string.format("fits %dU at U%d", Constants.COLOCATION.uSize, free) else "full"
			))
		end
		table.insert(lines, gr("Pick up colocation crate, then run: mount <rackId>"))
		return lines
	end

	if Carry == nil then
		return { r("mount: carry system not available") }
	end
	local rackId = sub
	if session.racks[rackId] == nil then
		return { r("mount: rack not found (" .. tostring(rackId) .. ")") }
	end
	if Carry.MountCarried(session, rackId) then
		return { g("Crate mounted into " .. rackId) }
	end
	return {}
end

---------------------------------------------------------------------
-- Fase 3: incidents, DDoS mitigation, drive replacement, shift info
---------------------------------------------------------------------

local function cmdIncident(session: any): { string }
	local lines: { string } = { b("=== ACTIVE / RECENT INCIDENTS ===") }
	local shown = 0
	for _, t in ipairs(session.tickets or {}) do
		if t.category == "Incident" and (t.status == "Active" or t.status == "Completed" or t.status == "Failed") then
			shown += 1
			local headerColor = if t.status == "Active" then r(t.title) elseif t.status == "Completed" then g(t.title) else gr(t.title)
			local sla = if t.status == "Active" then string.format("  SLA %ds", t.slaRemainingSec or 0) else "  [" .. tostring(t.status) .. "]"
			table.insert(lines, headerColor .. gr(sla))
			if t.validationText ~= nil and t.validationText ~= "" then
				table.insert(lines, gr("  Status : ") .. t.validationText)
			end
			if t.requirementsText ~= nil and t.requirementsText ~= "" then
				table.insert(lines, gr("  Resolve: ") .. t.requirementsText)
			end
		end
	end
	if shown == 0 then
		table.insert(lines, gr("No active incidents. Outages may trigger during peak hours (11:00-17:00)."))
	end
	return lines
end

local function cmdDDoS(player: Player, session: any, tokens: { string }): { string }
	local sub = if tokens[2] ~= nil then string.lower(tokens[2]) else "list"
	if sub ~= "block" then
		local lines: { string } = { b("=== DDoS STATUS ===") }
		local found = 0
		for _, node in pairs(session.devices) do
			if node.isUnderDDoS == true then
				found += 1
				table.insert(lines, r(string.format("%s (%s) under attack from %s", node.name, node.ip or "?", node.ddosAttackerIp or "?")))
			end
		end
		if found == 0 then
			table.insert(lines, gr("No active DDoS attacks."))
		end
		table.insert(lines, gr("Mitigate: run 'ddos block <attackerIp>' on router console."))
		return lines
	end

	local ip = tokens[3]
	if ip == nil then
		return { r("ddos block: usage: ddos block <ip>") }
	end
	if Utils == nil or not Utils.IsValidIPv4(ip) then
		return { r("ddos block: invalid IPv4 address") }
	end
	local node, err = requireDevice(session, "ddos block")
	if err ~= nil then
		return { r(err) }
	end
	if node.deviceType ~= "Router" then
		return { r("ddos block: run on router console (not " .. node.name .. ")") }
	end
	node.blockedIps[ip] = true
	local cleared = 0
	for _, victim in pairs(session.devices) do
		if victim.isUnderDDoS == true and victim.ddosAttackerIp == ip then
			victim.isUnderDDoS = false
			victim.ddosAttackerIp = nil
			cleared += 1
			if Graph ~= nil then
				Graph.UpdateDeviceLED(session, victim.id)
			end
		end
	end
	playSfx(player, if cleared > 0 then "plug" else "error")
	local lines: { string } = {
		g(string.format("Firewall %s: blocked %s.", node.name, ip)),
	}
	if cleared > 0 then
		table.insert(lines, g(string.format("%d device(s) recovered from DDoS flood.", cleared)))
	else
		table.insert(lines, gr("No active target matched that IP (rule saved)."))
	end
	return lines
end

local function cmdDrive(player: Player, session: any, tokens: { string }): { string }
	local node, err = requireDevice(session, "drive")
	if err ~= nil then
		return { r(err) }
	end
	if session.spareParts == nil then
		session.spareParts = { hdd = 0 }
	end
	local sub = if tokens[2] ~= nil then string.lower(tokens[2]) else "status"
	local spares = tonumber(session.spareParts.hdd) or 0

	if sub == "status" then
		local lines: { string } = { b("=== DRIVE " .. node.name .. " ===") }
		if node.hasDegradedDrive == true then
			table.insert(lines, r(string.format("Bay %d: FAILED - performance degraded, host payout paused", node.degradedBayIndex or 0)))
		else
			table.insert(lines, g("All drives healthy."))
		end
		table.insert(lines, gr("Spare replacement_hdd: " .. tostring(spares)))
		table.insert(lines, gr("Replace: drive replace <bay> (buy replacement_hdd in Store > Component)"))
		return lines
	end

	if sub ~= "replace" then
		return { r("drive: usage: drive status | drive replace [bay]") }
	end
	if node.hasDegradedDrive ~= true then
		return { r("drive replace: no failed drive on " .. node.name) }
	end
	local bay = tonumber(tokens[3]) or node.degradedBayIndex
	if bay == nil then
		return { r("drive replace: unknown bay") }
	end
	if node.degradedBayIndex ~= nil and bay ~= node.degradedBayIndex then
		return { r(string.format("drive replace: bay %d is healthy - failed bay is %d", bay, node.degradedBayIndex)) }
	end
	if spares <= 0 then
		return { r("drive replace: no replacement_hdd in stock. Buy one in Store > Component ($90).") }
	end
	session.spareParts.hdd = spares - 1
	node.hasDegradedDrive = false
	node.degradedBayIndex = nil
	node.smartReallocated = 0
	node.smartPending = 0
	node.smartHealth = 100
	node.smartWarned = false
	Graph.Journal(session, "info", "smartd", node.name .. ": bay " .. tostring(bay) .. " replaced - array healthy")
	if Graph ~= nil then
		Graph.UpdateDeviceLED(session, node.id)
	end
	playSfx(player, "plug")
	return {
		g(string.format("Drive bay %d replaced on %s. Storage array healthy.", bay, node.name)),
		gr("Remaining spare replacement_hdd: " .. tostring(session.spareParts.hdd)),
	}
end

local function cmdShift(session: any): { string }
	local shift = session.shift
	if shift == nil then
		return { r("shift: shift state unavailable") }
	end
	local total = math.floor(shift.clockMinutes) % (24 * 60)
	local phase = "SHIFT"
	if shift.clockMinutes >= Constants.SHIFT.peakStartMinutes and shift.clockMinutes < Constants.SHIFT.peakEndMinutes then
		phase = "PEAK HOURS (11:00-17:00)"
	elseif shift.clockMinutes >= Constants.SHIFT.peakEndMinutes then
		phase = "CLOSING"
	end
	local lines: { string } = {
		b("=== SHIFT STATUS ==="),
		string.format("  Day         : %d", session.day),
		string.format("  Time        : %02d:%02d  (%s)", math.floor(total / 60), total % 60, phase),
		string.format("  Contracts   : %d completed", shift.stats.contractsCompleted),
		string.format("  Incidents   : %d resolved, %d failed", shift.stats.incidentsResolved, shift.stats.incidentsFailed),
	}
	if shift.lastSettlementText ~= nil then
		table.insert(lines, gr("  Last Settle : " .. shift.lastSettlementText))
	end
	table.insert(lines, gr("Shift runs 08:00-18:00; daily settlement runs at 18:00."))
	return lines
end

---------------------------------------------------------------------
-- Sysadmin telemetry & operations commands (real-world CLI surface)
---------------------------------------------------------------------

local function fmtUptime(sec: number): string
	local d = math.floor(sec / 86400)
	local h = math.floor((sec % 86400) / 3600)
	local m = math.floor((sec % 3600) / 60)
	if d > 0 then
		return string.format("%d day%s, %d:%02d", d, if d == 1 then "" else "s", h, m)
	end
	return string.format("%d:%02d", h, m)
end

local function cmdSensors(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "sensors")
	if err ~= nil then
		return { r(err) }
	end
	local temp = node.temperatureC or 30
	local status = if temp >= 80 then r("CRITICAL - thermal throttling") elseif temp >= 65 then r("WARM - check airflow") else g("OPTIMAL")
	local lines: { string } = {
		b("=== SENSORS - " .. node.name .. " ==="),
		"coretemp-isa-0000",
		string.format("  Package id 0:  +%.1f C  (high = +80.0 C, crit = +95.0 C)", temp),
		string.format("  fan1:        %d RPM  (min 2800, max 9000)", node.fanRpm or 0),
		string.format("  fan2:        %d RPM", math.floor((node.fanRpm or 0) * 0.94)),
		"  Thermal status: " .. status,
	}
	if node.isUnderDDoS == true then
		table.insert(lines, r("  NOTE: load pinned at 100% by inbound flood traffic"))
	end
	return lines
end

local function cmdSmartctl(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "smartctl")
	if err ~= nil then
		return { r(err) }
	end
	if node.deviceType ~= "BareMetal" and node.deviceType ~= "ColocationServer" then
		return { r("smartctl: no SMART-capable drives on " .. node.name) }
	end
	local lines: { string } = { b("=== SMART - " .. node.name .. " ===") }
	local failedBay = node.degradedBayIndex
	for bay = 1, 4 do
		if failedBay ~= nil and bay == failedBay then
			table.insert(lines, r(string.format("  Bay %d: FAILED    reallocated=%d pending=%d health=%d%%", bay, node.smartReallocated or 0, node.smartPending or 0, node.smartHealth or 0)))
		else
			table.insert(lines, g(string.format("  Bay %d: HEALTHY   reallocated=0 pending=0 health=100%%", bay)))
		end
	end
	local health = node.smartHealth or 100
	if failedBay ~= nil then
		table.insert(lines, r("  Overall: DEGRADED - replace bay " .. tostring(failedBay) .. " (buy replacement_hdd + 'drive replace " .. tostring(failedBay) .. "')"))
	elseif health < 70 then
		table.insert(lines, r(string.format("  Overall: FAILING (%d%% health) - predictive warning: schedule replacement now", health)))
	elseif health < 90 then
		table.insert(lines, gr(string.format("  Overall: WEAR (%d%% health) - reallocated sectors accumulating", health)))
	else
		table.insert(lines, g("  Overall: HEALTHY"))
	end
	return lines
end

local function cmdJournalctl(session: any, tokens: { string }): { string }
	local count = 15
	if tokens[2] == "-n" then
		count = math.clamp(tonumber(tokens[3]) or 15, 1, 60)
	end
	local journal = session.journal or {}
	local lines: { string } = { b(string.format("=== JOURNALCTL - last %d of %d entries ===", math.min(count, #journal), #journal)) }
	local start = math.max(1, #journal - count + 1)
	for i = start, #journal do
		local e = journal[i]
		local body = string.format("%s %-7s %s: %s", e.t or "--:--", e.level or "info", e.unit or "kernel", e.msg or "")
		if e.level == "warning" or e.level == "err" then
			table.insert(lines, r(body))
		else
			table.insert(lines, gr(body))
		end
	end
	if #journal == 0 then
		table.insert(lines, gr("  (no entries yet)"))
	end
	return lines
end

local function cmdIftop(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "iftop")
	if err ~= nil then
		return { r(err) }
	end
	local lines: { string } = {
		b("=== IFTOP - " .. node.name .. " ==="),
		string.format("  total rx: %8.1f Mbps   tx: %8.1f Mbps", node.trafficInMbps or 0, node.trafficOutMbps or 0),
	}
	local portIds = {}
	for portId in pairs(node.ports) do
		table.insert(portIds, portId)
	end
	table.sort(portIds)
	for _, portId in ipairs(portIds) do
		local port = node.ports[portId]
		if port.portType ~= "Console" then
			local state = if port.linkUp then g("UP  ") else gr("DOWN")
			local bar = string.rep("|", math.clamp(math.floor((port.trafficLoadMbps or 0) / 40), 0, 10))
			table.insert(lines, string.format("  %-6s %s %6.1f Mbps  [%-10s]", portId, state, port.trafficLoadMbps or 0, bar))
		end
	end
	if node.isUnderDDoS == true then
		table.insert(lines, r("  WARNING: flood from " .. tostring(node.ddosAttackerIp) .. " - mitigate with 'ddos block " .. tostring(node.ddosAttackerIp) .. "' on the router"))
	end
	return lines
end

local function cmdUptime(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "uptime")
	if err ~= nil then
		return { r(err) }
	end
	local load = (node.loadPercent or 0) / 100 * math.max(1, (node.specs and node.specs.cpu) or 1)
	local clock = if session.shift ~= nil then session.shift.clockMinutes else 0
	return {
		string.format(" %02d:%02d:01 up %s,  1 user,  load average: %.2f, %.2f, %.2f",
			math.floor(clock / 60) % 24, math.floor(clock % 60), fmtUptime(node.uptimeSec or 0), load, load * 0.92, load * 0.85),
	}
end

local function cmdDf(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "df")
	if err ~= nil then
		return { r(err) }
	end
	local total = (node.specs and node.specs.disk) or 0
	if total <= 0 then
		return { r("df: no storage on " .. node.name) }
	end
	local used = 8 -- base OS footprint
	for _, vm in pairs(node.vms) do
		used += vm.disk or 0
	end
	used = math.min(used, total)
	local pct = math.floor(used / total * 100)
	local ramHalf = math.max(1, math.floor(((node.specs and node.specs.ram) or 1) / 2))
	return {
		b("Filesystem      Size  Used Avail Use% Mounted on"),
		string.format("/dev/sda1       %4dG %4dG %4dG %3d%% /", total, used, total - used, pct),
		string.format("tmpfs           %4dG    0G %4dG   0%% /dev/shm", ramHalf, ramHalf),
	}
end

local function cmdFree(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "free")
	if err ~= nil then
		return { r(err) }
	end
	local total = (node.specs and node.specs.ram) or 0
	local used = 1
	for _, vm in pairs(node.vms) do
		used += vm.ram or 0
	end
	used = math.min(used, total)
	local swap = math.max(1, math.floor(total / 4))
	return {
		b("               total        used        free      shared  buff/cache   available"),
		string.format("Mem:           %5dGi     %5dGi     %5dGi       0Gi     %5dGi     %5dGi", total, used, total - used, math.min(1, total), math.max(0, total - used - 1)),
		string.format("Swap:          %5dGi        0Gi     %5dGi", swap, swap),
	}
end

local function cmdUname(session: any, _tokens: { string }): { string }
	local node, err = requireDevice(session, "uname")
	if err ~= nil then
		return { r(err) }
	end
	local os = node.osInstalled
	if os == nil then
		return { r("uname: no OS installed (run 'install-os <os>')") }
	end
	local kernel = if os == "ubuntu-22.04" then "5.15.0-91-generic #101-Ubuntu SMP" elseif os == "debian-12" then "6.1.0-17-amd64 #1 SMP Debian" else "5.14.0-362.el9.x86_64 #1 SMP Rocky"
	return { "Linux " .. string.lower(node.name) .. " " .. kernel .. " x86_64 GNU/Linux" }
end

local function cmdSystemctl(player: Player, session: any, tokens: { string }): { string }
	local node, err = requireDevice(session, "systemctl")
	if err ~= nil then
		return { r(err) }
	end
	if node.osInstalled == nil then
		return { r("systemctl: no OS installed (run 'install-os <os>')") }
	end
	if node.services == nil or next(node.services) == nil then
		node.services = { sshd = "running", nginx = "running", cron = "running", node_exporter = "running" }
	end
	local sub = string.lower(tokens[2] or "status")
	local svc = tokens[3]
	if sub == "restart" then
		if svc == nil then
			return { r("systemctl restart: usage: systemctl restart <service>") }
		end
		svc = string.lower(svc)
		local state = node.services[svc]
		if state == nil then
			return { r("systemctl: unit " .. svc .. ".service not found") }
		end
		if state == "crashed" then
			node.services[svc] = "running"
			Graph.Journal(session, "info", "systemctl", node.name .. ": " .. svc .. ".service restarted successfully")
			playSfx(player, "plug")
			return { g("[ ok ] " .. svc .. ".service restarted - active (running)") }
		end
		return { gr(svc .. ".service is already active (running)") }
	end
	if svc ~= nil and node.services[string.lower(svc)] == nil then
		return { r("systemctl: unit " .. tostring(svc) .. ".service not found") }
	end
	local lines: { string } = { b("=== SYSTEMCTL - " .. node.name .. " ===") }
	local names = {}
	for name in pairs(node.services) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if svc == nil or string.lower(svc) == name then
			if node.services[name] == "crashed" then
				table.insert(lines, r(string.format("  %-16s CRASHED (failed) - 'systemctl restart %s'", name .. ".service", name)))
			else
				table.insert(lines, g(string.format("  %-16s active (running)", name .. ".service")))
			end
		end
	end
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
	elseif cmd == "ship" then
		return cmdShip(session)
	elseif cmd == "cable" then
		return cmdCable(player, session, tokens)
	elseif cmd == "vlan" then
		return cmdVlan(session, tokens)
	elseif cmd == "switch" then
		return cmdSwitch(session, tokens)
	elseif cmd == "mount" then
		return cmdMount(session, tokens)
	elseif cmd == "incident" or cmd == "insiden" then
		return cmdIncident(session)
	elseif cmd == "ddos" then
		return cmdDDoS(player, session, tokens)
	elseif cmd == "drive" then
		return cmdDrive(player, session, tokens)
	elseif cmd == "shift" then
		return cmdShift(session)
	elseif cmd == "sensors" then
		return cmdSensors(session, tokens)
	elseif cmd == "smartctl" then
		return cmdSmartctl(session, tokens)
	elseif cmd == "journalctl" then
		return cmdJournalctl(session, tokens)
	elseif cmd == "iftop" then
		return cmdIftop(session, tokens)
	elseif cmd == "uptime" then
		return cmdUptime(session, tokens)
	elseif cmd == "df" then
		return cmdDf(session, tokens)
	elseif cmd == "free" then
		return cmdFree(session, tokens)
	elseif cmd == "uname" then
		return cmdUname(session, tokens)
	elseif cmd == "systemctl" then
		return cmdSystemctl(player, session, tokens)
	end
	return { r("command not found: " .. cmd) .. gr("  (type 'help')") }
end

-- ExecuteCommand.OnServerInvoke(player, rawText) -> {lines = {string}}
local function onInvoke(player: Player, rawText: any): { lines: { string } }
	local session = if Sessions ~= nil then Sessions.GetSession(player) else nil
	if session == nil then
		return { lines = { r("Session not ready yet. Please wait a moment ...") } }
	end
	if type(rawText) ~= "string" or #rawText == 0 then
		return { lines = {} }
	end
	if #rawText > 240 then
		return { lines = { r("command too long (max 240 characters)") } }
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
	Placement = deps.placement
	Carry = deps.carry
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
