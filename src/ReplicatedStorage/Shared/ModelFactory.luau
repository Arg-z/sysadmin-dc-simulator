--!strict
--[[
	ModelFactory (ModuleScript, ReplicatedStorage/Shared)
	Pabrik model 3D prosedural: device rackable, rack, workbench, NOC desk,
	dock, ISP uplink, beacon, AC unit, laptop tool, crate, visual komponen.
	Dipakai server (model asli) dan client (ghost preview placement).
	Konvensi: semua model dibangun dengan pivot di titik tengah-bawah (lantai).
]]

local Catalog = require(script.Parent.HardwareCatalog)
local PlotConstants = require(script.Parent.PlotConstants)

local ModelFactory = {}

local C = PlotConstants.COLORS

type PortRef = {
	portId: string,
	portType: string,
	part: Part,
	attachment: Attachment,
	led: Part,
}

local function newPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size or Vector3.new(1, 1, 1)
	p.CFrame = props.cf or CFrame.new(0, 0, 0)
	p.Color = props.color or Color3.fromRGB(120, 120, 125)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.canCollide ~= nil then props.canCollide else false
	p.Anchored = if props.anchored ~= nil then props.anchored else true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.shape == "Cylinder" then
		p.Shape = Enum.PartType.Cylinder
	end
	return p
end

local function neon(props: { [string]: any }): Part
	props.material = Enum.Material.Neon
	return newPart(props)
end

function ModelFactory.DeviceDimensions(itemId: string): (number, number, number, number)
	-- return: width, height, depth, uSize
	local def = Catalog.Get(itemId)
	local uSize = if def then def.uSize else 1
	local width = 4.6
	local depth = 3.4
	if itemId == "switch_8p" then
		width = 5
	elseif itemId == "switch_24p" then
		width = 7
	elseif itemId == "router_edge" then
		width = 6
	elseif itemId == "bm_starter" or itemId == "bm_enterprise" then
		width = 4.6
		depth = 3.8
	end
	local height = if uSize <= 1 then 1.2 else 2.4
	return width, height, depth, uSize
end

function ModelFactory.ComputeFootprint(itemId: string): (number, number)
	local width, _, depth, _ = ModelFactory.DeviceDimensions(itemId)
	if itemId == "rack_12u" then
		return 3.6, 2.0
	elseif itemId == "rack_24u" then
		return 3.6, 2.0
	end
	return width / 2 + 0.2, depth / 2 + 0.2
end

