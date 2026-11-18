--!strict
--[[
	NetworkGraph (ModuleScript, ServerScriptService/Core)
	State store otoritatif: device, port, kabel, BFS reachability, subnet/gateway,
	VLAN isolation (default 1 di Fase 1), deteksi broadcast storm, LED update.
]]

local HardwareCatalog = require(game:GetService("ReplicatedStorage").Shared.HardwareCatalog)
local PlotConstants = require(game:GetService("ReplicatedStorage").Shared.PlotConstants)
local NetworkUtils = require(game:GetService("ReplicatedStorage").Shared.NetworkUtils)
local SessionManager = require(script.Parent.SessionManager)

local NetworkGraph = {}

local BEAM_COLORS: { [string]: ColorSequence } = {
	LAN_Blue = ColorSequence.new(Color3.fromRGB(70, 130, 255)),
	WAN_Yellow = ColorSequence.new(Color3.fromRGB(240, 210, 70)),
	Mgmt_Red = ColorSequence.new(Color3.fromRGB(230, 80, 80)),
}

local LED_GREEN = Color3.fromRGB(85, 255, 120)
local LED_RED = Color3.fromRGB(255, 80, 80)
local LED_OFF = Color3.fromRGB(70, 70, 70)

local BRIDGE_IP = PlotConstants.LAPTOP_BRIDGE_IP

function NetworkGraph.Init(_deps: { [string]: any })
	-- deps direserve untuk pengembangan; modul shared di-require di atas.
end

function NetworkGraph.MakePortsForItem(itemId: string): { [string]: any }
	local defItem = HardwareCatalog.Get(itemId)
	local ports: { [string]: any } = {}
	if defItem == nil then
		return ports
	end
	local specs = (defItem :: any).specs
	local wan = specs.wanPorts or 0
	local rj = specs.ports or 0
	local sfp = specs.sfpPorts or 0
	for i = 1, wan do
		ports["wan" .. i] = {
			portId = "wan" .. i,
			portType = "WAN",
			connectedToDeviceId = nil,
			connectedToPortId = nil,
			cableColor = nil,
			linkUp = false,
			vlanId = 1,
			trafficLoadMbps = 0,
		}
	end
	for i = 1, rj do
		ports["eth" .. i] = {
			portId = "eth" .. i,
			portType = "RJ45",
			connectedToDeviceId = nil,
			connectedToPortId = nil,
			cableColor = nil,
			linkUp = false,
			vlanId = 1,
			trafficLoadMbps = 0,
		}
	end
	for i = 1, sfp do
		ports["sfp" .. i] = {
			portId = "sfp" .. i,
			portType = "SFP",
			connectedToDeviceId = nil,
			connectedToPortId = nil,
			cableColor = nil,
			linkUp = false,
			vlanId = 1,
			trafficLoadMbps = 0,
		}
	end
	return ports
end

function NetworkGraph.DefaultNode(id: string, name: string, itemId: string): any
	local defItem = HardwareCatalog.Get(itemId)
	local specs = { cpu = 0, ram = 0, disk = 0, powerWatts = 0 }
	local deviceType: string = "Switch"
	local uSize = 1
	if defItem ~= nil then
		local d = defItem :: any
		local cat = d.category
		if cat == "Network" then
			if (d.specs.wanPorts or 0) > 0 then
				deviceType = "Router"
			else
				deviceType = "Switch"
			end
		elseif cat == "Server" then
			deviceType = "BareMetal"
		end
		specs = {
			cpu = d.specs.cpu or 0,
			ram = d.specs.ram or 0,
			disk = d.specs.disk or 0,
			powerWatts = d.specs.powerWatts or 0,
		}
		uSize = d.uSize
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

function NetworkGraph.RegisterDevice(session: any, node: any, model: Model?)
	session.devices[node.id] = node
	if model then
		session.deviceModels[node.id] = model
	end
	NetworkGraph.UpdateDeviceLED(session, node.id)
end

