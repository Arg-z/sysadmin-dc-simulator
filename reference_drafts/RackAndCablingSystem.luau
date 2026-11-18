--!strict
--[[
	RackAndCablingSystem (ModuleScript, ServerScriptService/Physical)
	Interaksi fisik: cabling dua-klik antar port, disconnect, kabel console laptop
	(ProximityPrompt + Beam biru, detach >18 studs), toggle PDU rack, toggle power
	device freeform, hook semua ClickDetector/ProximityPrompt pada model device.
]]

local RackAndCablingSystem = {}

local sessions = nil
local graph = nil
local remotesFolder = nil

local HIGHLIGHT_YELLOW = Color3.fromRGB(255, 220, 80)

function RackAndCablingSystem.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	remotesFolder = deps.remotesFolder
end

local function playSFX(player: Player, name: string)
	local remote = remotesFolder:FindFirstChild("PlaySFXRemote")
	if remote then
		remote:FireClient(player, name)
	end
end

local function openTerminal(player: Player, payload: { [string]: any })
	local remote = remotesFolder:FindFirstChild("OpenTerminalEvent")
	if remote then
		remote:FireClient(player, payload)
	end
end

local function clearPendingCable(session: any)
	if session.pendingCableHighlight then
		session.pendingCableHighlight:Destroy()
	end
	session.pendingCableHighlight = nil
	session.pendingCableDeviceId = nil
	session.pendingCablePortId = nil
end