--[[
	BuildDeviceModel: model device rackable/freeform lengkap dengan port.
	Mengembalikan: model, ports (portId -> ref), consoleAttachment, statusLED, smoke
]]
function ModelFactory.BuildDeviceModel(itemId: string, deviceId: string): (Model, { [string]: PortRef }, Attachment, Part, ParticleEmitter)
	local def = Catalog.Get(itemId)
	assert(def ~= nil, "Item tidak ada di katalog: " .. itemId)
	local defv = def :: ItemDef
	local width, height, depth, uSize = ModelFactory.DeviceDimensions(itemId)

	local model = Instance.new("Model")
	model.Name = defv.name

	local chassis = newPart({
		name = "Chassis",
		size = Vector3.new(width, height, depth),
		cf = CFrame.new(0, height / 2, 0),
		color = defv.visualColor,
		material = Enum.Material.Metal,
	})
	chassis.Parent = model

	-- vent dekoratif depan
	local vent = newPart({
		name = "Vent",
		size = Vector3.new(width - 1.2, 0.16, 0.1),
		cf = CFrame.new(0, height / 2, depth / 2 + 0.05),
		color = Color3.fromRGB(25, 25, 28),
	})
	vent.Parent = model

	-- Status LED
	local led = neon({
		name = "StatusLED",
		size = Vector3.new(0.3, 0.14, 0.12),
		cf = CFrame.new(width / 2 - 0.35, height - 0.2, depth / 2 + 0.06),
		color = C.ledRed,
	})
	led.Parent = model

	-- Smoke overheat (off by default)
	local smokeAnchor = newPart({
		name = "SmokeAnchor",
		size = Vector3.new(0.1, 0.1, 0.1),
		cf = CFrame.new(0, height + 0.1, -depth / 2 + 0.3),
		transparency = 1,
	})
	smokeAnchor.Parent = model
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "OverheatSmoke"
	smoke.Rate = 8
	smoke.Lifetime = NumberRange.new(1, 1.8)
	smoke.Speed = NumberRange.new(1.2, 2.2)
	smoke.Size = NumberSequence.new(0.45)
	smoke.Color = ColorSequence.new(Color3.fromRGB(90, 90, 95))
	smoke.Transparency = NumberSequence.new(0.3, 1)
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Enabled = false
	smoke.Parent = smokeAnchor

	-- Port plan
	local portsSpec: { { id: string, portType: string } } = {}
	local specs = defv.specs
	local wanPorts = specs.wanPorts or 0
	local rjPorts = specs.ports or 0
	local sfpPorts = specs.sfpPorts or 0
	for i = 1, wanPorts do
		table.insert(portsSpec, { id = "wan" .. i, portType = "WAN" })
	end
	for i = 1, rjPorts do
		table.insert(portsSpec, { id = "eth" .. i, portType = "RJ45" })
	end
	for i = 1, sfpPorts do
		table.insert(portsSpec, { id = "sfp" .. i, portType = "SFP" })
	end

	local ports: { [string]: PortRef } = {}
	local total = #portsSpec
	if total > 0 then
		local rows = if total > 12 then 2 else 1
		local perRow = math.ceil(total / rows)
		local usable = width - 1.2
		local step = if perRow > 1 then usable / (perRow - 1) else 0
		for idx, spec in ipairs(portsSpec) do
			local rowIdx = if rows == 2 then (if idx <= perRow then 0 else 1) else 0
			local colIdx = if rows == 2 then ((idx - 1) % perRow) else (idx - 1)
			local px = if perRow > 1 then (-usable / 2) + colIdx * step else 0
			local py = height - 0.45 - rowIdx * 0.5
			local portPart = newPart({
				name = "Port_" .. spec.id,
				size = Vector3.new(0.55, 0.4, 0.24),
				cf = CFrame.new(px, py, depth / 2 + 0.12),
				color = Color3.fromRGB(30, 30, 34),
			})
			portPart:SetAttribute("PortId", spec.id)
			portPart:SetAttribute("PortType", spec.portType)
			portPart:SetAttribute("DeviceId", deviceId)
			portPart.Parent = model

			local portLed = neon({
				name = "PortLED_" .. spec.id,
				size = Vector3.new(0.18, 0.12, 0.06),
				cf = CFrame.new(px, py - 0.28, depth / 2 + 0.14),
				color = C.ledOff,
			})
			portLed:SetAttribute("PortId", spec.id)
			portLed:SetAttribute("DeviceId", deviceId)
			portLed.Parent = model

			local attach = Instance.new("Attachment")
			attach.Name = "PortAttach"
			attach.CFrame = CFrame.new(0, 0, -0.14)
			attach.Parent = portPart

			local click = Instance.new("ClickDetector")
			click.Name = "Click"
			click.MaxActivationDistance = 45
			click.Parent = portPart

			ports[spec.id] = { portId = spec.id, portType = spec.portType, part = portPart, attachment = attach, led = portLed }
		end
	end

	-- Console port (belakang, biru)
	local consolePart = neon({
		name = "ConsolePort",
		size = Vector3.new(0.6, 0.45, 0.22),
		cf = CFrame.new(0, height / 2, -depth / 2 - 0.11),
		color = C.consoleBlue,
	})
	consolePart:SetAttribute("ConsoleDeviceId", deviceId)
	consolePart.Parent = model
	local consoleAttach = Instance.new("Attachment")
	consoleAttach.Name = "ConsoleAttach"
	consoleAttach.CFrame = CFrame.new(0, 0, 0.12)
	consoleAttach.Parent = consolePart

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ConsolePrompt"
	prompt.ActionText = "Connect Console Cable"
	prompt.ObjectText = defv.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = consolePart

	model:SetAttribute("DeviceId", deviceId)
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("USize", uSize)
	model.WorldPivot = CFrame.new(0, 0, 0)

	return model, ports, consoleAttach, led, smoke
end

