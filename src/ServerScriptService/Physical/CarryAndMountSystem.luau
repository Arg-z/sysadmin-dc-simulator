--!strict
--[[
	CarryAndMountSystem (ModuleScript, ServerScriptService/Physical)
	Fase 2 physical layer for colocation deliveries:
	- SpawnCrate: a client server crate appears on the loading dock when a
	  Colocation contract is accepted (label + "Angkat Crate" prompt)
	- BeginCarry / EndCarry: the crate follows the player's HumanoidRootPart
	  on Heartbeat while every rack exposes a "Pasang Server" prompt
	- MountCarried: validates a free U block, calls PlacementSystem.MountDevice
	  (ColocationServer node, client IP, rack power) and links the ticket
	- DropCarried: puts the crate back on the dock (prompt on the crate)
	- EvaluateColo: ticket acceptance test = powered + switch access VLAN match
	  + reachable from the ISP gateway
	- CleanupTicket: removes the crate and the rack-mounted client server
	No remotes are introduced: every action is a ProximityPrompt on the server.
]]

local RunService = game:GetService("RunService")

local CarryAndMountSystem = {}

local Sessions: any = nil
local Placement: any = nil
local Graph: any = nil
local ModelFactory: any = nil
local Constants: any = nil
local Remotes: any = nil
local Catalog: any = nil

local GATEWAY_DEVICE_ID = "isp_router_1"

---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------

function CarryAndMountSystem.Init(deps: { [string]: any })
	Sessions = deps.sessions
	Placement = deps.placement
	Graph = deps.graph
	ModelFactory = deps.modelFactory
	Constants = deps.constants
	Remotes = deps.remotesFolder
	Catalog = deps.catalog
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function playSFX(player: Player, name: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("PlaySFXRemote") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, name)
	end
end

local function hint(player: Player, message: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("OpenTerminalEvent") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, { action = "hint", message = message })
	end
end

local function findTicket(session: any, ticketId: string): any?
	for _, ticket in ipairs(session.tickets or {}) do
		if ticket.id == ticketId then
			return ticket
		end
	end
	return nil
end

