--!strict
--[[
	ModelFactory (ModuleScript, ReplicatedStorage/Shared)
	Pabrik model 3D prosedural berskala ergonomis karakter Roblox (~5.2 studs):
	device rackable (1U=0.50 / 2U=1.04), rack (12U=7.6 / 24U=14.3 studs),
	workbench (tinggi meja 2.68), NOC desk (tinggi meja 2.58, monitor setinggi
	mata 2.9..5.2), dock, ISP uplink, beacon, AC unit, laptop, crate, komponen.
	Konvensi: semua model dibangun dengan pivot di titik tengah-bawah (lantai).
]]

local Catalog = require(script.Parent.HardwareCatalog)
local PlotConstants = require(script.Parent.PlotConstants)

type ItemDef = Catalog.ItemDef

local ModelFactory = {}

local C = PlotConstants.COLORS

-- Shared bright industrial palette for multi-part hardware detailing
local ALU_LIGHT = Color3.fromRGB(204, 212, 224)
local ALU_MID = Color3.fromRGB(162, 174, 190)
local SLATE_TRIM = Color3.fromRGB(72, 86, 106)
local NAVY_PANEL = Color3.fromRGB(48, 64, 88)
local FACE_LIGHT = Color3.fromRGB(230, 236, 244)
local PORT_SOCKET = Color3.fromRGB(52, 62, 76)
local GOLD_PIN = Color3.fromRGB(240, 196, 62)
local SAFETY_YELLOW = Color3.fromRGB(245, 196, 48)
local CYAN_ACCENT = Color3.fromRGB(56, 189, 248)
local ESD_BLUE = Color3.fromRGB(64, 134, 198)
local OAK_WOOD = Color3.fromRGB(204, 164, 118)

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
	p.Color = props.color or ALU_MID
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.canCollide ~= nil then props.canCollide else false
	p.Anchored = if props.anchored ~= nil then props.anchored else true
	if props.castShadow ~= nil then
		p.CastShadow = props.castShadow
	end
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

-- Human-scale rack dimensions (1U = 0.50 studs, 2U = 1.04 studs; fits inside 5.6-wide rack)
function ModelFactory.DeviceDimensions(itemId: string): (number, number, number, number)
	-- return: width, height, depth, uSize
	local def = Catalog.Get(itemId)
	local uSize = if def then def.uSize else 1
	local width = 4.4
	local depth = 2.6
	if itemId == "switch_8p" then
		width = 4.4
	elseif itemId == "switch_24p" then
		width = 4.8
	elseif itemId == "router_edge" then
		width = 4.6
	elseif itemId == "bm_starter" or itemId == "bm_enterprise" then
		width = 4.4
		depth = 2.8
	end
	local height = if uSize <= 1 then 0.50 else 1.04
	return width, height, depth, uSize
end

function ModelFactory.ComputeFootprint(itemId: string): (number, number)
	local width, _, depth, _ = ModelFactory.DeviceDimensions(itemId)
	if itemId == "rack_12u" or itemId == "rack_24u" then
		return 2.9, 1.8
	end
	return width / 2 + 0.2, depth / 2 + 0.2
end