--[[
	BuildRack: rak dengan slot attachment U1..UmaxU + PDU strip.
]]
function ModelFactory.BuildRack(itemId: string, rackId: string): (Model, { [number]: Attachment }, Part)
	local def = Catalog.Get(itemId)
	assert(def ~= nil, "Item tidak ada di katalog: " .. itemId)
	local defv = def :: ItemDef
	local maxU = defv.specs.maxU
	local slotH = 1.3
	local baseH = 1
	local bodyH = maxU * slotH + baseH
	local w = 7
	local d = 3.5

	local model = Instance.new("Model")
	model.Name = defv.name

	local back = newPart({
		name = "BackPanel",
		size = Vector3.new(w, bodyH, 0.3),
		cf = CFrame.new(0, bodyH / 2, -d / 2 + 0.15),
		color = defv.visualColor,
		material = Enum.Material.Metal,
	})
	back.Parent = model
	model.PrimaryPart = back

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			local post = newPart({
				name = "Post",
				size = Vector3.new(0.45, bodyH, 0.45),
				cf = CFrame.new(sx * (w / 2 - 0.25), bodyH / 2, sz * (d / 2 - 0.25)),
				color = Color3.fromRGB(35, 37, 42),
				material = Enum.Material.Metal,
			})
			post.Parent = model
		end
	end

	local topCap = newPart({
		name = "TopCap",
		size = Vector3.new(w, 0.4, d),
		cf = CFrame.new(0, bodyH + 0.2, 0),
		color = Color3.fromRGB(35, 37, 42),
		material = Enum.Material.Metal,
	})
	topCap.Parent = model

	-- PDU strip (belakang kanan)
	local pdu = newPart({
		name = "PDU_Strip",
		size = Vector3.new(0.5, bodyH - 1.4, 0.5),
		cf = CFrame.new(w / 2 - 0.6, (bodyH - 1.4) / 2 + 0.7, -d / 2 + 0.8),
		color = Color3.fromRGB(28, 28, 32),
		material = Enum.Material.Metal,
	})
	pdu.Parent = model
	local pduLed = neon({
		name = "PDULed",
		size = Vector3.new(0.22, 0.22, 0.1),
		cf = CFrame.new(w / 2 - 0.6, bodyH - 1.1, -d / 2 + 0.55),
		color = C.ledGreen,
	})
	pduLed.Parent = model
	local pduClick = Instance.new("ClickDetector")
	pduClick.Name = "PDUClick"
	pduClick.MaxActivationDistance = 45
	pduClick.Parent = pdu

	-- Slot attachments di muka rak (z positif)
	local slots: { [number]: Attachment } = {}
	local slotFrame = newPart({
		name = "SlotFrame",
		size = Vector3.new(w - 1, 0.1, 0.1),
		cf = CFrame.new(0, baseH + 0.05, d / 2 - 0.35),
		transparency = 1,
	})
	slotFrame.Parent = model
	for u = 1, maxU do
		local a = Instance.new("Attachment")
		a.Name = "USlot_" .. u
		a.CFrame = CFrame.new(0, (u - 1) * slotH, 0)
		a.Parent = slotFrame
		slots[u] = a
	end

	model:SetAttribute("RackId", rackId)
	model:SetAttribute("ItemId", itemId)
	model.WorldPivot = CFrame.new(0, 0, 0)

	return model, slots, pdu
end

function ModelFactory.BuildWorkbench(): (Model, { [number]: Attachment }, Part, Part)
	local model = Instance.new("Model")
	model.Name = "AssemblyWorkbench"

	local top = newPart({
		name = "BenchTop",
		size = Vector3.new(10, 0.4, 5),
		cf = CFrame.new(0, 3.3, 0),
		color = Color3.fromRGB(66, 60, 52),
		material = Enum.Material.Wood,
	})
	top.Parent = model
	model.PrimaryPart = top

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			local leg = newPart({
				name = "Leg",
				size = Vector3.new(0.5, 3.1, 0.5),
				cf = CFrame.new(sx * 4.4, 1.55, sz * 2.0),
				color = Color3.fromRGB(45, 42, 38),
				material = Enum.Material.Metal,
			})
			leg.Parent = model
		end
	end

	local backPanel = newPart({
		name = "BackPanel",
		size = Vector3.new(10, 2.2, 0.25),
		cf = CFrame.new(0, 4.6, -2.3),
		color = Color3.fromRGB(52, 48, 44),
		material = Enum.Material.Metal,
	})
	backPanel.Parent = model

	local snaps: { [number]: Attachment } = {}
	for i = 1, 6 do
		local a = Instance.new("Attachment")
		a.Name = "Snap_" .. i
		a.CFrame = CFrame.new(-3.75 + (i - 1) * 1.5, 0.2, 0)
		a.Parent = top
		snaps[i] = a
	end

	local switchPart = newPart({
		name = "PowerSwitch",
		size = Vector3.new(0.7, 0.5, 0.4),
		cf = CFrame.new(4.5, 3.75, 1.6),
		color = Color3.fromRGB(200, 60, 60),
	})
	switchPart.Parent = model
	local switchClick = Instance.new("ClickDetector")
	switchClick.Name = "BenchPowerClick"
	switchClick.MaxActivationDistance = 45
	switchClick.Parent = switchPart

	local benchLed = neon({
		name = "BenchLed",
		size = Vector3.new(0.3, 0.2, 0.1),
		cf = CFrame.new(4.5, 4.15, 1.6),
		color = C.ledOff,
	})
	benchLed.Parent = model

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, snaps, switchPart, benchLed
end

