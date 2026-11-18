--!strict
--[[
	PlacementSystem (ModuleScript, ServerScriptService/Physical)
	Beli hardware + placement freeform (toolbar + ghost + klik lantai).
	Validasi server-authoritative: bounds lab, zona furniture, tabrakan device,
	snap grid 2 studs. RestoreDevice dipakai DataPersistenceManager.
]]

local PlacementSystem = {}

local sessions = nil
local graph = nil
local catalog = nil
local constants = nil
local modelFactory = nil
local workbench = nil
local cabling = nil
local remotesFolder = nil

function PlacementSystem.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	catalog = deps.catalog
	constants = deps.constants
	modelFactory = deps.modelFactory
	workbench = deps.workbench
	cabling = deps.cabling
	remotesFolder = deps.remotesFolder

	local purchaseRemote = remotesFolder:FindFirstChild("PurchaseHardwareRemote")
	if purchaseRemote then
		purchaseRemote.OnServerEvent:Connect(function(player, itemId, action, cf, rotY)
			PlacementSystem.OnPurchase(player, itemId, action, cf, rotY)
		end)
	end
end

local function floorTopY(): number
	return (constants :: any).ROOM.floorTopY
end

function PlacementSystem.ValidatePlacement(session: any, itemId: string, cf: CFrame): (boolean, string, CFrame)
	local origin = (constants :: any).PLOT_POSITIONS[session.plotIndex]
	local halfX, halfZ = modelFactory.ComputeFootprint(itemId)
	local rel = cf.Position - origin
	local grid = (constants :: any).SNAP_GRID
	local sx = math.floor(rel.X / grid + 0.5) * grid
	local sz = math.floor(rel.Z / grid + 0.5) * grid
	local bounds = (constants :: any).PLACEMENT_BOUNDS
	if sx < bounds.minX or sx > bounds.maxX or sz < bounds.minZ or sz > bounds.maxZ then
		return false, "Di luar area lab", cf
	end
	local relSnap = Vector3.new(sx, 0, sz)
	for _, zone in ipairs((constants :: any).FURNITURE_ZONES) do
		local d = (Vector3.new(zone.position.X, 0, zone.position.Z) - relSnap).Magnitude
		local margin = math.max(halfX, halfZ) + 1
		if d < zone.radius + margin - 1 then
			return false, "Menabrak " .. zone.name, cf
		end
	end
	for id, node in pairs(session.devices) do
		if node.freeform and node.posX ~= nil then
			local otherHalfX, otherHalfZ = modelFactory.ComputeFootprint(node.itemId)
			local d = math.sqrt((node.posX - sx) ^ 2 + (node.posZ - sz) ^ 2)
			if d < (halfX + otherHalfX) + (halfZ + otherHalfZ) + 0.5 then
				return false, "Menabrak " .. node.name, cf
			end
		end
	end
	local snapped = CFrame.new(origin + Vector3.new(sx, floorTopY(), sz))
	return true, "", snapped
end

local function prefixFor(def: any): string
	if def.category == "Rack" then
		return "rack"
	elseif def.category == "Server" then
		return "bm"
	elseif (def.specs.wanPorts or 0) > 0 then
		return "rt"
	end
	return "sw"
end

