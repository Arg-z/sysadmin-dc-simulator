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
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkUtils = require(sharedFolder:WaitForChild("NetworkUtils"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[HudClient] ReplicatedStorage.Remotes not found (timeout 180s)")
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
local COLOR_CYAN = Color3.fromRGB(44, 156, 208)

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
panel.Size = UDim2.new(0, 212, 0, 190)
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
panelTitle.Text = "LAB STATUS"
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
	label.Text = "BALANCE"
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
	{ key = "reputation", label = "Reputation" },
	{ key = "uptime", label = "Uptime" },
	{ key = "power", label = "Power" },
	{ key = "temp", label = "Temp" },
	{ key = "clock", label = "Day / Time" },
	{ key = "phase", label = "Phase" },
	{ key = "insiden", label = "Incidents" },
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
resetBtn.Position = UDim2.new(1, -12, 0, 208)
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


-- Left column: objectives checklist (moved here from the TicketMonitor)
local OBJECTIVES: { { key: string, label: string } } = {
	{ key = "cableWired", label = "Cable switch -> router & server" },
	{ key = "ipSetStarter", label = "Configure starter server IP" },
	{ key = "osInstalledStarter", label = "Install OS on starter server" },
	{ key = "pingGateway", label = "Ping gateway router" },
	{ key = "vmCreated", label = "Create first VM" },
	{ key = "benchBuilt", label = "Assemble server on workbench" },
	{ key = "benchOsInstalled", label = "Workbench: install OS" },
	{ key = "stressPassed", label = "Pass stress test" },
	{ key = "shipped", label = "Ship custom server crate" },
}
local objectiveDefs: { [string]: string } = {}
for _, objDef in ipairs(OBJECTIVES) do
	objectiveDefs[objDef.key] = objDef.label
end

local objPanel = Instance.new("Frame")
objPanel.Name = "ObjectivesPanel"
objPanel.Position = UDim2.new(0, 12, 0, 50)
objPanel.Size = UDim2.new(0, 224, 0, 182)
objPanel.BackgroundColor3 = COLOR_BG
objPanel.BackgroundTransparency = 0.4
objPanel.BorderSizePixel = 0
objPanel.Visible = false
objPanel.Parent = gui
local objPanelCorner = Instance.new("UICorner")
objPanelCorner.CornerRadius = UDim.new(0, 10)
objPanelCorner.Parent = objPanel
local objPanelStroke = Instance.new("UIStroke")
objPanelStroke.Color = COLOR_BORDER
objPanelStroke.Thickness = 1
objPanelStroke.Parent = objPanel

local objTitle = Instance.new("TextButton")
objTitle.Name = "ObjectivesTitle"
objTitle.Size = UDim2.new(1, -12, 0, 16)
objTitle.Position = UDim2.new(0, 8, 0, 4)
objTitle.BackgroundTransparency = 1
objTitle.Font = Enum.Font.GothamBold
objTitle.TextSize = 11
objTitle.TextXAlignment = Enum.TextXAlignment.Left
objTitle.TextColor3 = COLOR_GREY
objTitle.Text = "OBJECTIVES  [O]  (click to hide)"
objTitle.AutoButtonColor = false
objTitle.Parent = objPanel

-- Collapsed pill: the checklist starts hidden so it does not cover the lab.
local objPill = Instance.new("TextButton")
objPill.Name = "ObjectivesPill"
objPill.Position = UDim2.new(0, 12, 0, 50)
objPill.Size = UDim2.new(0, 150, 0, 26)
objPill.BackgroundColor3 = COLOR_CARD
objPill.BackgroundTransparency = 0.2
objPill.Font = Enum.Font.GothamBold
objPill.TextSize = 12
objPill.TextColor3 = COLOR_GREY
objPill.Text = "OBJECTIVES [O]"
objPill.AutoButtonColor = true
objPill.Parent = gui
local objPillCorner = Instance.new("UICorner")
objPillCorner.CornerRadius = UDim.new(0, 6)
objPillCorner.Parent = objPill
local objPillStroke = Instance.new("UIStroke")
objPillStroke.Color = COLOR_BORDER
objPillStroke.Thickness = 1
objPillStroke.Parent = objPill

local objList = Instance.new("Frame")
objList.Name = "ObjectivesList"
objList.Position = UDim2.new(0, 8, 0, 20)
objList.Size = UDim2.new(1, -16, 1, -26)
objList.BackgroundTransparency = 1
objList.Parent = objPanel
local objListLayout = Instance.new("UIListLayout")
objListLayout.FillDirection = Enum.FillDirection.Vertical
objListLayout.Padding = UDim.new(0, 2)
objListLayout.SortOrder = Enum.SortOrder.LayoutOrder
objListLayout.Parent = objList

local objectiveRows: { [string]: TextLabel } = {}
for _, objDef in ipairs(OBJECTIVES) do
	local row = Instance.new("TextLabel")
	row.Name = "Objective_" .. objDef.key
	row.Size = UDim2.new(1, 0, 0, 16)
	row.BackgroundTransparency = 1
	row.Font = Enum.Font.Gotham
	row.TextSize = 12
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.TextColor3 = COLOR_GREY
	row.Text = "o  " .. objDef.label
	row.Parent = objList
	objectiveRows[objDef.key] = row
end

local objectivesOpen = false
local function setObjectivesOpen(open: boolean)
	objectivesOpen = open
	objPanel.Visible = open
	objPill.Visible = not open
end
objTitle.MouseButton1Click:Connect(function()
	setObjectivesOpen(false)
end)
objPill.MouseButton1Click:Connect(function()
	setObjectivesOpen(true)
end)
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
		return
	end
	if input.KeyCode == Enum.KeyCode.O then
		setObjectivesOpen(not objectivesOpen)
	end
end)
setObjectivesOpen(false)

-- ===== Current step banner (top-center) =====
-- Short Indonesian instruction for the first unfinished objective.
local OBJECTIVE_HINTS: { [string]: string } = {
	cableWired = "Dekati rak: klik port switch lalu port router/server untuk menyambung kabel LAN (klik port yang terpasang = lepas)",
	ipSetStarter = "Klik laptop di hotbar [1], sambungkan console ke server, lalu di terminal: ip set 10.0.0.2 10.0.0.1",
	osInstalledStarter = "Di terminal server: install-os ubuntu-22.04",
	pingGateway = "Di terminal: ping 10.0.0.1",
	vmCreated = "Di terminal: vm create --name web1 --cpu 4 --ram 8 --disk 200",
	benchBuilt = "Ke workbench, beli komponen di Store [B], rakit: Chassis>Mobo>CPU>RAM>Storage>PSU",
	benchOsInstalled = "Nyalakan bench, sambung console laptop ke bench server, install-os ubuntu-22.04",
	stressPassed = "Di terminal bench: stress-test",
	shipped = "Di workbench: ship crate, lalu ambil di dock dan kirim",
}
local STEP_DONE_TEXT = "Semua langkah selesai — kembangkan labmu! Income jalan tiap 15 detik."

local bannerGui = Instance.new("ScreenGui")
bannerGui.Name = "NetSimStepBanner"
bannerGui.ResetOnSpawn = false
bannerGui.DisplayOrder = 90
bannerGui.Parent = playerGui

local banner = Instance.new("Frame")
banner.Name = "StepBanner"
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.new(0.5, 0, 0, 8)
banner.Size = UDim2.new(0, 560, 0, 46)
banner.BackgroundColor3 = COLOR_BG
banner.BackgroundTransparency = 0.06
banner.BorderSizePixel = 0
banner.Parent = bannerGui
local bannerCorner = Instance.new("UICorner")
bannerCorner.CornerRadius = UDim.new(0, 8)
bannerCorner.Parent = banner
local bannerStroke = Instance.new("UIStroke")
bannerStroke.Color = COLOR_CYAN
bannerStroke.Thickness = 1
bannerStroke.Parent = banner

local bannerTag = Instance.new("TextLabel")
bannerTag.Name = "StepTag"
bannerTag.Size = UDim2.new(0, 70, 1, 0)
bannerTag.Position = UDim2.new(0, 10, 0, 0)
bannerTag.BackgroundTransparency = 1
bannerTag.Font = Enum.Font.GothamBold
bannerTag.TextSize = 11
bannerTag.TextXAlignment = Enum.TextXAlignment.Left
bannerTag.TextColor3 = COLOR_CYAN
bannerTag.Text = "LANGKAH"
bannerTag.Parent = banner

local bannerText = Instance.new("TextLabel")
bannerText.Name = "StepText"
bannerText.AnchorPoint = Vector2.new(0.5, 0.5)
bannerText.Position = UDim2.new(0.5, 5, 0.5, 0)
bannerText.Size = UDim2.new(1, -160, 1, -8)
bannerText.BackgroundTransparency = 1
bannerText.Font = Enum.Font.Gotham
bannerText.TextSize = 14
bannerText.TextColor3 = COLOR_TEXT
bannerText.TextWrapped = true
bannerText.TextTruncate = Enum.TextTruncate.AtEnd
bannerText.Text = OBJECTIVE_HINTS.cableWired
bannerText.Parent = banner

local bannerKeyHint = Instance.new("TextLabel")
bannerKeyHint.Name = "StepKeyHint"
bannerKeyHint.AnchorPoint = Vector2.new(1, 0)
bannerKeyHint.Position = UDim2.new(1, -10, 0, 0)
bannerKeyHint.Size = UDim2.new(0, 60, 1, 0)
bannerKeyHint.BackgroundTransparency = 1
bannerKeyHint.Font = Enum.Font.Gotham
bannerKeyHint.TextSize = 11
bannerKeyHint.TextXAlignment = Enum.TextXAlignment.Right
bannerKeyHint.TextColor3 = COLOR_GREY
bannerKeyHint.Text = "lihat [O]"
bannerKeyHint.Parent = banner

-- Pick the first unfinished objective (OBJECTIVES order) and show its hint;
-- when everything is done, switch the banner to a green "all clear" state.
local function updateStepBanner(objectives: { [string]: boolean }?)
	local doneMap: { [string]: boolean } = objectives or {}
	local currentKey: string? = nil
	for _, objDef in ipairs(OBJECTIVES) do
		if doneMap[objDef.key] ~= true then
			currentKey = objDef.key
			break
		end
	end

	if currentKey == nil then
		bannerText.Text = STEP_DONE_TEXT
		bannerText.TextColor3 = COLOR_GREEN
		bannerStroke.Color = COLOR_GREEN
		bannerTag.TextColor3 = COLOR_GREEN
	else
		bannerText.Text = OBJECTIVE_HINTS[currentKey] or OBJECTIVE_HINTS.cableWired
		bannerText.TextColor3 = COLOR_TEXT
		bannerStroke.Color = COLOR_CYAN
		bannerTag.TextColor3 = COLOR_CYAN
	end
end

-- ===== Welcome tutorial card (shown once per join) =====
local welcomeGui = Instance.new("ScreenGui")
welcomeGui.Name = "NetSimWelcome"
welcomeGui.ResetOnSpawn = false
welcomeGui.DisplayOrder = 110
welcomeGui.Enabled = false
welcomeGui.Parent = playerGui

-- Clickable backdrop: clicking outside the panel closes the card.
local welcomeDim = Instance.new("TextButton")
welcomeDim.Name = "Backdrop"
welcomeDim.Size = UDim2.new(1, 0, 1, 0)
welcomeDim.BackgroundColor3 = Color3.new(0, 0, 0)
welcomeDim.BackgroundTransparency = 0.55
welcomeDim.BorderSizePixel = 0
welcomeDim.Text = ""
welcomeDim.AutoButtonColor = false
welcomeDim.Parent = welcomeGui

local welcomePanel = Instance.new("Frame")
welcomePanel.Name = "Card"
welcomePanel.AnchorPoint = Vector2.new(0.5, 0.5)
welcomePanel.Position = UDim2.new(0.5, 0, 0.5, 0)
welcomePanel.Size = UDim2.new(0, 520, 0, 400)
welcomePanel.BackgroundColor3 = COLOR_BG
welcomePanel.BackgroundTransparency = 0.06
welcomePanel.BorderSizePixel = 0
welcomePanel.Active = true
welcomePanel.Parent = welcomeDim
local welcomePanelCorner = Instance.new("UICorner")
welcomePanelCorner.CornerRadius = UDim.new(0, 10)
welcomePanelCorner.Parent = welcomePanel
local welcomePanelStroke = Instance.new("UIStroke")
welcomePanelStroke.Color = COLOR_CYAN
welcomePanelStroke.Thickness = 1
welcomePanelStroke.Parent = welcomePanel

local welcomeTitle = Instance.new("TextLabel")
welcomeTitle.Name = "Title"
welcomeTitle.Size = UDim2.new(1, -32, 0, 28)
welcomeTitle.Position = UDim2.new(0, 16, 0, 16)
welcomeTitle.BackgroundTransparency = 1
welcomeTitle.Font = Enum.Font.GothamBold
welcomeTitle.TextSize = 20
welcomeTitle.TextXAlignment = Enum.TextXAlignment.Center
welcomeTitle.TextColor3 = COLOR_GREEN
welcomeTitle.Text = "SELAMAT DATANG, SYSADMIN"
welcomeTitle.Parent = welcomePanel

local welcomeGoal = Instance.new("TextLabel")
welcomeGoal.Name = "Goal"
welcomeGoal.Size = UDim2.new(1, -32, 0, 44)
welcomeGoal.Position = UDim2.new(0, 16, 0, 54)
welcomeGoal.BackgroundTransparency = 1
welcomeGoal.Font = Enum.Font.Gotham
welcomeGoal.TextSize = 14
welcomeGoal.TextXAlignment = Enum.TextXAlignment.Center
welcomeGoal.TextColor3 = COLOR_TEXT
welcomeGoal.TextWrapped = true
welcomeGoal.Text = "Tujuan: bangun lab servermu — kabel, install OS, hosting VM, terima kontrak, dapat income."
welcomeGoal.Parent = welcomePanel

local welcomeControls = Instance.new("TextLabel")
welcomeControls.Name = "Controls"
welcomeControls.Size = UDim2.new(1, -32, 0, 150)
welcomeControls.Position = UDim2.new(0, 16, 0, 108)
welcomeControls.BackgroundTransparency = 1
welcomeControls.Font = Enum.Font.Gotham
welcomeControls.TextSize = 13
welcomeControls.TextXAlignment = Enum.TextXAlignment.Left
welcomeControls.TextYAlignment = Enum.TextYAlignment.Top
welcomeControls.TextColor3 = COLOR_TEXT
welcomeControls.TextWrapped = true
welcomeControls.Text = table.concat({
	"[WASD] — gerak",
	"[Klik port] — pasang kabel LAN (klik port terpasang = lepas)",
	"[Laptop 1] + [E] dekat device — console",
	"[~] / [F2] — terminal",
	"[B] — toko",
	"[O] — objectives",
	"[Tab] — menu (save / guide / reset)",
}, "\n")
welcomeControls.Parent = welcomePanel

local welcomeNote = Instance.new("TextLabel")
welcomeNote.Name = "Note"
welcomeNote.Size = UDim2.new(1, -32, 0, 22)
welcomeNote.Position = UDim2.new(0, 16, 0, 266)
welcomeNote.BackgroundTransparency = 1
welcomeNote.Font = Enum.Font.GothamBold
welcomeNote.TextSize = 13
welcomeNote.TextXAlignment = Enum.TextXAlignment.Center
welcomeNote.TextColor3 = COLOR_CYAN
welcomeNote.TextWrapped = true
welcomeNote.Text = "Ikuti banner LANGKAH di atas — selalu menunjukkan langkah berikutnya."
welcomeNote.Parent = welcomePanel

local welcomeStartBtn = Instance.new("TextButton")
welcomeStartBtn.Name = "StartButton"
welcomeStartBtn.AnchorPoint = Vector2.new(0.5, 0)
welcomeStartBtn.Position = UDim2.new(0.5, 0, 0, 330)
welcomeStartBtn.Size = UDim2.new(0, 160, 0, 40)
welcomeStartBtn.BackgroundColor3 = COLOR_GREEN
welcomeStartBtn.Font = Enum.Font.GothamBold
welcomeStartBtn.TextSize = 15
welcomeStartBtn.TextColor3 = COLOR_BG
welcomeStartBtn.Text = "MULAI"
welcomeStartBtn.AutoButtonColor = true
welcomeStartBtn.Parent = welcomePanel
local welcomeStartCorner = Instance.new("UICorner")
welcomeStartCorner.CornerRadius = UDim.new(0, 6)
welcomeStartCorner.Parent = welcomeStartBtn

local function closeWelcome()
	welcomeGui.Enabled = false
end
welcomeStartBtn.MouseButton1Click:Connect(closeWelcome)
welcomeDim.MouseButton1Click:Connect(closeWelcome)

-- Reveal once per join, shortly after spawn so the HUD is ready first.
task.delay(0.6, function()
	welcomeGui.Enabled = true
end)

-- ===== Hint system: rotating PC tips + priority server hints =====
local TIPS = {
	"Press [~] or [F2] to open / close Terminal (or click X [~])",
	"Press [B] to open / close the Hardware Store",
	"Press [O] to show / hide the objectives checklist (top-left)",
	"Stand in front of the NOC Desk + press [E] for 3-Monitor Workstation View",
	"Equip TechnicianLaptop [1] + press [E] near a device = Console Cable",
	"Click two different ports to wire a LAN cable | Click a wired port to unplug",
	"Placement mode: [R] Rotate 90 deg | Left Click = Place | Right Click / [Esc] = Cancel",
	"Color-coded cables: WAN ports auto-use yellow spool, data ports use blue/red",
	"Colocation: accept contract, pick up crate at dock, mount in rack, configure VLAN + PDU",
	"Peak hours 11:00-17:00: incidents may trigger. Type 'incident' in terminal to resolve",
	"Red alarm + klaxon = active outage. Check TicketMonitor or type 'incident'",
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
		showPriority("Data reset! Rebuilding server lab...")
	else
		resetArmed = true
		resetBtn.Text = "CONFIRM? CLICK AGAIN (4s)"
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
		warn("[HudClient] BindableEvent NetSimToggleStore not found; STORE button hidden")
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
	setValue("clock", string.format("Day %d  -  %s", payload.day or 1, payload.clockText or "--:--"), COLOR_TEXT)
	local phase = tostring(payload.shiftPhase or "-")
	setValue("phase", phase, if phase == "PEAK HOURS" or phase == "JAM SIBUK" then COLOR_YELLOW else COLOR_TEXT)
	local incidentCount = tonumber(payload.incidentCount) or 0
	setValue(
		"insiden",
		if incidentCount > 0 then string.format("%d ACTIVE", incidentCount) else "Clear",
		if incidentCount > 0 then COLOR_RED else COLOR_GREEN
	)
	-- Objectives checklist
	local objectives = payload.objectives or {}
	for key, row in pairs(objectiveRows) do
		local done = objectives[key] == true
		row.Text = (done and "✓ " or "o ") .. objectiveDefs[key]
		row.TextColor3 = if done then COLOR_GREEN else COLOR_GREY
	end
	-- Step banner follows the same objectives payload.
	updateStepBanner(objectives)

end)
