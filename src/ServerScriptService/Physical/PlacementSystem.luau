--!strict
--[[
	PlacementSystem (ModuleScript, ServerScriptService/Physical)
	Server-authoritative hardware purchase + freeform placement:
	- ValidatePlacement: 2-stud grid snap, lab bounds, furniture-zone
	  clearance, freeform device overlap, floor height forcing
	- PlaceDevice: racks (rack data + PDU + hooks) or freeform devices
	  (model + graph node + config apply + auto-cable + hooks). Also used by
	  DataPersistenceManager to restore saved devices (session.loadedFromSave
	  suppresses auto-cabling; restored cables are linked explicitly)
	- OnPurchase: PurchaseHardwareRemote dispatcher - "prepare"/"place"/
	  "cancel" for placeables, "buy" for components (workbench) and cable
	  spools (Fase 2 inventory), plus MountDevice/UnmountDevice for the carry
	  system and save restore.
	All rejections reach the client as OpenTerminalEvent {action="hint"}.
]]

local PlacementSystem = {}

local Sessions: any = nil -- SessionManager module
local Graph: any = nil -- NetworkGraph module
local Catalog: any = nil -- HardwareCatalog module
local Constants: any = nil -- PlotConstants module
local ModelFactory: any = nil -- ModelFactory module
local Workbench: any = nil -- WorkbenchBuilderSystem module
local Cabling: any = nil -- RackAndCablingSystem module
local Remotes: any = nil -- Remotes folder

-- Id counters live in SessionManager (Core, owned by AGENT A; read-only use).
local SessionManager = require(script.Parent.Parent.Core.SessionManager)

---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------

function PlacementSystem.Init(deps: { [string]: any })
	Sessions = deps.sessions
	Graph = deps.graph
	Catalog = deps.catalog
	Constants = deps.constants
	ModelFactory = deps.modelFactory
	Workbench = deps.workbench
	Cabling = deps.cabling
	Remotes = deps.remotesFolder

	local purchase = Remotes:FindFirstChild("PurchaseHardwareRemote")
	if purchase ~= nil then
		(purchase :: any).OnServerEvent:Connect(function(player, itemId, action, cf, rotY)
			PlacementSystem.OnPurchase(player, itemId, action, cf, rotY)
		end)
	end
end

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------

local function hint(player: Player, message: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("OpenTerminalEvent") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, { action = "hint", message = message })
	end
end

local function playSFX(player: Player, name: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("PlaySFXRemote") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, name)
	end
end

-- Device id prefix: "bm" servers, "rt" routers (Network with WAN ports),
-- "sw" everything else (switches). Racks use "rack".
local function prefixFor(def: any): string
	if def.category == "Server" then
		return "bm"
	end
	if def.category == "Network" and (def.specs.wanPorts or 0) > 0 then
		return "rt"
	end
	return "sw"
end

---------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------

--[[
	ValidatePlacement(session, itemId, cf) -> (ok, reason, snappedCF)
	- snaps the requested position to the 2-stud grid (plot-relative)
	- inside PLACEMENT_BOUNDS (plot-relative)
	- clear of every FURNITURE_ZONES bubble (radius + device half-extent)
	- clear of every other freeform device ((sum of half extents) + 0.5)
	- Y is forced to the room floor top
	node.posX/posZ are stored as world coordinates (so DataPersistenceManager
	can rebuild with CFrame.new(posX, floorY, posZ)); they are converted back
	to plot-relative here for the distance checks.
]]
function PlacementSystem.ValidatePlacement(session: any, itemId: string, cf: CFrame): (boolean, string, CFrame)
	local def = Catalog.Get(itemId)
	if def == nil then
		return false, "Unknown item", cf
	end

	local origin = Constants.PLOT_POSITIONS[session.plotIndex]
	local floorY = Constants.ROOM.floorTopY
	local halfX, halfZ = ModelFactory.ComputeFootprint(itemId)

	local rel = cf.Position - origin
	local grid = Constants.SNAP_GRID
	local sx = math.floor(rel.X / grid + 0.5) * grid
	local sz = math.floor(rel.Z / grid + 0.5) * grid

	local bounds = Constants.PLACEMENT_BOUNDS
	if sx < bounds.minX or sx > bounds.maxX or sz < bounds.minZ or sz > bounds.maxZ then
		return false, "Outside lab bounds", cf
	end

	local relSnap = Vector3.new(sx, 0, sz)
	local margin = math.max(halfX, halfZ)
	for _, zone in ipairs(Constants.FURNITURE_ZONES) do
		local zoneRel = Vector3.new(zone.position.X, 0, zone.position.Z)
		local dist = (zoneRel - relSnap).Magnitude
		if dist < zone.radius + margin then
			return false, "Overlaps " .. zone.name .. " zone", cf
		end
	end

	for _, node in pairs(session.devices) do
		if node.freeform == true and node.posX ~= nil and node.posZ ~= nil then
			local otherHalfX, otherHalfZ = ModelFactory.ComputeFootprint(node.itemId)
			local otherRel = Vector3.new(node.posX - origin.X, 0, node.posZ - origin.Z)
			local dist = (otherRel - relSnap).Magnitude
			if dist < (halfX + otherHalfX) + (halfZ + otherHalfZ) + 0.5 then
				return false, "Overlaps " .. node.name, cf
			end
		end
	end

	local snapped = CFrame.new(origin + Vector3.new(sx, floorY, sz))
	return true, "", snapped
