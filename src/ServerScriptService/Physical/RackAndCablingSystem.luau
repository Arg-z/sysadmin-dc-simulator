--!strict
--[[
	RackAndCablingSystem (ModuleScript, ServerScriptService/Physical)
	Physical interaction layer for cabling, console links and power:
	- Two-click port cabling with Fase 2 colour-coded spools: WAN ports always
	  use the yellow spool, data ports use the selected LAN/Mgmt spool; the
	  spool is consumed only when the link is created
	- WireCutter tool equipped: clicking a connected port cuts its cable
	- First click marks the port with a yellow SelectionBox "PendingCableSel"
	  (15 s timeout), second click connects; clicking a connected port
	  disconnects it; clicking the same port cancels the pending selection
	- Laptop console cable: ProximityPrompt on the device ConsolePort attaches
	  a blue Beam from the equipped TechnicianLaptop to the device and opens
	  the terminal in LocalConsole mode; auto-detach beyond 18 studs
	- HookDevice: wires port ClickDetectors, the console prompt and a power
	  toggle prompt for freeform devices (once per device per session)
	- HookFacility: rack PDU click toggles power for every rack-mounted device
	- Remote responders: CableActionRemote "disconnect_all" (topology UI) and
	  OpenTerminalEvent "request_shell" (laptop click -> open terminal)
	Player isolation: every handler verifies the caller owns the session.
]]

local RackAndCablingSystem = {}

local Sessions: any = nil -- SessionManager module
local Graph: any = nil -- NetworkGraph module
local Remotes: any = nil -- Remotes folder

local PENDING_TIMEOUT = 15 -- seconds before a pending cable selection expires
local CONSOLE_MAX_DISTANCE = 18 -- studs between player and device pivot

local LED_GREEN = Color3.fromRGB(85, 255, 120)
local LED_RED = Color3.fromRGB(255, 80, 80)
local HIGHLIGHT_YELLOW = Color3.fromRGB(255, 220, 80)
local CONSOLE_BLUE = Color3.fromRGB(80, 160, 255)

---------------------------------------------------------------------
-- Init & remote bindings
---------------------------------------------------------------------

function RackAndCablingSystem.Init(deps: { [string]: any })
	Sessions = deps.sessions
	Graph = deps.graph
	Remotes = deps.remotesFolder

	-- Topology UI: disconnect every cable of one device (ownership checked).
	local cableRemote = Remotes:FindFirstChild("CableActionRemote")
	if cableRemote ~= nil then
		(cableRemote :: any).OnServerEvent:Connect(function(player, payload)
			RackAndCablingSystem.onCableAction(player, payload)
		end)
	end

	-- Laptop Tool click (client fires {action="request_shell"}): answer by
	-- opening the terminal in the session's current mode - "Disconnected"
	-- for a fresh session, matching the CONTRACT section 7 flow.
	local terminalRemote = Remotes:FindFirstChild("OpenTerminalEvent")
	if terminalRemote ~= nil then
		(terminalRemote :: any).OnServerEvent:Connect(function(player, payload)
			RackAndCablingSystem.onTerminalRequest(player, payload)
		end)
	end
end

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------

local function playSFX(player: Player, name: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("PlaySFXRemote") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, name)
	end
end

local function openTerminal(player: Player, payload: { [string]: any })
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("OpenTerminalEvent") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, payload)
	end
end

-- Clears the pending two-click cable selection (highlight + state).
local function clearPendingCable(session: any)
	if session.pendingCableHighlight ~= nil then
		session.pendingCableHighlight:Destroy()
	end
	session.pendingCableHighlight = nil
	session.pendingCableDeviceId = nil
	session.pendingCablePortId = nil
	session.pendingCableColor = nil
end

local function hasWireCutter(player: Player): boolean
	local char = player.Character
	if char == nil then
		return false
	end
	local tool = char:FindFirstChild("WireCutter")
	return tool ~= nil and tool:IsA("Tool")
end

local function hint(player: Player, message: string)
	openTerminal(player, { action = "hint", message = message })
end

