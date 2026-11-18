--!strict
--[[
	WorldAndAssetBuilder (ModuleScript, ServerScriptService/Bootstrap)
	Builds the world procedurally for every player lab plot:
	- ReplicatedStorage.Remotes with EXACTLY the 10 contract remotes (idempotent)
	- Atmospheric Lighting (Future + bloom + color correction)
	- Per-plot room geometry: floor slab, walls with a front (+Z) door
	  opening, ceiling, 6 ceiling LED panels with SurfaceLight
	- Furniture: 12U rack "rack_main_1" (PDU powered), ISP uplink node,
	  starter kit mounted at U12/U10/U8 (ONLY the router is wired to the ISP;
	  switch and bare-metal stay unwired - wiring them is the first objective),
	  assembly workbench, NOC desk, loading dock, alarm beacon, AC unit
	  (fan registered for Heartbeat-driven rotation)
	- Door sign billboard ("SERVER LAB #n | <DisplayName>") and spawn CF refs
	All geometry hangs under workspace.Plots.Plot<n> so SessionManager can
	tear a whole lab down with a single root:Destroy(). Every part is anchored.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ModelFactory = require(ReplicatedStorage.Shared.ModelFactory)
local PlotConstants = require(ReplicatedStorage.Shared.PlotConstants)
local HardwareCatalog = require(ReplicatedStorage.Shared.HardwareCatalog)
local NetworkGraph = require(script.Parent.Parent.Core.NetworkGraph)

local WorldAndAssetBuilder = {}

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------

-- CONTRACT section 3: the exact 10 remotes created by EnsureRemotes.
local REMOTE_DEFS = {
	{ name = "ExecuteCommand", class = "RemoteFunction" },
	{ name = "TerminalPushOutput", class = "RemoteEvent" },
	{ name = "OpenTerminalEvent", class = "RemoteEvent" },
	{ name = "CableActionRemote", class = "RemoteEvent" },
	{ name = "WorkbenchRemote", class = "RemoteEvent" },
	{ name = "ContractActionRemote", class = "RemoteEvent" },
	{ name = "PurchaseHardwareRemote", class = "RemoteEvent" },
	{ name = "StateSyncRemote", class = "RemoteEvent" },
	{ name = "PlaySFXRemote", class = "RemoteEvent" },
	{ name = "ResetDataRemote", class = "RemoteEvent" },
}

--[[
	Creates ReplicatedStorage.Remotes with exactly the 10 contract remotes.
	Idempotent: an existing folder is reused and any missing remote is added,
	so calling it twice never duplicates entries.
]]
function WorldAndAssetBuilder.EnsureRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder == nil or not folder:IsA("Folder") then
		local created = Instance.new("Folder")
		created.Name = "Remotes"
		created.Parent = ReplicatedStorage
		folder = created
	end
	local guaranteed = folder :: Folder
	for _, def in ipairs(REMOTE_DEFS) do
		if guaranteed:FindFirstChild(def.name) == nil then
			local inst = Instance.new(def.class)
			inst.Name = def.name
			inst.Parent = guaranteed
		end
	end
	return guaranteed
end

---------------------------------------------------------------------
-- Lighting
---------------------------------------------------------------------

-- Dark data-center atmosphere: Future lighting for crisp neon LEDs, subtle
-- bloom for glow, mild color correction for contrast.
function WorldAndAssetBuilder.SetupLighting()
	Lighting.Technology = Enum.Technology.Future
	Lighting.Brightness = 1.5
	Lighting.Ambient = Color3.fromRGB(25, 30, 40)
	Lighting.OutdoorAmbient = Color3.fromRGB(20, 25, 35)
	Lighting.ClockTime = 14
	Lighting.GlobalShadows = true

	if Lighting:FindFirstChild("DCBloom") == nil then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "DCBloom"
		bloom.Intensity = 0.4
		bloom.Size = 16
		bloom.Threshold = 1.1
		bloom.Parent = Lighting
	end
	if Lighting:FindFirstChild("DCColor") == nil then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "DCColor"
		cc.Brightness = 0.02
		cc.Contrast = 0.08
		cc.Saturation = 0.05
		cc.Parent = Lighting
	end
end

---------------------------------------------------------------------
-- Plots folder & AC fans
---------------------------------------------------------------------

function WorldAndAssetBuilder.EnsurePlotsFolder(): Folder
	local existing = Workspace:FindFirstChild("Plots")
	if existing ~= nil and existing:IsA("Folder") then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "Plots"
	folder.Parent = Workspace
	return folder
end

-- Registered AC fans (one entry per built facility, cleared on teardown).
type FanEntry = {
	part: BasePart,
	baseCF: CFrame,
	angle: number,
}

local activeFans: { FanEntry } = {}

-- Called from MainServer on every Heartbeat. Rotates each registered AC fan
-- around its disc axis; entries whose part vanished (destroyed plot) are pruned.
function WorldAndAssetBuilder.UpdateFans(dt: number)
	local step = math.clamp(dt, 0, 0.5) * 6 -- roughly one revolution per second
	for i = #activeFans, 1, -1 do
		local fan = activeFans[i]
		if fan.part == nil or fan.part.Parent == nil then
			table.remove(activeFans, i)
			continue
		end
		fan.angle += step
		fan.part.CFrame = fan.baseCF * CFrame.Angles(fan.angle, 0, 0)
	end
end

-- Drops every fan registration whose fan part lives under `root`
-- (called when a facility is destroyed / rebuilt).
function WorldAndAssetBuilder.ClearFansOfRoot(root: Instance)
	for i = #activeFans, 1, -1 do
		local fan = activeFans[i]
		if fan.part == nil or fan.part:IsDescendantOf(root) then
			table.remove(activeFans, i)
		end
	end
end

---------------------------------------------------------------------
-- Part helper
---------------------------------------------------------------------

local function newPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size or Vector3.new(1, 1, 1)
	p.CFrame = props.cf or CFrame.new(0, 0, 0)
	p.Color = props.color or Color3.fromRGB(120, 120, 125)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.canCollide ~= nil then props.canCollide else true
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- Fresh WAN port table for the ISP uplink node (catalog has no isp_uplink
-- item, so its port layout is built literally here).
local function makeWanPort(): any
	return {
		portId = "wan1",
		portType = "WAN",
		connectedToDeviceId = nil,
		connectedToPortId = nil,
		cableColor = nil,
		linkUp = false,
		vlanId = 1,
		trafficLoadMbps = 0,
	}
end

---------------------------------------------------------------------
-- Facility
---------------------------------------------------------------------

--[[
	BuildFacility(session): constructs the whole lab for one session and the
	starter kit, returning the facility refs table (CONTRACT section 5 keys).
]]
function WorldAndAssetBuilder.BuildFacility(session: any): { [string]: any }
	local origin = PlotConstants.PLOT_POSITIONS[session.plotIndex]
	local floorTopY = PlotConstants.ROOM.floorTopY
	local halfX = PlotConstants.ROOM.halfX
	local halfZ = PlotConstants.ROOM.halfZ
	local roomH = PlotConstants.ROOM.height
	local colors = PlotConstants.COLORS

	-- helper: CFrame relative to this plot's origin
	local function plotCF(x: number, y: number, z: number): CFrame
		return CFrame.new(origin + Vector3.new(x, y, z))
	end

	local root = Instance.new("Model")
	root.Name = "Plot" .. tostring(session.plotIndex)

	local facility = Instance.new("Folder")
	facility.Name = "Facility"
	facility.Parent = root
	local devicesFolder = Instance.new("Folder")
	devicesFolder.Name = "Devices"
	devicesFolder.Parent = root
	local cablesFolder = Instance.new("Folder")
	cablesFolder.Name = "Cables"
	cablesFolder.Parent = root
	local cratesFolder = Instance.new("Folder")
	cratesFolder.Name = "Crates"
	cratesFolder.Parent = root

	-- ===== Room geometry =====
	-- Floor slab 66 x 0.5 x 66, top surface at y = floorTopY (0.5).
	local floor = newPart({
		name = "RoomFloor",
		size = Vector3.new(halfX * 2 + 2, floorTopY, halfZ * 2 + 2),
		cf = plotCF(0, floorTopY / 2, 0),
		color = colors.floor,
		material = Enum.Material.Metal,
	})
	floor.Parent = facility

	-- Walls, thickness 1, height 24 (y = 0 .. 24). The front (+Z) wall has a
	-- door opening (width 14, height 12) -> two segments + lintel.
	local wallH = roomH
	local wallY = wallH / 2
	local doorW = PlotConstants.ROOM.doorWidth
	local doorH = PlotConstants.ROOM.doorHeight
	local segW = (halfX * 2 + 2 - doorW) / 2 -- 26 studs per side segment
	local wallDefs: { { size: Vector3, x: number, y: number, z: number } } = {
		{ size = Vector3.new(halfX * 2 + 2, wallH, 1), x = 0, y = wallY, z = -halfZ - 0.5 }, -- back
		{ size = Vector3.new(1, wallH, halfZ * 2 + 2), x = -halfX - 0.5, y = wallY, z = 0 }, -- left
		{ size = Vector3.new(1, wallH, halfZ * 2 + 2), x = halfX + 0.5, y = wallY, z = 0 }, -- right
		{ size = Vector3.new(segW, wallH, 1), x = -(doorW / 2 + segW / 2), y = wallY, z = halfZ + 0.5 }, -- front left
		{ size = Vector3.new(segW, wallH, 1), x = doorW / 2 + segW / 2, y = wallY, z = halfZ + 0.5 }, -- front right
		{ size = Vector3.new(doorW, wallH - doorH, 1), x = 0, y = doorH + (wallH - doorH) / 2, z = halfZ + 0.5 }, -- lintel
	}
	for i, def in ipairs(wallDefs) do
		local wall = newPart({
			name = "Wall_" .. tostring(i),
			size = def.size,
			cf = plotCF(def.x, def.y, def.z),
			color = colors.wall,
			material = Enum.Material.Concrete,
		})
		wall.Parent = facility
	end

	-- Ceiling slab above the walls.
	local ceiling = newPart({
		name = "Ceiling",
		size = Vector3.new(halfX * 2 + 2, 0.5, halfZ * 2 + 2),
		cf = plotCF(0, roomH + 0.25, 0),
		color = colors.trim,
		material = Enum.Material.Concrete,
	})
	ceiling.Parent = facility

	-- 6 ceiling LED panels (8 x 0.15 x 2) with downward SurfaceLight.
	for _, lx in ipairs({ -16, 0, 16 }) do
		for _, lz in ipairs({ -10, 10 }) do
			local panel = newPart({
				name = "LightPanel",
				size = Vector3.new(8, 0.15, 2),
				cf = plotCF(lx, roomH - 0.08, lz),
				color = colors.lightPanel,
				material = Enum.Material.Neon,
				canCollide = false,
			})
			panel.Parent = facility
			local light = Instance.new("SurfaceLight")
			light.Face = Enum.NormalId.Bottom
			light.Range = 30
			light.Brightness = 1.1
			light.Angle = 140
			light.Parent = panel
		end
	end

	-- ===== Main rack (PDU powered) =====
	local rackModel, rackSlots, pduPart = ModelFactory.BuildRack("rack_12u", "rack_main_1")
	rackModel:PivotTo(plotCF(PlotConstants.RACK_POS.X, floorTopY, PlotConstants.RACK_POS.Z))
	rackModel.Parent = facility

	session.racks["rack_main_1"] = {
		rackId = "rack_main_1",
		name = "Main Rack 12U",
		itemId = "rack_12u",
		maxU = 12,
		occupiedSlots = {},
		totalPowerWatts = 0,
		maxPowerWatts = 3000,
		pduPowered = true,
	}
	session.rackModels["rack_main_1"] = rackModel

	-- ===== ISP uplink node (WAN junction, always powered) =====
	local ispSpec = PlotConstants.STARTER.isp
	local ispModel, _ispAttach, ispWanLed = ModelFactory.BuildISPUplink(ispSpec.id)
	ispModel:PivotTo(plotCF(PlotConstants.ISP_POS.X, floorTopY, PlotConstants.ISP_POS.Z))
	ispModel.Parent = devicesFolder

	local ispNode = NetworkGraph.DefaultNode(ispSpec.id, ispSpec.name, "isp_uplink")
	ispNode.deviceType = "Router"
	ispNode.uSize = 0
	ispNode.isPowered = true
	ispNode.ports = { wan1 = makeWanPort() }
	NetworkGraph.RegisterDevice(session, ispNode, ispModel)

	-- ===== Starter devices mounted in the rack (U12 / U10 / U8) =====
	local function mountStarter(spec: any)
		local itemId = spec.itemId :: string
		local uSlot = spec.uSlot :: number
		local model, _ports, _consoleAttach, _led, _smoke = ModelFactory.BuildDeviceModel(itemId, spec.id)
		local node = NetworkGraph.DefaultNode(spec.id, spec.name, itemId)
		node.rackId = "rack_main_1"
		node.uSlot = uSlot
		node.isPowered = true

		local rack = session.racks["rack_main_1"]
		for u = uSlot - node.uSize + 1, uSlot do
			rack.occupiedSlots[u] = spec.id
		end
		rack.totalPowerWatts += node.specs.powerWatts

		if itemId == "router_edge" then
			node.ip = PlotConstants.STARTER.router.ip
			node.gateway = PlotConstants.STARTER.router.gateway
			node.subnetMask = PlotConstants.STARTER.router.subnetMask
		end

		local slot = rackSlots[uSlot]
		if slot ~= nil then
			model:PivotTo((slot :: Attachment).WorldCFrame * CFrame.new(0, 0, 0.95))
		end
		model.Parent = devicesFolder
		NetworkGraph.RegisterDevice(session, node, model)

		-- Rack-mounted devices are powered by the PDU (no freeform power prompt).
		local consolePart = model:FindFirstChild("ConsolePort", true)
		if consolePart ~= nil and consolePart:IsA("BasePart") then
			local prompt = consolePart:FindFirstChildOfClass("ProximityPrompt")
			if prompt ~= nil then
				prompt.ObjectText = spec.name .. " (U" .. tostring(uSlot) .. ")"
			end
		end
	end

	mountStarter(PlotConstants.STARTER.router)
	mountStarter(PlotConstants.STARTER.switch)
	mountStarter(PlotConstants.STARTER.baremetal)

	-- Single initial cable: router WAN <-> ISP uplink. The starter switch and
	-- bare-metal stay UNWIRED - wiring them is the player's first objective.
	NetworkGraph.ConnectPorts(session, "isp_router_1", "wan1", "isp_uplink", "wan1", "WAN_Yellow")

	-- ===== Assembly workbench =====
	local wbModel, benchSnaps, benchSwitch, benchLed = ModelFactory.BuildWorkbench()
	wbModel:PivotTo(plotCF(PlotConstants.WORKBENCH_POS.X, floorTopY, PlotConstants.WORKBENCH_POS.Z))
	wbModel.Parent = facility

	-- ===== NOC desk (3 monitors with SurfaceGui.Root for the client) =====
	local nocModel, nocMonitors = ModelFactory.BuildNOCDesk()
	nocModel:PivotTo(plotCF(PlotConstants.NOCDESK_POS.X, floorTopY, PlotConstants.NOCDESK_POS.Z))
	nocModel.Parent = facility

	-- ===== Loading dock (crate spawn pad) =====
	local dockModel, crateLocalCF = ModelFactory.BuildDockPad()
	local dockPivot = plotCF(PlotConstants.DOCK_POS.X, floorTopY, PlotConstants.DOCK_POS.Z)
	dockModel:PivotTo(dockPivot)
	dockModel.Parent = facility
	local dockCF = dockPivot * crateLocalCF

	-- ===== Alarm beacon (visual; alarm logic arrives in Fase 3) =====
	local beaconModel, beaconLens, beaconLight = ModelFactory.BuildBeacon()
	beaconModel:PivotTo(plotCF(PlotConstants.BEACON_OFFSET.X, floorTopY + PlotConstants.BEACON_OFFSET.Y, PlotConstants.BEACON_OFFSET.Z))
	beaconModel.Parent = facility

	-- ===== AC unit (fan registered for Heartbeat rotation) =====
	local acModel, acFan = ModelFactory.BuildACUnit()
	acModel:PivotTo(plotCF(PlotConstants.AC_OFFSET.X, floorTopY + PlotConstants.AC_OFFSET.Y, PlotConstants.AC_OFFSET.Z))
	acModel.Parent = facility
	table.insert(activeFans, { part = acFan, baseCF = acFan.CFrame, angle = 0 })

	-- ===== Lab sign billboard above the front door =====
	local signAnchor = newPart({
		name = "SignAnchor",
		size = Vector3.new(0.2, 0.2, 0.2),
		cf = plotCF(0, floorTopY + doorH + 2.2, halfZ + 0.9),
		transparency = 1,
		canCollide = false,
	})
	signAnchor.Parent = facility
	local signGui = Instance.new("BillboardGui")
	signGui.Name = "LabSign"
	signGui.Size = UDim2.new(0, 360, 0, 56)
	signGui.StudsOffset = Vector3.new(0, 0, 0)
	signGui.AlwaysOnTop = true
	signGui.MaxDistance = 120
	signGui.Parent = signAnchor
	local signLabel = Instance.new("TextLabel")
	signLabel.Size = UDim2.new(1, 0, 1, 0)
	signLabel.BackgroundTransparency = 1
	signLabel.Font = Enum.Font.GothamBold
	signLabel.TextScaled = true
	signLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
	signLabel.TextStrokeTransparency = 0.5
	signLabel.Text = "SERVER LAB #" .. tostring(session.plotIndex) .. " | " .. session.player.DisplayName
	signLabel.Parent = signGui

	-- ===== Facility refs (CONTRACT section 5, exact keys) =====
	local spawnCF = CFrame.new(origin + Vector3.new(0, 4, halfZ + 8))

	local refs: { [string]: any } = {
		root = root,
		facility = facility,
		devices = devicesFolder,
		cables = cablesFolder,
		crates = cratesFolder,
		rackModel = rackModel,
		rackSlots = rackSlots,
		pduPart = pduPart,
		pduParts = { rack_main_1 = pduPart },
		workbenchModel = wbModel,
		benchSnaps = benchSnaps,
		benchSwitch = benchSwitch,
		benchLed = benchLed,
		nocMonitors = nocMonitors,
		dockCF = dockCF,
		beaconLens = beaconLens,
		beaconLight = beaconLight,
		fan = acFan,
		spawnCF = spawnCF,
		ispWanLed = ispWanLed,
	}

	session.facility = refs
	root.Parent = WorldAndAssetBuilder.EnsurePlotsFolder()
	return refs
end

-- Tears the lab down: stops fan registrations and destroys the whole plot.
-- Safe to call on a half-built session or twice in a row.
function WorldAndAssetBuilder.DestroyFacility(session: any)
	local facility = session.facility
	if type(facility) == "table" and facility.root ~= nil then
		WorldAndAssetBuilder.ClearFansOfRoot(facility.root)
		facility.root:Destroy()
	end
end

-- Shared catalog module (same instance the client requires).
function WorldAndAssetBuilder.GetCatalog()
	return HardwareCatalog
end

return WorldAndAssetBuilder