local function cratePart(crate: Model): BasePart?
	local box = crate:FindFirstChild("CrateBox")
	if box ~= nil and box:IsA("BasePart") then
		return box :: BasePart
	end
	for _, desc in ipairs(crate:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc :: BasePart
		end
	end
	return nil
end

local function removeMountPrompts(session: any)
	for _, rackModel in pairs(session.rackModels) do
		local frame = rackModel:FindFirstChild("SlotFrame", true)
		if frame ~= nil then
			local prompt = frame:FindFirstChild("MountPrompt")
			if prompt ~= nil then
				prompt:Destroy()
			end
		end
	end
end

local function addMountPrompts(session: any)
	local player = session.player
	for rackId, rackModel in pairs(session.rackModels) do
		local frame = rackModel:FindFirstChild("SlotFrame", true)
		if frame ~= nil and frame:IsA("BasePart") and frame:FindFirstChild("MountPrompt") == nil then
			local rack = session.racks[rackId]
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "MountPrompt"
			prompt.ActionText = "Mount Server"
			prompt.ObjectText = if rack ~= nil then rack.name else rackId
			prompt.HoldDuration = 0.35
			prompt.MaxActivationDistance = 18
			prompt.RequiresLineOfSight = false
			prompt.Parent = frame
			prompt.Triggered:Connect(function(triggerer: Player)
				if triggerer ~= player then
					return
				end
				CarryAndMountSystem.MountCarried(session, rackId)
			end)
		end
	end
end

local function setCratePromptText(crate: Model, text: string)
	local part = cratePart(crate)
	if part == nil then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt ~= nil and prompt:IsA("ProximityPrompt") then
		prompt.ActionText = text
	end
end

local function updateCarry(session: any)
	local carry = session.carry
	if carry == nil then
		return
	end
	local crate = carry.crate
	if crate == nil or crate.Parent == nil then
		CarryAndMountSystem.EndCarry(session)
		return
	end
	local char = session.player.Character
	local hrp = if char ~= nil then char:FindFirstChild("HumanoidRootPart") else nil
	if hrp == nil or not hrp:IsA("BasePart") then
		CarryAndMountSystem.DropCarried(session)
		return
	end
	crate:PivotTo((hrp :: BasePart).CFrame * CFrame.new(0, -1.25, -2.35))
end

---------------------------------------------------------------------
-- Crate lifecycle
---------------------------------------------------------------------

--[[ Creates the client server crate for an accepted Colocation ticket at the
	 loading dock. Returns false when the dock/CF is missing or a crate
	 already exists for this ticket. ]]
function CarryAndMountSystem.SpawnCrate(session: any, ticket: any): boolean
	if session == nil or ticket == nil or type(ticket.id) ~= "string" then
		return false
	end
	if session.colocation.crates[ticket.id] ~= nil then
		return false
	end
	local facility = session.facility
	local dockCF = if type(facility) == "table" then facility.dockCF else nil
	if dockCF == nil then
		return false
	end

	local crate = ModelFactory.BuildCrate("COLOCATION\n" .. tostring(ticket.clientName))
	crate.Name = "ColoCrate_" .. ticket.id
	for _, desc in ipairs(crate:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
		end
	end
	-- Keep multiple deliveries side by side on the dock pad.
	local occupied = 0
	for _ in pairs(session.colocation.crates) do
		occupied += 1
	end
	crate:PivotTo((dockCF :: CFrame) * CFrame.new(occupied * 2.9, 0, 0))

	local box = cratePart(crate)
	if box ~= nil then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "CarryPrompt"
		prompt.ActionText = "Pick Up Crate"
		prompt.ObjectText = tostring(ticket.clientName) .. " Colo Server"
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.Parent = box
		prompt.Triggered:Connect(function(triggerer: Player)
			if triggerer ~= session.player then
				return
			end
			if session.carry ~= nil and session.carry.crate == crate then
				CarryAndMountSystem.DropCarried(session)
			else
				CarryAndMountSystem.BeginCarry(session, crate, ticket.id)
			end
		end)
	end

	local cratesFolder = if type(facility) == "table" then facility.crates else nil
	crate.Parent = if cratesFolder ~= nil then cratesFolder else facility.root
	session.colocation.crates[ticket.id] = crate
	session.colocation.byTicket[ticket.id] = crate
	hint(session.player, "Colocation crate arrived at the Loading Dock. Pick it up and mount it in a rack.")
	playSFX(session.player, "key")
	return true
end

function CarryAndMountSystem.BeginCarry(session: any, crate: Model, ticketId: string)
	if session.carry ~= nil then
		hint(session.player, "You are already carrying a crate. Mount it in a rack first.")
		return
	end
	local char = session.player.Character
	local hrp = if char ~= nil then char:FindFirstChild("HumanoidRootPart") else nil
	if hrp == nil then
		hint(session.player, "Character is not ready.")
		return
	end

	session.carry = {
		crate = crate,
		ticketId = ticketId,
		conn = RunService.Heartbeat:Connect(function()
			updateCarry(session)
		end),
	}
	setCratePromptText(crate, "Drop Crate")
	addMountPrompts(session)
	updateCarry(session)
	playSFX(session.player, "key")
	hint(session.player, "Crate picked up. Approach a rack and press 'Mount Server'.")
end

function CarryAndMountSystem.EndCarry(session: any)
	local carry = session.carry
	if carry == nil then
		return
	end
	if carry.conn ~= nil then
		carry.conn:Disconnect()
	end
	if carry.crate ~= nil and carry.crate.Parent ~= nil then
		setCratePromptText(carry.crate, "Pick Up Crate")
	end
	session.carry = nil
	removeMountPrompts(session)
end

--[[ Puts the carried crate back on the dock (or in front of the player). ]]
function CarryAndMountSystem.DropCarried(session: any)
	local carry = session.carry
	if carry == nil then
		return
	end
	local crate = carry.crate
	local dockCF = if type(session.facility) == "table" then session.facility.dockCF else nil
	if crate ~= nil and crate.Parent ~= nil and dockCF ~= nil then
		crate:PivotTo(dockCF :: CFrame)
	end
	CarryAndMountSystem.EndCarry(session)
	hint(session.player, "Crate dropped at the Loading Dock.")
	playSFX(session.player, "plug")
end

--[[ Mounts the carried crate into the first free U block of a rack. ]]
function CarryAndMountSystem.MountCarried(session: any, rackId: string): boolean
	local carry = session.carry
	if carry == nil then
		hint(session.player, "You are not carrying a crate.")
		return false
	end
	local ticket = findTicket(session, carry.ticketId)
	if ticket == nil or ticket.status ~= "Active" then
		hint(session.player, "Colocation contract is not active.")
		return false
	end
	local rack = session.racks[rackId]
	if rack == nil then
		hint(session.player, "Rack not found.")
		return false
	end

	local colo = Constants.COLOCATION
	local uSize = colo.uSize
	local uSlot = Placement.FindFreeUSlot(session, rackId, uSize)
	if uSlot == nil then
		hint(session.player, string.format("Rack %s does not have %dU of free space.", rack.name, uSize))
		playSFX(session.player, "error")
		return false
	end

	local itemId = "bm_starter"
	local def = Catalog.Get(itemId)
	local displayName = tostring(ticket.clientName) .. " Colo Server"
	local ok, result = Placement.MountDevice(session, itemId, rackId, uSlot, {
		name = displayName,
		deviceType = "ColocationServer",
		ip = ticket.targetIp,
		gateway = "192.168.1.1",
		subnetMask = "255.255.255.0",
		osInstalled = "ubuntu-22.04",
		isPowered = rack.pduPowered,
		contractId = ticket.id,
		noAutoCable = true,
		idPrefix = "colo",
	})
	if not ok then
		hint(session.player, "Mount failed: " .. tostring(result))
		playSFX(session.player, "error")
		return false
	end

	ticket.targetDeviceId = result
	ticket.targetRackId = rackId
	ticket.targetUSlot = uSlot
	ticket.phase = "mounted"
	ticket.validationText = "Mounted - cable to switch, configure VLAN, turn PDU ON"

	local crate = carry.crate
	if crate ~= nil then
		crate:Destroy()
	end
	session.colocation.crates[ticket.id] = nil
	session.colocation.byTicket[ticket.id] = nil
	CarryAndMountSystem.EndCarry(session)

	playSFX(session.player, "plug")
	local ourU = uSlot - (def ~= nil and def.uSize or uSize) + 1
	hint(session.player, string.format(
		"Client server mounted in %s U%d-%d. Cable to switch, set VLAN %d, power on PDU.",
		rack.name,
		math.max(1, ourU),
		uSlot,
		ticket.vlanId or 1
	))
	return true
end

---------------------------------------------------------------------
-- Colocation validation & cleanup
---------------------------------------------------------------------

--[[ Returns (ready, validationText) for an active Colocation ticket. ]]
function CarryAndMountSystem.EvaluateColo(session: any, ticket: any): (boolean, string)
	local deviceId = ticket.targetDeviceId
	if deviceId == nil then
		return false, "Crate not mounted in rack yet"
	end
	local node = session.devices[deviceId]
	if node == nil then
		return false, "Client server not found"
	end
	if not node.isPowered then
		return false, "Rack PDU is OFF - power on PDU"
	end
	local accessSwitch, accessPortId = Graph.GetAccessSwitchPort(session, deviceId)
	if accessSwitch == nil or accessPortId == nil then
		return false, "No cable connected to switch yet"
	end
	local port = accessSwitch.ports[accessPortId]
	if port == nil then
		return false, "Switch port not found"
	end
	local wanted = ticket.vlanId or 1
	if port.isTrunk == true then
		return false, "Access port is in trunk mode - set access mode + VLAN " .. tostring(wanted)
	end
	if port.vlanId ~= wanted then
		return false, string.format("Switch VLAN %d != %d", port.vlanId, wanted)
	end
	if node.ip == nil then
		return false, "Client server has no IP"
	end
	local reachable = Graph.CanReachIP(session, GATEWAY_DEVICE_ID, node.ip)
	if not reachable then
		return false, "Unreachable from gateway - check uplink cable/VLAN"
	end
	return true, string.format("Reachable from gateway on VLAN %d", port.vlanId)
end

--[[ Removes every physical trace of a ticket: crate and mounted server. ]]
function CarryAndMountSystem.CleanupTicket(session: any, ticket: any)
	if session == nil or ticket == nil then
		return
	end
	local crate = session.colocation.crates[ticket.id]
	if crate ~= nil then
		crate:Destroy()
		session.colocation.crates[ticket.id] = nil
		session.colocation.byTicket[ticket.id] = nil
	end
	local deviceId = ticket.targetDeviceId
	if type(deviceId) == "string" and session.devices[deviceId] ~= nil then
		Placement.UnmountDevice(session, deviceId)
	end
	ticket.targetDeviceId = nil
	ticket.targetRackId = nil
	ticket.targetUSlot = nil
end

--[[ Tick guard: if the carried character disappears, drop the crate. ]]
function CarryAndMountSystem.Update(session: any)
	if session.carry == nil then
		return
	end
	local char = session.player.Character
	if char == nil or char:FindFirstChild("HumanoidRootPart") == nil then
		CarryAndMountSystem.DropCarried(session)
	end
end

return CarryAndMountSystem