--[[ Fase 2: pick the cable colour for a pending link. WAN ports always use
	 the yellow spool; data ports use the player's selected spool (never WAN). ]]
local function cableColorFor(session: any, port: any): string
	if port.portType == "WAN" then
		return "WAN_Yellow"
	end
	local selected = session.selectedCableColor
	if selected == "Mgmt_Red" then
		return "Mgmt_Red"
	end
	return "LAN_Blue"
end

local function spoolCount(session: any, color: string): number
	return tonumber(session.cableSpools[color]) or 0
end

---------------------------------------------------------------------
-- Port cabling (two-click)
---------------------------------------------------------------------

--[[
	HandlePortClick(player, session, deviceId, portId):
	- connected port  -> DisconnectPort + "plug" SFX
	- empty port      -> first click starts a pending selection (yellow
	                     SelectionBox, 15 s timeout); second click on another
	                     port connects both ("LAN_Blue") with "plug"/"error";
	                     same port cancels the pending selection
]]
function RackAndCablingSystem.HandlePortClick(player: Player, session: any, deviceId: string, portId: string)
	if session == nil or session.player ~= player then
		return -- only the session owner may touch its ports
	end
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	local port = node.ports[portId]
	if port == nil or port.portType == "Console" then
		return
	end

	-- WireCutter equipped: click a connected port to cut its cable.
	if hasWireCutter(player) then
		if port.connectedToDeviceId ~= nil then
			Graph.DisconnectPort(session, deviceId, portId)
			playSFX(player, "plug")
			hint(player, "Kabel dipotong dengan WireCutter.")
		else
			playSFX(player, "error")
			hint(player, "WireCutter: klik port yang tersambung untuk memotong kabel.")
		end
		return
	end

	-- Connected port: click = unplug.
	if port.connectedToDeviceId ~= nil then
		Graph.DisconnectPort(session, deviceId, portId)
		playSFX(player, "plug")
		return
	end

	-- Empty port, no pending selection yet: start one.
	if session.pendingCableDeviceId == nil or session.pendingCablePortId == nil then
		local color = cableColorFor(session, port)
		if spoolCount(session, color) <= 0 then
			playSFX(player, "error")
			hint(player, "Spool " .. color .. " habis. Beli di Store > Cable (1 spool = 5 kabel).")
			return
		end
		session.pendingCableDeviceId = deviceId
		session.pendingCablePortId = portId
		session.pendingCableColor = color
		local model = session.deviceModels[deviceId]
		if model ~= nil then
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
		task.delay(PENDING_TIMEOUT, function()
			-- expires only if the same selection is still pending
			if session.pendingCableDeviceId == deviceId and session.pendingCablePortId == portId then
				clearPendingCable(session)
			end
		end)
		return
	end

	-- Same port clicked again: cancel the pending selection.
	if session.pendingCableDeviceId == deviceId and session.pendingCablePortId == portId then
		clearPendingCable(session)
		return
	end

	-- Second endpoint: connect (NetworkGraph validates type + colour rules).
	local fromDev = session.pendingCableDeviceId :: string
	local fromPort = session.pendingCablePortId :: string
	local color = session.pendingCableColor or "LAN_Blue"
	clearPendingCable(session)
	if spoolCount(session, color) <= 0 then
		playSFX(player, "error")
		hint(player, "Spool " .. color .. " habis. Beli di Store > Cable.")
		return
	end
	local ok, err = Graph.ConnectPorts(session, fromDev, fromPort, deviceId, portId, color)
	if ok then
		session.cableSpools[color] = spoolCount(session, color) - 1
	end
	playSFX(player, if ok then "plug" else "error")
	if not ok and err ~= "" then
		hint(player, err)
	end
end

---------------------------------------------------------------------
-- Console cable (laptop <-> device)
---------------------------------------------------------------------

--[[
	AttachConsole(player, session, deviceId): requires the TechnicianLaptop
	Tool equipped; clicking the console prompt of the linked device detaches
	(toggle), another device re-targets the console link. Opens the terminal
	in LocalConsole mode for the device.
]]
function RackAndCablingSystem.AttachConsole(player: Player, session: any, deviceId: string)
	if session == nil or session.player ~= player then
		return
	end
	local node = session.devices[deviceId]
	if node == nil then
		return
	end

	-- Toggle: same device already linked -> detach.
	local link = session.consoleLink
	if link ~= nil and link.deviceId == deviceId then
		RackAndCablingSystem.DetachConsole(session, player, true)
		return
	end

	-- The console cable is physical: the laptop must be equipped.
	local char = player.Character
	local laptop = if char ~= nil then char:FindFirstChild("TechnicianLaptop") else nil
	if laptop == nil then
		playSFX(player, "error")
		openTerminal(player, { action = "hint", message = "Equip TechnicianLaptop dulu (slot 1) untuk menyambung kabel console." })
		return
	end

	local serial = laptop:FindFirstChild("SerialPortAttachment", true)
	local model = session.deviceModels[deviceId]
	local consolePart = if model ~= nil then model:FindFirstChild("ConsolePort", true) else nil
	local consoleAttach = if consolePart ~= nil and consolePart:IsA("BasePart") then consolePart:FindFirstChild("ConsoleAttach") else nil
	if serial == nil or not serial:IsA("Attachment") or consoleAttach == nil or not consoleAttach:IsA("Attachment") then
		playSFX(player, "error")
		return
	end

	-- Re-targeting: silently drop the previous beam (no detach notification).
	if link ~= nil then
		if link.beam ~= nil then
			link.beam:Destroy()
		end
		session.consoleLink = nil
	end

	local beam = Instance.new("Beam")
	beam.Name = "ConsoleBeam"
	beam.Attachment0 = serial
	beam.Attachment1 = consoleAttach
	beam.Color = ColorSequence.new(CONSOLE_BLUE)
	beam.Transparency = NumberSequence.new(0.05)
	beam.Width0 = 0.16
	beam.Width1 = 0.16
	beam.CurveSize0 = -0.8
	beam.CurveSize1 = -0.8
	beam.Segments = 14
	beam.FaceCamera = true
	local cablesFolder = session.facility.cables
	if cablesFolder ~= nil then
		beam.Parent = cablesFolder
	else
		beam.Parent = model :: Model -- fallback before the facility refs exist
	end
	session.consoleLink = { deviceId = deviceId, beam = beam }

	session.terminal.mode = "LocalConsole"
	session.terminal.targetDeviceId = deviceId

	playSFX(player, "plug")
	openTerminal(player, { action = "open", mode = "LocalConsole", deviceName = node.name, deviceId = deviceId })
end

--[[
	DetachConsole(session, player?, notify): destroys the console beam and
	resets the terminal to Disconnected. `notify` also tells the client
	({action="detach"} + "key" SFX) so the terminal window reacts.
]]
function RackAndCablingSystem.DetachConsole(session: any, player: Player?, notify: boolean)
	local link = session.consoleLink
	if link ~= nil then
		if link.beam ~= nil then
			link.beam:Destroy()
		end
		session.consoleLink = nil
	end
	session.terminal.mode = "Disconnected"
	session.terminal.targetDeviceId = nil
	session.terminal.sshStack = {}
	if notify and player ~= nil then
		openTerminal(player, { action = "detach" })
		playSFX(player, "key")
	end
end

---------------------------------------------------------------------
-- Hooking device interactions
---------------------------------------------------------------------

--[[
	HookDevice(session, deviceId): connects all interaction callbacks of one
	device model, exactly once per session (session.hookedDevices guard):
	- every port ClickDetector -> HandlePortClick
	- console ProximityPrompt  -> AttachConsole
	- freeform devices get a "PowerPrompt" on their Chassis (HoldDuration 0.4)
	  toggling node.isPowered (rack-mounted devices are driven by the PDU)
]]
function RackAndCablingSystem.HookDevice(session: any, deviceId: string)
	if session.hookedDevices[deviceId] then
		return
	end
	local model = session.deviceModels[deviceId]
	if model == nil then
		return -- nothing to hook yet; do not consume the guard
	end
	session.hookedDevices[deviceId] = true
	local player = session.player

	-- Port click detectors ("Click" on parts carrying PortId/DeviceId attrs).
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("ClickDetector") and desc.Name == "Click" then
			local portPart = desc.Parent
			if portPart ~= nil and portPart:IsA("BasePart") then
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

	-- Console port prompt -> laptop console link.
	local consolePart = model:FindFirstChild("ConsolePort", true)
	if consolePart ~= nil and consolePart:IsA("BasePart") then
		local prompt = consolePart:FindFirstChildOfClass("ProximityPrompt")
		if prompt ~= nil then
			prompt.Triggered:Connect(function(triggerer)
				if triggerer ~= player then
					return
				end
				RackAndCablingSystem.AttachConsole(triggerer, session, deviceId)
			end)
		end
	end

	-- Freeform devices: physical power toggle on the chassis.
	local node = session.devices[deviceId]
	if node ~= nil and node.freeform == true then
		local chassis = model:FindFirstChild("Chassis")
		if chassis ~= nil and chassis:IsA("BasePart") and chassis:FindFirstChild("PowerPrompt") == nil then
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
				local live = session.devices[deviceId]
				if live == nil then
					return
				end
				live.isPowered = not live.isPowered
				Graph.UpdateDeviceLED(session, deviceId)
				playSFX(player, if live.isPowered then "plug" else "key")
			end)
		end
	end
end

---------------------------------------------------------------------
-- Rack PDU
---------------------------------------------------------------------

--[[
	HookFacility(session): wires the PDU click detector of every rack in
	facility.pduParts (guard attribute "Hooked" so racks are wired once even
	when HookFacility runs again after another rack is placed). Toggling the
	PDU powers on/off every rack-mounted device and recolors the PDU LED.
]]
function RackAndCablingSystem.HookFacility(session: any)
	local facility = session.facility
	if type(facility) ~= "table" then
		return
	end
	local pduParts = facility.pduParts
	if type(pduParts) ~= "table" then
		return
	end
	local player = session.player

	for rackId, pdu in pairs(pduParts) do
		local click = if pdu ~= nil and pdu:IsA("BasePart") then pdu:FindFirstChild("PDUClick") else nil
		if click ~= nil and click:IsA("ClickDetector") and not click:GetAttribute("Hooked") then
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
				-- PDU drives every device mounted in this rack
				for id, node in pairs(session.devices) do
					if node.rackId == rackId then
						node.isPowered = rack.pduPowered
						Graph.UpdateDeviceLED(session, id)
					end
				end
				local rackModel = session.rackModels[rackId]
				local ledSource = if rackModel ~= nil then rackModel else pdu.Parent
				local led = if ledSource ~= nil then ledSource:FindFirstChild("PDULed", true) else nil
				if led ~= nil and led:IsA("BasePart") then
					led.Color = if rack.pduPowered then LED_GREEN else LED_RED
				end
				playSFX(player, if rack.pduPowered then "plug" else "key")
			end)
		end
	end
