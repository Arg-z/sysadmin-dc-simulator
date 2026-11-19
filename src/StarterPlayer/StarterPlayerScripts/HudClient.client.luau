--!strict
--[[
	HudClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	HUD pemain:
	- Panel kanan-atas: Saldo (besar, hijau), Reputasi, Uptime %, Daya, Suhu rata-rata,
	  Hari/Jam -- di-update dari StateSyncRemote (FacilitySnapshot tiap 5s).
	- Tombol "STORE [B]" kiri-atas: memicu BindableEvent "NetSimToggleStore" yang dibuat
	  oleh CatalogAndBuilderClient untuk membuka/menutup jendela store.
	- Tombol "RESET DATA" kanan-atas (di bawah panel): konfirmasi 2 klik dalam 4 detik
	  -> ResetDataRemote:FireServer().
	- Hint bawah-tengah: tips berputar tiap 8 detik; pesan {action="hint"} dari
	  OpenTerminalEvent tampil 4 detik dengan prioritas.

	Semua teks GUI Bahasa Indonesia; komentar kode Bahasa Inggris.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkUtils = require(sharedFolder:WaitForChild("NetworkUtils"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[HudClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local stateSyncRemote = remotesFolder:WaitForChild("StateSyncRemote") :: RemoteEvent
local openTerminalRemote = remotesFolder:WaitForChild("OpenTerminalEvent") :: RemoteEvent
local resetDataRemote = remotesFolder:WaitForChild("ResetDataRemote") :: RemoteEvent

-- ===== Palette =====
local COLOR_BG = Color3.fromRGB(13, 17, 23)
local COLOR_CARD = Color3.fromRGB(22, 27, 34)
local COLOR_BORDER = Color3.fromRGB(48, 54, 61)
local COLOR_GREEN = Color3.fromRGB(0, 255, 102)
local COLOR_RED = Color3.fromRGB(255, 85, 85)
local COLOR_YELLOW = Color3.fromRGB(255, 216, 102)
local COLOR_GREY = Color3.fromRGB(139, 148, 158)
local COLOR_TEXT = Color3.fromRGB(230, 237, 243)
local COLOR_RESET = Color3.fromRGB(140, 45, 45)

-- ===== GUI build =====
local gui = Instance.new("ScreenGui")
gui.Name = "NetSimHUD"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.Parent = playerGui

-- Top-left: PC quick buttons (STORE [B] + TERMINAL [~])
local storeBtn = Instance.new("TextButton")
storeBtn.Name = "StoreButton"
storeBtn.Size = UDim2.new(0, 110, 0, 30)
storeBtn.Position = UDim2.new(0, 12, 0, 12)
storeBtn.BackgroundColor3 = COLOR_CARD
storeBtn.Font = Enum.Font.GothamBold
storeBtn.TextSize = 13
storeBtn.TextColor3 = COLOR_GREEN
storeBtn.Text = "STORE [B]"
storeBtn.AutoButtonColor = true
storeBtn.Active = true
storeBtn.Parent = gui
local storeCorner = Instance.new("UICorner")
storeCorner.CornerRadius = UDim.new(0, 6)
storeCorner.Parent = storeBtn
local storeStroke = Instance.new("UIStroke")
storeStroke.Color = COLOR_BORDER
storeStroke.Thickness = 1
storeStroke.Parent = storeBtn

local termBtn = Instance.new("TextButton")
termBtn.Name = "TerminalButton"
termBtn.Size = UDim2.new(0, 128, 0, 30)
termBtn.Position = UDim2.new(0, 130, 0, 12)
termBtn.BackgroundColor3 = COLOR_CARD
termBtn.Font = Enum.Font.GothamBold
termBtn.TextSize = 13
termBtn.TextColor3 = Color3.fromRGB(88, 166, 255)
termBtn.Text = "TERMINAL [~]"
termBtn.AutoButtonColor = true
termBtn.Active = true
termBtn.Parent = gui
local termCorner = Instance.new("UICorner")
termCorner.CornerRadius = UDim.new(0, 6)
termCorner.Parent = termBtn
local termStroke = Instance.new("UIStroke")
termStroke.Color = COLOR_BORDER
termStroke.Thickness = 1
termStroke.Parent = termBtn

-- Top-right: stats panel
local panel = Instance.new("Frame")
panel.Name = "StatsPanel"
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -12, 0, 12)
panel.Size = UDim2.new(0, 212, 0, 152)
panel.BackgroundColor3 = COLOR_BG
panel.BackgroundTransparency = 0.15
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = gui
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Color = COLOR_BORDER
panelStroke.Thickness = 1
panelStroke.Parent = panel

local panelTitle = Instance.new("TextLabel")
panelTitle.Name = "PanelTitle"
panelTitle.Size = UDim2.new(1, -12, 0, 14)
panelTitle.Position = UDim2.new(0, 8, 0, 4)
panelTitle.BackgroundTransparency = 1
panelTitle.Font = Enum.Font.GothamBold
panelTitle.TextSize = 11
panelTitle.TextXAlignment = Enum.TextXAlignment.Left
panelTitle.TextColor3 = COLOR_GREY
panelTitle.Text = "STATUS LAB"
panelTitle.Parent = panel

local valueLabels: { [string]: TextLabel } = {}

-- Balance row (big green value)
do
	local row = Instance.new("Frame")
	row.Name = "Row_balance"
	row.Size = UDim2.new(1, -12, 0, 26)
	row.Position = UDim2.new(0, 8, 0, 20)
	row.BackgroundTransparency = 1
	row.Parent = panel

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.4, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLOR_GREY
	label.Text = "SALDO"
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(0.6, 0, 1, 0)
	value.Position = UDim2.new(0.4, 0, 0, 0)
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.GothamBold
	value.TextSize = 19
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextColor3 = COLOR_GREEN
	value.Text = "$0"
	value.Parent = row

	valueLabels["balance"] = value
end

local HUD_ROWS: { { key: string, label: string } } = {
	{ key = "reputation", label = "Reputasi" },
	{ key = "uptime", label = "Uptime" },
	{ key = "power", label = "Daya" },
	{ key = "temp", label = "Suhu" },
	{ key = "clock", label = "Hari / Jam" },
}

for i, rowDef in ipairs(HUD_ROWS) do
	local row = Instance.new("Frame")
	row.Name = "Row_" .. rowDef.key
	row.Size = UDim2.new(1, -12, 0, 16)
	row.Position = UDim2.new(0, 8, 0, 48 + (i - 1) * 18)
	row.BackgroundTransparency = 1
	row.Parent = panel

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.4, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLOR_GREY
	label.Text = rowDef.label
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(0.6, 0, 1, 0)
	value.Position = UDim2.new(0.4, 0, 0, 0)
	value.BackgroundTransparency = 1
	value.Font = Enum.Font.GothamBold
	value.TextSize = 13
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextColor3 = COLOR_TEXT
	value.Text = "-"
	value.Parent = row

	valueLabels[rowDef.key] = value
end

-- Top-right: RESET DATA button under the panel (2-click confirm, 4s window)
local resetBtn = Instance.new("TextButton")
resetBtn.Name = "ResetButton"
resetBtn.AnchorPoint = Vector2.new(1, 0)
resetBtn.Position = UDim2.new(1, -12, 0, 170)
resetBtn.Size = UDim2.new(0, 212, 0, 26)
resetBtn.BackgroundColor3 = COLOR_RESET
resetBtn.Font = Enum.Font.GothamBold
resetBtn.TextSize = 12
resetBtn.TextColor3 = COLOR_TEXT
resetBtn.Text = "RESET DATA"
resetBtn.AutoButtonColor = true
resetBtn.Parent = gui
local resetCorner = Instance.new("UICorner")
resetCorner.CornerRadius = UDim.new(0, 6)
resetCorner.Parent = resetBtn

-- Bottom-center hint label
local hintLabel = Instance.new("TextLabel")
hintLabel.Name = "HintLabel"
hintLabel.AnchorPoint = Vector2.new(0.5, 1)
hintLabel.Position = UDim2.new(0.5, 0, 1, -12)
hintLabel.Size = UDim2.new(0, 700, 0, 26)
hintLabel.BackgroundTransparency = 1
hintLabel.Font = Enum.Font.Gotham
hintLabel.TextSize = 14
hintLabel.TextColor3 = COLOR_TEXT
hintLabel.TextStrokeTransparency = 0.4
hintLabel.TextTruncate = Enum.TextTruncate.AtEnd
hintLabel.Text = ""
hintLabel.Parent = gui

-- ===== Hint system: rotating PC tips + priority server hints =====
local TIPS = {
	"Tekan [~] atau [F2] untuk buka / tutup Terminal (klik X [~] juga bisa)",
	"Tekan [B] untuk buka / tutup Hardware Store",
	"Pegang Laptop [1] lalu dekati device + tekan [E] = Kabel Console",
	"Klik 2 port berbeda untuk kabel LAN | Klik port terhubung = cabut",
	"Mode placement: [R] Putar 90 deg | Klik Kiri = Pasang | Klik Kanan/[Esc] = Batal",
}
local tipIndex = 1
local priorityActive = false
local priorityToken = 0

hintLabel.Text = TIPS[1]

local function showPriority(message: string)
	priorityToken += 1
	local myToken = priorityToken
	priorityActive = true
	hintLabel.Text = message
	task.delay(4, function()
		if priorityToken == myToken then
			priorityActive = false
			hintLabel.Text = TIPS[tipIndex]
		end
	end)
end

task.spawn(function()
	while true do
		task.wait(8)
		tipIndex = (tipIndex % #TIPS) + 1
		if not priorityActive then
			hintLabel.Text = TIPS[tipIndex]
		end
	end
end)

-- ===== RESET DATA: 2-click confirm within 4 seconds =====
local resetArmed = false
resetBtn.MouseButton1Click:Connect(function()
	if resetArmed then
		resetArmed = false
		resetBtn.Text = "RESET DATA"
		resetBtn.BackgroundColor3 = COLOR_RESET
		resetDataRemote:FireServer()
		showPriority("Data direset! Lab dibangun ulang oleh server...")
	else
		resetArmed = true
		resetBtn.Text = "YAKIN? KLIK LAGI (4s)"
		resetBtn.BackgroundColor3 = COLOR_RED
		task.delay(4, function()
			if resetArmed then
				resetArmed = false
				resetBtn.Text = "RESET DATA"
				resetBtn.BackgroundColor3 = COLOR_RESET
			end
		end)
	end
end)

-- ===== STORE [B] & TERMINAL [~] buttons -> BindableEvents =====
task.spawn(function()
	local toggleBindable = playerGui:WaitForChild("NetSimToggleStore", 60) :: any
	if toggleBindable ~= nil and toggleBindable:IsA("BindableEvent") then
		storeBtn.MouseButton1Down:Connect(function()
			toggleBindable:Fire()
		end)
	else
		storeBtn.Visible = false
		warn("[HudClient] BindableEvent NetSimToggleStore tidak ditemukan; tombol STORE disembunyikan")
	end
end)

task.spawn(function()
	local toggleTerm = playerGui:WaitForChild("NetSimToggleTerminal", 60) :: any
	if toggleTerm ~= nil and toggleTerm:IsA("BindableEvent") then
		termBtn.MouseButton1Down:Connect(function()
			toggleTerm:Fire()
		end)
	else
		termBtn.Visible = false
	end
end)

-- ===== OpenTerminalEvent hint messages (4s priority) =====
openTerminalRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.action == "hint" then
		showPriority(tostring(payload.message or ""))
	end
end)

-- ===== Snapshot updates =====
stateSyncRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end

	local function setValue(key: string, text: string, color: Color3?)
		local label = valueLabels[key]
		if label ~= nil then
			label.Text = text
			if color ~= nil then
				label.TextColor3 = color
			end
		end
	end

	setValue("balance", NetworkUtils.FormatCurrency(payload.balance or 0), COLOR_GREEN)
	setValue("reputation", tostring(payload.reputation or 0), COLOR_TEXT)
	setValue("uptime", string.format("%.1f%%", payload.uptimePercent or 0), COLOR_TEXT)
	setValue("power", NetworkUtils.FormatWatts(payload.powerWatts or 0), COLOR_YELLOW)
	local tempC = payload.avgTempC or 0
	setValue("temp", string.format("%.1f °C", tempC), if tempC > 75 then COLOR_RED else COLOR_TEXT)
	setValue("clock", string.format("Hari %d  -  %s", payload.day or 1, payload.clockText or "--:--"), COLOR_TEXT)
end)