--[[
	BuildDeviceModel: model device rackable/freeform berskala 1U/2U realistis,
	lengkap dengan faceplate, drive bays (server), rack ears, port berkode warna,
	console port belakang, status LED, dan smoke emitter.
	Mengembalikan: model, ports (portId -> ref), consoleAttachment, statusLED, smoke
]]
function ModelFactory.BuildDeviceModel(itemId: string, deviceId: string): (Model, { [string]: PortRef }, Attachment, Part, ParticleEmitter)
	local def = Catalog.Get(itemId)
	assert(def ~= nil, "Item tidak ada di katalog: " .. itemId)
	local defv = def :: ItemDef
	local width, height, depth, uSize = ModelFactory.DeviceDimensions(itemId)
	local isServer = defv.category == "Server" or string.sub(itemId, 1, 8) == "chassis_"

	local model = Instance.new("Model")
	model.Name = defv.name

	-- Main powder-coated chassis
	local chassis = newPart({
		name = "Chassis",
		size = Vector3.new(width, height, depth),
		cf = CFrame.new(0, height / 2, 0),
		color = defv.visualColor,
		material = Enum.Material.SmoothPlastic,
	})
	chassis.Parent = model

	-- Silver top airflow panel
	newPart({
		name = "TopGrille",
		size = Vector3.new(width - 0.5, 0.04, depth - 0.6),
		cf = CFrame.new(0, height + 0.02, -0.08),
		color = ALU_LIGHT,
	}).Parent = model

	-- Rack-mount ears (brushed silver flanges on left & right)
	for _, side in ipairs({ -1, 1 }) do
		newPart({
			name = "RackEar",
			size = Vector3.new(0.22, height - 0.06, 0.12),
			cf = CFrame.new(side * (width / 2 + 0.09), height / 2, depth / 2 - 0.05),
			color = ALU_LIGHT,
		}).Parent = model
	end

	-- Contrasting front faceplate bezel
	local faceplateColor = if isServer then FACE_LIGHT else NAVY_PANEL
	newPart({
		name = "Faceplate",
		size = Vector3.new(width - 0.14, height - 0.08, 0.06),
		cf = CFrame.new(0, height / 2, depth / 2 + 0.02),
		color = faceplateColor,
	}).Parent = model

	-- Category-specific front detailing
	if isServer then
		local bayCount = 4
		local bayAreaW = width - 1.35
		local bayW = (bayAreaW - 0.28) / bayCount
		local bayH = math.min(0.46, height * 0.44)
		for i = 1, bayCount do
			local bx = -bayAreaW / 2 + (i - 0.5) * (bayAreaW / bayCount) - 0.22
			newPart({
				name = "DriveBay_" .. i,
				size = Vector3.new(bayW, bayH, 0.08),
				cf = CFrame.new(bx, bayH / 2 + 0.14, depth / 2 + 0.06),
				color = SLATE_TRIM,
			}).Parent = model
			newPart({
				name = "DriveLatch_" .. i,
				size = Vector3.new(0.11, bayH - 0.08, 0.1),
				cf = CFrame.new(bx + bayW / 2 - 0.09, bayH / 2 + 0.14, depth / 2 + 0.07),
				color = CYAN_ACCENT,
			}).Parent = model
		end
		newPart({
			name = "AccentStrip",
			size = Vector3.new(width - 0.35, 0.07, 0.08),
			cf = CFrame.new(0, height - 0.1, depth / 2 + 0.06),
			color = if itemId == "bm_enterprise" then GOLD_PIN else CYAN_ACCENT,
		}).Parent = model
	else
		local stripeColor = if itemId == "router_edge" then SAFETY_YELLOW else CYAN_ACCENT
		newPart({
			name = "BrandStripe",
			size = Vector3.new(width - 0.25, 0.06, 0.08),
			cf = CFrame.new(0, 0.07, depth / 2 + 0.06),
			color = stripeColor,
		}).Parent = model
	end

	-- Status LED (bright neon indicator on front-right)
	local led = neon({
		name = "StatusLED",
		size = Vector3.new(0.22, 0.1, 0.09),
		cf = CFrame.new(width / 2 - 0.28, height - 0.12, depth / 2 + 0.07),
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
	smoke.Size = NumberSequence.new(0.4)
	smoke.Color = ColorSequence.new(Color3.fromRGB(165, 170, 180))
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
		local usable = width - 0.95
		local step = if perRow > 1 then usable / (perRow - 1) else 0
		local portW = if rows == 2 then 0.22 else 0.34
		local portH = if rows == 2 then 0.14 else 0.22
		for idx, spec in ipairs(portsSpec) do
			local rowIdx = if rows == 2 then (if idx <= perRow then 0 else 1) else 0
			local colIdx = if rows == 2 then ((idx - 1) % perRow) else (idx - 1)
			local px: number
			if isServer then
				px = width / 2 - 0.52 - (if perRow > 1 then (colIdx * 0.45) else 0)
			else
				px = if perRow > 1 then (-usable / 2 - 0.08) + colIdx * step else 0
			end
			local py = if rows == 2
				then (height * 0.68 - rowIdx * 0.22)
				else (height * 0.54)

			local collarColor = ALU_LIGHT
			if spec.portType == "WAN" then
				collarColor = SAFETY_YELLOW
			elseif spec.portType == "SFP" then
				collarColor = CYAN_ACCENT
			end
			local isCopper = spec.portType == "RJ45" or spec.portType == "WAN"

			-- Every visible port sub-part carries the port attributes and a
			-- ClickDetector so the whole socket (not just the jack) is a
			-- valid click target. RackAndCablingSystem.HookDevice binds any
			-- ClickDetector named "Click" whose parent has PortId/DeviceId.
			local function tagPort(part: BasePart): BasePart
				part:SetAttribute("PortId", spec.id)
				part:SetAttribute("PortType", spec.portType)
				part:SetAttribute("DeviceId", deviceId)
				local cd = Instance.new("ClickDetector")
				cd.Name = "Click"
				cd.MaxActivationDistance = 45
				cd.Parent = part
				return part
			end

			-- Socket jack: dark recess created first so PortId lookups and the
			-- pending-cable SelectionBox resolve to the socket itself. It also
			-- carries the PortAttach used as the cable beam anchor.
			local portPart = tagPort(newPart({
				name = "Port_" .. spec.id,
				size = Vector3.new(portW, portH, 0.16),
				cf = CFrame.new(px, py, depth / 2 + 0.09),
				color = PORT_SOCKET,
			}))
			portPart.Parent = model

			local attach = Instance.new("Attachment")
			attach.Name = "PortAttach"
			attach.CFrame = CFrame.new(0, 0, 0.11)
			attach.Parent = portPart

			-- Collar bezel behind the jack (clickable -> same port)
			local framePart = tagPort(newPart({
				name = "PortFrame_" .. spec.id,
				size = Vector3.new(portW + 0.08, portH + 0.08, 0.08),
				cf = CFrame.new(px, py, depth / 2 + 0.04),
				color = collarColor,
			}))
			framePart.Parent = model

			-- Connector mouth detail: RJ45/WAN get a recessed tongue with gold
			-- pins; SFP gets a smaller cage with a cyan latch slot.
			if isCopper then
				local mouth = tagPort(newPart({
					name = "PortMouth_" .. spec.id,
					size = Vector3.new(portW * 0.78, portH * 0.52, 0.05),
					cf = CFrame.new(px, py, depth / 2 + 0.145),
					color = Color3.fromRGB(34, 42, 54),
				}))
				mouth.Parent = model
				local pins = tagPort(newPart({
					name = "PortPins_" .. spec.id,
					size = Vector3.new(portW * 0.72, 0.03, 0.02),
					cf = CFrame.new(px, py - portH * 0.24, depth / 2 + 0.172),
					color = GOLD_PIN,
				}))
				pins.Parent = model
			else
				local cage = tagPort(newPart({
					name = "PortCage_" .. spec.id,
					size = Vector3.new(portW * 0.72, portH * 0.72, 0.06),
					cf = CFrame.new(px, py, depth / 2 + 0.14),
					color = Color3.fromRGB(30, 36, 48),
				}))
				cage.Parent = model
				local slot = tagPort(newPart({
					name = "PortSlot_" .. spec.id,
					size = Vector3.new(portW * 0.5, 0.02, 0.02),
					cf = CFrame.new(px, py, depth / 2 + 0.172),
					color = CYAN_ACCENT,
				}))
				slot.Parent = model
			end

			local portLed = neon({
				name = "PortLED_" .. spec.id,
				size = Vector3.new(math.min(0.14, portW * 0.5), 0.06, 0.07),
				cf = CFrame.new(px, py - portH / 2 - 0.05, depth / 2 + 0.11),
				color = C.ledOff,
			})
			portLed:SetAttribute("PortId", spec.id)
			portLed:SetAttribute("DeviceId", deviceId)
			portLed.Parent = model

			ports[spec.id] = { portId = spec.id, portType = spec.portType, part = portPart, attachment = attach, led = portLed }
		end
	end

	-- Console port (belakang, biru terang + collar silver)
	newPart({
		name = "ConsoleCollar",
		size = Vector3.new(0.58, math.min(0.42, height - 0.06), 0.12),
		cf = CFrame.new(0, height / 2, -depth / 2 - 0.04),
		color = ALU_LIGHT,
	}).Parent = model
	local consolePart = neon({
		name = "ConsolePort",
		size = Vector3.new(0.44, math.min(0.32, height - 0.12), 0.18),
		cf = CFrame.new(0, height / 2, -depth / 2 - 0.09),
		color = C.consoleBlue,
	})
	consolePart:SetAttribute("ConsoleDeviceId", deviceId)
	consolePart.Parent = model
	local consoleAttach = Instance.new("Attachment")
	consoleAttach.Name = "ConsoleAttach"
	consoleAttach.CFrame = CFrame.new(0, 0, -0.1)
	consoleAttach.Parent = consolePart

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ConsolePrompt"
	prompt.ActionText = "Console"
	prompt.ObjectText = defv.name
	prompt.HoldDuration = 0
	-- Small close-range card, lifted so it does not cover RJ45 clicks.
	prompt.MaxActivationDistance = 7
	prompt.UIOffset = Vector3.new(0, 44, 0)
	prompt.RequiresLineOfSight = false
	prompt.Parent = consolePart

	model:SetAttribute("DeviceId", deviceId)
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("USize", uSize)
	model.WorldPivot = CFrame.new(0, 0, 0)

	return model, ports, consoleAttach, led, smoke
end

--[[
	BuildRack: rak enterprise proporsional (12U = ~7.6 studs, 24U = ~14.3 studs)
	dengan plinth bawah, rail U silver, header LED, dan vertical PDU strip.
	SlotFrame diposisikan di z = -0.80 sehingga offset +0.95 dari BuildFacility
	mendudukkan device rata rapi di dalam kabinet rak.
]]
function ModelFactory.BuildRack(itemId: string, rackId: string): (Model, { [number]: Attachment }, Part)
	local def = Catalog.Get(itemId)
	assert(def ~= nil, "Item tidak ada di katalog: " .. itemId)
	local defv = def :: ItemDef
	local maxU = defv.specs.maxU
	local slotH = 0.56
	local baseH = 0.55
	local bodyH = maxU * slotH + baseH
	local w = 5.6
	local d = 3.2

	local model = Instance.new("Model")
	model.Name = defv.name

	-- Bottom plinth base
	newPart({
		name = "BasePlinth",
		size = Vector3.new(w, baseH * 0.85, d),
		cf = CFrame.new(0, baseH * 0.425, 0),
		color = SLATE_TRIM,
		canCollide = true,
	}).Parent = model

	-- Back panel (clean slate blue-grey)
	newPart({
		name = "BackPanel",
		size = Vector3.new(w - 0.35, bodyH - baseH * 0.5, 0.16),
		cf = CFrame.new(0, bodyH / 2 + 0.15, -d / 2 + 0.08),
		color = defv.visualColor,
		canCollide = true,
	}).Parent = model

	-- 4 vertical corner posts + brushed silver front U-rails + side braces
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			newPart({
				name = "Post",
				size = Vector3.new(0.32, bodyH, 0.32),
				cf = CFrame.new(sx * (w / 2 - 0.18), bodyH / 2, sz * (d / 2 - 0.18)),
				color = SLATE_TRIM,
				canCollide = true,
			}).Parent = model
		end
		-- Brushed aluminum front U-mounting rail
		newPart({
			name = "FrontRail",
			size = Vector3.new(0.16, bodyH - baseH, 0.14),
			cf = CFrame.new(sx * (w / 2 - 0.44), baseH + (bodyH - baseH) / 2, d / 2 - 0.22),
			color = ALU_LIGHT,
		}).Parent = model
		-- Side horizontal cross-braces
		for _, frac in ipairs({ 0.36, 0.72 }) do
			newPart({
				name = "SideBrace",
				size = Vector3.new(0.14, 0.2, d - 0.6),
				cf = CFrame.new(sx * (w / 2 - 0.18), bodyH * frac, 0),
				color = ALU_MID,
			}).Parent = model
		end
	end

	-- Top cap roof + illuminated front header LED bar
	newPart({
		name = "TopCap",
		size = Vector3.new(w + 0.16, 0.36, d + 0.16),
		cf = CFrame.new(0, bodyH + 0.18, 0),
		color = SLATE_TRIM,
		canCollide = true,
	}).Parent = model
	neon({
		name = "RackHeaderLED",
		size = Vector3.new(w - 0.6, 0.12, 0.1),
		cf = CFrame.new(0, bodyH + 0.18, d / 2 + 0.09),
		color = if itemId == "rack_24u" then GOLD_PIN else CYAN_ACCENT,
	}).Parent = model

	-- High-visibility vertical PDU power strip (right rear)
	local pduH = math.max(3.6, bodyH - 1.0)
	local pdu = newPart({
		name = "PDU_Strip",
		size = Vector3.new(0.42, pduH, 0.42),
		cf = CFrame.new(w / 2 - 0.44, pduH / 2 + 0.55, -d / 2 + 0.55),
		color = NAVY_PANEL,
		canCollide = true,
	})
	pdu.Parent = model
	newPart({
		name = "PDUStripe",
		size = Vector3.new(0.1, pduH - 0.3, 0.44),
		cf = CFrame.new(w / 2 - 0.64, pduH / 2 + 0.55, -d / 2 + 0.55),
		color = Color3.fromRGB(235, 90, 70),
	}).Parent = model
	local outletCount = math.clamp(math.floor(pduH / 1.1), 4, 8)
	for i = 1, outletCount do
		local oy = 0.9 + (i - 0.5) * ((pduH - 0.9) / outletCount)
		newPart({
			name = "PDUOutlet_" .. i,
			size = Vector3.new(0.24, 0.28, 0.1),
			cf = CFrame.new(w / 2 - 0.44, oy, -d / 2 + 0.78),
			color = FACE_LIGHT,
		}).Parent = model
	end
	local pduLed = neon({
		name = "PDULed",
		size = Vector3.new(0.22, 0.22, 0.12),
		cf = CFrame.new(w / 2 - 0.44, pduH + 0.2, -d / 2 + 0.78),
		color = C.ledGreen,
	})
	pduLed.Parent = model
	local pduClick = Instance.new("ClickDetector")
	pduClick.Name = "PDUClick"
	pduClick.MaxActivationDistance = 45
	pduClick.Parent = pdu

	-- Slot attachments: z = -0.80 so WorldCFrame * CFrame.new(0, 0, 0.95) puts
	-- mounted devices at z = +0.15 (front faceplate flush with front rack rails).
	local slots: { [number]: Attachment } = {}
	local slotFrame = newPart({
		name = "SlotFrame",
		size = Vector3.new(w - 0.8, 0.08, 0.08),
		cf = CFrame.new(0, baseH, -0.80),
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

--[[
	BuildWorkbench: meja rakit ergonomis (permukaan 2.68 studs, ESD mat 2.72)
	dengan kayu oak cerah, pegboard alat, lampu kerja LED (5.1 studs), dan saklar merah.
]]
function ModelFactory.BuildWorkbench(): (Model, { [number]: Attachment }, Part, Part)
	local model = Instance.new("Model")
	model.Name = "AssemblyWorkbench"

	-- Warm light oak butcher-block tabletop (surface at y = 2.68)
	local top = newPart({
		name = "BenchTop",
		size = Vector3.new(8.6, 0.28, 4.0),
		cf = CFrame.new(0, 2.54, 0),
		color = OAK_WOOD,
		material = Enum.Material.Wood,
		canCollide = true,
	})
	top.Parent = model

	-- Blue anti-static ESD mat on bench surface (top at y = 2.72)
	newPart({
		name = "ESDMat",
		size = Vector3.new(6.8, 0.04, 3.1),
		cf = CFrame.new(-0.4, 2.70, 0.1),
		color = ESD_BLUE,
	}).Parent = model

	-- Silver tubular industrial frame legs + lower storage shelf
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			newPart({
				name = "Leg",
				size = Vector3.new(0.34, 2.4, 0.34),
				cf = CFrame.new(sx * 3.9, 1.2, sz * 1.65),
				color = ALU_MID,
				canCollide = true,
			}).Parent = model
		end
	end
	newPart({
		name = "LowerShelf",
		size = Vector3.new(7.6, 0.14, 3.1),
		cf = CFrame.new(0, 0.65, 0),
		color = ALU_LIGHT,
		canCollide = true,
	}).Parent = model

	-- Eye-level tool pegboard backpanel (y = 2.68..4.98) + overhead task light (y = 5.1)
	newPart({
		name = "BackPanel",
		size = Vector3.new(8.6, 2.3, 0.22),
		cf = CFrame.new(0, 3.83, -1.89),
		color = Color3.fromRGB(136, 150, 168),
		canCollide = true,
	}).Parent = model
	newPart({
		name = "ToolTray",
		size = Vector3.new(3.4, 0.2, 0.45),
		cf = CFrame.new(-1.8, 3.35, -1.58),
		color = SAFETY_YELLOW,
	}).Parent = model
	newPart({
		name = "ScrewdriverA",
		size = Vector3.new(0.14, 0.95, 0.14),
		cf = CFrame.new(1.9, 3.95, -1.72),
		color = Color3.fromRGB(235, 92, 68),
	}).Parent = model
	newPart({
		name = "ScrewdriverB",
		size = Vector3.new(0.14, 0.8, 0.14),
		cf = CFrame.new(2.35, 3.88, -1.72),
		color = CYAN_ACCENT,
	}).Parent = model
	newPart({
		name = "TaskLightHood",
		size = Vector3.new(8.6, 0.22, 1.35),
		cf = CFrame.new(0, 5.08, -1.35),
		color = SLATE_TRIM,
	}).Parent = model
	local taskBar = neon({
		name = "TaskLightBar",
		size = Vector3.new(7.4, 0.1, 0.42),
		cf = CFrame.new(0, 4.94, -1.05),
		color = Color3.fromRGB(250, 252, 255),
	})
	taskBar.Parent = model
	local taskLight = Instance.new("SurfaceLight")
	taskLight.Face = Enum.NormalId.Bottom
	taskLight.Range = 12
	taskLight.Brightness = 1.5
	taskLight.Angle = 120
	taskLight.Parent = taskBar

	-- Snap attachments flush on ESD mat (2.54 + 0.18 = 2.72)
	local snaps: { [number]: Attachment } = {}
	for i = 1, 6 do
		local a = Instance.new("Attachment")
		a.Name = "Snap_" .. i
		a.CFrame = CFrame.new(-3.25 + (i - 1) * 1.3, 0.18, 0)
		a.Parent = top
		snaps[i] = a
	end

	-- Power switch box + red clickable switch + bright LED on right edge of bench
	newPart({
		name = "SwitchHousing",
		size = Vector3.new(0.88, 0.24, 0.88),
		cf = CFrame.new(3.65, 2.80, 1.25),
		color = ALU_LIGHT,
	}).Parent = model
	local switchPart = newPart({
		name = "PowerSwitch",
		size = Vector3.new(0.62, 0.36, 0.36),
		cf = CFrame.new(3.65, 3.04, 1.25),
		color = Color3.fromRGB(230, 68, 68),
	})
	switchPart.Parent = model
	local switchClick = Instance.new("ClickDetector")
	switchClick.Name = "BenchPowerClick"
	switchClick.MaxActivationDistance = 45
	switchClick.Parent = switchPart

	local benchLed = neon({
		name = "BenchLed",
		size = Vector3.new(0.26, 0.18, 0.12),
		cf = CFrame.new(3.65, 3.34, 1.25),
		color = C.ledOff,
	})
	benchLed.Parent = model

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, snaps, switchPart, benchLed
end

--[[
	BuildNOCDesk: konsol operasi NOC ergonomis (tinggi meja 2.58 studs,
	3 monitor widescreen melengkung tepat setinggi mata di y = 2.88..5.22,
	PixelsPerStud = 78 agar layout SurfaceGui 180px pas & tajam).
]]
function ModelFactory.BuildNOCDesk(): (Model, { [string]: Part })
	local model = Instance.new("Model")
	model.Name = "NOCDesk"

	-- Human-scale command-center desktop (surface at y = 2.58)
	local top = newPart({
		name = "DeskTop",
		size = Vector3.new(11.6, 0.28, 4.0),
		cf = CFrame.new(0, 2.44, 0),
		color = Color3.fromRGB(216, 222, 232),
		canCollide = true,
	})
	top.Parent = model

	-- Cobalt-blue modesty panel + cyan LED front accent trim
	newPart({
		name = "FrontPanel",
		size = Vector3.new(10.6, 1.7, 0.2),
		cf = CFrame.new(0, 1.45, -1.75),
		color = Color3.fromRGB(64, 118, 198),
		canCollide = true,
	}).Parent = model
	neon({
		name = "DeskAccentLED",
		size = Vector3.new(11.4, 0.08, 0.1),
		cf = CFrame.new(0, 2.32, 2.02),
		color = CYAN_ACCENT,
	}).Parent = model

	-- Brushed silver legs
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			newPart({
				name = "Leg",
				size = Vector3.new(0.34, 2.3, 0.34),
				cf = CFrame.new(sx * 5.3, 1.15, sz * 1.65),
				color = ALU_MID,
				canCollide = true,
			}).Parent = model
		end
	end

	-- Articulated monitor arm rail behind monitors
	newPart({
		name = "MonitorBar",
		size = Vector3.new(8.6, 0.18, 0.18),
		cf = CFrame.new(0, 3.65, -1.35),
		color = ALU_LIGHT,
	}).Parent = model
	newPart({
		name = "MonitorCenterPost",
		size = Vector3.new(0.28, 1.35, 0.28),
		cf = CFrame.new(0, 3.2, -1.35),
		color = ALU_MID,
	}).Parent = model

	-- 3 eye-level widescreen monitors (y = 2.88..5.23), gently angled toward operator
	local monitors: { [string]: Part } = {}
	local specs = {
		{ name = "TopologyMonitor", x = -3.65, z = -0.82, yaw = 12 },
		{ name = "TicketMonitor", x = 0, z = -1.12, yaw = 0 },
		{ name = "TelemetryMonitor", x = 3.65, z = -0.82, yaw = -12 },
	}
	for _, m in ipairs(specs) do
		local baseCF = CFrame.new(m.x, 4.05, m.z) * CFrame.Angles(0, math.rad(m.yaw), 0) * CFrame.Angles(math.rad(-4), 0, 0)
		newPart({
			name = m.name .. "_Stand",
			size = Vector3.new(0.24, 1.25, 0.24),
			cf = CFrame.new(m.x, 3.18, m.z - 0.16),
			color = ALU_MID,
		}).Parent = model

		local screen = newPart({
			name = m.name,
			size = Vector3.new(3.5, 2.35, 0.16),
			cf = baseCF,
			color = Color3.fromRGB(16, 22, 32),
		})
		screen.Parent = model

		-- Slim silver monitor back bezel
		newPart({
			name = m.name .. "_Bezel",
			size = Vector3.new(3.68, 2.52, 0.12),
			cf = baseCF * CFrame.new(0, 0, -0.11),
			color = ALU_LIGHT,
		}).Parent = model

		local gui = Instance.new("SurfaceGui")
		gui.Name = "SurfaceGui"
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 78 -- 3.5*78=273px x 2.35*78=183px (matches NOCMonitorClient layout)
		gui.Face = Enum.NormalId.Back
		gui.Brightness = 2
		gui.Parent = screen

		local root = Instance.new("Frame")
		root.Name = "Root"
		root.Size = UDim2.new(1, 0, 1, 0)
		root.BackgroundTransparency = 1
		root.Parent = gui

		monitors[m.name] = screen
	end

	-- Desk accessories scaled to desktop height (y = 2.58)
	newPart({
		name = "DeskMat",
		size = Vector3.new(4.6, 0.03, 1.65),
		cf = CFrame.new(0, 2.60, 0.75),
		color = NAVY_PANEL,
	}).Parent = model
	newPart({
		name = "Keyboard",
		size = Vector3.new(2.2, 0.1, 0.78),
		cf = CFrame.new(-0.35, 2.65, 0.75),
		color = ALU_LIGHT,
	}).Parent = model
	neon({
		name = "KeyboardGlow",
		size = Vector3.new(2.05, 0.03, 0.64),
		cf = CFrame.new(-0.35, 2.71, 0.75),
		color = CYAN_ACCENT,
	}).Parent = model
	newPart({
		name = "Mouse",
		size = Vector3.new(0.36, 0.1, 0.58),
		cf = CFrame.new(1.35, 2.65, 0.78),
		color = FACE_LIGHT,
	}).Parent = model
	newPart({
		name = "CoffeeMug",
		shape = "Cylinder",
		size = Vector3.new(0.58, 0.44, 0.44),
		cf = CFrame.new(4.1, 2.88, 0.85) * CFrame.Angles(0, 0, math.rad(90)),
		color = Color3.fromRGB(56, 178, 172),
	}).Parent = model

	-- Ergonomic swivel office chair centered in front of the 3 monitors
	local chairCF = CFrame.new(0, 0, 2.75)
	newPart({
		name = "ChairBase",
		shape = "Cylinder",
		size = Vector3.new(0.18, 2.0, 2.0),
		cf = chairCF * CFrame.new(0, 0.12, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = ALU_MID,
	}).Parent = model
	newPart({
		name = "ChairStem",
		shape = "Cylinder",
		size = Vector3.new(1.25, 0.24, 0.24),
		cf = chairCF * CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = SLATE_TRIM,
	}).Parent = model
	newPart({
		name = "ChairSeat",
		size = Vector3.new(1.85, 0.26, 1.75),
		cf = chairCF * CFrame.new(0, 1.5, 0),
		color = Color3.fromRGB(56, 98, 168),
	}).Parent = model
	newPart({
		name = "ChairBack",
		size = Vector3.new(1.75, 2.1, 0.22),
		cf = chairCF * CFrame.new(0, 2.6, 0.82) * CFrame.Angles(math.rad(-8), 0, 0),
		color = Color3.fromRGB(56, 98, 168),
	}).Parent = model

	-- [E] ProximityPrompt to focus camera directly in front of the 3 NOC monitors
	local stationPrompt = Instance.new("ProximityPrompt")
	stationPrompt.Name = "NOCStationPrompt"
	stationPrompt.ActionText = "Access NOC Workstation"
	stationPrompt.ObjectText = "NOC Command Center (3 Monitors)"
	stationPrompt.KeyboardKeyCode = Enum.KeyCode.E
	stationPrompt.HoldDuration = 0
	stationPrompt.MaxActivationDistance = 12
	stationPrompt.RequiresLineOfSight = false
	stationPrompt.Parent = top

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, monitors
end

--[[
	BuildDockPad: platform loading dock industrial berskala rapi (10.4x10.4)
	dengan tepi kuning safety, 4 bollard sudut, dan zona hologram hijau.
]]
function ModelFactory.BuildDockPad(): (Model, CFrame)
	local model = Instance.new("Model")
	model.Name = "LoadingDock"

	newPart({
		name = "DockDeck",
		size = Vector3.new(10.4, 0.26, 10.4),
		cf = CFrame.new(0, 0.13, 0),
		color = Color3.fromRGB(190, 198, 210),
		material = Enum.Material.DiamondPlate,
		canCollide = true,
	}).Parent = model

	local frameDefs = {
		{ size = Vector3.new(10.6, 0.3, 0.36), cf = CFrame.new(0, 0.15, 5.2) },
		{ size = Vector3.new(10.6, 0.3, 0.36), cf = CFrame.new(0, 0.15, -5.2) },
		{ size = Vector3.new(0.36, 0.3, 10.0), cf = CFrame.new(5.2, 0.15, 0) },
		{ size = Vector3.new(0.36, 0.3, 10.0), cf = CFrame.new(-5.2, 0.15, 0) },
	}
	for i, fd in ipairs(frameDefs) do
		newPart({
			name = "SafetyTrim_" .. i,
			size = fd.size,
			cf = fd.cf,
			color = SAFETY_YELLOW,
		}).Parent = model
	end

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			newPart({
				name = "Bollard",
				shape = "Cylinder",
				size = Vector3.new(1.85, 0.44, 0.44),
				cf = CFrame.new(sx * 4.9, 0.925, sz * 4.9) * CFrame.Angles(0, 0, math.rad(90)),
				color = SAFETY_YELLOW,
				canCollide = true,
			}).Parent = model
		end
	end

	local pad = newPart({
		name = "DockPad",
		size = Vector3.new(9.2, 0.1, 9.2),
		cf = CFrame.new(0, 0.31, 0),
		color = Color3.fromRGB(64, 218, 134),
		material = Enum.Material.Neon,
		transparency = 0.55,
	})
	pad.Parent = model

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, CFrame.new(0, 0.36, 0)
end

--[[
	BuildISPUplink: kotak demarkasi fiber ISP setinggi tangan/mata (2.7..4.9)
	dengan pipa conduit fiber kuning menuju overhead cable tray (y = 15.2).
]]
function ModelFactory.BuildISPUplink(deviceId: string): (Model, Attachment, Part)
	local model = Instance.new("Model")
	model.Name = "ISP_Uplink"

	local box = newPart({
		name = "Chassis",
		size = Vector3.new(2.6, 2.2, 1.2),
		cf = CFrame.new(0, 3.8, 0),
		color = FACE_LIGHT,
		canCollide = true,
	})
	box.Parent = model

	newPart({
		name = "ISPBezel",
		size = Vector3.new(2.25, 1.8, 0.12),
		cf = CFrame.new(0, 3.8, 0.62),
		color = SLATE_TRIM,
	}).Parent = model
	newPart({
		name = "FiberStripe",
		size = Vector3.new(2.25, 0.22, 0.14),
		cf = CFrame.new(0, 4.55, 0.63),
		color = SAFETY_YELLOW,
	}).Parent = model

	-- Vertical yellow fiber conduit pipe climbing to overhead cable tray
	newPart({
		name = "FiberConduit",
		shape = "Cylinder",
		size = Vector3.new(10.3, 0.34, 0.34),
		cf = CFrame.new(0, 10.05, -0.15) * CFrame.Angles(0, 0, math.rad(90)),
		color = SAFETY_YELLOW,
	}).Parent = model

	local led = neon({
		name = "StatusLED",
		size = Vector3.new(0.26, 0.18, 0.1),
		cf = CFrame.new(0.82, 4.22, 0.72),
		color = C.ledGreen,
	})
	led.Parent = model

	newPart({
		name = "WANCollar",
		size = Vector3.new(0.62, 0.46, 0.14),
		cf = CFrame.new(0, 3.55, 0.7),
		color = SAFETY_YELLOW,
	}).Parent = model
	local wanPart = newPart({
		name = "Port_wan1",
		size = Vector3.new(0.46, 0.34, 0.2),
		cf = CFrame.new(0, 3.55, 0.77),
		color = PORT_SOCKET,
	})
	wanPart:SetAttribute("PortId", "wan1")
	wanPart:SetAttribute("PortType", "WAN")
	wanPart:SetAttribute("DeviceId", deviceId)
	wanPart.Parent = model

	local wanLed = neon({
		name = "PortLED_wan1",
		size = Vector3.new(0.2, 0.12, 0.08),
		cf = CFrame.new(0, 3.22, 0.77),
		color = C.ledGreen,
	})
	wanLed:SetAttribute("PortId", "wan1")
	wanLed:SetAttribute("DeviceId", deviceId)
	wanLed.Parent = model

	local attach = Instance.new("Attachment")
	attach.Name = "PortAttach"
	attach.CFrame = CFrame.new(0, 0, 0.12)
	attach.Parent = wanPart

	local function tagUplink(part: BasePart): BasePart
		part:SetAttribute("PortId", "wan1")
		part:SetAttribute("PortType", "WAN")
		part:SetAttribute("DeviceId", deviceId)
		local cd = Instance.new("ClickDetector")
		cd.Name = "Click"
		cd.MaxActivationDistance = 45
		cd.Parent = part
		return part
	end
	tagUplink(wanPart)

	-- Connector mouth + gold pins, matching the device port styling
	local uplinkMouth = tagUplink(newPart({
		name = "PortMouth_wan1",
		size = Vector3.new(0.36, 0.2, 0.05),
		cf = CFrame.new(0, 3.55, 0.85),
		color = Color3.fromRGB(34, 42, 54),
	}))
	uplinkMouth.Parent = model
	local uplinkPins = tagUplink(newPart({
		name = "PortPins_wan1",
		size = Vector3.new(0.3, 0.03, 0.02),
		cf = CFrame.new(0, 3.44, 0.878),
		color = GOLD_PIN,
	}))
	uplinkPins.Parent = model

	model:SetAttribute("DeviceId", deviceId)
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, attach, wanLed
end

--[[
	BuildBeacon: lampu alarm plafon dengan collar silver & lensa merah.
]]
function ModelFactory.BuildBeacon(): (Model, Part, PointLight)
	local model = Instance.new("Model")
	model.Name = "AlarmBeacon"

	newPart({
		name = "BeaconBase",
		shape = "Cylinder",
		size = Vector3.new(0.42, 1.25, 1.25),
		cf = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = ALU_LIGHT,
	}).Parent = model

	local lens = neon({
		name = "BeaconLens",
		shape = "Cylinder",
		size = Vector3.new(0.82, 0.88, 0.88),
		cf = CFrame.new(0, 0.58, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = C.ledRed,
		transparency = 0.2,
	})
	lens.Parent = model

	local light = Instance.new("PointLight")
	light.Name = "AlarmLight"
	light.Color = Color3.fromRGB(255, 70, 70)
	light.Range = 24
	light.Brightness = 0
	light.Parent = lens

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, lens, light
end

--[[
	BuildACUnit: unit CRAC dinding putih bersih dengan kipas silinder rata
	yang berputar mulus di Heartbeat.
]]
function ModelFactory.BuildACUnit(): (Model, Part)
	local model = Instance.new("Model")
	model.Name = "AC_Unit"

	local body = newPart({
		name = "ACBody",
		size = Vector3.new(1.4, 3.4, 5.0),
		cf = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(236, 242, 248),
		canCollide = true,
	})
	body.Parent = model

	newPart({
		name = "ACTrim",
		size = Vector3.new(1.46, 0.28, 5.06),
		cf = CFrame.new(0, 1.32, 0),
		color = Color3.fromRGB(82, 162, 224),
	}).Parent = model
	neon({
		name = "ACLed",
		size = Vector3.new(0.12, 0.16, 0.42),
		cf = CFrame.new(-0.74, 1.32, 1.85),
		color = CYAN_ACCENT,
	}).Parent = model

	for i = 1, 4 do
		newPart({
			name = "ACLouver_" .. i,
			size = Vector3.new(0.14, 0.18, 1.5),
			cf = CFrame.new(-0.72, -0.95 + i * 0.44, 1.4),
			color = ALU_MID,
		}).Parent = model
	end

	local fan = newPart({
		name = "ACFan",
		shape = "Cylinder",
		size = Vector3.new(0.24, 2.1, 2.1),
		cf = CFrame.new(-0.76, -0.12, -0.8),
		color = SLATE_TRIM,
	})
	fan.Parent = model

	local fanGui = Instance.new("SurfaceGui")
	fanGui.Name = "FanBlades"
	fanGui.Face = Enum.NormalId.Left
	fanGui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	fanGui.CanvasSize = Vector2.new(128, 128)
	fanGui.Parent = fan
	for _, rot in ipairs({ 0, 60, 120 }) do
		local blade = Instance.new("Frame")
		blade.AnchorPoint = Vector2.new(0.5, 0.5)
		blade.Position = UDim2.fromScale(0.5, 0.5)
		blade.Size = UDim2.new(0.86, 0, 0.16, 0)
		blade.Rotation = rot
		blade.BackgroundColor3 = ALU_LIGHT
		blade.BorderSizePixel = 0
		blade.Parent = fanGui
	end
	local hub = Instance.new("Frame")
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.26, 0.26)
	hub.BackgroundColor3 = CYAN_ACCENT
	hub.BorderSizePixel = 0
	hub.Parent = fanGui
	local hubCorner = Instance.new("UICorner")
	hubCorner.CornerRadius = UDim.new(1, 0)
	hubCorner.Parent = hub

	local cold = Instance.new("ParticleEmitter")
	cold.Name = "ColdAir"
	cold.Rate = 6
	cold.Lifetime = NumberRange.new(0.8, 1.4)
	cold.Speed = NumberRange.new(2, 4)
	cold.Size = NumberSequence.new(0.45)
	cold.Color = ColorSequence.new(Color3.fromRGB(165, 220, 255))
	cold.Transparency = NumberSequence.new(0.55, 1)
	cold.EmissionDirection = Enum.NormalId.Left
	cold.Parent = body

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model, fan
end

--[[
	BuildLaptop: ultrabook teknisi ringkas (1.6x1.15) pas di genggaman avatar.
]]
function ModelFactory.BuildLaptop(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "TechnicianLaptop"
	tool.ToolTip = "Click = SSH Terminal | Approach device + [E] = Console"
	tool.CanBeDropped = false

	local handle = newPart({
		name = "Handle",
		size = Vector3.new(1.6, 0.14, 1.15),
		cf = CFrame.new(0, 0, 0),
		color = ALU_LIGHT,
		anchored = false,
		canCollide = false,
	})
	handle.Parent = tool
	tool.Grip = CFrame.new(0, -0.1, 0.25)
	tool.GripPos = Vector3.new(0, -0.1, 0.25)

	local keydeck = newPart({
		name = "KeyDeck",
		size = Vector3.new(1.42, 0.03, 0.72),
		cf = CFrame.new(0, 0.08, -0.05),
		color = SLATE_TRIM,
		anchored = false,
		canCollide = false,
	})
	keydeck.Parent = tool
	local weldKey = Instance.new("WeldConstraint")
	weldKey.Part0 = handle
	weldKey.Part1 = keydeck
	weldKey.Parent = handle

	local lid = newPart({
		name = "Lid",
		size = Vector3.new(1.6, 1.05, 0.08),
		cf = CFrame.new(0, 0.54, -0.62) * CFrame.Angles(math.rad(-15), 0, 0),
		color = ALU_LIGHT,
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
	gui.PixelsPerStud = 70
	gui.Face = Enum.NormalId.Back
	gui.Brightness = 2
	gui.Parent = lid
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundColor3 = Color3.fromRGB(13, 20, 30)
	root.BorderSizePixel = 0
	root.Parent = gui
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -10, 1, -10)
	label.Position = UDim2.new(0, 5, 0, 5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.RobotoMono
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(0, 255, 128)
	label.Text = "[TECHNICIAN LAPTOP]\nClick = Terminal\nApproach + [E] = Console"
	label.Parent = root

	local serialAttach = Instance.new("Attachment")
	serialAttach.Name = "SerialPortAttachment"
	serialAttach.CFrame = CFrame.new(0.84, 0, 0)
	serialAttach.Parent = handle

	local kbLight = neon({
		name = "KBTrim",
		size = Vector3.new(1.4, 0.04, 0.07),
		cf = CFrame.new(0, 0.09, 0.4),
		color = CYAN_ACCENT,
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

--[[
	BuildWireCutter: gunting kabel teknisi (grip hitam + rahang oranye).
	Equipped: klik port yang tersambung untuk memotong kabel.
]]
function ModelFactory.BuildWireCutter(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "WireCutter"
	tool.ToolTip = "Click a connected port to cut the cable"
	tool.CanBeDropped = false

	local handle = newPart({
		name = "Handle",
		size = Vector3.new(0.28, 1.35, 0.28),
		cf = CFrame.new(0, 0, 0),
		color = Color3.fromRGB(34, 40, 50),
		material = Enum.Material.Rubber,
		anchored = false,
		canCollide = false,
	})
	handle.Parent = tool
	tool.Grip = CFrame.new(0, -0.15, 0.2)
	tool.GripPos = Vector3.new(0, -0.15, 0.2)

	-- Pivot bolt + two jaw halves at the head of the tool.
	local bolt = newPart({
		name = "PivotBolt",
		size = Vector3.new(0.34, 0.18, 0.34),
		cf = CFrame.new(0, 0.78, 0),
		color = ALU_LIGHT,
		shape = "Cylinder",
		anchored = false,
		canCollide = false,
	})
	bolt.Parent = tool
	local weldBolt = Instance.new("WeldConstraint")
	weldBolt.Part0 = handle
	weldBolt.Part1 = bolt
	weldBolt.Parent = handle

	for side = -1, 1, 2 do
		local jaw = newPart({
			name = "Jaw",
			size = Vector3.new(0.16, 0.62, 0.22),
			cf = CFrame.new(side * 0.18, 1.14, 0) * CFrame.Angles(0, 0, math.rad(side * -14)),
			color = Color3.fromRGB(240, 120, 44),
			material = Enum.Material.Metal,
			anchored = false,
			canCollide = false,
		})
		jaw.Parent = tool
		local weldJaw = Instance.new("WeldConstraint")
		weldJaw.Part0 = handle
		weldJaw.Part1 = jaw
		weldJaw.Parent = handle
	end

	local light = neon({
		name = "CutterLED",
		size = Vector3.new(0.1, 0.1, 0.1),
		cf = CFrame.new(0, 0.55, 0.16),
		color = CYAN_ACCENT,
		anchored = false,
		canCollide = false,
	})
	light.Parent = tool
	local weldLight = Instance.new("WeldConstraint")
	weldLight.Part0 = handle
	weldLight.Part1 = light
	weldLight.Parent = handle

	return tool
end

function ModelFactory.BuildCrate(label: string): Model
	local model = Instance.new("Model")
	model.Name = "Crate"

	local box = newPart({
		name = "CrateBox",
		size = Vector3.new(2.4, 1.9, 2.4),
		cf = CFrame.new(0, 0.95, 0),
		color = Color3.fromRGB(212, 168, 114),
		material = Enum.Material.Wood,
		canCollide = true,
	})
	box.Parent = model

	for _, y in ipairs({ 0.35, 1.55 }) do
		newPart({
			name = "CrateStrap",
			size = Vector3.new(2.5, 0.14, 2.5),
			cf = CFrame.new(0, y, 0),
			color = SLATE_TRIM,
		}).Parent = model
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.new(0, 180, 0, 40)
	bb.StudsOffset = Vector3.new(0, 1.9, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 60
	bb.Parent = box
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.GothamBold
	tl.TextScaled = true
	tl.TextColor3 = Color3.fromRGB(255, 240, 160)
	tl.TextStrokeTransparency = 0.35
	tl.Text = label
	tl.Parent = bb

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	Visual komponen yang nempel di workbench saat di-install (proporsional dengan ESD mat).
]]
function ModelFactory.BuildBenchComponentVisual(componentId: string): Model
	local def = Catalog.Get(componentId)
	assert(def ~= nil, "Komponen tidak dikenal: " .. componentId)
	local defv = def :: ItemDef
	local model = Instance.new("Model")
	model.Name = "Comp_" .. componentId

	local main: Part
	if componentId == "chassis_1u" or componentId == "chassis_2u" then
		local h = if componentId == "chassis_1u" then 0.50 else 1.04
		main = newPart({
			name = "BenchChassis",
			size = Vector3.new(3.2, h, 2.2),
			cf = CFrame.new(0, h / 2, 0),
			color = defv.visualColor,
		})
		neon({
			name = "StatusLED",
			size = Vector3.new(0.2, 0.1, 0.08),
			cf = CFrame.new(1.2, h - 0.12, 1.12),
			color = C.ledRed,
		}).Parent = model
	elseif componentId == "mobo_single" or componentId == "mobo_dual" then
		main = newPart({
			name = "BenchMobo",
			size = Vector3.new(1.6, 0.08, 1.4),
			cf = CFrame.new(0, 0.05, 0),
			color = defv.visualColor,
		})
		newPart({
			name = "SocketFrame",
			size = Vector3.new(0.45, 0.06, 0.45),
			cf = CFrame.new(-0.22, 0.11, -0.15),
			color = ALU_LIGHT,
		}).Parent = model
		newPart({
			name = "DimmSlot",
			size = Vector3.new(0.12, 0.08, 0.85),
			cf = CFrame.new(0.42, 0.12, 0),
			color = CYAN_ACCENT,
		}).Parent = model
	elseif string.sub(componentId, 1, 4) == "cpu_" then
		main = newPart({
			name = "BenchCPU",
			size = Vector3.new(0.48, 0.1, 0.48),
			cf = CFrame.new(0, 0.08, 0),
			color = defv.visualColor,
		})
		newPart({
			name = "CPUSubstrate",
			size = Vector3.new(0.56, 0.04, 0.56),
			cf = CFrame.new(0, 0.03, 0),
			color = Color3.fromRGB(48, 148, 92),
		}).Parent = model
	elseif string.sub(componentId, 1, 4) == "ram_" then
		main = newPart({
			name = "BenchRAM",
			size = Vector3.new(0.76, 0.28, 0.1),
			cf = CFrame.new(0, 0.18, 0),
			color = defv.visualColor,
		})
		newPart({
			name = "RAMPins",
			size = Vector3.new(0.72, 0.05, 0.09),
			cf = CFrame.new(0, 0.03, 0),
			color = GOLD_PIN,
		}).Parent = model
		neon({
			name = "RAMBar",
			size = Vector3.new(0.74, 0.05, 0.11),
			cf = CFrame.new(0, 0.34, 0),
			color = defv.visualColor,
		}).Parent = model
	elseif componentId == "nvme_1tb" then
		main = newPart({
			name = "BenchStorage",
			size = Vector3.new(0.72, 0.08, 0.36),
			cf = CFrame.new(0, 0.06, 0),
			color = defv.visualColor,
		})
		newPart({
			name = "NVMeEdge",
			size = Vector3.new(0.11, 0.06, 0.32),
			cf = CFrame.new(-0.35, 0.06, 0),
			color = GOLD_PIN,
		}).Parent = model
	elseif componentId == "psu_redundant" then
		main = newPart({
			name = "BenchPSU",
			size = Vector3.new(0.95, 0.48, 0.78),
			cf = CFrame.new(0, 0.25, 0),
			color = defv.visualColor,
		})
		newPart({
			name = "PSULabel",
			size = Vector3.new(0.56, 0.24, 0.04),
			cf = CFrame.new(0, 0.28, 0.4),
			color = SAFETY_YELLOW,
		}).Parent = model
	else
		main = newPart({
			name = "BenchMisc",
			size = Vector3.new(0.5, 0.24, 0.5),
			cf = CFrame.new(0, 0.13, 0),
			color = defv.visualColor,
		})
	end
	main.Parent = model
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

---------------------------------------------------------------------
-- Decorative 3D Data-Center Interior Props
---------------------------------------------------------------------

--[[
	BuildUPSBank: industrial Uninterruptible Power Supply battery bank +
	power distribution cabinet with glowing green battery level bars,
	high-voltage warning badge, and orange power conduits.
]]
function ModelFactory.BuildUPSBank(): Model
	local model = Instance.new("Model")
	model.Name = "UPS_BatteryBank"

	-- Twin cabinet bays
	for i = 0, 1 do
		local cx = -2.1 + i * 4.2
		newPart({
			name = "UPSBase_" .. i,
			size = Vector3.new(3.9, 0.35, 2.4),
			cf = CFrame.new(cx, 0.175, 0),
			color = SLATE_TRIM,
			canCollide = true,
		}).Parent = model
		newPart({
			name = "UPSCabinet_" .. i,
			size = Vector3.new(3.8, 6.4, 2.2),
			cf = CFrame.new(cx, 3.55, 0),
			color = NAVY_PANEL,
			canCollide = true,
		}).Parent = model
		newPart({
			name = "UPSDoor_" .. i,
			size = Vector3.new(3.4, 5.8, 0.12),
			cf = CFrame.new(cx, 3.55, 1.12),
			color = Color3.fromRGB(64, 82, 108),
		}).Parent = model
		-- 4 glowing green battery charge bars per cabinet
		for b = 1, 4 do
			neon({
				name = "BatteryBar_" .. i .. "_" .. b,
				size = Vector3.new(1.1, 0.16, 0.08),
				cf = CFrame.new(cx - 0.8, 2.2 + b * 0.48, 1.2),
				color = C.ledGreen,
			}).Parent = model
		end
		-- High-voltage yellow warning badge
		newPart({
			name = "VoltageBadge_" .. i,
			size = Vector3.new(0.65, 0.65, 0.08),
			cf = CFrame.new(cx + 0.85, 5.2, 1.2),
			color = SAFETY_YELLOW,
		}).Parent = model
		-- Orange power conduit rising to overhead cable tray
		newPart({
			name = "PowerConduit_" .. i,
			shape = "Cylinder",
			size = Vector3.new(8.5, 0.36, 0.36),
			cf = CFrame.new(cx, 11.0, -0.5) * CFrame.Angles(0, 0, math.rad(90)),
			color = Color3.fromRGB(238, 118, 48),
		}).Parent = model
	end

	-- Digital telemetry readout on left bay
	local disp = newPart({
		name = "UPSDisplay",
		size = Vector3.new(1.4, 0.85, 0.1),
		cf = CFrame.new(-1.15, 5.2, 1.2),
		color = Color3.fromRGB(14, 20, 28),
	})
	disp.Parent = model
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(200, 120)
	gui.Parent = disp
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -12, 1, -12)
	lbl.Position = UDim2.new(0, 6, 0, 6)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.RobotoMono
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.fromRGB(60, 245, 115)
	lbl.Text = "UPS BANK A+B\n480V ONLINE\nCHRG: 100%"
	lbl.Parent = gui

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildFireSuppression: FM-200 clean-agent fire suppression twin cylinders
	with brass valves, manifold piping, alarm release box, and wall extinguisher.
]]
function ModelFactory.BuildFireSuppression(): Model
	local model = Instance.new("Model")
	model.Name = "FM200_FireSuppression"

	-- Wall mounting backplate
	newPart({
		name = "Backplate",
		size = Vector3.new(5.4, 5.8, 0.18),
		cf = CFrame.new(0, 3.2, -0.55),
		color = ALU_MID,
	}).Parent = model

	-- Twin crimson FM-200 gas cylinders
	for i, cx in ipairs({ -1.35, 0.15 }) do
		newPart({
			name = "GasTank_" .. i,
			shape = "Cylinder",
			size = Vector3.new(4.2, 1.15, 1.15),
			cf = CFrame.new(cx, 2.1, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = Color3.fromRGB(208, 42, 46),
			canCollide = true,
		}).Parent = model
		newPart({
			name = "TankDome_" .. i,
			shape = "Cylinder",
			size = Vector3.new(0.45, 0.85, 0.85),
			cf = CFrame.new(cx, 4.35, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = Color3.fromRGB(185, 34, 38),
		}).Parent = model
		newPart({
			name = "BrassValve_" .. i,
			shape = "Cylinder",
			size = Vector3.new(0.55, 0.32, 0.32),
			cf = CFrame.new(cx, 4.78, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = GOLD_PIN,
		}).Parent = model
		newPart({
			name = "TankLabel_" .. i,
			size = Vector3.new(0.85, 1.1, 0.08),
			cf = CFrame.new(cx, 2.6, 0.56),
			color = FACE_LIGHT,
		}).Parent = model
	end

	-- Horizontal retaining strap + overhead discharge manifold
	newPart({
		name = "RetainingStrap",
		size = Vector3.new(3.1, 0.22, 1.26),
		cf = CFrame.new(-0.6, 2.4, 0),
		color = SLATE_TRIM,
	}).Parent = model
	newPart({
		name = "ManifoldPipe",
		shape = "Cylinder",
		size = Vector3.new(3.2, 0.24, 0.24),
		cf = CFrame.new(-0.6, 5.1, 0),
		color = ALU_LIGHT,
	}).Parent = model

	-- FM-200 release control panel on right side
	local ctrl = newPart({
		name = "ReleasePanel",
		size = Vector3.new(1.5, 1.9, 0.42),
		cf = CFrame.new(1.8, 3.6, -0.25),
		color = Color3.fromRGB(210, 46, 48),
	})
	ctrl.Parent = model
	neon({
		name = "ArmedLED",
		size = Vector3.new(0.24, 0.14, 0.08),
		cf = CFrame.new(1.8, 4.25, 0.0),
		color = C.ledGreen,
	}).Parent = model

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildStorageRack: 4-tier industrial shelving loaded with colorful cable
	spools, boxed spare hardware, and component organizer bins.
]]
function ModelFactory.BuildStorageRack(): Model
	local model = Instance.new("Model")
	model.Name = "HardwareStorageRack"

	local w = 7.4
	local d = 2.2
	local h = 6.2

	-- 4 vertical corner posts
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			newPart({
				name = "ShelfPost",
				size = Vector3.new(0.24, h, 0.24),
				cf = CFrame.new(sx * (w / 2 - 0.14), h / 2, sz * (d / 2 - 0.14)),
				color = SLATE_TRIM,
				canCollide = true,
			}).Parent = model
		end
	end

	-- 4 shelf decks
	local shelfHeights = { 0.45, 2.2, 3.95, 5.7 }
	for i, sy in ipairs(shelfHeights) do
		newPart({
			name = "ShelfDeck_" .. i,
			size = Vector3.new(w, 0.16, d),
			cf = CFrame.new(0, sy, 0),
			color = ALU_LIGHT,
			canCollide = true,
		}).Parent = model
	end

	-- Shelf 1 (bottom): wooden & cardboard shipping boxes
	for i, bx in ipairs({ -2.2, 0.1, 2.3 }) do
		newPart({
			name = "SpareBox_" .. i,
			size = Vector3.new(1.75, 1.3, 1.65),
			cf = CFrame.new(bx, 1.18, 0),
			color = if i == 2 then ALU_MID else OAK_WOOD,
			material = if i == 2 then Enum.Material.SmoothPlastic else Enum.Material.Wood,
		}).Parent = model
	end

	-- Shelf 2 (middle-low): colorful cable spools (Blue LAN, Yellow WAN, Red Mgmt)
	local spoolColors = {
		Color3.fromRGB(70, 130, 255),
		Color3.fromRGB(70, 130, 255),
		SAFETY_YELLOW,
		Color3.fromRGB(230, 80, 80),
	}
	for i, col in ipairs(spoolColors) do
		local sx = -2.55 + (i - 1) * 1.7
		newPart({
			name = "CableSpool_" .. i,
			shape = "Cylinder",
			size = Vector3.new(0.95, 1.05, 1.05),
			cf = CFrame.new(sx, 2.82, 0) * CFrame.Angles(0, 0, math.rad(90)),
			color = col,
		}).Parent = model
	end

	-- Shelf 3 (middle-high): anti-static component storage bins
	local binColors = { ESD_BLUE, CYAN_ACCENT, ESD_BLUE, SAFETY_YELLOW, ESD_BLUE }
	for i, col in ipairs(binColors) do
		local bx = -2.6 + (i - 1) * 1.3
		newPart({
			name = "PartBin_" .. i,
			size = Vector3.new(1.05, 0.85, 1.5),
			cf = CFrame.new(bx, 4.46, 0.1),
			color = col,
		}).Parent = model
	end

	-- Shelf 4 (top): spare 1U server chassis stack
	for i = 0, 1 do
		newPart({
			name = "SpareChassis_" .. i,
			size = Vector3.new(3.8, 0.42, 1.8),
			cf = CFrame.new(-1.1 + i * 2.4, 6.0, 0),
			color = ALU_MID,
		}).Parent = model
	end

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildPatchPanelWall: wall-mounted optical fiber & copper distribution
	cabinet with glowing port LEDs and overhead trunk conduits.
]]
function ModelFactory.BuildPatchPanelWall(): Model
	local model = Instance.new("Model")
	model.Name = "FiberDistributionPanel"

	newPart({
		name = "CabinetBody",
		size = Vector3.new(4.6, 3.8, 0.9),
		cf = CFrame.new(0, 4.2, 0),
		color = SLATE_TRIM,
		canCollide = true,
	}).Parent = model
	newPart({
		name = "GlassDoor",
		size = Vector3.new(4.2, 3.4, 0.08),
		cf = CFrame.new(0, 4.2, 0.46),
		color = C.glass,
		material = Enum.Material.Glass,
		transparency = 0.55,
	}).Parent = model

	-- 3 internal horizontal patch strips with blinking green/cyan fiber LEDs
	for r = 1, 3 do
		local py = 2.9 + r * 0.72
		newPart({
			name = "PatchRow_" .. r,
			size = Vector3.new(3.8, 0.36, 0.2),
			cf = CFrame.new(0, py, 0.22),
			color = NAVY_PANEL,
		}).Parent = model
		for c = 1, 8 do
			neon({
				name = "FiberLED_" .. r .. "_" .. c,
				size = Vector3.new(0.18, 0.1, 0.06),
				cf = CFrame.new(-1.6 + (c - 1) * 0.45, py, 0.34),
				color = if (r + c) % 3 == 0 then CYAN_ACCENT else C.ledGreen,
			}).Parent = model
		end
	end

	-- Dual trunk conduits (blue LAN + yellow fiber) climbing to cable tray
	for i, col in ipairs({ ESD_BLUE, SAFETY_YELLOW }) do
		newPart({
			name = "TrunkPipe_" .. i,
			shape = "Cylinder",
			size = Vector3.new(9.2, 0.3, 0.3),
			cf = CFrame.new(-0.9 + (i - 1) * 1.8, 10.6, -0.1) * CFrame.Angles(0, 0, math.rad(90)),
			color = col,
		}).Parent = model
	end

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildWallboard: sleek widescreen NOC operations LED wallboard sign.
]]
function ModelFactory.BuildWallboard(): Model
	local model = Instance.new("Model")
	model.Name = "NOC_Wallboard"

	newPart({
		name = "BoardFrame",
		size = Vector3.new(14.6, 3.4, 0.28),
		cf = CFrame.new(0, 0, 0),
		color = SLATE_TRIM,
	}).Parent = model
	local screen = newPart({
		name = "BoardScreen",
		size = Vector3.new(14.1, 2.95, 0.14),
		cf = CFrame.new(0, 0, 0.12),
		color = Color3.fromRGB(13, 19, 28),
	})
	screen.Parent = model
	neon({
		name = "BoardAccent",
		size = Vector3.new(14.1, 0.1, 0.16),
		cf = CFrame.new(0, 1.52, 0.13),
		color = CYAN_ACCENT,
	}).Parent = model

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(720, 150)
	gui.Brightness = 2
	gui.Parent = screen

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -24, 0.45, 0)
	title.Position = UDim2.new(0, 12, 0.08, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = CYAN_ACCENT
	title.Text = "TIER-IV CLOUD DATA CENTER  |  GLOBAL NOC OPERATIONS"
	title.Parent = gui

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, -24, 0.34, 0)
	sub.Position = UDim2.new(0, 12, 0.56, 0)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.RobotoMono
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(60, 245, 115)
	sub.Text = "BGP UPLINK: ONLINE   |   HVAC CRAC: OPTIMAL   |   FM-200: ARMED   |   ISO-27001"
	sub.Parent = gui

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildBreakCorner: technician staff lockers + water dispenser cooler.
]]
function ModelFactory.BuildBreakCorner(): Model
	local model = Instance.new("Model")
	model.Name = "TechnicianLockerStation"

	-- 3-bay brushed aluminum staff lockers
	for i = 0, 2 do
		local lx = -1.6 + i * 1.6
		newPart({
			name = "LockerBody_" .. i,
			size = Vector3.new(1.52, 5.6, 1.8),
			cf = CFrame.new(lx, 2.8, 0),
			color = ALU_MID,
			canCollide = true,
		}).Parent = model
		newPart({
			name = "LockerDoor_" .. i,
			size = Vector3.new(1.36, 5.1, 0.1),
			cf = CFrame.new(lx, 2.8, 0.92),
			color = if i == 1 then ESD_BLUE else ALU_LIGHT,
		}).Parent = model
		newPart({
			name = "LockerHandle_" .. i,
			size = Vector3.new(0.12, 0.48, 0.14),
			cf = CFrame.new(lx + 0.48, 2.8, 0.98),
			color = SLATE_TRIM,
		}).Parent = model
	end

	-- Water dispenser cooler + translucent blue water jug on right side
	newPart({
		name = "CoolerStand",
		size = Vector3.new(1.3, 3.2, 1.3),
		cf = CFrame.new(3.5, 1.6, 0),
		color = FACE_LIGHT,
		canCollide = true,
	}).Parent = model
	newPart({
		name = "CoolerRecess",
		size = Vector3.new(0.85, 0.75, 0.12),
		cf = CFrame.new(3.5, 2.35, 0.62),
		color = SLATE_TRIM,
	}).Parent = model
	newPart({
		name = "WaterJug",
		shape = "Cylinder",
		size = Vector3.new(1.45, 1.05, 1.05),
		cf = CFrame.new(3.5, 3.92, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color = Color3.fromRGB(88, 188, 250),
		material = Enum.Material.Glass,
		transparency = 0.3,
	}).Parent = model

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

--[[
	BuildOfficePlanter: modern architectural planter box with lush greenery.
]]
function ModelFactory.BuildOfficePlanter(): Model
	local model = Instance.new("Model")
	model.Name = "OfficePlanter"

	newPart({
		name = "PlanterBox",
		size = Vector3.new(2.8, 1.35, 1.4),
		cf = CFrame.new(0, 0.675, 0),
		color = FACE_LIGHT,
		canCollide = true,
	}).Parent = model
	newPart({
		name = "PlanterSoil",
		size = Vector3.new(2.5, 0.14, 1.1),
		cf = CFrame.new(0, 1.32, 0),
		color = Color3.fromRGB(92, 68, 48),
	}).Parent = model

	local bushColors = {
		Color3.fromRGB(58, 168, 92),
		Color3.fromRGB(74, 188, 106),
		Color3.fromRGB(52, 154, 84),
	}
	for i, bx in ipairs({ -0.8, 0, 0.8 }) do
		newPart({
			name = "Foliage_" .. i,
			size = Vector3.new(0.85, 1.55 + (i % 2) * 0.35, 0.85),
			cf = CFrame.new(bx, 2.05, 0),
			color = bushColors[i],
		}).Parent = model
	end

	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

return ModelFactory