end

---------------------------------------------------------------------
-- Placement
---------------------------------------------------------------------

--[[ Builds and registers one rack at the given world CFrame. Shared by the
	 store placement flow and the save-restore path so both keep the same
	 rack data, slot attachments and PDU hooks. Returns the new rack id. ]]
local function createRack(session: any, itemId: string, snappedCF: CFrame, rotY: number): string
	local def = Catalog.Get(itemId)
	if def == nil then
		return ""
	end
	local rackId = SessionManager.NextDeviceId(session, "rack")
	local model, slots, pduPart = ModelFactory.BuildRack(itemId, rackId)
	model:PivotTo(snappedCF * CFrame.Angles(0, rotY, 0))
	model.Parent = session.facility.devices

	session.racks[rackId] = {
		rackId = rackId,
		name = def.name,
		itemId = itemId,
		maxU = def.specs.maxU,
		occupiedSlots = {},
		totalPowerWatts = 0,
		maxPowerWatts = def.specs.maxPowerWatts,
		pduPowered = false,
	}
	session.rackModels[rackId] = model
	session.rackSlots[rackId] = slots

	session.facility.pduParts = session.facility.pduParts or {}
	session.facility.pduParts[rackId] = pduPart
	Cabling.HookFacility(session) -- wires the new PDU (guard attr skips old ones)
	return rackId
end

--[[ Restores a rack saved by DataPersistenceManager (including PDU state). ]]
function PlacementSystem.RestoreRack(session: any, itemId: string, posX: number, posZ: number, rotY: number, pduPowered: boolean): string
	local rackId = createRack(session, itemId, CFrame.new(Vector3.new(posX, Constants.ROOM.floorTopY, posZ)), rotY)
	local rack = session.racks[rackId]
	if rack ~= nil then
		rack.pduPowered = pduPowered
	end
	return rackId
end

--[[ First free contiguous U block of uSize (top slot number), or nil. ]]
function PlacementSystem.FindFreeUSlot(session: any, rackId: string, uSize: number): number?
	local rack = session.racks[rackId]
	if rack == nil then
		return nil
	end
	local size = math.max(1, math.floor(uSize))
	for top = rack.maxU, size, -1 do
		local free = true
		for u = top - size + 1, top do
			if rack.occupiedSlots[u] ~= nil then
				free = false
				break
			end
		end
		if free then
			return top
		end
	end
	return nil
end

--[[ Mounts a catalog device into a rack U slot and registers its graph node.
	 Used by the Fase 2 carry system, colocation delivery and save restore.
	 config: { name?, deviceType?, ip?, gateway?, subnetMask?, osInstalled?,
	           isPowered?, contractId?, noAutoCable?, idPrefix? }
	 Returns (ok, deviceId or errorMessage). ]]
