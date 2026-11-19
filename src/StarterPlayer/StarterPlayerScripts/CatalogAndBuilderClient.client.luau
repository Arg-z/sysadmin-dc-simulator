--!strict
--[[
	CatalogAndBuilderClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	Hardware Store (tombol keyboard B / tombol "STORE [B]" di HUD via BindableEvent
	"NetSimToggleStore" yang dibuat script ini) + ghost placement mode.

	Store 620x420 center: kolom kategori (Rack/Network/Server/Component dari
	HardwareCatalog.StoreCategories), daftar item (nama/harga/specs + tombol BELI),
	dan panel kanan "PANDUAN BUILD".

	Buy behavior (CONTRACT.md Section 3, PurchaseHardwareRemote):
	- Component -> FireServer(itemId, "buy")
	- Placeable (Rack/Network/Server) -> FireServer(itemId, "prepare") lalu ghost mode:
	  RenderStepped mouse raycast (player:GetMouse(), TargetFilter=ghost), snap 2-grid
	  relatif PLOT_POSITIONS[ownPlotIndex], validasi lokal = bounds + furniture zones
	  (radius + max(halfX,halfZ) dari ModelFactory.ComputeFootprint; overlap device
	  lain divalidasi ulang oleh server). LMB = place, RMB/Esc = cancel, R = rotate 90.

	Semua teks GUI Bahasa Indonesia; komentar kode Bahasa Inggris.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(sharedFolder:WaitForChild("HardwareCatalog"))
local PlotConstants = require(sharedFolder:WaitForChild("PlotConstants"))
local ModelFactory = require(sharedFolder:WaitForChild("ModelFactory"))
local NetworkUtils = require(sharedFolder:WaitForChild("NetworkUtils"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[CatalogAndBuilderClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local purchaseRemote = remotesFolder:WaitForChild("PurchaseHardwareRemote") :: RemoteEvent
local stateSyncRemote = remotesFolder:WaitForChild("StateSyncRemote") :: RemoteEvent

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
local COLOR_BUY_OK = Color3.fromRGB(35, 134, 54)
local COLOR_BUY_POOR = Color3.fromRGB(110, 60, 60)

-- ===== State =====
local lastPlotIndex: number? = nil
local lastBalance: number? = nil
local storeVisible = false
local selectedCategory: string = "Rack"

type GhostState = {
	itemId: string,
	model: Model,
	origColors: { [BasePart]: Color3 },
	halfX: number,
	halfZ: number,
	rotY: number,
	valid: boolean,
	snappedCF: CFrame,
	connRender: RBXScriptConnection,
	connInput: RBXScriptConnection,
}
local ghost: GhostState? = nil

-- Forward declarations (mutually recursive helpers, assigned further below)
local selectCategory: (string) -> ()
local rebuildItems: () -> ()
local onBuy: (def: any) -> ()
local startGhost: (itemId: string) -> ()
local exitGhost: (cancel: boolean) -> ()
local updateGhost: () -> ()
local toggleStore: () -> ()

-- ===== Helpers =====
local function plotOrigin(): Vector3?
	local idx = lastPlotIndex
	if idx == nil or idx < 1 or idx > #PlotConstants.PLOT_POSITIONS then
		return nil
	end
	return PlotConstants.PLOT_POSITIONS[idx]
end

local function clearDynamicChildren(inst: Instance)
	for _, child in ipairs(inst:GetChildren()) do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

-- Compact Indonesian spec line per item category
local function specsLine(def: any): string
	local s = def.specs or {}
	local id = tostring(def.id)
	if def.category == "Rack" then
		return string.format("Max %dU  -  PDU %dW", s.maxU or 0, s.maxPowerWatts or 0)
	elseif def.category == "Network" then
		return string.format("%d RJ45  -  %d WAN  -  %d SFP  -  %dW", s.ports or 0, s.wanPorts or 0, s.sfpPorts or 0, s.powerWatts or 0)
	elseif def.category == "Server" then
		return string.format("%d vCPU  -  %dGB RAM  -  %dGB Disk  -  %dW", s.cpu or 0, s.ram or 0, s.disk or 0, s.powerWatts or 0)
	end
	-- Components
	if string.sub(id, 1, 8) == "chassis_" then
		return string.format("%dU  -  %d port", s.uSize or def.uSize or 0, s.ports or 0)
	elseif string.sub(id, 1, 5) == "mobo_" then
		return string.format("%d socket  -  %d slot RAM  -  %d bay", s.sockets or 0, s.ramSlots or 0, s.storageBays or 0)
	elseif string.sub(id, 1, 4) == "cpu_" then
		return string.format("%d core", s.cores or 0)
	elseif string.sub(id, 1, 4) == "ram_" then
		return string.format("%d GB", s.ramGb or 0)
	elseif string.sub(id, 1, 5) == "nvme_" or id == "replacement_hdd" then
		return string.format("%d GB", s.storageGb or 0)
	elseif string.sub(id, 1, 4) == "psu_" then
		return string.format("%d W", s.powerWatts or 0)
	end
	return tostring(def.description)
end

-- ===== Store GUI build =====
local storeGui = Instance.new("ScreenGui")
storeGui.Name = "NetSimStore"
storeGui.ResetOnSpawn = false
storeGui.DisplayOrder = 90
storeGui.Parent = playerGui

local storeWindow = Instance.new("Frame")
storeWindow.Name = "StoreWindow"
storeWindow.AnchorPoint = Vector2.new(0.5, 0.5)
storeWindow.Position = UDim2.new(0.5, 0, 0.5, 0)
storeWindow.Size = UDim2.new(0, 740, 0, 470)
storeWindow.BackgroundColor3 = COLOR_BG
storeWindow.BorderSizePixel = 0
storeWindow.Active = true -- absorb mouse clicks on PC so tools/ClickDetectors behind do not trigger
storeWindow.Visible = false
storeWindow.Parent = storeGui
local windowCorner = Instance.new("UICorner")
windowCorner.CornerRadius = UDim.new(0, 10)
windowCorner.Parent = storeWindow
local windowStroke = Instance.new("UIStroke")
windowStroke.Color = COLOR_BORDER
windowStroke.Thickness = 1
windowStroke.Parent = storeWindow

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = COLOR_CARD
titleBar.BorderSizePixel = 0
titleBar.Parent = storeWindow
local titleBarCorner = Instance.new("UICorner")
titleBarCorner.CornerRadius = UDim.new(0, 10)
titleBarCorner.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -260, 1, 0)
titleLabel.Position = UDim2.new(0, 12, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 15
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextColor3 = COLOR_GREEN
titleLabel.Text = "TOKO HARDWARE"
titleLabel.Parent = titleBar

local subLabel = Instance.new("TextLabel")
subLabel.Size = UDim2.new(0, 220, 1, 0)
subLabel.Position = UDim2.new(1, -294, 0, 0)
subLabel.BackgroundTransparency = 1
subLabel.Font = Enum.Font.Gotham
subLabel.TextSize = 11
subLabel.TextXAlignment = Enum.TextXAlignment.Right
subLabel.TextColor3 = COLOR_GREY
subLabel.Text = "tekan [B] buka / tutup"
subLabel.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 60, 0, 26)
closeBtn.Position = UDim2.new(1, -66, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(145, 40, 48)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Text = "X [B]"
closeBtn.Modal = true -- frees PC mouse cursor in First-Person / ShiftLock
closeBtn.Active = true
closeBtn.Parent = titleBar
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

-- Left column: categories
local catHeader = Instance.new("TextLabel")
catHeader.Size = UDim2.new(0, 120, 0, 16)
catHeader.Position = UDim2.new(0, 8, 0, 40)
catHeader.BackgroundTransparency = 1
catHeader.Font = Enum.Font.GothamBold
catHeader.TextSize = 11
catHeader.TextXAlignment = Enum.TextXAlignment.Left
catHeader.TextColor3 = COLOR_GREY
catHeader.Text = "KATEGORI"
catHeader.Parent = storeWindow

local categoryButtons: { [string]: TextButton } = {}
local categoryStrokes: { [string]: UIStroke } = {}

for i, category in ipairs(Catalog.StoreCategories) do
	local catName = tostring(category)
	local btn = Instance.new("TextButton")
	btn.Name = "Category_" .. catName
	btn.Size = UDim2.new(0, 120, 0, 30)
	btn.Position = UDim2.new(0, 8, 0, 60 + (i - 1) * 36)
	btn.BackgroundColor3 = COLOR_CARD
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 13
	btn.TextColor3 = COLOR_TEXT
	btn.Text = catName
	btn.AutoButtonColor = true
	btn.Parent = storeWindow
	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = btn
	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = COLOR_BORDER
	btnStroke.Thickness = 1
	btnStroke.Transparency = 0.4
	btnStroke.Parent = btn
	btn.MouseButton1Click:Connect(function()
		selectCategory(catName)
	end)
	categoryButtons[catName] = btn
	categoryStrokes[catName] = btnStroke
end

-- Middle column: item list
local itemsHeader = Instance.new("TextLabel")
itemsHeader.Size = UDim2.new(0, 380, 0, 16)
itemsHeader.Position = UDim2.new(0, 136, 0, 40)
itemsHeader.BackgroundTransparency = 1
itemsHeader.Font = Enum.Font.GothamBold
itemsHeader.TextSize = 11
itemsHeader.TextXAlignment = Enum.TextXAlignment.Left
itemsHeader.TextColor3 = COLOR_GREY
itemsHeader.Text = "ITEM"
itemsHeader.Parent = storeWindow

local itemsScroll = Instance.new("ScrollingFrame")
itemsScroll.Name = "ItemsScroll"
itemsScroll.Position = UDim2.new(0, 136, 0, 60)
itemsScroll.Size = UDim2.new(0, 380, 1, -84)
itemsScroll.BackgroundTransparency = 1
itemsScroll.BorderSizePixel = 0
itemsScroll.ScrollBarThickness = 6
itemsScroll.ScrollBarImageColor3 = COLOR_BORDER
itemsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
itemsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
itemsScroll.Parent = storeWindow
local itemsLayout = Instance.new("UIListLayout")
itemsLayout.FillDirection = Enum.FillDirection.Vertical
itemsLayout.Padding = UDim.new(0, 5)
itemsLayout.SortOrder = Enum.SortOrder.LayoutOrder
itemsLayout.Parent = itemsScroll

-- Status label (transient feedback, e.g. saldo tidak cukup)
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(0, 380, 0, 16)
statusLabel.Position = UDim2.new(0, 136, 1, -20)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextColor3 = COLOR_YELLOW
statusLabel.Text = ""
statusLabel.Visible = false
statusLabel.Parent = storeWindow
local statusToken = 0

local function showStatus(message: string)
	statusToken += 1
	local myToken = statusToken
	statusLabel.Text = message
	statusLabel.Visible = true
	task.delay(3, function()
		if statusToken == myToken then
			statusLabel.Visible = false
		end
	end)
end

-- Right column: build guide (static, PC-oriented)
local guideHeader = Instance.new("TextLabel")
guideHeader.Size = UDim2.new(0, 208, 0, 16)
guideHeader.Position = UDim2.new(0, 524, 0, 40)
guideHeader.BackgroundTransparency = 1
guideHeader.Font = Enum.Font.GothamBold
guideHeader.TextSize = 11
guideHeader.TextXAlignment = Enum.TextXAlignment.Left
guideHeader.TextColor3 = COLOR_BLUE
guideHeader.Text = "PANDUAN BUILD (PC)"
guideHeader.Parent = storeWindow

local guideBody = Instance.new("TextLabel")
guideBody.Name = "BuildGuide"
guideBody.Size = UDim2.new(0, 208, 1, -68)
guideBody.Position = UDim2.new(0, 524, 0, 60)
guideBody.BackgroundColor3 = COLOR_CARD
guideBody.BorderSizePixel = 0
guideBody.Font = Enum.Font.Gotham
guideBody.TextSize = 12
guideBody.TextWrapped = true
guideBody.TextXAlignment = Enum.TextXAlignment.Left
guideBody.TextYAlignment = Enum.TextYAlignment.Top
guideBody.TextColor3 = COLOR_TEXT
guideBody.Text = "Urutan Rakit Workbench:\nChassis -> Mobo -> CPU -> RAM -> Storage -> PSU\n\nLangkah PC:\n- Klik saklar merah di bench\n- Dekati bench + tekan [E] (pegang laptop)\n- Terminal: install-os ubuntu-22.04\n- Terminal: stress-test\n- Terminal: ship (kirim ke dock)\n\nKontrol Placement:\n[Klik Kiri] Pasang\n[R] Putar 90 deg\n[Klik Kanan / Esc] Batal"
guideBody.Parent = storeWindow
local guideCorner = Instance.new("UICorner")
guideCorner.CornerRadius = UDim.new(0, 6)
guideCorner.Parent = guideBody
local guidePadding = Instance.new("UIPadding")
guidePadding.PaddingLeft = UDim.new(0, 10)
guidePadding.PaddingTop = UDim.new(0, 8)
guidePadding.PaddingRight = UDim.new(0, 10)
guidePadding.PaddingBottom = UDim.new(0, 8)
guidePadding.Parent = guideBody

-- PC ghost placement bottom control bar (visible only while placing)
local ghostBanner = Instance.new("TextLabel")
ghostBanner.Name = "GhostBanner"
ghostBanner.AnchorPoint = Vector2.new(0.5, 1)
ghostBanner.Position = UDim2.new(0.5, 0, 1, -46)
ghostBanner.Size = UDim2.new(0, 540, 0, 30)
ghostBanner.BackgroundColor3 = COLOR_BG
ghostBanner.BackgroundTransparency = 0.12
ghostBanner.Font = Enum.Font.GothamBold
ghostBanner.TextSize = 13
ghostBanner.TextColor3 = COLOR_YELLOW
ghostBanner.Text = "[PLACEMENT PC]  Klik Kiri: Pasang  |  [R]: Putar 90 deg  |  Klik Kanan / [Esc]: Batal"
ghostBanner.Visible = false
ghostBanner.Parent = storeGui
local ghostBannerCorner = Instance.new("UICorner")
ghostBannerCorner.CornerRadius = UDim.new(0, 8)
ghostBannerCorner.Parent = ghostBanner
local ghostBannerStroke = Instance.new("UIStroke")
ghostBannerStroke.Color = COLOR_BORDER
ghostBannerStroke.Thickness = 1
ghostBannerStroke.Parent = ghostBanner

-- ===== Category selection + item rows =====
type ItemRow = {
	def: any,
	buyBtn: TextButton,
}
local currentRows: { ItemRow } = {}

local function updateAffordability()
	local balance = lastBalance
	for _, row in ipairs(currentRows) do
		local poor = balance ~= nil and balance < (row.def.price or 0)
		row.buyBtn.BackgroundColor3 = if poor then COLOR_BUY_POOR else COLOR_BUY_OK
	end
end

selectCategory = function(category: string)
	selectedCategory = category
	for name, btn in pairs(categoryButtons) do
		local stroke = categoryStrokes[name]
		local active = name == selectedCategory
		btn.TextColor3 = if active then COLOR_GREEN else COLOR_TEXT
		if stroke ~= nil then
			stroke.Color = if active then COLOR_GREEN else COLOR_BORDER
			stroke.Transparency = if active then 0 else 0.4
		end
	end
	rebuildItems()
end

onBuy = function(def: any)
	if ghost ~= nil then
		showStatus("Selesaikan / batalkan placement dulu (klik kanan = batal)")
		return
	end
	if def.category == "Component" then
		-- Components go straight to the workbench (server validates order + proximity)
		purchaseRemote:FireServer(def.id, "buy")
		showStatus("Komponen dibeli: " .. tostring(def.name) .. " (pasang di bench)")
	else
		if lastBalance ~= nil and lastBalance < (def.price or 0) then
			showStatus("Saldo tidak cukup untuk " .. tostring(def.name))
			return
		end
		purchaseRemote:FireServer(def.id, "prepare")
		startGhost(def.id)
	end
end

rebuildItems = function()
	clearDynamicChildren(itemsScroll)
	currentRows = {}
	local items = Catalog.ListByCategory(selectedCategory :: any)
	for i, def in ipairs(items) do
		local row = Instance.new("Frame")
		row.Name = "Item_" .. tostring(def.id)
		row.Size = UDim2.new(1, -6, 0, 54)
		row.BackgroundColor3 = COLOR_ROW
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = itemsScroll
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 6)
		rowCorner.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -84, 0, 16)
		nameLabel.Position = UDim2.new(0, 8, 0, 4)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextColor3 = COLOR_TEXT
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Text = tostring(def.name)
		nameLabel.Parent = row

		local specLabel = Instance.new("TextLabel")
		specLabel.Size = UDim2.new(1, -84, 0, 14)
		specLabel.Position = UDim2.new(0, 8, 0, 21)
		specLabel.BackgroundTransparency = 1
		specLabel.Font = Enum.Font.Gotham
		specLabel.TextSize = 11
		specLabel.TextXAlignment = Enum.TextXAlignment.Left
		specLabel.TextColor3 = COLOR_GREY
		specLabel.TextTruncate = Enum.TextTruncate.AtEnd
		specLabel.Text = specsLine(def)
		specLabel.Parent = row

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Size = UDim2.new(1, -84, 0, 14)
		priceLabel.Position = UDim2.new(0, 8, 0, 37)
		priceLabel.BackgroundTransparency = 1
		priceLabel.Font = Enum.Font.GothamBold
		priceLabel.TextSize = 12
		priceLabel.TextXAlignment = Enum.TextXAlignment.Left
		priceLabel.TextColor3 = COLOR_GREEN
		priceLabel.Text = NetworkUtils.FormatCurrency(def.price or 0)
		priceLabel.Parent = row

		local buyBtn = Instance.new("TextButton")
		buyBtn.Name = "BuyButton"
		buyBtn.Size = UDim2.new(0, 62, 0, 34)
		buyBtn.Position = UDim2.new(1, -70, 0, 10)
		buyBtn.BackgroundColor3 = COLOR_BUY_OK
		buyBtn.Font = Enum.Font.GothamBold
		buyBtn.TextSize = 13
		buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		buyBtn.Text = "BELI"
		buyBtn.AutoButtonColor = true
		buyBtn.Parent = row
		local buyCorner = Instance.new("UICorner")
		buyCorner.CornerRadius = UDim.new(0, 6)
		buyCorner.Parent = buyBtn
		buyBtn.MouseButton1Click:Connect(function()
			onBuy(def)
		end)

		table.insert(currentRows, { def = def, buyBtn = buyBtn })
	end
	if #currentRows == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, -6, 0, 24)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 12
		empty.TextColor3 = COLOR_GREY
		empty.Text = "Tidak ada item di kategori ini"
		empty.LayoutOrder = 9999
		empty.Parent = itemsScroll
	end
	updateAffordability()
end

local function closeStore()
	storeWindow.Visible = false
	storeVisible = false
end

closeBtn.MouseButton1Down:Connect(closeStore)
closeBtn.MouseButton1Click:Connect(closeStore)

local function setStoreVisible(visible: boolean)
	if ghost ~= nil and visible then
		return -- never open the store while a ghost placement is in progress
	end
	storeWindow.Visible = visible
	storeVisible = visible
end

toggleStore = function()
	setStoreVisible(not storeVisible)
end

-- ===== Ghost placement mode =====
exitGhost = function(cancel: boolean)
	local g = ghost
	if g == nil then
		return
	end
	ghost = nil
	ghostBanner.Visible = false
	if g.connRender.Connected then
		g.connRender:Disconnect()
	end
	if g.connInput.Connected then
		g.connInput:Disconnect()
	end
	if cancel then
		purchaseRemote:FireServer(g.itemId, "cancel")
	end
	player:GetMouse().TargetFilter = nil
	g.model:Destroy()
end

updateGhost = function()
	local g = ghost
	if g == nil then
		return
	end
	local mouse = player:GetMouse()
	local hit = mouse.Target
	if hit ~= nil then
		local hitPos = mouse.Hit.Position
		local origin = plotOrigin()
		if origin ~= nil then
			local snap = PlotConstants.SNAP_GRID
			local relX = hitPos.X - origin.X
			local relZ = hitPos.Z - origin.Z
			local sx = math.floor(relX / snap + 0.5) * snap
			local sz = math.floor(relZ / snap + 0.5) * snap
			g.snappedCF = CFrame.new(origin.X + sx, PlotConstants.ROOM.floorTopY, origin.Z + sz)

			-- Local validity: placement bounds + furniture zones (server revalidates overlap etc.)
			local bounds = PlotConstants.PLACEMENT_BOUNDS
			local valid = sx >= bounds.minX and sx <= bounds.maxX and sz >= bounds.minZ and sz <= bounds.maxZ
			if valid then
				local maxHalf = math.max(g.halfX, g.halfZ)
				for _, zone in ipairs(PlotConstants.FURNITURE_ZONES) do
					local dx = sx - zone.position.X
					local dz = sz - zone.position.Z
					if math.sqrt(dx * dx + dz * dz) < zone.radius + maxHalf then
						valid = false
						break
					end
				end
			end
			g.valid = valid
		else
			g.valid = false
		end
	end

	local tint = if g.valid then COLOR_GREEN else COLOR_RED
	for part, orig in pairs(g.origColors) do
		if part.Parent ~= nil then
			part.Color = orig:Lerp(tint, 0.5)
		end
	end
	g.model:PivotTo(g.snappedCF * CFrame.Angles(0, math.rad(g.rotY), 0))
end

startGhost = function(itemId: string)
	local def = Catalog.Get(itemId)
	if def == nil then
		return
	end
	exitGhost(true) -- cancel any previous pending placement

	local model: Model
	if def.category == "Rack" then
		model = ModelFactory.BuildRack(itemId, "ghost")
	else
		model = ModelFactory.BuildDeviceModel(itemId, "ghost")
	end
	model.Name = "Ghost_" .. itemId

	local origColors: { [BasePart]: Color3 } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			local part = desc :: BasePart
			origColors[part] = part.Color
			part.Transparency = 0.5
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Anchored = true
		end
	end

	local halfX, halfZ = ModelFactory.ComputeFootprint(itemId)
	local origin = plotOrigin()
	local startCF: CFrame
	if origin ~= nil then
		startCF = CFrame.new(origin.X, PlotConstants.ROOM.floorTopY, origin.Z)
	else
		startCF = CFrame.new(0, PlotConstants.ROOM.floorTopY, 0)
	end

	local connRender = RunService.RenderStepped:Connect(updateGhost)
	local connInput = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		local g = ghost
		if g == nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			g.rotY = (g.rotY + 90) % 360
		elseif input.KeyCode == Enum.KeyCode.Escape then
			exitGhost(true)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessed then
			if g.valid then
				purchaseRemote:FireServer(g.itemId, "place", g.snappedCF, math.rad(g.rotY))
				exitGhost(false)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			exitGhost(true)
		end
	end)

	ghost = {
		itemId = itemId,
		model = model,
		origColors = origColors,
		halfX = halfX,
		halfZ = halfZ,
		rotY = 0,
		valid = false,
		snappedCF = startCF,
		connRender = connRender,
		connInput = connInput,
	}

	model.Parent = Workspace
	player:GetMouse().TargetFilter = model
	model:PivotTo(startCF)

	ghostBanner.Visible = true
	setStoreVisible(false)
end

-- ===== Input: key B toggles store (works anytime no TextBox is focused) =====
UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if UserInputService:GetFocusedTextBox() ~= nil then
		return
	end
	if input.KeyCode == Enum.KeyCode.B then
		toggleStore()
	end
end)

-- ===== Cross-script toggle: HudClient's "STORE [B]" button fires this bindable =====
local toggleBindable = Instance.new("BindableEvent")
toggleBindable.Name = "NetSimToggleStore"
toggleBindable.Parent = playerGui
toggleBindable.Event:Connect(function()
	toggleStore()
end)

-- ===== Snapshot: keep plot index + balance for ghost validation & affordability =====
stateSyncRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local plotIndex = payload.plotIndex
	local balance = payload.balance
	if type(plotIndex) == "number" and plotIndex >= 1 then
		lastPlotIndex = plotIndex
	end
	if type(balance) == "number" then
		lastBalance = balance
		updateAffordability()
	end
end)

-- Initial category render
selectCategory("Rack")
