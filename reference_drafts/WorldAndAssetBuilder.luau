--!strict
--[[
	WorldAndAssetBuilder (ModuleScript, ServerScriptService/Bootstrap)
	Membangun dunia secara prosedural: lighting atmosferik, room lab per pemain,
	furniture (rack, workbench, NOC desk, dock, ISP uplink, beacon, AC), starter kit
	ter-mount di rack, dan Remotes folder. Zero-setup: place kosong pun jalan.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ModelFactory = require(ReplicatedStorage.Shared.ModelFactory)
local PlotConstants = require(ReplicatedStorage.Shared.PlotConstants)
local HardwareCatalog = require(ReplicatedStorage.Shared.HardwareCatalog)
local NetworkGraph = require(script.Parent.Parent.Core.NetworkGraph)

local WorldAndAssetBuilder = {}

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

local activeFans: { { part: BasePart, baseCF: CFrame } } = {}

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

function WorldAndAssetBuilder.EnsureRemotes(): Folder
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, def in ipairs(REMOTE_DEFS) do
		local inst = Instance.new(def.class)
		inst.Name = def.name
		inst.Parent = folder
	end
	folder.Parent = ReplicatedStorage
	return folder
end

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

function WorldAndAssetBuilder.EnsurePlotsFolder(): Folder
	local existing = Workspace:FindFirstChild("Plots")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Plots"
	folder.Parent = Workspace
	return folder
end

function WorldAndAssetBuilder.UpdateFans(dt: number)
	for _, fan in ipairs(activeFans) do
		local ok = pcall(function()
			fan.part.CFrame = fan.baseCF * CFrame.Angles(os.clock() * 4, 0, 0)
		end)
		if not ok then
			-- part hilang (plot dihancurkan); abaikan
		end
	end
	-- dt tidak dipakai langsung; rotasi berbasis os.clock agar kontinu
	_ = dt
end

local function clearFan(part: BasePart)
	for i, fan in ipairs(activeFans) do
		if fan.part == part then
			table.remove(activeFans, i)
			break
		end
	end
end

function WorldAndAssetBuilder.ClearFansOfRoot(root: Instance)
	for _, fan in ipairs(activeFans) do
		if fan.part:IsDescendantOf(root) then
			clearFan(fan.part)
		end
	end
end

--[[
	BuildFacility: bangun seluruh lab untuk satu session + starter kit.
	Return: tabel refs facility.
]]
function WorldAndAssetBuilder.BuildFacility(session: any): { [string]: any }
	local origin = PlotConstants.PLOT_POSITIONS[session.plotIndex]
	local floorTopY = PlotConstants.ROOM.floorTopY
	local halfX = PlotConstants.ROOM.halfX
	local halfZ = PlotConstants.ROOM.halfZ
	local H = PlotConstants.ROOM.height

	local root = Instance.new("Model")
	root.Name = "Plot" .. session.plotIndex

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

	-- ===== Geometri room =====
	local floor = newPart({
		name = "RoomFloor",
		size = Vector3.new(halfX * 2 + 2, floorTopY, halfZ * 2 + 2),
		cf = CFrame.new(0, floorTopY / 2, 0),
		color = PlotConstants.COLORS.floor,
		material = Enum.Material.Metal,
	})
	floor.Parent = facility

	local wallH = H - floorTopY
	local wallY = floorTopY + wallH / 2
	local walls: { { size: Vector3, pos: Vector3 } } = {
		{ size = Vector3.new(halfX * 2 + 2, wallH, 1), pos = Vector3.new(0, wallY, -halfZ - 0.5) },
		{ size = Vector3.new(1, wallH, halfZ * 2 + 2), pos = Vector3.new(-halfX - 0.5, wallY, 0) },
		{ size = Vector3.new(1, wallH, halfZ * 2 + 2), pos = Vector3.new(halfX + 0.5, wallY, 0) },
	}
	local doorW = PlotConstants.ROOM.doorWidth
	local segW = halfX - doorW / 2
	table.insert(walls, { size = Vector3.new(segW, wallH, 1), pos = Vector3.new(-(doorW / 2 + segW / 2), wallY, halfZ + 0.5) })
	table.insert(walls, { size = Vector3.new(segW, wallH, 1), pos = Vector3.new(doorW / 2 + segW / 2, wallY, halfZ + 0.5) })
	local lintelH = wallH - PlotConstants.ROOM.doorHeight
	table.insert(walls, { size = Vector3.new(doorW, lintelH, 1), pos = Vector3.new(0, floorTopY + PlotConstants.ROOM.doorHeight + lintelH / 2, halfZ + 0.5) })

	for i, w in ipairs(walls) do
		local wall = newPart({
			name = "Wall_" .. i,
			size = w.size,
			cf = CFrame.new(w.pos),
			color = PlotConstants.COLORS.wall,
			material = Enum.Material.Concrete,
		})
		wall.Parent = facility
	end

	local ceiling = newPart({
		name = "Ceiling",
		size = Vector3.new(halfX * 2 + 2, 0.5, halfZ * 2 + 2),
		cf = CFrame.new(0, H + floorTopY + 0.25, 0),
		color = PlotConstants.COLORS.trim,
		material = Enum.Material.Concrete,
	})
	ceiling.Parent = facility

	-- Panel lampu LED + SurfaceLight
	for _, x in ipairs({ -16, 0, 16 }) do
		for _, z in ipairs({ -10, 10 }) do
			local panel = newPart({
				name = "LightPanel",
				size = Vector3.new(8, 0.15, 2),
				cf = CFrame.new(x, H + floorTopY - 0.15, z),
				color = PlotConstants.COLORS.lightPanel,
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

	-- ===== Rack + starter kit =====
	local rackModel, rackSlots, pduPart = ModelFactory.BuildRack("rack_12u", "rack_main_1")
	rackModel:PivotTo(CFrame.new(origin + PlotConstants.RACK_POS + Vector3.new(0, floorTopY, 0)))
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

	-- ISP uplink (junction WAN di dinding belakang)
	local ispSpec = PlotConstants.STARTER.isp
	local ispModel, ispAttach, ispWanLed = ModelFactory.BuildISPUplink(ispSpec.id)
	ispModel:PivotTo(CFrame.new(origin + PlotConstants.ISP_POS + Vector3.new(0, floorTopY, 0)))
	ispModel.Parent = devicesFolder
	local ispNode = {
		id = ispSpec.id,
		name = ispSpec.name,
		deviceType = "Router",
		itemId = "isp_uplink",
		rackId = nil,
		uSlot = nil,
		uSize = 0,
		ip = nil,
		gateway = nil,
		subnetMask = "255.255.255.0",
		defaultVlan = 1,
		ports = {
			wan1 = {
				portId = "wan1",
				portType = "WAN",
				connectedToDeviceId = nil,
				connectedToPortId = nil,
				cableColor = nil,
				linkUp = false,
				vlanId = 1,
				trafficLoadMbps = 0,
			},
		},
		specs = { cpu = 0, ram = 0, disk = 0, powerWatts = 0 },
		vms = {},
		blockedIps = {},
		osInstalled = nil,
		isPowered = true,
		temperatureC = 30,
		hasDegradedDrive = false,
		degradedBayIndex = nil,
		isUnderDDoS = false,
		ddosAttackerIp = nil,
		freeform = false,
		posX = nil,
		posZ = nil,
		rotY = nil,
	}
	NetworkGraph.RegisterDevice(session, ispNode, ispModel)

	-- Starter ter-mount: router (U12), switch (U10), bare-metal (U8)
	local function mountStarter(spec: any)
		local itemId = spec.itemId :: string
		local model, ports, consoleAttach, led, smoke = ModelFactory.BuildDeviceModel(itemId, spec.id)
		local node = NetworkGraph.DefaultNode(spec.id, spec.name, itemId)
		node.rackId = "rack_main_1"
		node.uSlot = spec.uSlot
		node.isPowered = true
		local rack = session.racks["rack_main_1"]
		for u = (spec.uSlot :: number) - node.uSize + 1, spec.uSlot do
			rack.occupiedSlots[u] = spec.id
		end
		rack.totalPowerWatts += node.specs.powerWatts
		if itemId == "router_edge" then
			node.ip = PlotConstants.STARTER.router.ip
			node.gateway = PlotConstants.STARTER.router.gateway
			node.subnetMask = PlotConstants.STARTER.router.subnetMask
		end
		model:PivotTo(CFrame.new((rackSlots[spec.uSlot] :: Attachment).WorldCFrame * CFrame.new(0, 0, 0.95)))
		model.Parent = devicesFolder
		NetworkGraph.RegisterDevice(session, node, model)
		-- prompt power tidak dipakai untuk device rack-mounted (dikontrol PDU)
		local p = model:FindFirstChild("ConsolePort", true)
		if p and p:IsA("BasePart") then
			local pr = p:FindFirstChildOfClass("ProximityPrompt")
			if pr then
				pr.ObjectText = spec.name .. " (U" .. tostring(spec.uSlot) .. ")"
			end
		end
		_ = ports
		_ = consoleAttach
		_ = led
		_ = smoke
	end

	mountStarter(PlotConstants.STARTER.router)
	mountStarter(PlotConstants.STARTER.switch)
	mountStarter(PlotConstants.STARTER.baremetal)

	-- WAN router -> ISP (satu-satunya kabel awal)
	NetworkGraph.ConnectPorts(session, "isp_router_1", "wan1", "isp_uplink", "wan1", "WAN_Yellow")

	-- ===== Workbench =====
	local wbModel, benchSnaps, benchSwitch, benchLed = ModelFactory.BuildWorkbench()
	wbModel:PivotTo(CFrame.new(origin + PlotConstants.WORKBENCH_POS + Vector3.new(0, floorTopY, 0)))
	wbModel.Parent = facility

	-- ===== NOC Desk =====
	local nocModel, monitors = ModelFactory.BuildNOCDesk()
	nocModel:PivotTo(CFrame.new(origin + PlotConstants.NOCDESK_POS + Vector3.new(0, floorTopY, 0)))
	nocModel.Parent = facility

	-- ===== Loading Dock =====
	local dockModel, crateCF = ModelFactory.BuildDockPad()
	dockModel:PivotTo(CFrame.new(origin + PlotConstants.DOCK_POS + Vector3.new(0, floorTopY, 0)))
	dockModel.Parent = facility

	-- ===== Alarm beacon =====
	local beaconModel, beaconLens, beaconLight = ModelFactory.BuildBeacon()
	beaconModel:PivotTo(CFrame.new(origin + PlotConstants.BEACON_OFFSET + Vector3.new(0, floorTopY, 0)))
	beaconModel.Parent = facility

	-- ===== AC unit =====
	local acModel, acFan = ModelFactory.BuildACUnit()
	acModel:PivotTo(CFrame.new(origin + PlotConstants.AC_OFFSET + Vector3.new(0, floorTopY, 0)))
	acModel.Parent = facility
	table.insert(activeFans, { part = acFan, baseCF = acFan.CFrame })

	-- ===== Sign lab di atas pintu =====
	local signPart = newPart({
		name = "SignAnchor",
		size = Vector3.new(0.1, 0.1, 0.1),
		cf = CFrame.new(0, floorTopY + PlotConstants.ROOM.doorHeight + 1.6, halfZ + 0.2),
		transparency = 1,
		canCollide = false,
	})
	signPart.Parent = facility
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.new(0, 320, 0, 56)
	bb.StudsOffset = Vector3.new(0, 0, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 90
	bb.Parent = signPart
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.GothamBold
	tl.TextScaled = true
	tl.TextColor3 = Color3.fromRGB(120, 220, 255)
	tl.TextStrokeTransparency = 0.5
	tl.Text = "SERVER LAB #" .. tostring(session.plotIndex) .. " | " .. session.player.DisplayName
	tl.Parent = bb

	local spawnCF = CFrame.new(origin + Vector3.new(0, 4, halfZ + 8))

	session.facility = {
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
		nocMonitors = monitors,
		dockCF = origin + PlotConstants.DOCK_POS + Vector3.new(0, floorTopY, 0) + crateCF.Position,
		beaconLens = beaconLens,
		beaconLight = beaconLight,
		fan = acFan,
		spawnCF = spawnCF,
		ispWanLed = ispWanLed,
	}

	root.Parent = WorldAndAssetBuilder.EnsurePlotsFolder()
	return session.facility
end

function WorldAndAssetBuilder.DestroyFacility(session: any)
	local facility = session.facility
	if facility and facility.root then
		WorldAndAssetBuilder.ClearFansOfRoot(facility.root)
		facility.root:Destroy()
	end
end

function WorldAndAssetBuilder.BuildDeviceModelFor(itemId: string, deviceId: string): (Model, { [string]: any }, Attachment, Part, ParticleEmitter)
	return ModelFactory.BuildDeviceModel(itemId, deviceId)
end

function WorldAndAssetBuilder.GetCatalog()
	return HardwareCatalog
end

return WorldAndAssetBuilder
