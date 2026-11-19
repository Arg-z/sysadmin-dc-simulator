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
	- Outdoor environment: lawn, front parking lot with stall lines, sidewalks,
	  trees, street lamps, "ARGA DATACENTER" site sign, condensers, back fence
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
	{ name = "SaveGameRemote", class = "RemoteFunction" },
}

--[[
	Creates ReplicatedStorage.Remotes with the contract remotes.
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

-- Bright modern data-center lighting: Future lighting (set in .rbxlx), high
-- indoor ambient + environment diffuse so metallic/plastic surfaces stay crisp
-- and vibrant rather than dark, plus subtle bloom and clean atmosphere.
function WorldAndAssetBuilder.SetupLighting()
	-- Lighting.Technology is non-scriptable at runtime (configured in .rbxlx XML).
	pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	Lighting.Brightness = 1.25
	Lighting.Ambient = Color3.fromRGB(72, 80, 96)
	Lighting.OutdoorAmbient = Color3.fromRGB(96, 106, 126)
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.8
	Lighting.ClockTime = 11.5
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25

	if Lighting:FindFirstChild("DCBloom") == nil then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "DCBloom"
		bloom.Intensity = 0.3
		bloom.Size = 18
		bloom.Threshold = 1.1
		bloom.Parent = Lighting
	end
	if Lighting:FindFirstChild("DCColor") == nil then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "DCColor"
		cc.Brightness = 0.0
		cc.Contrast = 0.12
		cc.Saturation = -0.02
		cc.Parent = Lighting
	end
	if Lighting:FindFirstChild("DCAtmosphere") == nil then
		local atmo = Instance.new("Atmosphere")
		atmo.Name = "DCAtmosphere"
		atmo.Density = 0.1
		atmo.Offset = 0.1
		atmo.Color = Color3.fromRGB(205, 222, 242)
		atmo.Decay = Color3.fromRGB(170, 195, 225)
		atmo.Glare = 0.05
		atmo.Haze = 0.35
		atmo.Parent = Lighting
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

-- Albedo skins environment dari pipeline ArtCraft VM (tileable 1024px).
local TEX_FLOOR = "rbxassetid://89253845579252"
local TEX_WALL = "rbxassetid://107945148969183"
local TEX_ASPHALT = "rbxassetid://127856414140892"
local TEX_GRASS = "rbxassetid://112395333726131"

-- Texture di satu face Top dengan tiling per studs.
local function applyTopTexture(part: BasePart, asset: string, studs: number)
	local tex = Instance.new("Texture")
	tex.Name = "EnvSkin"
	tex.Texture = asset
	tex.Face = Enum.NormalId.Top
	tex.StudsPerTileU = studs
	tex.StudsPerTileV = studs
	tex.Parent = part
end

-- Texture di dua face besar dinding (pilih sumbu tipis box).
local function applyWallTexture(part: BasePart, asset: string, studs: number)
	local faces = if part.Size.X >= part.Size.Z
		then { Enum.NormalId.Front, Enum.NormalId.Back }
		else { Enum.NormalId.Left, Enum.NormalId.Right }
	for _, face in ipairs(faces) do
		local tex = Instance.new("Texture")
		tex.Name = "EnvSkin"
		tex.Texture = asset
		tex.Face = face
		tex.StudsPerTileU = studs
		tex.StudsPerTileV = studs
		tex.Parent = part
	end
end

local function newPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size or Vector3.new(1, 1, 1)
	p.CFrame = props.cf or CFrame.new(0, 0, 0)
	p.Color = props.color or Color3.fromRGB(190, 198, 210)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.canCollide ~= nil then props.canCollide else true
	if props.canQuery ~= nil then
		p.CanQuery = props.canQuery
	end
	if props.castShadow ~= nil then
		p.CastShadow = props.castShadow
	end
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
-- Outdoor environment
---------------------------------------------------------------------

--[[
	BuildOutdoorEnvironment: exterior dressing around one facility plot —
	lawn, front parking lot with stall lines, sidewalks, trees, street lamps,
	site name sign, condenser units behind the back wall and a slim back fence.
	Flat placeholder colors for now; future texture swaps are marked [TEX:..].
	Everything hangs under `facility` so the plot teardown removes it too.
]]
function WorldAndAssetBuilder.BuildOutdoorEnvironment(facility: Folder, plotCF: (number, number, number) -> CFrame)
	-- Lawn slab under the whole plot (top at y = 0, room floor sits on top).
	local groundPart = newPart({
		name = "OutdoorGround",
		size = Vector3.new(300, 0.4, 300),
		cf = plotCF(0, -0.2, 0),
		color = Color3.fromRGB(84, 122, 58), -- [TEX:grass]
		castShadow = false,
	})
	applyTopTexture(groundPart, TEX_GRASS, 16)
	groundPart.Parent = facility

	-- Front parking lot asphalt just outside the entrance (top ~y 0.45).
	local parkingPart = newPart({
		name = "OutdoorParking",
		size = Vector3.new(56, 0.45, 22),
		cf = plotCF(0, 0.22, 44),
		color = Color3.fromRGB(45, 47, 50), -- [TEX:asphalt]
		castShadow = false,
	})
	applyTopTexture(parkingPart, TEX_ASPHALT, 8)
	parkingPart.Parent = facility

	-- Concrete sidewalks: front strip along the facade + side aprons.
	local sidewalkFront = newPart({
		name = "OutdoorSidewalkFront",
		size = Vector3.new(56, 0.5, 4),
		cf = plotCF(0, 0.28, 33.5),
		color = Color3.fromRGB(150, 150, 145), -- [TEX:concrete]
		castShadow = false,
	})
	applyTopTexture(sidewalkFront, TEX_WALL, 6)
	sidewalkFront.Parent = facility
	for _, sx in ipairs({ -36.5, 36.5 }) do
		local sidewalkSide = newPart({
			name = "OutdoorSidewalkSide",
			size = Vector3.new(8, 0.5, 64),
			cf = plotCF(sx, 0.28, 0),
			color = Color3.fromRGB(150, 150, 145), -- [TEX:concrete]
			castShadow = false,
		})
		applyTopTexture(sidewalkSide, TEX_WALL, 6)
		sidewalkSide.Parent = facility
	end

	-- White parking stall lines, two rows across the lot (paint, no collision).
	for _, pz in ipairs({ 40, 49 }) do
		for px = -20, 20, 6 do
			newPart({
				name = "ParkingLine",
				size = Vector3.new(0.3, 0.02, 5),
				cf = plotCF(px, 0.47, pz),
				color = Color3.fromRGB(235, 235, 235),
				canCollide = false,
				castShadow = false,
			}).Parent = facility
		end
	end

	-- Four trees flanking the building (trunk cylinder + two foliage balls).
	for _, tpos in ipairs({ { -38, 10 }, { 38, 10 }, { -38, 52 }, { 38, 52 } }) do
		local tx, tz = tpos[1], tpos[2]
		local trunk = newPart({
			name = "TreeTrunk",
			size = Vector3.new(3, 0.6, 0.6), -- cylinder axis is X; stood upright below
			cf = plotCF(tx, 1.5, tz) * CFrame.Angles(0, 0, math.rad(90)),
			color = Color3.fromRGB(92, 64, 40),
		})
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Parent = facility
		local canopy = newPart({
			name = "TreeCanopy",
			size = Vector3.new(4, 4, 4),
			cf = plotCF(tx, 3.9, tz),
			color = Color3.fromRGB(58, 102, 48),
			canCollide = false,
		})
		canopy.Shape = Enum.PartType.Ball
		canopy.Parent = facility
		local canopyTop = newPart({
			name = "TreeCanopyTop",
			size = Vector3.new(2.6, 2.6, 2.6),
			cf = plotCF(tx + 0.7, 5.2, tz - 0.6),
			color = Color3.fromRGB(58, 102, 48),
			canCollide = false,
		})
		canopyTop.Shape = Enum.PartType.Ball
		canopyTop.Parent = facility
	end

	-- Three street lamps at the lot edges; each arm reaches over the asphalt.
	for _, lamp in ipairs({
		{ x = -26, z = 36, dirX = 1, dirZ = 0 },
		{ x = 26, z = 36, dirX = -1, dirZ = 0 },
		{ x = 0, z = 56, dirX = 0, dirZ = -1 },
	}) do
		local pole = newPart({
			name = "LampPole",
			size = Vector3.new(7, 0.25, 0.25),
			cf = plotCF(lamp.x, 3.5, lamp.z) * CFrame.Angles(0, 0, math.rad(90)),
			color = Color3.fromRGB(70, 74, 80),
		})
		pole.Shape = Enum.PartType.Cylinder
		pole.Parent = facility
		newPart({
			name = "LampArm",
			size = if lamp.dirZ ~= 0 then Vector3.new(0.18, 0.18, 1.6) else Vector3.new(1.6, 0.18, 0.18),
			cf = plotCF(lamp.x + lamp.dirX * 0.8, 6.85, lamp.z + lamp.dirZ * 0.8),
			color = Color3.fromRGB(70, 74, 80),
			canCollide = false,
		}).Parent = facility
		newPart({
			name = "LampHead",
			size = if lamp.dirZ ~= 0 then Vector3.new(0.5, 0.18, 0.9) else Vector3.new(0.9, 0.18, 0.5),
			cf = plotCF(lamp.x + lamp.dirX * 1.15, 6.72, lamp.z + lamp.dirZ * 1.15),
			color = Color3.fromRGB(255, 226, 180), -- warm white glow
			material = Enum.Material.Neon,
			canCollide = false,
		}).Parent = facility
	end

	-- Site name sign by the road: two posts + dark panel with SurfaceGui text.
	for _, sx in ipairs({ -4, 4 }) do
		newPart({
			name = "SignPost",
			size = Vector3.new(0.3, 4.5, 0.3),
			cf = plotCF(sx, 2.25, 57),
			color = Color3.fromRGB(48, 54, 64),
		}).Parent = facility
	end
	local signPanel = newPart({
		name = "SiteSignPanel",
		size = Vector3.new(9, 2.2, 0.25),
		cf = plotCF(0, 5.6, 57),
		color = Color3.fromRGB(24, 28, 34),
	})
	signPanel.Parent = facility
	local siteGui = Instance.new("SurfaceGui")
	siteGui.Name = "SiteSign"
	siteGui.Face = Enum.NormalId.Front -- +Z face, readable from the road
	siteGui.CanvasSize = Vector2.new(600, 150)
	siteGui.MaxDistance = 120
	siteGui.Parent = signPanel
	local siteLabel = Instance.new("TextLabel")
	siteLabel.Size = UDim2.new(1, 0, 1, 0)
	siteLabel.BackgroundTransparency = 1
	siteLabel.Font = Enum.Font.GothamBold
	siteLabel.TextScaled = true
	siteLabel.TextColor3 = PlotConstants.COLORS.accentCyan
	siteLabel.Text = "ARGA DATACENTER"
	siteLabel.Parent = siteGui
	-- slim cyan accent bar under the lettering
	newPart({
		name = "SiteSignAccent",
		size = Vector3.new(2.6, 0.09, 0.06),
		cf = plotCF(0, 4.72, 57.14),
		color = PlotConstants.COLORS.accentCyan,
		material = Enum.Material.Neon,
		canCollide = false,
	}).Parent = facility

	-- Condenser units behind the back wall: gray cabinet, dark fan disc,
	-- thin neon ring as the "powered" tell.
	for _, cx in ipairs({ -10, 10 }) do
		newPart({
			name = "OutdoorCondenser",
			size = Vector3.new(3, 2.5, 1.5),
			cf = plotCF(cx, 1.25, -38),
			color = Color3.fromRGB(120, 126, 134),
		}).Parent = facility
		local fan = newPart({
			name = "OutdoorCondenserFan",
			size = Vector3.new(0.18, 1.9, 1.9),
			cf = plotCF(cx, 1.25, -37.1) * CFrame.Angles(0, math.rad(90), 0),
			color = Color3.fromRGB(40, 44, 50),
			canCollide = false,
		})
		fan.Shape = Enum.PartType.Cylinder
		fan.Parent = facility
		newPart({
			name = "OutdoorCondenserGlow",
			size = Vector3.new(0.06, 2.1, 2.1),
			cf = plotCF(cx, 1.25, -37.16) * CFrame.Angles(0, math.rad(90), 0),
			color = Color3.fromRGB(170, 225, 255),
			material = Enum.Material.Neon,
			canCollide = false,
		}).Parent = facility
	end

	-- Slim back fence: two rails + one post every 8 studs (11 parts total).
	for _, fy in ipairs({ 1.2, 2.0 }) do
		newPart({
			name = "BackFenceRail",
			size = Vector3.new(64, 0.12, 0.12),
			cf = plotCF(0, fy, -36),
			color = Color3.fromRGB(142, 148, 156),
		}).Parent = facility
	end
	for px = -32, 32, 8 do
		newPart({
			name = "BackFencePost",
			size = Vector3.new(0.3, 2.4, 0.3),
			cf = plotCF(px, 1.2, -36),
			color = Color3.fromRGB(142, 148, 156),
		}).Parent = facility
	end
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

	-- ===== Room geometry (bright Tier-4 enterprise data-center lab) =====
	local fullW = halfX * 2 + 2 -- 66 studs
	local fullD = halfZ * 2 + 2 -- 66 studs
	local wallH = roomH -- 18 studs (proportional data-center hall)
	local doorW = PlotConstants.ROOM.doorWidth -- 14
	local doorH = PlotConstants.ROOM.doorHeight -- 10
	local wainscotH = 3.5 -- lower architectural wall band height (waist/desk level)

	-- Anti-static epoxy raised floor slab (top at y = floorTopY = 0.5) with a
	-- subtle sheen: real DC floors are sealed epoxy that reflects the fixtures.
	local floor = newPart({
		name = "RoomFloor",
		size = Vector3.new(fullW, floorTopY, fullD),
		cf = plotCF(0, floorTopY / 2, 0),
		color = colors.floor,
		material = Enum.Material.SmoothPlastic,
	})	applyTopTexture(floor, TEX_FLOOR, 4)
	floor.Reflectance = 0.12
	floor.Parent = facility

	-- Decorative raised-floor tile grid lines (non-collidable, non-queryable).
	for gx = -24, 24, 8 do
		newPart({
			name = "FloorGridX",
			size = Vector3.new(0.14, 0.02, halfZ * 2 - 1),
			cf = plotCF(gx, floorTopY + 0.01, 0),
			color = colors.floorGrid,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
	end
	for gz = -24, 24, 8 do
		newPart({
			name = "FloorGridZ",
			size = Vector3.new(halfX * 2 - 1, 0.02, 0.14),
			cf = plotCF(0, floorTopY + 0.01, gz),
			color = colors.floorGrid,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Central cold-aisle walkway: dark anti-static runner mat + LED guide rails.
	newPart({
		name = "WalkwayMat",
		size = Vector3.new(8.5, 0.03, 46),
		cf = plotCF(0, floorTopY + 0.015, 9),
		color = Color3.fromRGB(88, 94, 102),
		canCollide = false,
		canQuery = false,
		castShadow = false,
	}).Parent = facility
	for _, side in ipairs({ -4.35, 4.35 }) do
		newPart({
			name = "WalkwayLED",
			size = Vector3.new(0.18, 0.04, 46),
			cf = plotCF(side, floorTopY + 0.02, 9),
			color = colors.accentCyan,
			material = Enum.Material.Neon,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Floor zone pads (visual wayfinding per station; CanQuery=false so placement hits RoomFloor).
	local zonePads: { { name: string, pos: Vector3, size: Vector3, color: Color3, border: Color3 } } = {
		{
			name = "ZonePad_Rack",
			pos = Vector3.new(-21, floorTopY + 0.018, -22),
			size = Vector3.new(15, 0.03, 15),
			color = Color3.fromRGB(140, 150, 164),
			border = Color3.fromRGB(222, 178, 40),
		},
		{
			name = "ZonePad_Workbench",
			pos = Vector3.new(18, floorTopY + 0.018, -12),
			size = Vector3.new(14, 0.03, 11),
			color = Color3.fromRGB(150, 144, 132),
			border = Color3.fromRGB(222, 178, 40),
		},
		{
			name = "ZonePad_NOC",
			pos = Vector3.new(18, floorTopY + 0.018, 16),
			size = Vector3.new(17, 0.03, 12),
			color = Color3.fromRGB(140, 150, 164),
			border = Color3.fromRGB(222, 178, 40),
		},
	}
	for _, zp in ipairs(zonePads) do
		newPart({
			name = zp.name,
			size = zp.size,
			cf = plotCF(zp.pos.X, zp.pos.Y, zp.pos.Z),
			color = zp.color,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
		-- crisp front safety-tape accent bar on each zone pad (paint, not neon)
		newPart({
			name = zp.name .. "_Trim",
			size = Vector3.new(zp.size.X, 0.04, 0.25),
			cf = plotCF(zp.pos.X, floorTopY + 0.025, zp.pos.Z + zp.size.Z / 2),
			color = zp.border,
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Helper: builds a two-tone solid wall section (steel wainscot + dado + painted upper).
	local function addSolidWall(namePrefix: string, sizeX: number, sizeZ: number, cx: number, cz: number, yLow: number, yHigh: number)
		local lowerTop = math.clamp(wainscotH, yLow, yHigh)
		if yLow < lowerTop then
			local h = lowerTop - yLow
			newPart({
				name = namePrefix .. "_Low",
				size = Vector3.new(sizeX, h, sizeZ),
				cf = plotCF(cx, yLow + h / 2, cz),
				color = colors.wallLower,
				material = Enum.Material.Metal,
			}).Parent = facility
		end
		if yHigh > lowerTop then
			local h = yHigh - lowerTop
			local wallHigh = newPart({
				name = namePrefix .. "_High",
				size = Vector3.new(sizeX, h, sizeZ),
				cf = plotCF(cx, lowerTop + h / 2, cz),
				color = colors.wall,
				material = Enum.Material.Concrete,
			})
			applyWallTexture(wallHigh, TEX_WALL, 8)
			wallHigh.Parent = facility
		end
	end

	-- Back wall (-Z): solid two-tone with dado rail & cyan LED strip.
	addSolidWall("Wall_Back", fullW, 1, 0, -halfZ - 0.5, 0, wallH)
	newPart({
		name = "Dado_Back",
		size = Vector3.new(fullW - 2, 0.28, 0.16),
		cf = plotCF(0, wainscotH, -halfZ + 0.08),
		color = colors.trim,
		canCollide = false,
	}).Parent = facility
	newPart({
		name = "LEDStrip_Back",
		size = Vector3.new(fullW - 4, 0.14, 0.1),
		cf = plotCF(0, wainscotH + 0.22, -halfZ + 0.06),
		color = colors.accentCyan,
		material = Enum.Material.Neon,
		canCollide = false,
	}).Parent = facility

	-- Right wall (+X): solid two-tone (houses AC unit) with dado rail & cyan LED strip.
	addSolidWall("Wall_Right", 1, fullD, halfX + 0.5, 0, 0, wallH)
	newPart({
		name = "Dado_Right",
		size = Vector3.new(0.16, 0.28, fullD - 2),
		cf = plotCF(halfX - 0.08, wainscotH, 0),
		color = colors.trim,
		canCollide = false,
	}).Parent = facility
	newPart({
		name = "LEDStrip_Right",
		size = Vector3.new(0.1, 0.14, fullD - 4),
		cf = plotCF(halfX - 0.06, wainscotH + 0.22, 0),
		color = colors.accentCyan,
		material = Enum.Material.Neon,
		canCollide = false,
	}).Parent = facility

	-- Left wall (-X): panoramic observation glass window (z = -18..18, y = 3.5..12.5) for daylight.
	local lx = -halfX - 0.5
	addSolidWall("Wall_Left_North", 1, 15, lx, -25.5, 0, wallH) -- z = -33..-18
	addSolidWall("Wall_Left_South", 1, 15, lx, 25.5, 0, wallH) -- z = 18..33
	addSolidWall("Wall_Left_Sill", 1, 36, lx, 0, 0, 3.5)
	addSolidWall("Wall_Left_Header", 1, 36, lx, 0, 12.5, wallH)
	newPart({
		name = "Window_Left_Glass",
		size = Vector3.new(0.25, 9, 36),
		cf = plotCF(lx, 8.0, 0),
		color = Color3.fromRGB(120, 150, 170),
		material = Enum.Material.Glass,
		transparency = 0.4,
		castShadow = false,
	}).Parent = facility
	-- Window frame mullions (horizontal sill/top + vertical dividers).
	for _, my in ipairs({ 3.65, 12.35 }) do
		newPart({
			name = "Window_Left_Bar",
			size = Vector3.new(1.15, 0.35, 36.2),
			cf = plotCF(lx, my, 0),
			color = colors.frame,
		}).Parent = facility
	end
	for _, mz in ipairs({ -18, -6, 6, 18 }) do
		newPart({
			name = "Window_Left_Mullion",
			size = Vector3.new(1.15, 9, 0.45),
			cf = plotCF(lx, 8.0, mz),
			color = colors.frame,
		}).Parent = facility
	end

	-- Front wall (+Z): open glass-framed entrance (doorW=14, doorH=10) + side display windows.
	local fz = halfZ + 0.5
	-- Center lintel above doorway
	addSolidWall("Wall_Front_Lintel", doorW, 1, 0, fz, doorH, wallH)
	-- Left and right front wings with windows (x = +-11..+-25, y = 3.5..10.5)
	for _, dir in ipairs({ -1, 1 }) do
		local tag = if dir < 0 then "L" else "R"
		addSolidWall("Wall_Front_Inner_" .. tag, 4, 1, dir * 9, fz, 0, wallH) -- 7..11
		addSolidWall("Wall_Front_Outer_" .. tag, 8, 1, dir * 29, fz, 0, wallH) -- 25..33
		addSolidWall("Wall_Front_Sill_" .. tag, 14, 1, dir * 18, fz, 0, 3.5) -- 11..25
		addSolidWall("Wall_Front_Top_" .. tag, 14, 1, dir * 18, fz, 10.5, wallH)
		newPart({
			name = "Window_Front_Glass_" .. tag,
			size = Vector3.new(14, 7, 0.25),
			cf = plotCF(dir * 18, 7.0, fz),
			color = Color3.fromRGB(120, 150, 170),
			material = Enum.Material.Glass,
			transparency = 0.4,
			castShadow = false,
		}).Parent = facility
		for _, wy in ipairs({ 3.65, 10.35 }) do
			newPart({
				name = "Window_Front_Bar_" .. tag,
				size = Vector3.new(14.3, 0.35, 1.15),
				cf = plotCF(dir * 18, wy, fz),
				color = colors.frame,
			}).Parent = facility
		end
		newPart({
			name = "Window_Front_Mullion_" .. tag,
			size = Vector3.new(0.4, 7, 1.15),
			cf = plotCF(dir * 18, 7.0, fz),
			color = colors.frame,
		}).Parent = facility
	end

	-- Entrance portal frame (sleek slate aluminum pillars + glowing cyan lintel bar).
	for _, side in ipairs({ -1, 1 }) do
		newPart({
			name = "DoorPillar",
			size = Vector3.new(0.9, doorH + 0.6, 1.5),
			cf = plotCF(side * (doorW / 2 + 0.35), (doorH + 0.6) / 2, fz),
			color = colors.frame,
		}).Parent = facility
	end
	newPart({
		name = "DoorHeader",
		size = Vector3.new(doorW + 1.6, 1.2, 1.6),
		cf = plotCF(0, doorH + 0.5, fz),
		color = colors.frame,
	}).Parent = facility
	newPart({
		name = "DoorHeaderLED",
		size = Vector3.new(doorW + 0.6, 0.2, 1.68),
		cf = plotCF(0, doorH + 0.05, fz),
		color = colors.accentCyan,
		material = Enum.Material.Neon,
		canCollide = false,
	}).Parent = facility

	-- Exterior corner trim columns + roof fascia band for clean outside silhouette.
	for _, cx in ipairs({ -halfX - 0.5, halfX + 0.5 }) do
		for _, cz in ipairs({ -halfZ - 0.5, halfZ + 0.5 }) do
			newPart({
				name = "CornerColumn",
				size = Vector3.new(1.5, wallH + 0.6, 1.5),
				cf = plotCF(cx, (wallH + 0.6) / 2, cz),
				color = colors.frame,
			}).Parent = facility
		end
	end

	-- Ceiling perimeter with a central 24x24 glass skylight atrium so daylight fills the lab.
	local skyHalf = 12
	local sideBand = (fullW - skyHalf * 2) / 2 -- 21 studs
	local ceilingDefs: { { size: Vector3, x: number, z: number } } = {
		{ size = Vector3.new(fullW, 0.6, sideBand), x = 0, z = -(skyHalf + sideBand / 2) },
		{ size = Vector3.new(fullW, 0.6, sideBand), x = 0, z = skyHalf + sideBand / 2 },
		{ size = Vector3.new(sideBand, 0.6, skyHalf * 2), x = -(skyHalf + sideBand / 2), z = 0 },
		{ size = Vector3.new(sideBand, 0.6, skyHalf * 2), x = skyHalf + sideBand / 2, z = 0 },
	}
	for i, cdef in ipairs(ceilingDefs) do
		newPart({
			name = "Ceiling_" .. tostring(i),
			size = cdef.size,
			cf = plotCF(cdef.x, roomH + 0.3, cdef.z),
			color = Color3.fromRGB(74, 78, 86),
			material = Enum.Material.Metal,
		}).Parent = facility
	end
	-- Solid roof deck above the skylight: machine halls take no direct sun;
	-- the glass reads as a dark architectural panel and fixtures do the work.
	newPart({
		name = "SkylightDeck",
		size = Vector3.new(skyHalf * 2 + 1, 0.4, skyHalf * 2 + 1),
		cf = plotCF(0, roomH + 0.9, 0),
		color = Color3.fromRGB(58, 62, 70),
		material = Enum.Material.Metal,
	}).Parent = facility
	-- Skylight glass pane + architectural crossbeams.
	newPart({
		name = "SkylightGlass",
		size = Vector3.new(skyHalf * 2, 0.25, skyHalf * 2),
		cf = plotCF(0, roomH + 0.35, 0),
		color = colors.glass,
		material = Enum.Material.Glass,
		transparency = 0.72,
		castShadow = false,
	}).Parent = facility
	for _, bx in ipairs({ -skyHalf, 0, skyHalf }) do
		newPart({
			name = "SkylightBeamX",
			size = Vector3.new(0.6, 0.75, skyHalf * 2 + 0.6),
			cf = plotCF(bx, roomH + 0.25, 0),
			color = colors.frame,
		}).Parent = facility
	end
	for _, bz in ipairs({ -skyHalf, 0, skyHalf }) do
		newPart({
			name = "SkylightBeamZ",
			size = Vector3.new(skyHalf * 2 + 0.6, 0.75, 0.6),
			cf = plotCF(0, roomH + 0.25, bz),
			color = colors.frame,
		}).Parent = facility
	end

	-- Overhead industrial cable ladder trays + yellow fiber raceway (y = 15.2).
	local trayY = 15.2
	local trayDefs: { { size: Vector3, x: number, z: number, color: Color3 } } = {
		{ size = Vector3.new(44, 0.25, 2.2), x = -2, z = -20, color = colors.trim }, -- back main trunk
		{ size = Vector3.new(44, 0.2, 0.7), x = -2, z = -20, color = colors.accentAmber }, -- yellow fiber raceway
		{ size = Vector3.new(2.2, 0.25, 36), x = 18, z = -2, color = colors.trim }, -- workbench to NOC trunk
		{ size = Vector3.new(0.7, 0.2, 36), x = 18, z = -2, color = colors.accentAmber },
		{ size = Vector3.new(24, 0.25, 2.2), x = -16, z = 27, color = colors.trim }, -- front ISP tray above the wall station (x -28..-4)
		{ size = Vector3.new(22, 0.25, 2.2), x = 7, z = 27, color = colors.trim }, -- L-connector front tray to the right-trunk line (x -4..18)
		{ size = Vector3.new(46, 0.2, 0.7), x = -5, z = 27, color = colors.accentAmber }, -- yellow fiber raceway following both front runs
	}
	for i, tdef in ipairs(trayDefs) do
		newPart({
			name = "CableTray_" .. tostring(i),
			size = tdef.size,
			cf = plotCF(tdef.x, trayY, tdef.z),
			color = tdef.color,
			canCollide = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Loaded cable bundles in the overhead trays (blue LAN, yellow WAN/fiber,
	-- red management, black power) so the trays read as live infrastructure.
	local bundleColors = {
		Color3.fromRGB(40, 90, 180),
		Color3.fromRGB(222, 178, 40),
		Color3.fromRGB(180, 50, 44),
		Color3.fromRGB(30, 32, 36),
	}
	for bi, bc in ipairs(bundleColors) do
		newPart({
			name = "TrunkCable_" .. bi,
			size = Vector3.new(43.5, 0.14, 0.16),
			cf = plotCF(-2, trayY + 0.18, -20.7 + (bi - 1) * 0.42),
			color = bc,
			canCollide = false,
			castShadow = false,
		}).Parent = facility
		newPart({
			name = "BranchCable_" .. bi,
			size = Vector3.new(0.16, 0.14, 35.5),
			cf = plotCF(17.3 + (bi - 1) * 0.42, trayY + 0.18, -2),
			color = bc,
			canCollide = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Single amber service cable riding the front tray + connector run (x
	-- -28..18), same thin profile as the TrunkCable_ bundles above.
	newPart({
		name = "FrontTrunkCable_1",
		size = Vector3.new(45.5, 0.14, 0.16),
		cf = plotCF(-5, trayY + 0.18, 26.3),
		color = colors.accentAmber,
		canCollide = false,
		castShadow = false,
	}).Parent = facility

	-- ===== Outdoor environment around the plot (lawn, parking, signage, fence) =====
	WorldAndAssetBuilder.BuildOutdoorEnvironment(facility, plotCF)

	-- 6 high-output ceiling LED fixtures with wide SurfaceLight + PointLight fill.
	for _, lx in ipairs({ -20, 0, 20 }) do
		for _, lz in ipairs({ -18, 18 }) do
			local housing = newPart({
				name = "LightHousing",
				size = Vector3.new(9.2, 0.25, 2.6),
				cf = plotCF(lx, roomH - 0.12, lz),
				color = colors.frame,
				canCollide = false,
				castShadow = false,
			})
			housing.Parent = facility
			local panel = newPart({
				name = "LightPanel",
				size = Vector3.new(8.6, 0.16, 2.1),
				cf = plotCF(lx, roomH - 0.26, lz),
				color = colors.lightPanel,
				material = Enum.Material.Neon,
				canCollide = false,
				castShadow = false,
			})
			panel.Parent = facility
			local light = Instance.new("SurfaceLight")
			light.Face = Enum.NormalId.Bottom
			light.Range = 36
			light.Brightness = 2.6
			light.Angle = 115
			light.Shadows = true
			light.Color = Color3.fromRGB(242, 248, 255)
			light.Parent = panel
			local fill = Instance.new("PointLight")
			fill.Range = 26
			fill.Brightness = 0.5
			fill.Color = Color3.fromRGB(236, 244, 255)
			fill.Shadows = false
			fill.Parent = panel
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
	session.rackSlots["rack_main_1"] = rackSlots

	-- ===== ISP uplink node (WAN junction, always powered) =====
	-- Sits at the front wall (+Z, near the entrance); rotated 180° so the box
	-- faces into the room (WAN port side points -Z toward the player).
	local ispSpec = PlotConstants.STARTER.isp
	local ispModel, _ispAttach, ispWanLed = ModelFactory.BuildISPUplink(ispSpec.id)
	ispModel:PivotTo(plotCF(PlotConstants.ISP_POS.X, floorTopY, PlotConstants.ISP_POS.Z) * CFrame.Angles(0, math.pi, 0))
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

	-- ===== Interior Data-Center Decorations (perimeter, outside PLACEMENT_BOUNDS) =====
	local upsModel = ModelFactory.BuildUPSBank()
	upsModel:PivotTo(plotCF(16, floorTopY, -30.2))
	upsModel.Parent = facility

	local fireModel = ModelFactory.BuildFireSuppression()
	fireModel:PivotTo(plotCF(-11, floorTopY, -30.8))
	fireModel.Parent = facility

	local storageModel = ModelFactory.BuildStorageRack()
	storageModel:PivotTo(plotCF(29.8, floorTopY, 2) * CFrame.Angles(0, math.rad(-90), 0))
	storageModel.Parent = facility

	local patchModel = ModelFactory.BuildPatchPanelWall()
	patchModel:PivotTo(plotCF(-30.8, floorTopY, -24) * CFrame.Angles(0, math.rad(90), 0))
	patchModel.Parent = facility

	local wallboardModel = ModelFactory.BuildWallboard()
	wallboardModel:PivotTo(plotCF(0, floorTopY + 11.2, -31.4))
	wallboardModel.Parent = facility

	local breakModel = ModelFactory.BuildBreakCorner()
	breakModel:PivotTo(plotCF(-24, floorTopY, 29.8) * CFrame.Angles(0, math.rad(180), 0))
	breakModel.Parent = facility

	for _, px in ipairs({ -9.5, 9.5 }) do
		local planter = ModelFactory.BuildOfficePlanter()
		planter:PivotTo(plotCF(px, floorTopY, 29.8))
		planter.Parent = facility
	end

	-- Sub-floor glass fiber-optic trench window along the central walkway
	newPart({
		name = "SubFloorTrenchGlass",
		size = Vector3.new(3.2, 0.035, 36),
		cf = plotCF(0, floorTopY + 0.018, 6),
		color = Color3.fromRGB(28, 42, 62),
		canCollide = false,
		canQuery = false,
		castShadow = false,
	}).Parent = facility
	for i, col in ipairs({ colors.accentCyan, Color3.fromRGB(70, 130, 255), colors.accentAmber }) do
		newPart({
			name = "SubFloorFiber_" .. tostring(i),
			size = Vector3.new(0.14, 0.04, 35.4),
			cf = plotCF(-0.85 + (i - 1) * 0.85, floorTopY + 0.022, 6),
			color = col,
			material = Enum.Material.Neon,
			canCollide = false,
			canQuery = false,
			castShadow = false,
		}).Parent = facility
	end

	-- Biometric door access keypad beside the entrance portal
	newPart({
		name = "BiometricKeypad",
		size = Vector3.new(0.55, 0.85, 0.16),
		cf = plotCF(doorW / 2 + 1.2, floorTopY + 4.0, halfZ - 0.08),
		color = colors.frame,
		canCollide = false,
	}).Parent = facility
	newPart({
		name = "KeypadLED",
		size = Vector3.new(0.32, 0.12, 0.18),
		cf = plotCF(doorW / 2 + 1.2, floorTopY + 4.25, halfZ - 0.09),
		color = colors.ledGreen,
		material = Enum.Material.Neon,
		canCollide = false,
	}).Parent = facility

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
