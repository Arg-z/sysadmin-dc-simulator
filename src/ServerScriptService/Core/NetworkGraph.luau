--!strict
--[[
	NetworkGraph (ModuleScript, ServerScriptService/Core)
	Authoritative network state store: devices, ports, cables and LEDs.
	Implements:
	- port layout + default node factory from the hardware catalog
	- link validation with color-coded Beam visuals (droop, width 0.12)
	- BFS reachability with VLAN isolation through switches, unpowered
	  nodes never forwarding, broadcast storm (topology loop) detection
	- routing path extraction for traceroute
	- smart auto-cabling to the nearest free port
	Fase 2 adds explicit port VLANs, 802.1Q trunks and inter-VLAN routing
	through routers (switches isolate VLANs; routers bridge them at L3).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HardwareCatalog = require(ReplicatedStorage.Shared.HardwareCatalog)
local PlotConstants = require(ReplicatedStorage.Shared.PlotConstants)
local NetworkUtils = require(ReplicatedStorage.Shared.NetworkUtils)
local SessionManager = require(script.Parent.SessionManager)

local NetworkGraph = {}

---------------------------------------------------------------------
-- Visual constants
---------------------------------------------------------------------

-- Beam colors per CableColorType (CONTRACT section 6 AGENT A)
local BEAM_COLORS: { [string]: ColorSequence } = {
	LAN_Blue = ColorSequence.new(Color3.fromRGB(70, 130, 255)),
	WAN_Yellow = ColorSequence.new(Color3.fromRGB(240, 210, 70)),
	Mgmt_Red = ColorSequence.new(Color3.fromRGB(230, 80, 80)),
}

-- Dark braided-jacket shade drawn under the coloured core beam so cables
-- read as round two-tone leads instead of flat single ribbons.
local BEAM_SHEATH_COLORS: { [string]: Color3 } = {
	LAN_Blue = Color3.fromRGB(28, 52, 105),
	WAN_Yellow = Color3.fromRGB(122, 102, 32),
	Mgmt_Red = Color3.fromRGB(108, 36, 36),
}

local LED_GREEN = Color3.fromRGB(85, 255, 120)
local LED_RED = Color3.fromRGB(255, 80, 80)
local LED_OFF = Color3.fromRGB(70, 70, 70)

local ISP_UPLINK_ID = "isp_uplink" -- WAN junction to the "internet"
local FALLBACK_SWITCH_ID = "sw_main_1" -- auto-cable fallback target
local AUTO_CABLE_RANGE = 60 -- studs

-- Init(deps): shared modules are required directly at the top, so deps are
-- reserved for future use (CONTRACT allows ignoring them).
function NetworkGraph.Init(_deps: { [string]: any }) end

--[[ Stable key for one physical link, independent of endpoint order.
	 Used by the Fase 3 incident engine (Cable Fault marks a link as bad and
	 clears the mark once the player re-cables the same pair). ]]
function NetworkGraph.LinkKey(devA: string, portA: string, devB: string, portB: string): string
	local left = devA .. "|" .. portA
	local right = devB .. "|" .. portB
	return if left <= right then left .. ">" .. right else right .. ">" .. left
end

---------------------------------------------------------------------
-- Port / node factories
---------------------------------------------------------------------

local function makePort(portId: string, portType: string): any
	return {
		portId = portId,
		portType = portType,
		connectedToDeviceId = nil,
		connectedToPortId = nil,
		cableColor = nil,
		linkUp = false,
		vlanId = 1,
		isTrunk = false,
		trafficLoadMbps = 0,
	}
end

-- Builds the default port layout for a catalog item: wanN / ethN / sfpN.
function NetworkGraph.MakePortsForItem(itemId: string): { [string]: any }
	local ports: { [string]: any } = {}
	local def = HardwareCatalog.Get(itemId)
	if def == nil then
		return ports
	end
	local specs = def.specs
	local wanCount = specs.wanPorts or 0
	local rj45Count = specs.ports or 0
	local sfpCount = specs.sfpPorts or 0
	-- Bare-metal hosts (Server category) carry no explicit port count in the
	-- catalog, but every server needs at least one RJ45 uplink to be playable
	-- (matches chassis_1u/2u, which ship with 1x RJ45). If the catalog later
	-- gains "ports" on Server items, this fallback stays a no-op.
	if def.category == "Server" and rj45Count == 0 and wanCount == 0 and sfpCount == 0 then
		rj45Count = 1
	end
	for i = 1, wanCount do
		ports["wan" .. i] = makePort("wan" .. i, "WAN")
	end
	for i = 1, rj45Count do
		ports["eth" .. i] = makePort("eth" .. i, "RJ45")
	end
	for i = 1, sfpCount do
		ports["sfp" .. i] = makePort("sfp" .. i, "SFP")
	end
	return ports
end

-- Builds a fresh DeviceNode for a catalog item; callers mutate specifics
-- (ip, rack slot, power state, freeform position, ...) afterwards.
function NetworkGraph.DefaultNode(id: string, name: string, itemId: string): any
	local def = HardwareCatalog.Get(itemId)
	local deviceType = "Switch"
	local specs = { cpu = 0, ram = 0, disk = 0, powerWatts = 0 }
	local uSize = 1
	if def ~= nil then
		if def.category == "Network" then
			deviceType = if (def.specs.wanPorts or 0) > 0 then "Router" else "Switch"
		elseif def.category == "Server" then
			deviceType = "BareMetal"
		elseif def.category == "Component" and (def.specs.ports or 0) > 0 then
			-- chassis items (chassis_1u/2u) are the base of custom builds:
			-- the workbench registers them as BareMetal hosts
			deviceType = "BareMetal"
		end
		specs = {
			cpu = def.specs.cpu or 0,
			ram = def.specs.ram or 0,
			disk = def.specs.disk or 0,
			powerWatts = def.specs.powerWatts or 0,
		}
		uSize = def.uSize
	end
	return {
		id = id,
		name = name,
		deviceType = deviceType,
		itemId = itemId,
		rackId = nil,
		uSlot = nil,
		uSize = uSize,
		ip = nil,
		gateway = nil,
		subnetMask = "255.255.255.0",
		defaultVlan = 1,
		interVlanRouting = deviceType == "Router",
		contractId = nil,
		ports = NetworkGraph.MakePortsForItem(itemId),
		specs = specs,
		vms = {},
		blockedIps = {},
		osInstalled = nil,
		isPowered = false,
		temperatureC = 32,
		hasDegradedDrive = false,
		degradedBayIndex = nil,
		isUnderDDoS = false,
		ddosAttackerIp = nil,
		freeform = false,
		posX = nil,
		posZ = nil,
		rotY = nil,
	}
end

---------------------------------------------------------------------
-- Registration & LEDs
---------------------------------------------------------------------

-- Adds a device to the session graph (and stores its model when given).
function NetworkGraph.RegisterDevice(session: any, node: any, model: Model?)
	session.devices[node.id] = node
	if model ~= nil then
		session.deviceModels[node.id] = model
	end
	NetworkGraph.UpdateDeviceLED(session, node.id)
end

-- Removes a device: severs every attached cable, destroys the model and
-- clears graph/hook bookkeeping.
function NetworkGraph.RemoveDevice(session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	-- collect connected port ids first: DisconnectPort mutates node.ports
	local connected: { string } = {}
	for portId, port in pairs(node.ports) do
		if port.connectedToDeviceId ~= nil then
			table.insert(connected, portId)
		end
	end
	for _, portId in ipairs(connected) do
		NetworkGraph.DisconnectPort(session, deviceId, portId)
	end
	local model = session.deviceModels[deviceId]
	if model ~= nil then
		model:Destroy()
		session.deviceModels[deviceId] = nil
	end
	session.hookedDevices[deviceId] = nil
	session.devices[deviceId] = nil
end

-- StatusLED green/red by power state; port LEDs green when linkUp else off.
-- A DDoSed device reports red even while powered.
function NetworkGraph.UpdateDeviceLED(session: any, deviceId: string)
	local node = session.devices[deviceId]
	local model = session.deviceModels[deviceId]
	if node == nil or model == nil then
		return
	end
	local led = model:FindFirstChild("StatusLED", true)
	if led ~= nil and led:IsA("BasePart") then
		if node.isUnderDDoS then
			led.Color = LED_RED
		else
			led.Color = if node.isPowered then LED_GREEN else LED_RED
		end
	end
	for _, port in pairs(node.ports) do
		local ledPart = model:FindFirstChild("PortLED_" .. port.portId, true)
		if ledPart ~= nil and ledPart:IsA("BasePart") then
			ledPart.Color = if port.linkUp then LED_GREEN else LED_OFF
		end
	end
end

---------------------------------------------------------------------
-- Cabling
---------------------------------------------------------------------

-- Finds the physical port Part inside a device model by its PortId attribute.
local function findPortPart(session: any, deviceId: string, portId: string): BasePart?
	local model = session.deviceModels[deviceId]
	if model == nil then
		return nil
	end
	-- Ports are now multi-part assemblies (jack + bezel + mouth details all
	-- carry PortId); the beam anchor lives on the part owning PortAttach.
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc:GetAttribute("PortId") == portId
			and desc:FindFirstChild("PortAttach") ~= nil then
			return desc
		end
	end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc:GetAttribute("PortId") == portId then
			return desc
		end
	end
	return nil
end

-- Validates and creates a cable between two free, compatible ports.
-- Returns (ok, errorMessage). On success both sides are linkUp, a color-coded
-- Beam is created (parented to session.facility.cables, or temporarily to the
-- device model during facility build before the cables folder exists) and the
-- cable is registered as session.cables[cableId].
function NetworkGraph.ConnectPorts(session: any, devAId: string, portAId: string, devBId: string, portBId: string, color: string): (boolean, string)
	local a = session.devices[devAId]
	local b = session.devices[devBId]
	if a == nil or b == nil then
		return false, "Device not found"
	end
	if devAId == devBId then
		return false, "Cannot connect a device to itself"
	end
	local pa = a.ports[portAId]
	local pb = b.ports[portBId]
	if pa == nil or pb == nil then
		return false, "Port not found"
	end
	if pa.portType == "Console" or pb.portType == "Console" then
		return false, "Console port is only for laptop console cable"
	end
	if pa.connectedToDeviceId ~= nil or pb.connectedToDeviceId ~= nil then
		return false, "Port is already in use"
	end
	-- type compatibility: WAN-WAN, RJ45-RJ45, SFP-SFP, RJ45 <-> SFP
	local compatible = pa.portType == pb.portType
		or (pa.portType == "RJ45" and pb.portType == "SFP")
		or (pa.portType == "SFP" and pb.portType == "RJ45")
	if not compatible then
		return false, "Incompatible port types (" .. pa.portType .. " vs " .. pb.portType .. ")"
	end

	-- Fase 2 cable colours: yellow is reserved for WAN uplinks, LAN/Mgmt for
	-- copper/fibre data ports. Persistence restores the recorded colour too.
	local bothWan = pa.portType == "WAN" and pb.portType == "WAN"
	local cableColor: string = if BEAM_COLORS[color] ~= nil then color else "LAN_Blue"
	if bothWan and cableColor ~= "WAN_Yellow" then
		return false, "WAN port requires a yellow cable (WAN_Yellow)"
	end
	if not bothWan and cableColor == "WAN_Yellow" then
		return false, "Yellow WAN cable is only for WAN ports"
	end

	local cableId = SessionManager.NextCableId(session)

	pa.connectedToDeviceId = devBId
	pa.connectedToPortId = portBId
	pa.cableColor = cableColor
	pa.linkUp = true
	pb.connectedToDeviceId = devAId
	pb.connectedToPortId = portAId
	pb.cableColor = cableColor
	pb.linkUp = true

	-- Beam visual with realistic droop
	local partA = findPortPart(session, devAId, portAId)
	local partB = findPortPart(session, devBId, portBId)
	local attachA = if partA ~= nil then partA:FindFirstChild("PortAttach") else nil
	local attachB = if partB ~= nil then partB:FindFirstChild("PortAttach") else nil
	local beam: Beam? = nil
	local sheath: Beam? = nil
	if attachA ~= nil and attachB ~= nil and attachA:IsA("Attachment") and attachB:IsA("Attachment") then
		-- Sag scales with run length so long runs droop naturally.
		local dist = (attachA.WorldPosition - attachB.WorldPosition).Magnitude
		local droop = -math.clamp(dist * 0.06, 0.4, 1.4)
		local facility = session.facility
		local cablesFolder = if facility ~= nil then facility.cables else nil
		local cableParent = cablesFolder
		if cableParent == nil then
			-- fallback during facility build (cables folder not assigned yet):
			-- keep the beams under the device model so they still render in-world
			cableParent = session.deviceModels[devAId]
		end
		if cableParent ~= nil then
			-- Outer braided jacket (wider, darker, more transparent)
			sheath = Instance.new("Beam")
			sheath.Name = "CableSheath_" .. cableId
			sheath.Attachment0 = attachA
			sheath.Attachment1 = attachB
			sheath.Color = ColorSequence.new(BEAM_SHEATH_COLORS[cableColor])
			sheath.Transparency = NumberSequence.new(0.3)
			sheath.Width0 = 0.26
			sheath.Width1 = 0.26
			sheath.CurveSize0 = droop
			sheath.CurveSize1 = droop
			sheath.Segments = 16
			sheath.FaceCamera = true
			sheath.Parent = cableParent

			-- Inner coloured core on top
			beam = Instance.new("Beam")
			beam.Name = "Cable_" .. cableId
			beam.Attachment0 = attachA
			beam.Attachment1 = attachB
			beam.Color = BEAM_COLORS[cableColor] :: ColorSequence
			beam.Transparency = NumberSequence.new(0.05)
			beam.Width0 = 0.14
			beam.Width1 = 0.14
			beam.CurveSize0 = droop
			beam.CurveSize1 = droop
			beam.Segments = 16
			beam.FaceCamera = true
			beam.Parent = cableParent
		end
	end

	session.cables[cableId] = {
		cableId = cableId,
		aDeviceId = devAId,
		aPortId = portAId,
		bDeviceId = devBId,
		bPortId = portBId,
		color = cableColor,
		beam = beam,
		sheath = sheath,
	}

	-- A fresh cable on this exact pair repairs an active Cable Fault incident.
	if session.incidentFaults ~= nil then
		session.incidentFaults[NetworkGraph.LinkKey(devAId, portAId, devBId, portBId)] = nil
	end

	NetworkGraph.UpdateDeviceLED(session, devAId)
	NetworkGraph.UpdateDeviceLED(session, devBId)
	return true, ""
end

-- Severs both ends of the cable attached to one port and destroys its beam.
function NetworkGraph.DisconnectPort(session: any, deviceId: string, portId: string): boolean
	local node = session.devices[deviceId]
	if node == nil then
		return false
	end
	local port = node.ports[portId]
	if port == nil or port.connectedToDeviceId == nil then
		return false
	end
	local peerId = port.connectedToDeviceId :: string
	local peerPortId = port.connectedToPortId :: string
	local peer = session.devices[peerId]

	-- destroy the cable record + beam
	for cableId, cable in pairs(session.cables) do
		local match = (cable.aDeviceId == deviceId and cable.aPortId == portId)
			or (cable.bDeviceId == deviceId and cable.bPortId == portId)
		if match then
			if cable.beam ~= nil then
				cable.beam:Destroy()
			end
			if cable.sheath ~= nil then
				cable.sheath:Destroy()
			end
			session.cables[cableId] = nil
			break
		end
	end

	port.connectedToDeviceId = nil
	port.connectedToPortId = nil
	port.cableColor = nil
	port.linkUp = false

	if peer ~= nil then
		local pport = peer.ports[peerPortId]
		if pport ~= nil then
			pport.connectedToDeviceId = nil
			pport.connectedToPortId = nil
			pport.cableColor = nil
			pport.linkUp = false
		end
		NetworkGraph.UpdateDeviceLED(session, peerId)
	end
	NetworkGraph.UpdateDeviceLED(session, deviceId)
	return true
end

---------------------------------------------------------------------
-- VLAN controls (Fase 2)
---------------------------------------------------------------------

--[[ Set a port VLAN (1..4094). Only non-Console ports are configurable.
	 Returns (ok, errorMessage). The simulation reads vlanId live, so no
	 re-link is needed: the next ping/traceroute sees the new isolation. ]]
function NetworkGraph.SetPortVlan(session: any, deviceId: string, portId: string, vlanId: number): (boolean, string)
	local node = session.devices[deviceId]
	if node == nil then
		return false, "Device not found"
	end
	local port = node.ports[portId]
	if port == nil then
		return false, "Port not found"
	end
	if port.portType == "Console" then
		return false, "Console port does not support VLANs"
	end
	if type(vlanId) ~= "number" or vlanId ~= vlanId then
		return false, "VLAN must be a number"
	end
	local vlan = math.floor(vlanId)
	if vlan < 1 or vlan > 4094 then
		return false, "VLAN must be in range 1..4094"
	end
	port.vlanId = vlan
	return true, ""
end

--[[ Marks a non-Console port as an 802.1Q trunk (all VLANs pass) or back to
	 access mode. Returns (ok, errorMessage). ]]
function NetworkGraph.SetPortTrunk(session: any, deviceId: string, portId: string, enabled: boolean): (boolean, string)
	local node = session.devices[deviceId]
	if node == nil then
		return false, "Device not found"
	end
	local port = node.ports[portId]
	if port == nil then
		return false, "Port not found"
	end
	if port.portType == "Console" then
		return false, "Console port cannot be configured as a trunk"
	end
	port.isTrunk = enabled == true
	return true, ""
end

--[[ The switch and port a device is physically plugged into, or nil when
	 the device has no cable to a switch (routers/ISP count separately). ]]
function NetworkGraph.GetAccessSwitchPort(session: any, deviceId: string): (any?, string?)
	local node = session.devices[deviceId]
	if node == nil then
		return nil, nil
	end
	for _, port in pairs(node.ports) do
		local peerId = port.connectedToDeviceId
		if peerId ~= nil then
			local peer = session.devices[peerId]
			local peerPortId = port.connectedToPortId
			if peer ~= nil and peer.deviceType == "Switch" and peerPortId ~= nil then
				return peer, peerPortId
			end
		end
	end
	return nil, nil
end

--[[ Deterministic "port eth1 VLAN 20" rows for the terminal/badges. ]]
function NetworkGraph.ListPortVlans(session: any, deviceId: string): { string }
	local node = session.devices[deviceId]
	if node == nil then
		return { "Device not found" }
	end
	local ids: { string } = {}
	for portId in pairs(node.ports) do
		table.insert(ids, portId)
	end
	table.sort(ids)
	local lines: { string } = {}
	for _, portId in ipairs(ids) do
		local port = node.ports[portId]
		local state = if port.connectedToDeviceId ~= nil then "UP" else "down"
		local mode = if port.isTrunk == true then "TRUNK" else string.format("VLAN %d", port.vlanId)
		table.insert(lines, string.format("%s  %s  %s", portId, mode, state))
	end
	if #lines == 0 then
		return { "No ports" }
	end
	return lines
end

---------------------------------------------------------------------
-- Lookup helpers
---------------------------------------------------------------------

-- First device whose ip matches (nil when none).
function NetworkGraph.FindDeviceByIP(session: any, ip: string): any?
	for _, node in pairs(session.devices) do
		if node.ip == ip then
			return node
		end
	end
	return nil
end

-- True when another device (different id) already uses the ip.
function NetworkGraph.IsIPUsedByOther(session: any, ip: string, exceptId: string): boolean
	for id, node in pairs(session.devices) do
		if id ~= exceptId and node.ip == ip then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------
-- BFS reachability
---------------------------------------------------------------------

-- Sort key for stable port ordering: wan -> eth -> sfp, then numeric suffix.
local function portSortKey(portId: string): (number, number)
	local prefix = string.match(portId, "^[a-zA-Z]+") or ""
	local num = tonumber(string.match(portId, "%d+") or "") or 0
	local order = 4
	if prefix == "wan" then
		order = 1
	elseif prefix == "eth" then
		order = 2
	elseif prefix == "sfp" then
		order = 3
	end
	return order, num
end

-- Deterministic port id list for a node.
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

-- First free non-Console port id of a node whose type is compatible with
-- wantedType (RJ45 <-> SFP counts as compatible), or nil.
local function firstCompatibleFreePortId(node: any, wantedType: string): string?
	for _, portId in ipairs(sortedPortIds(node)) do
		local port = node.ports[portId]
		if port.portType ~= "Console" and port.connectedToDeviceId == nil then
			local compatible = port.portType == wantedType
				or (port.portType == "RJ45" and wantedType == "SFP")
				or (port.portType == "SFP" and wantedType == "RJ45")
			if compatible then
				return portId
			end
		end
	end
	return nil
end

-- All free non-Console port ids of a node, in deterministic order.
local function freePortIds(node: any): { string }
	local out: { string } = {}
	for _, portId in ipairs(sortedPortIds(node)) do
		local port = node.ports[portId]
		if port.portType ~= "Console" and port.connectedToDeviceId == nil then
			table.insert(out, portId)
		end
	end
	return out
end

--[[
	BFS over linkUp edges from sourceDeviceId to targetId.
	Returns (path including both endpoints | nil, stormDetected).
	Rules:
	- unpowered devices never forward packets (skipped as intermediates)
	- passing THROUGH a switch requires in-port vlanId == out-port vlanId
	  (Fase 1: all ports default to vlan 1)
	- reaching an already-visited node over a non-tree edge means a physical
	  loop exists in the topology -> broadcast storm flag
]]
local function bfsPath(session: any, sourceDeviceId: string, targetId: string): ({ string }?, boolean)
	local visited: { [string]: boolean } = {}
	local parent: { [string]: string } = {} -- childId -> parentId
	local parentPort: { [string]: string } = {} -- childId -> port on the child used to reach its parent
	local queue: { { id: string, inPortId: string? } } = { { id = sourceDeviceId, inPortId = nil } }
	local head = 1
	local storm = false
	visited[sourceDeviceId] = true

	while queue[head] ~= nil do
		local current = queue[head]
		head += 1
		if current.id == targetId then
			-- reconstruct the path source -> ... -> target
			local path: { string } = {}
			local walk: string? = current.id
			while walk ~= nil do
				table.insert(path, 1, walk)
				if walk == sourceDeviceId then
					break
				end
				walk = parent[walk]
			end
			return path, storm
		end
		local node = session.devices[current.id]
		if node == nil then
			continue
		end
		for _, portId in ipairs(sortedPortIds(node)) do
			local port = node.ports[portId]
			if not port.linkUp or port.connectedToDeviceId == nil then
				continue
			end
			local nextId = port.connectedToDeviceId :: string
			-- Fase 3 Cable Fault: the physical cable is still plugged in, but
			-- the link is electrically bad until the pair is re-cabled.
			if session.incidentFaults ~= nil then
				local peerPortId = port.connectedToPortId or ""
				if session.incidentFaults[NetworkGraph.LinkKey(current.id, portId, nextId, peerPortId)] == true then
					continue
				end
			end
			-- VLAN isolation while forwarding through a switch (and through a
			-- router whose inter-VLAN routing is disabled). Routers route
			-- between VLANs at L3, so they bridge VLANs by design.
			local isolates = node.deviceType == "Switch"
				or (node.deviceType == "Router" and node.interVlanRouting == false)
			if isolates and current.inPortId ~= nil then
				local inPort = node.ports[current.inPortId]
				local trunked = (inPort ~= nil and inPort.isTrunk == true) or port.isTrunk == true
				if inPort ~= nil and inPort.vlanId ~= port.vlanId and not trunked then
					continue
				end
			end
			local nextNode = session.devices[nextId]
			if nextNode == nil then
				continue
			end
			-- A DDoSed device drops/does not forward traffic while mitigated.
			if nextNode.isUnderDDoS == true then
				continue
			end
			if visited[nextId] then
				-- non-tree edge => topology loop => broadcast storm
				local isTreeEdge = parent[current.id] == nextId and parentPort[current.id] == portId
				if not isTreeEdge then
					storm = true
				end
				continue
			end
			if not nextNode.isPowered then
				continue -- unpowered devices do not forward
			end
			visited[nextId] = true
			parent[nextId] = current.id
			-- remember the port on the CHILD through which it was discovered,
			-- so the tree edge can be recognized when the child is expanded
			parentPort[nextId] = port.connectedToPortId or portId
			table.insert(queue, { id = nextId, inPortId = port.connectedToPortId })
		end
	end
	return nil, storm
end

--[[
	CanReachIP(session, sourceDeviceId, targetIP) -> (reachable, latencyMs, err)
	sourceDeviceId == "__laptop__" = the laptop Wi-Fi management bridge
	(PlotConstants.LAPTOP_BRIDGE_IP): any powered device with an ip is
	reachable, public IPs go through the ISP (higher latency).
	Public targets (non-RFC1918) are reachable by reaching the isp_uplink.
	Ping to self = 0.1 ms. Sets session.broadcastStorm on topology loops.
]]
function NetworkGraph.CanReachIP(session: any, sourceDeviceId: string, targetIP: string): (boolean, number, string)
	session.broadcastStorm = false

	if not NetworkUtils.IsValidIPv4(targetIP) then
		return false, 0, "ping: invalid IP address"
	end

	-- Laptop management bridge (Disconnected terminal mode)
	if sourceDeviceId == "__laptop__" then
		if targetIP == PlotConstants.LAPTOP_BRIDGE_IP then
			return false, 0, "Destination Host Unreachable (own laptop bridge)"
		end
		local target = NetworkGraph.FindDeviceByIP(session, targetIP)
		if target ~= nil then
			if not target.isPowered then
				return false, 0, "Destination Host Unreachable (device powered off)"
			end
			if target.isUnderDDoS == true then
				return false, 0, "Request timed out (target under DDoS flood)"
			end
			return true, math.random(2, 6) + math.random(), ""
		end
		if not NetworkUtils.IsPrivateIP(targetIP) then
			return true, math.random(12, 25) + math.random(), ""
		end
		return false, 0, "Destination Host Unreachable"
	end

	local src = session.devices[sourceDeviceId]
	if src == nil then
		return false, 0, "Source device not found"
	end
	if not src.isPowered then
		return false, 0, "Destination Host Unreachable (device powered off)"
	end
	if src.isUnderDDoS == true then
		return false, 0, "Request timed out (source device under DDoS)"
	end
	if src.ip == targetIP then
		return true, 0.1, "" -- ping to self
	end

	local targetNode = NetworkGraph.FindDeviceByIP(session, targetIP)
	local isPublic = not NetworkUtils.IsPrivateIP(targetIP)
	if targetNode ~= nil and not targetNode.isPowered then
		return false, 0, "Destination Host Unreachable (device powered off)"
	end
	if targetNode ~= nil and targetNode.isUnderDDoS == true then
		return false, 0, "Request timed out (target under DDoS flood)"
	end
	if targetNode == nil and not isPublic then
		return false, 0, "Destination Host Unreachable"
	end
	local targetId: string
	if targetNode ~= nil then
		targetId = targetNode.id
	elseif session.devices[ISP_UPLINK_ID] ~= nil then
		targetId = ISP_UPLINK_ID -- public target: reaching the ISP uplink is enough
	else
		return false, 0, "Network is unreachable"
	end

	local path, storm = bfsPath(session, sourceDeviceId, targetId)
	if storm then
		session.broadcastStorm = true
	end
	if path == nil then
		local err: string
		if storm then
			err = "Request timed out (packet loss 95% - broadcast storm)"
		elseif isPublic then
			err = "Network is unreachable"
		else
			err = "Destination Host Unreachable"
		end
		return false, 0, err
	end

	-- latency grows with hop count; leaving the lab adds WAN latency
	local hops = #path - 1
	local latency = hops * 1.2 + 0.3 + math.random() * 1.8
	if targetNode == nil then
		latency += 12
	end
	return true, math.floor(latency * 100) / 100, ""
end

--[[
	GetRoutePath(session, sourceDeviceId, targetIP) -> {deviceIds}?
	BFS path including both endpoints, or nil when unreachable.
	Public targets route to the isp_uplink junction.
]]
function NetworkGraph.GetRoutePath(session: any, sourceDeviceId: string, targetIP: string): { string }?
	if not NetworkUtils.IsValidIPv4(targetIP) then
		return nil
	end
	local src = session.devices[sourceDeviceId]
	if src == nil or not src.isPowered or src.isUnderDDoS == true then
		return nil
	end
	if src.ip == targetIP then
		return { sourceDeviceId }
	end
	local targetNode = NetworkGraph.FindDeviceByIP(session, targetIP)
	local isPublic = not NetworkUtils.IsPrivateIP(targetIP)
	if targetNode ~= nil and not targetNode.isPowered then
		return nil
	end
	if targetNode == nil and not isPublic then
		return nil
	end
	local targetId: string
	if targetNode ~= nil then
		targetId = targetNode.id
	elseif session.devices[ISP_UPLINK_ID] ~= nil then
		targetId = ISP_UPLINK_ID
	else
		return nil
	end
	local path = bfsPath(session, sourceDeviceId, targetId)
	return path
end

---------------------------------------------------------------------
-- Auto cabling
---------------------------------------------------------------------

--[[
	AutoCable(session, deviceId): connect the new device to the nearest
	device (<= 60 studs) that still has a free non-Console port; fall back
	to the starter switch sw_main_1. isp_uplink is never a candidate.
	Caller skips this when session.loadedFromSave (links are restored
	explicitly by the persistence layer).
]]
function NetworkGraph.AutoCable(session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	local selfModel = session.deviceModels[deviceId]
	if selfModel == nil then
		return
	end
	local selfFreePorts = freePortIds(node)
	if #selfFreePorts == 0 then
		return
	end
	local selfPos = selfModel:GetPivot().Position

	local bestId: string? = nil
	local bestSelfPortId: string? = nil
	local bestPeerPortId: string? = nil
	local bestDist = AUTO_CABLE_RANGE
	for id, other in pairs(session.devices) do
		if id == deviceId or id == ISP_UPLINK_ID then
			continue
		end
		-- find a (self port, peer port) pair whose types are compatible,
		-- otherwise ConnectPorts would reject the link
		local chosenSelf: string? = nil
		local chosenPeer: string? = nil
		for _, selfPortId in ipairs(selfFreePorts) do
			local peerPortId = firstCompatibleFreePortId(other, node.ports[selfPortId].portType)
			if peerPortId ~= nil then
				chosenSelf = selfPortId
				chosenPeer = peerPortId
				break
			end
		end
		if chosenPeer == nil then
			continue
		end
		local model = session.deviceModels[id]
		if model ~= nil then
			local dist = (model:GetPivot().Position - selfPos).Magnitude
			if dist <= bestDist then
				bestDist = dist
				bestId = id
				bestSelfPortId = chosenSelf
				bestPeerPortId = chosenPeer
			end
		end
	end

	-- fallback: the starter main switch (never connect a device to itself)
	if bestId == nil then
		local sw = session.devices[FALLBACK_SWITCH_ID]
		if sw ~= nil and deviceId ~= FALLBACK_SWITCH_ID then
			for _, selfPortId in ipairs(selfFreePorts) do
				local peerPortId = firstCompatibleFreePortId(sw, node.ports[selfPortId].portType)
				if peerPortId ~= nil then
					bestId = FALLBACK_SWITCH_ID
					bestSelfPortId = selfPortId
					bestPeerPortId = peerPortId
					break
				end
			end
		end
	end
	if bestId == nil or bestSelfPortId == nil or bestPeerPortId == nil then
		return
	end

	NetworkGraph.ConnectPorts(session, deviceId, bestSelfPortId :: string, bestId :: string, bestPeerPortId :: string, "LAN_Blue")
end

return NetworkGraph