function ModelFactory.BuildNOCDesk(): (Model, { [string]: Part })
	local model = Instance.new("Model")
	model.Name = "NOCDesk"

	local top = newPart({
		name = "DeskTop",
		size = Vector3.new(14, 0.4, 5),
		cf = CFrame.new(0, 3.3, 0),
		color = Color3.fromRGB(52, 56, 64),
		material = Enum.Material.Metal,
	})
	top.Parent = model
	model.PrimaryPart = top

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			local leg = newPart({
				name = "Leg",
				size = Vector3.new(0.5, 3.1, 0.5),
				cf = CFrame.new(sx * 6.4, 1.55, sz * 2.0),
				color = Color3.fromRGB(40, 42, 48),
				material = Enum.Material.Metal,
			})
			leg.Parent = model
		end
	end

	local monitors: { [string]: Part } = {}
	local names = { "TopologyMonitor", "TicketMonitor", "TelemetryMonitor" }
	for i, name in ipairs(names) do
		local stand = newPart({
			name = name .. "_Stand",
			size = Vector3.new(0.4, 1.6, 0.4),
			cf = CFrame.new(-4.7 + (i - 1) * 4.7, 4.3, -1.4),
			color = Color3.fromRGB(30, 32, 36),
		})
		stand.Parent = model

		local screen = newPart({
			name = name,
			size = Vector3.new(4.4, 3.0, 0.25),
			cf = CFrame.new(-4.7 + (i - 1) * 4.7, 6.6, -1.35) * CFrame.Angles(math.rad(-6), 0, 0),
			color = Color3.fromRGB(12, 13, 16),
		})
		screen.Parent = model

		local bezelTop = newPart({
			name = name .. "_Bezel",
			size = Vector3.new(4.6, 3.2, 0.15),
			cf = CFrame.new(-4.7 + (i - 1) * 4.7, 6.6, -1.5) * CFrame.Angles(math.rad(-6), 0, 0),
			color = Color3.fromRGB(24, 26, 30),
		})
		bezelTop.Parent = model

		local gui = Instance.new("SurfaceGui")
		gui.Name = "SurfaceGui"
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 60
		gui.Face = Enum.NormalId.Front
		gui.Brightness = 2
		gui.Parent = screen

		local root = Instance.new("Frame")
		root.Name = "Root"
		root.Size = UDim2.new(1, 0, 1, 0)
		root.BackgroundTransparency = 1
		root.Parent = gui

		monitors[name] = screen
	end

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, monitors
end

function ModelFactory.BuildDockPad(): (Model, CFrame)
	local model = Instance.new("Model")
	model.Name = "LoadingDock"
	local pad = newPart({
		name = "DockPad",
		size = Vector3.new(12, 0.2, 12),
		cf = CFrame.new(0, 0.6, 0),
		color = Color3.fromRGB(70, 200, 110),
		material = Enum.Material.Neon,
		transparency = 0.55,
	})
	pad.Parent = model
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, CFrame.new(0, 1.6, 0)
end

function ModelFactory.BuildISPUplink(deviceId: string): (Model, Attachment, Part)
	local model = Instance.new("Model")
	model.Name = "ISP_Uplink"

	local box = newPart({
		name = "Chassis",
		size = Vector3.new(3, 2.5, 1.6),
		cf = CFrame.new(0, 4, 0),
		color = Color3.fromRGB(130, 132, 138),
		material = Enum.Material.Metal,
	})
	box.Parent = model
	model.PrimaryPart = box

	local led = neon({
		name = "StatusLED",
		size = Vector3.new(0.3, 0.2, 0.1),
		cf = CFrame.new(1, 4.8, 0.85),
		color = C.ledGreen,
	})
	led.Parent = model

	local wanPart = newPart({
		name = "Port_wan1",
		size = Vector3.new(0.55, 0.4, 0.24),
		cf = CFrame.new(0, 3.6, 0.92),
		color = Color3.fromRGB(30, 30, 34),
	})
	wanPart:SetAttribute("PortId", "wan1")
	wanPart:SetAttribute("PortType", "WAN")
	wanPart:SetAttribute("DeviceId", deviceId)
	wanPart.Parent = model
	local wanLed = neon({
		name = "PortLED_wan1",
		size = Vector3.new(0.18, 0.12, 0.06),
		cf = CFrame.new(0, 3.3, 0.94),
		color = C.ledGreen,
	})
	wanLed:SetAttribute("PortId", "wan1")
	wanLed:SetAttribute("DeviceId", deviceId)
	wanLed.Parent = model
	local attach = Instance.new("Attachment")
	attach.Name = "PortAttach"
	attach.CFrame = CFrame.new(0, 0, 0.14)
	attach.Parent = wanPart
	local click = Instance.new("ClickDetector")
	click.Name = "Click"
	click.MaxActivationDistance = 45
	click.Parent = wanPart

	model:SetAttribute("DeviceId", deviceId)
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, attach, wanLed
end

