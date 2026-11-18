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
	  "cancel" for placeables, "buy" for components (workbench), cable spools
	  answered with a Fase 2 hint
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
		return false, "Item tidak dikenal", cf
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
		return false, "Di luar area lab", cf
	end

	local relSnap = Vector3.new(sx, 0, sz)
	local margin = math.max(halfX, halfZ)
	for _, zone in ipairs(Constants.FURNITURE_ZONES) do
		local zoneRel = Vector3.new(zone.position.X, 0, zone.position.Z)
		local dist = (zoneRel - relSnap).Magnitude
		if dist < zone.radius + margin then
			return false, "Menabrak area " .. zone.name, cf
		end
	end

	for _, node in pairs(session.devices) do
		if node.freeform == true and node.posX ~= nil and node.posZ ~= nil then
			local otherHalfX, otherHalfZ = ModelFactory.ComputeFootprint(node.itemId)
			local otherRel = Vector3.new(node.posX - origin.X, 0, node.posZ - origin.Z)
			local dist = (otherRel - relSnap).Magnitude
			if dist < (halfX + otherHalfX) + (halfZ + otherHalfZ) + 0.5 then
				return false, "Menabrak " .. node.name, cf
			end
		end
	end

	local snapped = CFrame.new(origin + Vector3.new(sx, floorY, sz))
	return true, "", snapped
end

---------------------------------------------------------------------
-- Placement
---------------------------------------------------------------------

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
		local rackId = SessionManager.NextDeviceId(session, "rack")
		local model, _slots, pduPart = ModelFactory.BuildRack(itemId, rackId)
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

		session.facility.pduParts = session.facility.pduParts or {}
		session.facility.pduParts[rackId] = pduPart
		Cabling.HookFacility(session) -- wires the new PDU (guard attr skips old ones)
		return rackId
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
		hint(player, "Cable spools hadir di Fase 2. Fase 1 memakai auto-cable + klik dua port.")
		return
	end

	if def.category == "Component" then
		Workbench.TryInstall(player, session, itemId)
		return
	end

	-- Placeable categories: Rack / Network / Server
	if action == "prepare" then
		if session.balance < def.price then
			hint(player, "Uang belum cukup untuk " .. def.name .. " ($" .. tostring(def.price) .. ")")
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
			hint(player, "Placement ditolak: " .. reason)
			playSFX(player, "error")
			return
		end
		if session.balance < def.price then
			hint(player, "Uang belum cukup untuk " .. def.name .. " ($" .. tostring(def.price) .. ")")
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
