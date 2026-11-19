--!strict
--[[
	NOCMonitorClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	Mengisi 3 monitor SurfaceGui di NOC Desk milik plot pemain:
	- TopologyMonitor : kartu node device + garis edge (midpoint + atan2 rotation),
	  klik node -> popup info + tombol "Putus semua kabel" (CableActionRemote).
	- TicketMonitor   : daftar kontrak (Accept -> ContractActionRemote) + checklist objectives.
	- TelemetryMonitor: Saldo, Reputasi, Uptime, Daya, Suhu rata-rata, Hari/Jam + banner storm.

	Catatan tipe: mirror manual dari ReplicatedStorage/Shared/NetworkTypes (module type-only
	yang return nil; tidak bisa dipakai di posisi type lewat require path dinamis).
	Shell UI dibangun sekali per monitor (guard atribut "BuiltBy" pada Root); konten dinamis
	(node/edge topology, daftar tiket) di-rebuild tiap snapshot, label telemetri di-update.
	Semua teks GUI Bahasa Indonesia; komentar kode Bahasa Inggris.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkUtils = require(sharedFolder:WaitForChild("NetworkUtils"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[NOCMonitorClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local stateSyncRemote = remotesFolder:WaitForChild("StateSyncRemote") :: RemoteEvent
local contractRemote = remotesFolder:WaitForChild("ContractActionRemote") :: RemoteEvent
local cableRemote = remotesFolder:WaitForChild("CableActionRemote") :: RemoteEvent

-- ===== Palette =====
local COLOR_BG = Color3.fromRGB(13, 17, 23)
local COLOR_CARD = Color3.fromRGB(22, 27, 34)
local COLOR_ROW = Color3.fromRGB(28, 33, 41)
local COLOR_BORDER = Color3.fromRGB(48, 54, 61)
local COLOR_GREEN = Color3.fromRGB(0, 255, 102)
local COLOR_BLUE = Color3.fromRGB(88, 166, 255)
local COLOR_RED = Color3.fromRGB(255, 85, 85)
local COLOR_YELLOW = Color3.fromRGB(255, 216, 102)
local COLOR_GREY = Color3.fromRGB(139, 148, 158)
local COLOR_TEXT = Color3.fromRGB(201, 209, 217)

-- ===== Mirrored snapshot types (keep in sync with NetworkTypes) =====
type SnapDevice = {
	id: string,
	name: string,
	deviceType: string,
	ip: string?,
	isPowered: boolean,
	temperatureC: number,
	loadPercent: number,
	vmCount: number,
	peers: { string },
}

type SnapTicket = {
	id: string,
	category: string,
	title: string,
	description: string,
	rewardPayout: number,
	status: string,
	requirementsText: string,
}

type FacilitySnapshot = {
	plotIndex: number,
	balance: number,
	reputation: number,
	uptimePercent: number,
	powerWatts: number,
	avgTempC: number,
	storm: boolean,
	day: number,
	clockText: string,
	devices: { SnapDevice },
	vms: { any },
	objectives: { [string]: boolean },
	tickets: { SnapTicket },
}

-- ===== State =====
type MonitorRef = {
	part: BasePart,
	surfaceGui: SurfaceGui,
	root: Frame,
}

local monitorRefs: { [string]: MonitorRef } = {}
local lastPlotIndex: number? = nil

local topoCanvas: Frame? = nil
local topoPopup: Frame? = nil
local topoCanvasW = 264 -- px, recomputed at build time from part size x PixelsPerStud
local topoCanvasH = 164
local ticketsScroll: ScrollingFrame? = nil
local objectiveChecks: { [string]: TextLabel } = {}
local teleValues: { [string]: TextLabel } = {}
local stormBanner: Frame? = nil

local MONITOR_NAMES = { "TopologyMonitor", "TicketMonitor", "TelemetryMonitor" }

local OBJECTIVES: { { key: string, label: string } } = {
	{ key = "cableWired", label = "Kabel switch -> router & server" },
	{ key = "ipSetStarter", label = "Set IP server starter" },
	{ key = "osInstalledStarter", label = "Install OS server starter" },
	{ key = "pingGateway", label = "Ping gateway" },
	{ key = "vmCreated", label = "Buat VM pertama" },
	{ key = "benchBuilt", label = "Rakit server di bench" },
	{ key = "benchOsInstalled", label = "Bench: install OS" },
	{ key = "stressPassed", label = "Stress test" },
	{ key = "shipped", label = "Kirim crate" },
}

-- Row assignment per device type (top / middle / bottom), Y positions in canvas scale
local ROW_Y = { 0.12, 0.45, 0.78 }
local function rowIndexOf(deviceType: string): number
	if deviceType == "Router" then
		return 1
	elseif deviceType == "Switch" then
		return 2
	end
	return 3 -- BareMetal / ColocationServer / unknown
end

local function clearChildren(inst: Instance, keep: { Instance }?): ()
	local keepMap: { [Instance]: boolean } = {}
	if keep ~= nil then
		for _, k in ipairs(keep) do
			keepMap[k] = true
		end
	end
	for _, child in ipairs(inst:GetChildren()) do
		if not keepMap[child] and not child:IsA("UICorner") and not child:IsA("UIStroke") and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function makeTitle(parent: Instance, text: string): TextLabel
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -8, 0, 14)
	title.Position = UDim2.new(0, 4, 0, 2)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = COLOR_GREEN
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = text
	title.Parent = parent
	return title
end

-- ===== Monitor discovery =====
-- Moves each monitor's SurfaceGui into PlayerGui with Adornee = part so
-- TextButtons inside the SurfaceGui receive mouse clicks in Roblox.
local function findMonitorPart(plot: Instance, name: string): (BasePart?, SurfaceGui?, Frame?)
	for _, desc in ipairs(plot:GetDescendants()) do
		if desc.Name == name and desc:IsA("BasePart") then
			local part = desc :: BasePart
			-- Check if we already moved this part's SurfaceGui into PlayerGui
			for _, child in ipairs(playerGui:GetChildren()) do
				if child:IsA("SurfaceGui") and child.Adornee == part then
					local root = child:FindFirstChild("Root")
					if root ~= nil and root:IsA("Frame") then
						return part, child :: SurfaceGui, root :: Frame
					end
				end
			end
			local surfaceGui = part:FindFirstChild("SurfaceGui")
			if surfaceGui ~= nil and surfaceGui:IsA("SurfaceGui") then
				local sg = surfaceGui :: SurfaceGui
				local root = sg:FindFirstChild("Root")
				if root ~= nil and root:IsA("Frame") then
					sg.Name = "NetSimNOC_" .. name
					sg.Adornee = part
					sg.ResetOnSpawn = false
					sg.Parent = playerGui
					return part, sg, root :: Frame
				end
			end
		end
	end
	return nil, nil, nil
end

local function clearAllMonitorRefs()
	for name, ref in pairs(monitorRefs) do
		if ref.surfaceGui.Parent == playerGui then
			ref.surfaceGui:Destroy()
		end
		monitorRefs[name] = nil :: any
	end
end

local function resetContentCaches()
	topoCanvas = nil
	topoPopup = nil
	ticketsScroll = nil
	objectiveChecks = {}
	teleValues = {}
	stormBanner = nil
end

-- Reset only the dynamic-content caches of one monitor (used when its Root is rebuilt)
local function resetCachesFor(name: string)
	if name == "TopologyMonitor" then
		topoCanvas = nil
		topoPopup = nil
	elseif name == "TicketMonitor" then
		ticketsScroll = nil
		objectiveChecks = {}
	elseif name == "TelemetryMonitor" then
		teleValues = {}
		stormBanner = nil
	end
end

local function refreshMonitorRefs(plot: Instance)
	-- Drop refs whose plot was destroyed (facility rebuild / reset data)
	for name, ref in pairs(monitorRefs) do
		if ref.part.Parent == nil or ref.root.Parent == nil then
			if ref.surfaceGui.Parent == playerGui then
				ref.surfaceGui:Destroy()
			end
			monitorRefs[name] = nil :: any
		end
	end
	for _, name in ipairs(MONITOR_NAMES) do
		if monitorRefs[name] == nil then
			local part, sg, root = findMonitorPart(plot, name)
			if part ~= nil and sg ~= nil and root ~= nil then
				monitorRefs[name] = { part = part, surfaceGui = sg, root = root }
			end
		end
	end
end

-- ===== TopologyMonitor =====
local function buildTopology(ref: MonitorRef)
	local root = ref.root
	makeTitle(root, "TOPOLOGI JARINGAN")

	local canvas = Instance.new("Frame")
	canvas.Name = "TopoCanvas"
	canvas.Position = UDim2.new(0, 0, 0, 16)
	canvas.Size = UDim2.new(1, 0, 1, -16)
	canvas.BackgroundTransparency = 1
	canvas.Parent = root

	local surfaceGui = ref.surfaceGui
	local pps = 60
	if surfaceGui ~= nil and surfaceGui:IsA("SurfaceGui") then
		pps = surfaceGui.PixelsPerStud
	end
	topoCanvasW = math.max(64, ref.part.Size.X * pps)
	topoCanvasH = math.max(64, ref.part.Size.Y * pps - 16)

	local popup = Instance.new("Frame")
	popup.Name = "NodePopup"
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.fromScale(0.5, 0.5)
	popup.Size = UDim2.fromScale(0.86, 0.74)
	popup.BackgroundColor3 = COLOR_BG
	popup.BorderSizePixel = 0
	popup.ZIndex = 30
	popup.Visible = false
	popup.Parent = canvas
	local popupCorner = Instance.new("UICorner")
	popupCorner.CornerRadius = UDim.new(0, 6)
	popupCorner.Parent = popup
	local popupStroke = Instance.new("UIStroke")
	popupStroke.Color = COLOR_BLUE
	popupStroke.Thickness = 1.5
	popupStroke.Parent = popup

	topoCanvas = canvas
	topoPopup = popup
end

local function closePopup()
	if topoPopup ~= nil then
		topoPopup.Visible = false
	end
end

local function openNodePopup(dev: SnapDevice)
	local popup = topoPopup
	if popup == nil then
		return
	end
	clearChildren(popup)

	local title = Instance.new("TextLabel")
	title.Name = "PopupTitle"
	title.Size = UDim2.new(1, -40, 0.24, 0)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = COLOR_BLUE
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = dev.name
	title.ZIndex = 31
	title.Parent = popup

	local infoLines = string.format(
		"Tipe: %s\nIP: %s\nDaya: %s\nSuhu: %.1f C  |  Beban: %.0f%%  |  VM: %d\nPeer: %s",
		dev.deviceType,
		dev.ip or "-",
		if dev.isPowered then "ON" else "OFF",
		dev.temperatureC or 0,
		dev.loadPercent or 0,
		dev.vmCount or 0,
		if #dev.peers > 0 then table.concat(dev.peers, ", ") else "tidak ada"
	)
	local info = Instance.new("TextLabel")
	info.Name = "PopupInfo"
	info.Size = UDim2.new(1, -16, 0.5, 0)
	info.Position = UDim2.new(0, 8, 0.28, 0)
	info.BackgroundTransparency = 1
	info.Font = Enum.Font.Gotham
	info.TextSize = 10
	info.TextWrapped = true
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.TextColor3 = COLOR_TEXT
	info.Text = infoLines
	info.ZIndex = 31
	info.Parent = popup

	local discBtn = Instance.new("TextButton")
	discBtn.Name = "DisconnectButton"
	discBtn.Size = UDim2.new(0.62, 0, 0, 20)
	discBtn.Position = UDim2.new(0, 8, 1, -28)
	discBtn.BackgroundColor3 = Color3.fromRGB(140, 45, 45)
	discBtn.Font = Enum.Font.GothamBold
	discBtn.TextSize = 11
	discBtn.TextColor3 = COLOR_TEXT
	discBtn.Text = "PUTUS SEMUA KABEL"
	discBtn.AutoButtonColor = true
	discBtn.ZIndex = 31
	discBtn.Parent = popup
	local discCorner = Instance.new("UICorner")
	discCorner.CornerRadius = UDim.new(0, 4)
	discCorner.Parent = discBtn
	discBtn.MouseButton1Click:Connect(function()
		cableRemote:FireServer({ action = "disconnect_all", deviceId = dev.id })
		closePopup()
	end)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "PopupCloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Size = UDim2.new(0.24, 0, 0, 20)
	closeBtn.Position = UDim2.new(1, -8, 1, -28)
	closeBtn.BackgroundColor3 = COLOR_BORDER
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 11
	closeBtn.TextColor3 = COLOR_TEXT
	closeBtn.Text = "TUTUP"
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 31
	closeBtn.Parent = popup
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 4)
	closeCorner.Parent = closeBtn
	closeBtn.MouseButton1Click:Connect(closePopup)

	popup.Visible = true
end

local function createNodeButton(canvas: Frame, dev: SnapDevice, cx: number, cy: number)
	local powered = dev.isPowered == true
	local btn = Instance.new("TextButton")
	btn.Name = "Node_" .. dev.id
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.fromScale(cx, cy)
	btn.Size = UDim2.fromScale(0.16, 0.12)
	btn.BackgroundColor3 = COLOR_CARD
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.ZIndex = 2
	btn.Parent = canvas
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Color = if powered then COLOR_GREEN else COLOR_RED
	stroke.Thickness = 1.5
	stroke.Parent = btn

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NodeName"
	nameLabel.Size = UDim2.new(1, -4, 0.55, 0)
	nameLabel.Position = UDim2.new(0, 2, 0.04, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = if powered then COLOR_TEXT else COLOR_RED
	nameLabel.Text = dev.name
	nameLabel.ZIndex = 3
	nameLabel.Parent = btn

	local ipLabel = Instance.new("TextLabel")
	ipLabel.Name = "NodeIp"
	ipLabel.Size = UDim2.new(1, -4, 0.34, 0)
	ipLabel.Position = UDim2.new(0, 2, 0.62, 0)
	ipLabel.BackgroundTransparency = 1
	ipLabel.Font = Enum.Font.RobotoMono
	ipLabel.TextScaled = true
	ipLabel.TextColor3 = if dev.ip ~= nil then COLOR_BLUE else COLOR_GREY
	ipLabel.Text = dev.ip or "-"
	ipLabel.ZIndex = 3
	ipLabel.Parent = btn

	btn.MouseButton1Click:Connect(function()
		openNodePopup(dev)
	end)

	return { cx = cx, cy = cy, powered = powered, id = dev.id, name = dev.name }
end

local function updateTopology(snap: FacilitySnapshot)
	local canvas = topoCanvas
	if canvas == nil or topoPopup == nil then
		return
	end
	clearChildren(canvas, { topoPopup })

	local devices = snap.devices or {}
	local byName: { [string]: SnapDevice } = {}
	for _, dev in ipairs(devices) do
		if byName[dev.name] == nil then
			byName[dev.name] = dev
		end
	end

	-- Group devices per row, spread horizontally
	local rowDevices: { { SnapDevice } } = { {}, {}, {} }
	for _, dev in ipairs(devices) do
		table.insert(rowDevices[rowIndexOf(dev.deviceType)], dev)
	end

	local nodeByName: { [string]: { cx: number, cy: number, powered: boolean, id: string, name: string } } = {}
	for rowIdx = 1, 3 do
		local list = rowDevices[rowIdx]
		local n = #list
		for i, dev in ipairs(list) do
			local cx = (i - 0.5) / n
			local cy = ROW_Y[rowIdx] + 0.06 -- node center (node height = 0.12 scale)
			nodeByName[dev.name] = createNodeButton(canvas, dev, cx, cy)
		end
	end

	-- Edge lines derived from peers (matched by device name), one per unordered pair
	local seenEdges: { [string]: boolean } = {}
	for _, dev in ipairs(devices) do
		local a = nodeByName[dev.name]
		if a ~= nil then
			for _, peerName in ipairs(dev.peers) do
				local b = nodeByName[peerName]
				if b ~= nil and b.name ~= a.name then
					local pairKey = if a.id < b.id then a.id .. "|" .. b.id else b.id .. "|" .. a.id
					if not seenEdges[pairKey] then
						seenEdges[pairKey] = true
						local dx = (b.cx - a.cx) * topoCanvasW
						local dy = (b.cy - a.cy) * topoCanvasH
						local len = math.sqrt(dx * dx + dy * dy)
						if len > 8 then
							local edge = Instance.new("Frame")
							edge.Name = "Edge_" .. pairKey
							edge.AnchorPoint = Vector2.new(0.5, 0.5)
							edge.Position = UDim2.fromScale((a.cx + b.cx) / 2, (a.cy + b.cy) / 2)
							edge.Size = UDim2.new(0, len, 0, 2)
							-- Roblox GUI Y axis points down and Rotation is clockwise-positive,
							-- so the screen-space atan2 angle is used directly (not negated).
							edge.Rotation = math.deg(math.atan2(dy, dx))
							edge.BackgroundColor3 = if a.powered and b.powered then COLOR_GREEN else COLOR_RED
							edge.BorderSizePixel = 0
							edge.ZIndex = 1
							edge.Parent = canvas
						end
					end
				end
			end
		end
	end
end

-- ===== TicketMonitor =====
local function buildTickets(ref: MonitorRef)
	local root = ref.root
	makeTitle(root, "KONTRAK & OBJECTIVES")

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "TicketsList"
	scroll.Position = UDim2.new(0, 4, 0, 16)
	scroll.Size = UDim2.new(1, -8, 0, 62)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = COLOR_BORDER
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = root
	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0, 3)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = scroll

	local objHeader = Instance.new("TextLabel")
	objHeader.Name = "ObjectivesHeader"
	objHeader.Size = UDim2.new(1, -8, 0, 10)
	objHeader.Position = UDim2.new(0, 4, 0, 80)
	objHeader.BackgroundTransparency = 1
	objHeader.Font = Enum.Font.GothamBold
	objHeader.TextScaled = true
	objHeader.TextColor3 = COLOR_GREY
	objHeader.TextXAlignment = Enum.TextXAlignment.Left
	objHeader.Text = "OBJECTIVES:"
	objHeader.Parent = root

	for i, objDef in ipairs(OBJECTIVES) do
		local row = Instance.new("Frame")
		row.Name = "Objective_" .. objDef.key
		row.Size = UDim2.new(1, -8, 0, 8.6)
		row.Position = UDim2.new(0, 4, 0, 92 + (i - 1) * 9.2)
		row.BackgroundTransparency = 1
		row.Parent = root

		local check = Instance.new("TextLabel")
		check.Name = "Check"
		check.Size = UDim2.new(0, 10, 1, 0)
		check.Position = UDim2.new(0, 2, 0, 0)
		check.BackgroundTransparency = 1
		check.Font = Enum.Font.GothamBold
		check.TextScaled = true
		check.TextColor3 = COLOR_GREY
		check.Text = "o"
		check.Parent = row

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.new(1, -18, 1, 0)
		label.Position = UDim2.new(0, 14, 0, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Gotham
		label.TextScaled = true
		label.TextColor3 = COLOR_TEXT
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = objDef.label
		label.Parent = row

		objectiveChecks[objDef.key] = check
	end

	ticketsScroll = scroll
end

local function updateTickets(snap: FacilitySnapshot)
	local scroll = ticketsScroll
	if scroll == nil then
		return
	end
	clearChildren(scroll)

	local tickets = snap.tickets or {}
	local order = 0
	for _, ticket in ipairs(tickets) do
		if ticket.status == "Available" or ticket.status == "Active" then
			order += 1
			local isActive = ticket.status == "Active"
			local row = Instance.new("Frame")
			row.Name = "Ticket_" .. tostring(ticket.id)
			row.Size = UDim2.new(1, -6, 0, 30)
			row.BackgroundColor3 = COLOR_ROW
			row.BorderSizePixel = 0
			row.LayoutOrder = order
			row.Parent = scroll
			local rowCorner = Instance.new("UICorner")
			rowCorner.CornerRadius = UDim.new(0, 4)
			rowCorner.Parent = row

			local titleLabel = Instance.new("TextLabel")
			titleLabel.Name = "TicketTitle"
			titleLabel.Size = UDim2.new(1, -66, 0, 14)
			titleLabel.Position = UDim2.new(0, 6, 0, 2)
			titleLabel.BackgroundTransparency = 1
			titleLabel.Font = Enum.Font.GothamBold
			titleLabel.TextScaled = true
			titleLabel.TextColor3 = if isActive then COLOR_GREEN else COLOR_TEXT
			titleLabel.TextXAlignment = Enum.TextXAlignment.Left
			titleLabel.Text = ticket.title
			titleLabel.Parent = row

			local subLabel = Instance.new("TextLabel")
			subLabel.Name = "TicketReward"
			subLabel.Size = UDim2.new(1, -66, 0, 11)
			subLabel.Position = UDim2.new(0, 6, 0, 17)
			subLabel.BackgroundTransparency = 1
			subLabel.Font = Enum.Font.Gotham
			subLabel.TextScaled = true
			subLabel.TextColor3 = COLOR_YELLOW
			subLabel.TextXAlignment = Enum.TextXAlignment.Left
			subLabel.Text = NetworkUtils.FormatCurrency(ticket.rewardPayout or 0) .. "  -  " .. tostring(ticket.category)
			subLabel.Parent = row

			if isActive then
				local activeLabel = Instance.new("TextLabel")
				activeLabel.Name = "ActiveBadge"
				activeLabel.Size = UDim2.new(0, 52, 0, 22)
				activeLabel.Position = UDim2.new(1, -58, 0, 4)
				activeLabel.BackgroundTransparency = 1
				activeLabel.Font = Enum.Font.GothamBold
				activeLabel.TextScaled = true
				activeLabel.TextColor3 = COLOR_GREEN
				activeLabel.Text = "AKTIF"
				activeLabel.Parent = row
			else
				local acceptBtn = Instance.new("TextButton")
				acceptBtn.Name = "AcceptButton"
				acceptBtn.Size = UDim2.new(0, 52, 0, 22)
				acceptBtn.Position = UDim2.new(1, -58, 0, 4)
				acceptBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
				acceptBtn.Font = Enum.Font.GothamBold
				acceptBtn.TextSize = 12
				acceptBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
				acceptBtn.Text = "TERIMA"
				acceptBtn.AutoButtonColor = true
				acceptBtn.Parent = row
				local btnCorner = Instance.new("UICorner")
				btnCorner.CornerRadius = UDim.new(0, 4)
				btnCorner.Parent = acceptBtn
				acceptBtn.MouseButton1Click:Connect(function()
					contractRemote:FireServer({ action = "accept", ticketId = ticket.id })
				end)
			end
		end
	end
	if order == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "NoTickets"
		empty.Size = UDim2.new(1, -6, 0, 20)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 11
		empty.TextColor3 = COLOR_GREY
		empty.Text = "Belum ada kontrak tersedia..."
		empty.LayoutOrder = 999
		empty.Parent = scroll
	end

	-- Objectives checklist
	local objectives = snap.objectives or {}
	for _, objDef in ipairs(OBJECTIVES) do
		local check = objectiveChecks[objDef.key]
		if check ~= nil then
			local done = objectives[objDef.key] == true
			check.Text = if done then "✓" else "o"
			check.TextColor3 = if done then COLOR_GREEN else COLOR_GREY
		end
	end
end

-- ===== TelemetryMonitor =====
local function buildTelemetry(ref: MonitorRef)
	local root = ref.root
	makeTitle(root, "TELEMETRI")

	local rows: { { key: string, label: string } } = {
		{ key = "balance", label = "Saldo" },
		{ key = "reputation", label = "Reputasi" },
		{ key = "uptime", label = "Uptime" },
		{ key = "power", label = "Daya" },
		{ key = "temp", label = "Suhu Rata2" },
		{ key = "clock", label = "Hari / Jam" },
	}
	for i, rowDef in ipairs(rows) do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. rowDef.key
		row.Size = UDim2.new(1, -8, 0, 16)
		row.Position = UDim2.new(0, 4, 0, 20 + (i - 1) * 18)
		row.BackgroundTransparency = 1
		row.Parent = root

		local label = Instance.new("TextLabel")
		label.Name = "RowLabel"
		label.Size = UDim2.new(0.42, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Gotham
		label.TextScaled = true
		label.TextColor3 = COLOR_GREY
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = rowDef.label
		label.Parent = row

		local value = Instance.new("TextLabel")
		value.Name = "RowValue"
		value.Size = UDim2.new(0.58, -4, 1, 0)
		value.Position = UDim2.new(0.42, 0, 0, 0)
		value.BackgroundTransparency = 1
		value.Font = Enum.Font.GothamBold
		value.TextScaled = true
		value.TextColor3 = COLOR_TEXT
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Text = "-"
		value.Parent = row

		teleValues[rowDef.key] = value
	end

	local banner = Instance.new("Frame")
	banner.Name = "StormBanner"
	banner.Size = UDim2.new(1, -8, 0, 24)
	banner.Position = UDim2.new(0, 4, 0, 132)
	banner.BackgroundColor3 = Color3.fromRGB(150, 30, 30)
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.Parent = root
	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, 4)
	bannerCorner.Parent = banner
	local bannerLabel = Instance.new("TextLabel")
	bannerLabel.Name = "StormText"
	bannerLabel.Size = UDim2.new(1, -8, 1, 0)
	bannerLabel.Position = UDim2.new(0, 4, 0, 0)
	bannerLabel.BackgroundTransparency = 1
	bannerLabel.Font = Enum.Font.GothamBold
	bannerLabel.TextScaled = true
	bannerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	bannerLabel.Text = "BROADCAST STORM!"
	bannerLabel.Parent = banner

	stormBanner = banner
end

local function updateTelemetry(snap: FacilitySnapshot)
	local setValue = function(key: string, text: string, color: Color3?)
		local label = teleValues[key]
		if label ~= nil then
			label.Text = text
			if color ~= nil then
				label.TextColor3 = color
			end
		end
	end

	setValue("balance", NetworkUtils.FormatCurrency(snap.balance or 0), COLOR_GREEN)
	setValue("reputation", tostring(snap.reputation or 0), COLOR_TEXT)
	setValue("uptime", string.format("%.1f%%", snap.uptimePercent or 0), COLOR_TEXT)
	setValue("power", NetworkUtils.FormatWatts(snap.powerWatts or 0), COLOR_YELLOW)
	local tempC = snap.avgTempC or 0
	setValue("temp", string.format("%.1f °C", tempC), if tempC > 75 then COLOR_RED else COLOR_TEXT)
	setValue("clock", string.format("Hari %d  -  %s", snap.day or 1, snap.clockText or "--:--"), COLOR_TEXT)

	if stormBanner ~= nil then
		stormBanner.Visible = snap.storm == true
	end
end

-- ===== Build / update dispatch =====
local function buildMonitor(name: string, ref: MonitorRef)
	if name == "TopologyMonitor" then
		buildTopology(ref)
	elseif name == "TicketMonitor" then
		buildTickets(ref)
	elseif name == "TelemetryMonitor" then
		buildTelemetry(ref)
	end
	ref.root:SetAttribute("BuiltBy", "NetSimNOC")
end

local function updateMonitor(name: string, snap: FacilitySnapshot)
	if name == "TopologyMonitor" then
		updateTopology(snap)
	elseif name == "TicketMonitor" then
		updateTickets(snap)
	elseif name == "TelemetryMonitor" then
		updateTelemetry(snap)
	end
end

-- ===== Snapshot handling =====
stateSyncRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local snap = payload :: FacilitySnapshot
	if type(snap.plotIndex) ~= "number" or snap.plotIndex < 1 then
		return
	end
	if snap.plotIndex ~= lastPlotIndex then
		clearAllMonitorRefs()
		resetContentCaches()
		lastPlotIndex = snap.plotIndex
	end

	local plots = Workspace:FindFirstChild("Plots")
	if plots == nil then
		return
	end
	local plot = plots:FindFirstChild("Plot" .. tostring(snap.plotIndex))
	if plot == nil then
		return
	end

	refreshMonitorRefs(plot)

	for _, name in ipairs(MONITOR_NAMES) do
		local ref = monitorRefs[name]
		if ref ~= nil then
			-- Build once per Root (attribute guard); re-check in case the SurfaceGui got rebuilt
			if ref.root:GetAttribute("BuiltBy") ~= "NetSimNOC" then
				resetCachesFor(name)
				buildMonitor(name, ref)
			end
			updateMonitor(name, snap)
		end
	end
end)