--[[
	PlaceDevice: build model + register + auto-cable + hook interaksi.
]]
function PlacementSystem.PlaceDevice(session: any, itemId: string, snappedCF: CFrame, rotY: number, config: { [string]: any }?): string
	local def = catalog.Get(itemId)
	assert(def ~= nil, "Item tidak ada: " .. itemId)
	local defv = def :: any

	if defv.category == "Rack" then
		local SessionManager = require(script.Parent.Parent.Core.SessionManager)
		local rackId = SessionManager.NextDeviceId(session, "rack")
		local model, _slots, pduPart = modelFactory.BuildRack(itemId, rackId)
		model:PivotTo(snappedCF * CFrame.Angles(0, rotY, 0))
		model.Parent = session.facility.devices
		session.racks[rackId] = {
			rackId = rackId,
			name = defv.name,
			itemId = itemId,
			maxU = defv.specs.maxU,
			occupiedSlots = {},
			totalPowerWatts = 0,
			maxPowerWatts = defv.specs.maxPowerWatts,
			pduPowered = false,
		}
		session.rackModels[rackId] = model
		session.facility.pduParts = session.facility.pduParts or {}
		session.facility.pduParts[rackId] = pduPart
		cabling.HookFacility(session)
		return rackId
	end

	local SessionManager = require(script.Parent.Parent.Core.SessionManager)
	local deviceId = SessionManager.NextDeviceId(session, prefixFor(defv))
	local model, ports, consoleAttach, led, smoke = modelFactory.BuildDeviceModel(itemId, deviceId)
	model:PivotTo(snappedCF * CFrame.Angles(0, rotY, 0))
	model.Parent = session.facility.devices

	local node = graph.DefaultNode(deviceId, defv.name, itemId)
	node.freeform = true
	node.posX = snappedCF.Position.X
	node.posZ = snappedCF.Position.Z
	node.rotY = rotY

	if config then
		node.ip = config.ip
		node.gateway = config.gateway
		node.subnetMask = config.subnetMask or "255.255.255.0"
		node.osInstalled = config.osInstalled
		node.isPowered = if config.isPowered ~= nil then config.isPowered else false
		if config.vms then
			for _, vm in ipairs(config.vms) do
				node.vms[vm.name] = vm
			end
		end
	end

	graph.RegisterDevice(session, node, model)
	if not session.loadedFromSave and defv.category ~= "Rack" then
		graph.AutoCable(session, deviceId)
	end
	cabling.HookDevice(session, deviceId)

	_ = ports
	_ = consoleAttach
	_ = led
	_ = smoke
	return deviceId
end

function PlacementSystem.OnPurchase(player: Player, itemId: any, action: any, cf: any, rotY: any)
	local session = sessions.GetSession(player)
	if session == nil then
		return
	end
	if type(itemId) ~= "string" or type(action) ~= "string" then
		return
	end
	local def = catalog.Get(itemId)
	if def == nil then
		return
	end
	local defv = def :: any

	if defv.category == "Cable" then
		local openRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
		if openRemote then
			openRemote:FireClient(player, { action = "hint", message = "Cable spools & manual cabling hadir di Fase 2. Fase 1: kabel otomatis + dua-klik port." })
		end
		return
	end

	if defv.category == "Component" then
		workbench.TryInstall(player, session, itemId)
		return
	end

	-- Placeable: Rack / Network / Server
	if action == "prepare" then
		if session.balance < defv.price then
			local openRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
			if openRemote then
				openRemote:FireClient(player, { action = "hint", message = "Uang belum cukup untuk " .. defv.name })
			end
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
		if session.pendingPlacementItemId ~= itemId then
			session.pendingPlacementItemId = itemId
		end
		local ok, reason, snapped = PlacementSystem.ValidatePlacement(session, itemId, cf)
		if not ok then
			local openRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
			if openRemote then
				openRemote:FireClient(player, { action = "hint", message = "Placement ditolak: " .. reason })
			end
			return
		end
		if session.balance < defv.price then
			local openRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
			if openRemote then
				openRemote:FireClient(player, { action = "hint", message = "Uang belum cukup untuk " .. defv.name })
			end
			session.pendingPlacementItemId = nil
			return
		end
		session.balance -= defv.price
		session.pendingPlacementItemId = nil
		PlacementSystem.PlaceDevice(session, itemId, snapped, rotY, nil)
		local sfx = remotesFolder:FindFirstChild("PlaySFXRemote")
		if sfx then
			sfx:FireClient(player, "cash")
		end
		return
	end
end

return PlacementSystem