--[[
	HandlePortClick: dipanggil dari ClickDetector port.
	Port terhubung -> disconnect. Port kosong -> pilih/konek dua-klik.
]]
function RackAndCablingSystem.HandlePortClick(player: Player, session: any, deviceId: string, portId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	local port = node.ports[portId]
	if port == nil or port.portType == "Console" then
		return
	end

	if port.connectedToDeviceId ~= nil then
		graph.DisconnectPort(session, deviceId, portId)
		playSFX(player, "plug")
		return
	end

	if session.pendingCableDeviceId == nil then
		session.pendingCableDeviceId = deviceId
		session.pendingCablePortId = portId
		local model = session.deviceModels[deviceId]
		if model then
			for _, desc in ipairs(model:GetDescendants()) do
				if desc:IsA("BasePart") and desc:GetAttribute("PortId") == portId then
					local sel = Instance.new("SelectionBox")
					sel.Name = "PendingCableSel"
					sel.Adornee = desc
					sel.Color3 = HIGHLIGHT_YELLOW
					sel.LineThickness = 0.05
					sel.SurfaceTransparency = 0.7
					sel.Parent = desc
					session.pendingCableHighlight = sel
					break
				end
			end
		end
		playSFX(player, "key")
		task.delay(15, function()
			if session.pendingCablePortId == portId and session.pendingCableDeviceId == deviceId then
				clearPendingCable(session)
			end
		end)
		return
	end

	if session.pendingCableDeviceId == deviceId and session.pendingCablePortId == portId then
		clearPendingCable(session)
		return
	end

	local fromDev = session.pendingCableDeviceId :: string
	local fromPort = session.pendingCablePortId :: string
	clearPendingCable(session)
	local ok, _err = graph.ConnectPorts(session, fromDev, fromPort, deviceId, portId, "LAN_Blue")
	playSFX(player, if ok then "plug" else "error")
end

--[[
	AttachConsole / DetachConsole: kabel console laptop.
]]
function RackAndCablingSystem.AttachConsole(player: Player, session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end

	local link = session.consoleLink
	if link and link.deviceId == deviceId then
		RackAndCablingSystem.DetachConsole(session, player, true)
		return
	end

	local char = player.Character
	local laptop = if char then char:FindFirstChild("TechnicianLaptop") else nil
	if laptop == nil then
		playSFX(player, "error")
		openTerminal(player, { action = "hint", message = "Equip laptop dulu (slot 1) untuk sambung console." })
		return
	end

	local serial = laptop:FindFirstChild("SerialPortAttachment")
	local model = session.deviceModels[deviceId]
	local consolePart = if model then model:FindFirstChild("ConsolePort", true) else nil
	if serial == nil or consolePart == nil or not serial:IsA("Attachment") then
		playSFX(player, "error")
		return
	end
	local consoleAttach = consolePart:FindFirstChild("ConsoleAttach")
	if consoleAttach == nil or not consoleAttach:IsA("Attachment") then
		playSFX(player, "error")
		return
	end

	if link then
		if link.beam then
			link.beam:Destroy()
		end
		session.consoleLink = nil
	end

	local beam = Instance.new("Beam")
	beam.Name = "ConsoleBeam"
	beam.Attachment0 = serial
	beam.Attachment1 = consoleAttach
	beam.Color = ColorSequence.new(Color3.fromRGB(80, 160, 255))
	beam.Transparency = NumberSequence.new(0.05)
	beam.Width0 = 0.16
	beam.Width1 = 0.16
	beam.CurveSize0 = -0.8
	beam.CurveSize1 = -0.8
	beam.Segments = 14
	beam.FaceCamera = true
	beam.Parent = session.facility.cables
	session.consoleLink = { deviceId = deviceId, beam = beam }

	session.terminal.mode = "LocalConsole"
	session.terminal.targetDeviceId = deviceId

	playSFX(player, "plug")
	openTerminal(player, { action = "open", mode = "LocalConsole", deviceName = node.name, deviceId = deviceId })
end

function RackAndCablingSystem.DetachConsole(session: any, player: Player?, notify: boolean)
	local link = session.consoleLink
	if link then
		if link.beam then
			link.beam:Destroy()
		end
		session.consoleLink = nil
	end
	session.terminal.mode = "Disconnected"
	session.terminal.targetDeviceId = nil
	session.terminal.sshStack = {}
	if notify and player then
		openTerminal(player, { action = "detach" })
		playSFX(player, "key")
	end
end

--[[
	HookDevice: pasang handler ClickDetector port + ProximityPrompt console + power.
	Dipanggil sekali per device model.
]]
function RackAndCablingSystem.HookDevice(session: any, deviceId: string)
	if session.hookedDevices[deviceId] then
		return
	end
	session.hookedDevices[deviceId] = true
	local model = session.deviceModels[deviceId]
	if model == nil then
		return
	end
	local player = session.player

	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("ClickDetector") and desc.Name == "Click" then
			local portPart = desc.Parent
			if portPart and portPart:IsA("BasePart") then
				local portId = portPart:GetAttribute("PortId")
				local devId = portPart:GetAttribute("DeviceId")
				if portId ~= nil and devId ~= nil then
					desc.MouseClick:Connect(function(clicker)
						if clicker ~= player then
							return
						end
						RackAndCablingSystem.HandlePortClick(clicker, session, devId :: string, portId :: string)
					end)
				end
			end
		end
	end

	local consolePart = model:FindFirstChild("ConsolePort", true)
	if consolePart and consolePart:IsA("BasePart") then
		local prompt = consolePart:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Triggered:Connect(function(triggerer)
				if triggerer ~= player then
					return
				end
				RackAndCablingSystem.AttachConsole(triggerer, session, deviceId)
			end)
		end
	end

	-- Toggle power untuk device freeform (bukan rack-mounted)
	local node = session.devices[deviceId]
	if node and node.freeform then
		local chassis = model:FindFirstChild("Chassis")
		if chassis and chassis:IsA("BasePart") then
			local existing = chassis:FindFirstChild("PowerPrompt")
			if existing == nil then
				local powerPrompt = Instance.new("ProximityPrompt")
				powerPrompt.Name = "PowerPrompt"
				powerPrompt.ActionText = "Toggle Power"
				powerPrompt.ObjectText = node.name
				powerPrompt.HoldDuration = 0.4
				powerPrompt.MaxActivationDistance = 10
				powerPrompt.RequiresLineOfSight = false
				powerPrompt.Parent = chassis
				powerPrompt.Triggered:Connect(function(triggerer)
					if triggerer ~= player then
						return
					end
					node.isPowered = not node.isPowered
					graph.UpdateDeviceLED(session, deviceId)
					playSFX(player, if node.isPowered then "plug" else "key")
				end)
			end
		end
	end
end

--[[
	HookFacility: PDU rack + tombol power workbench.
]]
function RackAndCablingSystem.HookFacility(session: any)
	local player = session.player
	local facility = session.facility

	local pduParts: { [string]: BasePart } = facility.pduParts or {}
	for rackId, pdu in pairs(pduParts) do
		local click = pdu:FindFirstChild("PDUClick")
		if click and click:IsA("ClickDetector") then
			if not click:GetAttribute("Hooked") then
				click:SetAttribute("Hooked", true)
				click.MouseClick:Connect(function(clicker)
					if clicker ~= player then
						return
					end
					local rack = session.racks[rackId]
					if rack == nil then
						return
					end
					rack.pduPowered = not rack.pduPowered
					for id, node in pairs(session.devices) do
						if node.rackId == rackId then
							node.isPowered = rack.pduPowered
							graph.UpdateDeviceLED(session, id)
						end
					end
					local led = pdu.Parent and pdu.Parent:FindFirstChild("PDULed", true)
					if led and led:IsA("BasePart") then
						led.Color = if rack.pduPowered then Color3.fromRGB(85, 255, 120) else Color3.fromRGB(255, 80, 80)
					end
					playSFX(player, if rack.pduPowered then "plug" else "key")
				end)
			end
		end
	end
end

function RackAndCablingSystem.Update(session: any)
	-- cek jarak console cable >18 studs
	local link = session.consoleLink
	if link then
		local char = session.player.Character
		local model = session.deviceModels[link.deviceId]
		if char == nil or model == nil then
			RackAndCablingSystem.DetachConsole(session, session.player, true)
			return
		end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local d = (hrp.Position - model:GetPivot().Position).Magnitude
			if d > 18 then
				RackAndCablingSystem.DetachConsole(session, session.player, true)
			end
		end
	end
end

return RackAndCablingSystem