function NetworkGraph.RemoveDevice(session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	for portId, port in pairs(node.ports) do
		if port.connectedToDeviceId then
			NetworkGraph.DisconnectPort(session, deviceId, portId)
		end
	end
	local model = session.deviceModels[deviceId]
	if model then
		model:Destroy()
		session.deviceModels[deviceId] = nil
	end
	session.devices[deviceId] = nil
end

function NetworkGraph.UpdateDeviceLED(session: any, deviceId: string)
	local node = session.devices[deviceId]
	local model = session.deviceModels[deviceId]
	if node == nil or model == nil then
		return
	end
	local led = model:FindFirstChild("StatusLED", true)
	if led and led:IsA("BasePart") then
		led.Color = if node.isPowered then LED_GREEN else LED_RED
	end
	for _, port in pairs(node.ports) do
		local ledPart = model:FindFirstChild("PortLED_" .. port.portId, true)
		if ledPart and ledPart:IsA("BasePart") then
			ledPart.Color = if port.linkUp then LED_GREEN else LED_OFF
		end
	end
end

local function findPortPart(session: any, deviceId: string, portId: string): BasePart?
	local model = session.deviceModels[deviceId]
	if model == nil then
		return nil
	end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc:GetAttribute("PortId") == portId then
			return desc
		end
	end
	return nil
end

function NetworkGraph.ConnectPorts(session: any, devAId: string, portAId: string, devBId: string, portBId: string, color: string): (boolean, string)
	local a = session.devices[devAId]
	local b = session.devices[devBId]
	if a == nil or b == nil then
		return false, "Device tidak ditemukan"
	end
	if devAId == devBId then
		return false, "Tidak bisa menghubungkan device ke dirinya sendiri"
	end
	local pa = a.ports[portAId]
	local pb = b.ports[portBId]
	if pa == nil or pb == nil then
		return false, "Port tidak ditemukan"
	end
	if pa.portType == "Console" or pb.portType == "Console" then
		return false, "Port console hanya untuk kabel console laptop"
	end
	if pa.connectedToDeviceId ~= nil or pb.connectedToDeviceId ~= nil then
		return false, "Port sudah terpakai"
	end
	local compatible = (pa.portType == pb.portType)
		or (pa.portType == "RJ45" and pb.portType == "SFP")
		or (pa.portType == "SFP" and pb.portType == "RJ45")
	if not compatible then
		return false, "Tipe port tidak kompatibel (" .. pa.portType .. " vs " .. pb.portType .. ")"
	end

	local cableId = SessionManager.NextCableId(session)

	pa.connectedToDeviceId = devBId
	pa.connectedToPortId = portBId
	pa.cableColor = color
	pa.linkUp = true
	pb.connectedToDeviceId = devAId
	pb.connectedToPortId = portAId
	pb.cableColor = color
	pb.linkUp = true

	local partA = findPortPart(session, devAId, portAId)
	local partB = findPortPart(session, devBId, portBId)
	local attachA = if partA then partA:FindFirstChild("PortAttach") else nil
	local attachB = if partB then partB:FindFirstChild("PortAttach") else nil
	if attachA and attachB and attachA:IsA("Attachment") and attachB:IsA("Attachment") then
		local beam = Instance.new("Beam")
		beam.Name = "Cable_" .. cableId
		beam.Attachment0 = attachA
		beam.Attachment1 = attachB
		beam.Color = BEAM_COLORS[color] or BEAM_COLORS.LAN_Blue
		beam.Transparency = NumberSequence.new(0.1)
		beam.Width0 = 0.12
		beam.Width1 = 0.12
		beam.CurveSize0 = -0.6
		beam.CurveSize1 = -0.6
		beam.Segments = 12
		beam.FaceCamera = true
		local cablesFolder = session.facility.cables
		if cablesFolder then
			beam.Parent = cablesFolder
		end
		session.cables[cableId] = {
			cableId = cableId,
			aDeviceId = devAId,
			aPortId = portAId,
			bDeviceId = devBId,
			bPortId = portBId,
			color = color,
			beam = beam,
		}
	end

	NetworkGraph.UpdateDeviceLED(session, devAId)
	NetworkGraph.UpdateDeviceLED(session, devBId)
	return true, ""
end

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
	for cableId, cable in pairs(session.cables) do
		local match = (cable.aDeviceId == deviceId and cable.aPortId == portId)
			or (cable.bDeviceId == deviceId and cable.bPortId == portId)
		if match then
			if cable.beam then
				cable.beam:Destroy()
			end
			session.cables[cableId] = nil
			break
		end
	end
	port.connectedToDeviceId = nil
	port.connectedToPortId = nil
	port.cableColor = nil
	port.linkUp = false
	if peer then
		local pport = peer.ports[peerPortId]
		if pport then
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

function NetworkGraph.FindDeviceByIP(session: any, ip: string): any?
	for _, node in pairs(session.devices) do
		if node.ip == ip then
			return node
		end
	end
	return nil
end

function NetworkGraph.IsIPUsedByOther(session: any, ip: string, exceptDeviceId: string): boolean
	for id, node in pairs(session.devices) do
		if id ~= exceptDeviceId and node.ip == ip then
			return true
		end
	end
	return false
end

function NetworkGraph.FindDeviceByIPUsed(session: any, ip: string, exceptDeviceId: string): any?
	for id, node in pairs(session.devices) do
		if id ~= exceptDeviceId and node.ip == ip then
			return node
		end
	end
	return nil
end

--[[
	CanReachIP: BFS dari device sumber ke target IP.
	Menghormati: linkUp, isPowered, VLAN isolation saat melewati switch,
	subnet (via gateway logic sederhana Fase 1: switch meneruskan vlan sama,
	router meneruskan antar vlan). Target publik = cukup sampai ISP uplink.
	SourceDeviceId == "__laptop__" = management bridge laptop.
	Return: (reachable, latencyMs, errorMsg)
]]
function NetworkGraph.CanReachIP(session: any, sourceDeviceId: string, targetIP: string): (boolean, number, string)
	session.broadcastStorm = false

	if not NetworkUtils.IsValidIPv4(targetIP) then
		return false, 0, "ping: invalid IP address"
	end

	-- Laptop management bridge (mode Disconnected)
	if sourceDeviceId == "__laptop__" then
		if targetIP == BRIDGE_IP then
			return false, 0, "Tidak bisa ping bridge sendiri"
		end
		local target = NetworkGraph.FindDeviceByIP(session, targetIP)
		if target ~= nil then
			if (target :: any).isPowered then
				return true, math.random(2, 6), ""
			end
			return false, 0, "Destination Host Unreachable"
		end
		if not NetworkUtils.IsPrivateIP(targetIP) then
			return true, math.random(12, 25), ""
		end
		return false, 0, "Destination Host Unreachable"
	end

	local src = session.devices[sourceDeviceId]
	if src == nil then
		return false, 0, "Device sumber tidak ada"
	end

	if src.ip == targetIP then
		return true, 0.1, ""
	end

	if not src.isPowered then
		return false, 0, "Destination Host Unreachable (device mati)"
	end

	local isPublic = not NetworkUtils.IsPrivateIP(targetIP)
	local targetNode = NetworkGraph.FindDeviceByIP(session, targetIP)
	if targetNode == nil and not isPublic then
		return false, 0, "Destination Host Unreachable"
	end
	if targetNode ~= nil and not (targetNode :: any).isPowered then
		return false, 0, "Destination Host Unreachable (device mati)"
	end
	local targetId = if targetNode then (targetNode :: any).id else "__isp__"

	local visited: { [string]: boolean } = {}
	local parent: { [string]: string } = {}
	local switchFirstInPort: { [string]: string } = {}
	local queue: { { devId: string, inPortId: string? } } = {}
	table.insert(queue, { devId = sourceDeviceId, inPortId = nil })
	visited[sourceDeviceId] = true
	local found: string? = nil

	while #queue > 0 do
		local cur = table.remove(queue) :: any
		local curNode = session.devices[cur.devId]
		if curNode == nil then
			continue
		end
		if cur.devId == targetId then
			found = cur.devId
			break
		end
		for portId, port in pairs(curNode.ports) do
			if not port.linkUp or port.connectedToDeviceId == nil then
				continue
			end
			-- VLAN isolation saat melewati switch
			if curNode.deviceType == "Switch" and cur.inPortId ~= nil then
				local inPort = curNode.ports[cur.inPortId]
				if inPort ~= nil and inPort.vlanId ~= port.vlanId then
					continue
				end
			end
			local nextId = port.connectedToDeviceId :: string
			local nextNode = session.devices[nextId]
			if nextNode == nil then
				continue
			end
			if visited[nextId] and nextNode.deviceType == "Switch" then
				local firstPort = switchFirstInPort[nextId]
				if firstPort ~= nil and firstPort ~= port.connectedToPortId and nextNode.defaultVlan == port.vlanId then
					session.broadcastStorm = true
				end
			end
			if not visited[nextId] then
				if nextNode.deviceType == "Switch" then
					switchFirstInPort[nextId] = port.connectedToPortId :: string
				end
				if nextNode.isPowered or nextId == targetId then
					visited[nextId] = true
					parent[nextId] = cur.devId
					table.insert(queue, { devId = nextId, inPortId = portId })
				end
			end
		end
	end

	if found == nil then
		local err = if session.broadcastStorm
			then "Request timed out (packet loss 95% - broadcast storm)"
			else "Destination Host Unreachable"
		return false, 0, err
	end

	local hops = 0
	local walk = found
	while walk ~= sourceDeviceId do
		local p = parent[walk]
		if p == nil then
			break
		end
		hops += 1
		walk = p
	end
	local latency = hops * 1.2 + math.random() * 1.8 + 0.3
	if targetNode == nil then
		latency += 12
	end
	return true, math.floor(latency * 100) / 100, ""
end

function NetworkGraph.GetRoutePath(session: any, sourceDeviceId: string, targetIP: string): { string }?
	local src = session.devices[sourceDeviceId]
	if src == nil or not src.isPowered then
		return nil
	end
	local isPublic = not NetworkUtils.IsPrivateIP(targetIP)
	local targetNode = NetworkGraph.FindDeviceByIP(session, targetIP)
	if targetNode == nil and not isPublic then
		return nil
	end
	if targetNode ~= nil and not (targetNode :: any).isPowered then
		return nil
	end
	local targetId = if targetNode then (targetNode :: any).id else "__isp__"

	local visited: { [string]: boolean } = {}
	local parent: { [string]: string } = {}
	local queue: { string } = { sourceDeviceId }
	visited[sourceDeviceId] = true
	while #queue > 0 do
		local curId = table.remove(queue) :: string
		if curId == targetId then
			break
		end
		local curNode = session.devices[curId]
		if curNode == nil then
			continue
		end
		for _, port in pairs(curNode.ports) do
			if not port.linkUp or port.connectedToDeviceId == nil then
				continue
			end
			local nextId = port.connectedToDeviceId :: string
			local nextNode = session.devices[nextId]
			if nextNode ~= nil and not visited[nextId] and (nextNode.isPowered or nextId == targetId) then
				visited[nextId] = true
				parent[nextId] = curId
				table.insert(queue, nextId)
			end
		end
	end

	if not visited[targetId] then
		return nil
	end
	local path: { string } = {}
	local walk: string? = targetId
	while walk ~= nil do
		table.insert(path, 1, walk)
		if walk == sourceDeviceId then
			break
		end
		walk = parent[walk]
	end
	return path
end

function NetworkGraph.AutoCable(session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	local selfModel = session.deviceModels[deviceId]
	if selfModel == nil then
		return
	end
	local selfPos = selfModel:GetPivot().Position

	local function hasFreePort(dev: any): string?
		for _, port in pairs(dev.ports) do
			if port.portType ~= "Console" and port.connectedToDeviceId == nil then
				return port.portId
			end
		end
		return nil
	end

	local selfFree = hasFreePort(node)
	if selfFree == nil then
		return
	end

	local bestId: string? = nil
	local bestDist = 60
	for id, other in pairs(session.devices) do
		if id == deviceId or id == "isp_uplink" then
			continue
		end
		if hasFreePort(other) == nil then
			continue
		end
		local m = session.deviceModels[id]
		if m then
			local d = (m:GetPivot().Position - selfPos).Magnitude
			if d < bestDist then
				bestDist = d
				bestId = id
			end
		end
	end
	if bestId == nil and deviceId ~= "sw_main_1" then
		local sw = session.devices["sw_main_1"]
		if sw ~= nil and hasFreePort(sw) ~= nil then
			bestId = "sw_main_1"
		end
	end
	if bestId ~= nil then
		NetworkGraph.ConnectPorts(session, deviceId, selfFree, bestId, hasFreePort(session.devices[bestId :: string]) :: string, "LAN_Blue")
	end
end

return NetworkGraph