end

---------------------------------------------------------------------
-- Per-tick upkeep
---------------------------------------------------------------------

--[[
	Update(session) (called from the economy tick): the console cable is a
	physical wire - walking more than 18 studs from the device detaches it.
]]
function RackAndCablingSystem.Update(session: any)
	local link = session.consoleLink
	if link == nil then
		return
	end
	local char = session.player.Character
	local model = session.deviceModels[link.deviceId]
	if char == nil or model == nil then
		RackAndCablingSystem.DetachConsole(session, session.player, true)
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		local dist = (hrp.Position - model:GetPivot().Position).Magnitude
		if dist > CONSOLE_MAX_DISTANCE then
			RackAndCablingSystem.DetachConsole(session, session.player, true)
		end
	end
end

---------------------------------------------------------------------
-- Remote responders
---------------------------------------------------------------------

-- CableActionRemote {action="disconnect_all", deviceId}: disconnect every
-- connected non-Console port of a device owned by this session.
function RackAndCablingSystem.onCableAction(player: Player, payload: any)
	if type(payload) ~= "table" or payload.action ~= "disconnect_all" then
		return
	end
	if Sessions == nil then
		return
	end
	local session = Sessions.GetSession(player)
	if session == nil then
		return
	end
	local deviceId = payload.deviceId
	if type(deviceId) ~= "string" or session.devices[deviceId] == nil then
		return
	end
	local node = session.devices[deviceId]
	local disconnectedAny = false
	for _, port in pairs(node.ports) do
		if port.connectedToDeviceId ~= nil and port.portType ~= "Console" then
			Graph.DisconnectPort(session, deviceId, port.portId)
			disconnectedAny = true
		end
	end
	if disconnectedAny then
		playSFX(player, "plug")
	end
end

-- OpenTerminalEvent {action="request_shell"} from the laptop Tool click:
-- open the terminal in the session's current mode (fresh session = "Disconnected").
function RackAndCablingSystem.onTerminalRequest(player: Player, payload: any)
	if type(payload) ~= "table" or payload.action ~= "request_shell" then
		return
	end
	if Sessions == nil then
		return
	end
	local session = Sessions.GetSession(player)
	if session == nil then
		return
	end
	local mode = if session.terminal.mode ~= nil then session.terminal.mode else "Disconnected"
	local deviceName = "Laptop Shell"
	local deviceId = session.terminal.targetDeviceId
	if deviceId ~= nil and session.devices[deviceId] ~= nil then
		deviceName = session.devices[deviceId].name
	end
	openTerminal(player, { action = "open", mode = mode, deviceName = deviceName, deviceId = deviceId })
end

return RackAndCablingSystem