function PlacementSystem.MountDevice(session: any, itemId: string, rackId: string, uSlot: number, config: any?): (boolean, string)
	local def = Catalog.Get(itemId)
	if def == nil then
		return false, "Unknown item"
	end
	local rack = session.racks[rackId]
	if rack == nil then
		return false, "Rack not found"
	end
	local nodeSize = math.max(1, math.floor(def.uSize or 1))
	if uSlot < nodeSize or uSlot > rack.maxU then
		return false, "U slot out of rack bounds"
	end
	for u = uSlot - nodeSize + 1, uSlot do
		if rack.occupiedSlots[u] ~= nil then
			return false, "Slot U" .. tostring(uSlot) .. " is already occupied"
		end
	end

	local cfg = if type(config) == "table" then config else {}
	local prefix = if type(cfg.idPrefix) == "string" then cfg.idPrefix else "srv"
	local deviceId = SessionManager.NextDeviceId(session, prefix)
	local model, _ports, _consoleAttach, _led, _smoke = ModelFactory.BuildDeviceModel(itemId, deviceId)
	local slots = session.rackSlots[rackId]
	local slot = if type(slots) == "table" then slots[uSlot] else nil
	if slot ~= nil and slot:IsA("Attachment") then
		model:PivotTo((slot :: Attachment).WorldCFrame * CFrame.new(0, 0, 0.95))
	else
		local rackModel = session.rackModels[rackId]
		if rackModel ~= nil then
			model:PivotTo(rackModel:GetPivot() * CFrame.new(0, 1.2, 0.2))
		end
	end
	model.Parent = session.facility.devices

	local node = Graph.DefaultNode(deviceId, if type(cfg.name) == "string" then cfg.name else def.name, itemId)
	node.rackId = rackId
	node.uSlot = uSlot
	node.freeform = false
	if type(cfg.deviceType) == "string" then
		node.deviceType = cfg.deviceType
	end
	node.ip = cfg.ip
	node.gateway = cfg.gateway
	node.subnetMask = if type(cfg.subnetMask) == "string" then cfg.subnetMask else "255.255.255.0"
	node.osInstalled = cfg.osInstalled
	node.contractId = cfg.contractId
	node.isPowered = if cfg.isPowered ~= nil then cfg.isPowered == true else rack.pduPowered

	for u = uSlot - nodeSize + 1, uSlot do
		rack.occupiedSlots[u] = deviceId
	end
	rack.totalPowerWatts += node.specs.powerWatts

	Graph.RegisterDevice(session, node, model)
	if cfg.noAutoCable ~= true and not session.loadedFromSave then
		Graph.AutoCable(session, deviceId)
	end
	Cabling.HookDevice(session, deviceId)
	return true, deviceId
end

--[[ Removes a rack-mounted device, frees its U block and adjusts rack power. ]]
function PlacementSystem.UnmountDevice(session: any, deviceId: string)
	local node = session.devices[deviceId]
	if node == nil then
		return
	end
	local rack = if node.rackId ~= nil then session.racks[node.rackId] else nil
	if rack ~= nil and node.uSlot ~= nil then
		for u = node.uSlot - node.uSize + 1, node.uSlot do
			if rack.occupiedSlots[u] == deviceId then
				rack.occupiedSlots[u] = nil
			end
		end
		rack.totalPowerWatts = math.max(0, rack.totalPowerWatts - node.specs.powerWatts)
	end
	Graph.RemoveDevice(session, deviceId)
end

--[[
	PlaceDevice(session, itemId, snappedCF, rotY, config?) -> id
	Rack category: builds the rack model, session.racks entry (pduPowered =
	false - the player must switch the PDU on), registers the PDU part in
	facility.pduParts and hooks it.
	Everything else: device model + DefaultNode (freeform, world posX/posZ),
	config applied when present (restore path), RegisterDevice, AutoCable
	(skipped when session.loadedFromSave) and interaction hooks.
	Returns the new device/rack id ("" when the item is unknown).
]]
function PlacementSystem.PlaceDevice(session: any, itemId: string, snappedCF: CFrame, rotY: number, config: any?): string
	local def = Catalog.Get(itemId)
	if def == nil then
		return ""
	end

	if def.category == "Rack" then
		return createRack(session, itemId, snappedCF, rotY)
	end

	local deviceId = SessionManager.NextDeviceId(session, prefixFor(def))
	local model, _ports, _consoleAttach, _led, _smoke = ModelFactory.BuildDeviceModel(itemId, deviceId)
	model:PivotTo(snappedCF * CFrame.Angles(0, rotY, 0))
	model.Parent = session.facility.devices

	local node = Graph.DefaultNode(deviceId, def.name, itemId)
	node.freeform = true
	node.posX = snappedCF.Position.X
	node.posZ = snappedCF.Position.Z
	node.rotY = rotY

	-- Restore config (DataPersistenceManager): IP setup, OS, power, VMs.
	if type(config) == "table" then
		node.ip = config.ip
		node.gateway = config.gateway
		node.subnetMask = if type(config.subnetMask) == "string" then config.subnetMask else "255.255.255.0"
		node.osInstalled = config.osInstalled
		node.isPowered = if config.isPowered ~= nil then config.isPowered == true else false
		if type(config.vms) == "table" then
			for _, vm in ipairs(config.vms) do
				if type(vm) == "table" and type(vm.name) == "string" and #vm.name > 0 then
					node.vms[vm.name] = vm
				end
			end
		end
	end

	Graph.RegisterDevice(session, node, model)
	if not session.loadedFromSave then
		Graph.AutoCable(session, deviceId) -- saved sessions re-link cables explicitly
	end
	Cabling.HookDevice(session, deviceId)
	return deviceId