function ModelFactory.BuildBeacon(): (Model, Part, PointLight)
	local model = Instance.new("Model")
	model.Name = "AlarmBeacon"
	local base = newPart({
		name = "BeaconBase",
		size = Vector3.new(1.2, 0.6, 1.2),
		cf = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(35, 35, 40),
		material = Enum.Material.Metal,
	})
	base.Parent = model
	local lens = neon({
		name = "BeaconLens",
		shape = "Cylinder",
		size = Vector3.new(1.0, 1.0, 1.0),
		cf = CFrame.new(0, 0.8, 0),
		color = C.ledRed,
		transparency = 0.25,
	})
	lens.Parent = model
	local light = Instance.new("PointLight")
	light.Name = "AlarmLight"
	light.Color = Color3.fromRGB(255, 70, 70)
	light.Range = 26
	light.Brightness = 0
	light.Parent = lens
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, lens, light
end

function ModelFactory.BuildACUnit(): (Model, Part)
	local model = Instance.new("Model")
	model.Name = "AC_Unit"
	local body = newPart({
		name = "ACBody",
		size = Vector3.new(1.6, 4, 6),
		cf = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(190, 194, 200),
		material = Enum.Material.Metal,
	})
	body.Parent = model
	model.PrimaryPart = body
	local fan = newPart({
		name = "ACFan",
		shape = "Cylinder",
		size = Vector3.new(0.3, 2.6, 2.6),
		cf = CFrame.new(-0.95, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = Color3.fromRGB(60, 62, 68),
	})
	fan.Parent = model
	local cold = Instance.new("ParticleEmitter")
	cold.Name = "ColdAir"
	cold.Rate = 6
	cold.Lifetime = NumberRange.new(0.8, 1.4)
	cold.Speed = NumberRange.new(2, 4)
	cold.Size = NumberSequence.new(0.5)
	cold.Color = ColorSequence.new(Color3.fromRGB(150, 200, 255))
	cold.Transparency = NumberSequence.new(0.55, 1)
	cold.EmissionDirection = Enum.NormalId.Left
	cold.Parent = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, fan
end

function ModelFactory.BuildLaptop(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "TechnicianLaptop"
	tool.ToolTip = "Klik = Terminal SSH | Dekati device = console"
	tool.CanBeDropped = false

	local handle = newPart({
		name = "Handle",
		size = Vector3.new(2.4, 0.3, 1.7),
		cf = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(30, 32, 36),
		material = Enum.Material.Metal,
		anchored = false,
		canCollide = false,
	})
	handle.Parent = tool
	tool.Grip = CFrame.new(0, -0.15, 0.35)
	tool.GripPos = Vector3.new(0, -0.15, 0.35)

	local lid = newPart({
		name = "Lid",
		size = Vector3.new(2.4, 1.6, 0.14),
		cf = CFrame.new(0, 0.75, -0.72) * CFrame.Angles(math.rad(-115), 0, 0),
		color = Color3.fromRGB(24, 26, 30),
		material = Enum.Material.Metal,
		anchored = false,
		canCollide = false,
	})
	lid.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = lid
	weld.Parent = handle

	local gui = Instance.new("SurfaceGui")
	gui.Name = "LaptopScreen"
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.Face = Enum.NormalId.Front
	gui.Brightness = 2
	gui.Parent = lid
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
	root.BorderSizePixel = 0
	root.Parent = gui
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -10, 1, -10)
	label.Position = UDim2.new(0, 5, 0, 5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.RobotoMono
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(0, 255, 102)
	label.Text = "[TECHNICIAN LAPTOP]\nKlik = Terminal\nDekati device = Console"
	label.Parent = root

	local serialAttach = Instance.new("Attachment")
	serialAttach.Name = "SerialPortAttachment"
	serialAttach.CFrame = CFrame.new(1.25, 0, 0)
	serialAttach.Parent = handle

	local kbLight = neon({
		name = "KBTrim",
		size = Vector3.new(2.2, 0.06, 0.1),
		cf = CFrame.new(0, 0.16, 0.6),
		color = Color3.fromRGB(90, 160, 255),
		anchored = false,
		canCollide = false,
	})
	kbLight.Parent = tool
	local weld2 = Instance.new("WeldConstraint")
	weld2.Part0 = handle
	weld2.Part1 = kbLight
	weld2.Parent = handle

	return tool
end

function ModelFactory.BuildCrate(label: string): Model
	local model = Instance.new("Model")
	model.Name = "Crate"
	local box = newPart({
		name = "CrateBox",
		size = Vector3.new(3, 2.4, 3),
		cf = CFrame.new(0, 1.2, 0),
		color = Color3.fromRGB(133, 96, 60),
		material = Enum.Material.Wood,
	})
	box.Parent = model
	model.PrimaryPart = box
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.new(0, 180, 0, 40)
	bb.StudsOffset = Vector3.new(0, 2.2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 60
	bb.Parent = box
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.GothamBold
	tl.TextScaled = true
	tl.TextColor3 = Color3.fromRGB(255, 235, 170)
	tl.TextStrokeTransparency = 0.4
	tl.Text = label
	tl.Parent = bb
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	Visual komponen yang nempel di workbench saat di-install.
]]
function ModelFactory.BuildBenchComponentVisual(componentId: string): Model
	local def = Catalog.Get(componentId)
	assert(def ~= nil, "Komponen tidak dikenal: " .. componentId)
	local defv = def :: ItemDef
	local model = Instance.new("Model")
	model.Name = "Comp_" .. componentId
	local main: Part
	if componentId == "chassis_1u" or componentId == "chassis_2u" then
		local h = if componentId == "chassis_1u" then 1.3 else 2.6
		main = newPart({
			name = "BenchChassis",
			size = Vector3.new(3.4, h, 2.4),
			cf = CFrame.new(0, h / 2, 0),
			color = defv.visualColor,
			material = Enum.Material.Metal,
		})
		local led = neon({
			name = "StatusLED",
			size = Vector3.new(0.24, 0.12, 0.1),
			cf = CFrame.new(1.3, h - 0.2, 1.22),
			color = C.ledRed,
		})
		led.Parent = model
	elseif componentId == "mobo_single" or componentId == "mobo_dual" then
		main = newPart({
			name = "BenchMobo",
			size = Vector3.new(2.4, 0.12, 2.0),
			cf = CFrame.new(0, 0.4, 0),
			color = defv.visualColor,
		})
	elseif string.sub(componentId, 1, 4) == "cpu_" then
		main = newPart({
			name = "BenchCPU",
			size = Vector3.new(0.5, 0.1, 0.5),
			cf = CFrame.new(0, 0.55, 0),
			color = defv.visualColor,
			material = Enum.Material.Metal,
		})
	elseif string.sub(componentId, 1, 4) == "ram_" then
		main = newPart({
			name = "BenchRAM",
			size = Vector3.new(0.8, 0.35, 0.12),
			cf = CFrame.new(-0.8, 0.62, 0.3),
			color = defv.visualColor,
			material = Enum.Material.Neon,
		})
	elseif componentId == "nvme_1tb" then
		main = newPart({
			name = "BenchStorage",
			size = Vector3.new(0.9, 0.12, 0.5),
			cf = CFrame.new(0.6, 0.5, 0.3),
			color = defv.visualColor,
			material = Enum.Material.Metal,
		})
	elseif componentId == "psu_redundant" then
		main = newPart({
			name = "BenchPSU",
			size = Vector3.new(1.2, 0.6, 1.0),
			cf = CFrame.new(0, 0.3, -0.5),
			color = defv.visualColor,
			material = Enum.Material.Metal,
		})
	else
		main = newPart({
			name = "BenchMisc",
			size = Vector3.new(0.6, 0.3, 0.6),
			cf = CFrame.new(0, 0.15, 0),
			color = defv.visualColor,
		})
	end
	main.Parent = model
	model.PrimaryPart = main
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

return ModelFactory