end

---------------------------------------------------------------------
-- Purchase dispatch
---------------------------------------------------------------------

--[[
	OnPurchase(player, itemId, action, cf, rotY): PurchaseHardwareRemote
	handler. Categories:
	- Cable     -> Fase 2 hint (manual cabling is out of Fase 1 scope)
	- Component -> workbench.TryInstall (assembly order enforced there)
	- Rack/Network/Server -> "prepare" (balance check, remembers pending item),
	  "place" (validate + deduct + PlaceDevice + "cash"), "cancel"
]]
function PlacementSystem.OnPurchase(player: Player, itemId: any, action: any, cf: any, rotY: any)
	if Sessions == nil then
		return
	end
	local session = Sessions.GetSession(player)
	if session == nil then
		return
	end
	if type(itemId) ~= "string" or type(action) ~= "string" then
		return
	end
	local def = Catalog.Get(itemId)
	if def == nil then
		return
	end

	if def.category == "Cable" then
		if action ~= "buy" then
			hint(player, "Cables are purchased as spools: click BUY in the Cable category.")
			return
		end
		local color: string? = nil
		for candidate, item in pairs(Constants.CABLES.itemByColor) do
			if item == itemId then
				color = candidate
				break
			end
		end
		if color == nil then
			return
		end
		if session.balance < def.price then
			hint(player, "Insufficient funds for " .. def.name .. " ($" .. tostring(def.price) .. ")")
			return
		end
		session.balance -= def.price
		local current = tonumber(session.cableSpools[color]) or 0
		session.cableSpools[color] = current + Constants.CABLES.spoolYield
		playSFX(player, "cash")
		hint(player, string.format(
			"Purchased %s spool: +%d cables (stock: %d).",
			Constants.CABLES.labels[color] or color,
			Constants.CABLES.spoolYield,
			session.cableSpools[color]
		))
		return
	end

	if def.category == "Component" then
		Workbench.TryInstall(player, session, itemId)
		return
	end

	-- Placeable categories: Rack / Network / Server
	if action == "prepare" then
		if session.balance < def.price then
			hint(player, "Insufficient funds for " .. def.name .. " ($" .. tostring(def.price) .. ")")
			return
		end
		session.pendingPlacementItemId = itemId
		return
	elseif action == "cancel" then
		if session.pendingPlacementItemId == itemId then
			session.pendingPlacementItemId = nil
		end
		return
	elseif action == "place" then
		if typeof(cf) ~= "CFrame" or type(rotY) ~= "number" then
			return
		end
		-- Tolerant: a place without prepare is accepted (balance is still
		-- enforced server-side), keeping the ghost flow resilient.
		if session.pendingPlacementItemId ~= itemId then
			session.pendingPlacementItemId = itemId
		end

		local ok, reason, snapped = PlacementSystem.ValidatePlacement(session, itemId, cf :: CFrame)
		if not ok then
			hint(player, "Placement rejected: " .. reason)
			playSFX(player, "error")
			return
		end
		if session.balance < def.price then
			hint(player, "Insufficient funds for " .. def.name .. " ($" .. tostring(def.price) .. ")")
			session.pendingPlacementItemId = nil
			return
		end

		session.balance -= def.price
		session.pendingPlacementItemId = nil
		PlacementSystem.PlaceDevice(session, itemId, snapped, rotY :: number, nil)
		playSFX(player, "cash")
		return
	end
end

return PlacementSystem
