--[[ TabMenuClient: [Tab] membuka game menu (Resume / Save Game / Guide / Reset).

Terminal masih pemilik Tab saat window-nya visible (autocomplete), jadi menu
hanya toggle kalau NetSimTerminal.Window hidden. Tema warna & font ngikutin
TerminalClient supaya keduanya terbaca sebagai satu HUD. ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: any

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
local saveGameRemote = if remotesFolder ~= nil then remotesFolder:FindFirstChild("SaveGameRemote") else nil
local resetRemote = if remotesFolder ~= nil then remotesFolder:FindFirstChild("ResetDataRemote") else nil

-- Tema (sama dengan TerminalClient)
local COLOR_BG = Color3.fromRGB(13, 17, 23)
local COLOR_BAR = Color3.fromRGB(22, 27, 34)
local COLOR_BORDER = Color3.fromRGB(48, 54, 61)
local COLOR_GREEN = Color3.fromRGB(0, 255, 102)
local COLOR_BLUE = Color3.fromRGB(88, 166, 255)
local COLOR_RED = Color3.fromRGB(255, 85, 85)
local COLOR_RED_BG = Color3.fromRGB(145, 40, 48)
local COLOR_YELLOW = Color3.fromRGB(255, 216, 102)
local COLOR_GREY = Color3.fromRGB(139, 148, 158)
local COLOR_TEXT = Color3.fromRGB(201, 209, 217)
local FONT_MONO = Enum.Font.RobotoMono
local FONT_UI = Enum.Font.Gotham
local FONT_UI_BOLD = Enum.Font.GothamBold

---------------------------------------------------------------------
-- Build UI
---------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "NetSimTabMenu"
gui.ResetOnSpawn = false
gui.DisplayOrder = 120
gui.Enabled = false
gui.Parent = playerGui

-- Dim background: klik di luar panel = tutup menu
local dim = Instance.new("TextButton")
dim.Name = "Dim"
dim.Size = UDim2.new(1, 0, 1, 0)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 0.45
dim.BorderSizePixel = 0
dim.Text = ""
dim.AutoButtonColor = false
dim.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 440, 0, 380)
panel.Position = UDim2.new(0.5, -220, 0.5, -190)
panel.BackgroundColor3 = COLOR_BG
panel.BorderSizePixel = 0
panel.Parent = dim

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 12)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = COLOR_BORDER
panelStroke.Thickness = 1
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -32, 0, 34)
title.Position = UDim2.new(0, 20, 0, 12)
title.BackgroundTransparency = 1
title.Font = FONT_UI_BOLD
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLOR_TEXT
title.Text = "GAME MENU"
title.Parent = panel

local titleHint = Instance.new("TextLabel")
titleHint.Name = "TitleHint"
titleHint.Size = UDim2.new(1, -40, 0, 34)
titleHint.Position = UDim2.new(0, 20, 0, 12)
titleHint.BackgroundTransparency = 1
titleHint.Font = FONT_MONO
titleHint.TextSize = 12
titleHint.TextXAlignment = Enum.TextXAlignment.Right
titleHint.TextColor3 = COLOR_GREY
titleHint.Text = "[Tab] close"
titleHint.Parent = panel

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Size = UDim2.new(1, -40, 0, 18)
status.Position = UDim2.new(0, 20, 1, -28)
status.BackgroundTransparency = 1
status.Font = FONT_MONO
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextColor3 = COLOR_GREY
status.Text = ""
status.Parent = panel

-- ===== Buttons =====
local buttonsHolder = Instance.new("Frame")
buttonsHolder.Name = "Buttons"
buttonsHolder.Size = UDim2.new(1, -40, 1, -70)
buttonsHolder.Position = UDim2.new(0, 20, 0, 54)
buttonsHolder.BackgroundTransparency = 1
buttonsHolder.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = buttonsHolder

local function styleButton(btn: TextButton, accent: Color3)
	btn.BackgroundColor3 = COLOR_BAR
	btn.TextColor3 = accent
	btn.Font = FONT_UI_BOLD
	btn.TextSize = 15
	btn.AutoButtonColor = false
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_BORDER
	stroke.Thickness = 1
	stroke.Parent = btn
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = Color3.fromRGB(33, 40, 51)
		stroke.Color = accent
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = COLOR_BAR
		stroke.Color = COLOR_BORDER
	end)
end

local function makeButton(name: string, text: string, accent: Color3, order: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.new(1, 0, 0, 46)
	btn.LayoutOrder = order
	btn.Text = text
	btn.Parent = buttonsHolder
	styleButton(btn, accent)
	return btn
end

local resumeBtn = makeButton("Resume", "RESUME", COLOR_GREEN, 1)
local saveBtn = makeButton("SaveGame", "SAVE GAME", COLOR_BLUE, 2)
local guideBtn = makeButton("Guide", "GUIDE", COLOR_YELLOW, 3)
local resetBtn = makeButton("ResetData", "RESET DATA", COLOR_RED, 4)

-- ===== Guide =====
local guideFrame = Instance.new("Frame")
guideFrame.Name = "Guide"
guideFrame.Size = UDim2.new(1, -40, 1, -110)
guideFrame.Position = UDim2.new(0, 20, 0, 54)
guideFrame.BackgroundColor3 = COLOR_BAR
guideFrame.BorderSizePixel = 0
guideFrame.Visible = false
guideFrame.Parent = panel

local guideCorner = Instance.new("UICorner")
guideCorner.CornerRadius = UDim.new(0, 8)
guideCorner.Parent = guideFrame

local guideScroll = Instance.new("ScrollingFrame")
guideScroll.Name = "Scroll"
guideScroll.Size = UDim2.new(1, -16, 1, -52)
guideScroll.Position = UDim2.new(0, 8, 0, 8)
guideScroll.BackgroundTransparency = 1
guideScroll.BorderSizePixel = 0
guideScroll.ScrollBarThickness = 6
guideScroll.ScrollBarImageColor3 = COLOR_GREY
guideScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
guideScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
guideScroll.Parent = guideFrame

local guideText = Instance.new("TextLabel")
guideText.Name = "GuideText"
guideText.Size = UDim2.new(1, -14, 0, 0)
guideText.AutomaticSize = Enum.AutomaticSize.Y
guideText.BackgroundTransparency = 1
guideText.Font = FONT_MONO
guideText.TextSize = 13
guideText.TextWrapped = true
guideText.RichText = true
guideText.TextXAlignment = Enum.TextXAlignment.Left
guideText.TextYAlignment = Enum.TextYAlignment.Top
guideText.TextColor3 = COLOR_TEXT
guideText.Parent = guideScroll

local guideBack = Instance.new("TextButton")
guideBack.Name = "Back"
guideBack.Size = UDim2.new(1, -16, 0, 32)
guideBack.Position = UDim2.new(0, 8, 1, -40)
guideBack.BackgroundColor3 = COLOR_BG
guideBack.BorderSizePixel = 0
guideBack.Font = FONT_UI_BOLD
guideBack.TextSize = 13
guideBack.TextColor3 = COLOR_BLUE
guideBack.Text = "< BACK"
guideBack.Parent = guideFrame
local guideBackCorner = Instance.new("UICorner")
guideBackCorner.CornerRadius = UDim.new(0, 8)
guideBackCorner.Parent = guideBack

guideText.Text = table.concat({
	'<font color="rgb(88, 166, 255)"><b>QUICK GUIDE</b></font>',
	"",
	'<font color="rgb(255, 216, 102)"><b>Objective</b></font>',
	"Run your own lab: cable the network, host clients, earn money & reputation.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Getting started</b></font>',
	"- Starter kit ships pre-mounted in the rack.",
	"- Click two ports to cable them (switch &gt; router &gt; server). WAN ports need the yellow spool.",
	"- Click a wired port again to unplug.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Terminal [~] / [F2]</b></font>',
	"help, ip set &lt;ip&gt; &lt;gw&gt;, install-os &lt;image&gt;, ping 8.8.8.8,",
	"vm create --name web1 --cpu 4 --ram 8 --disk 200, stress-test,",
	"incident, ddos, drive, shift, journalctl ...",
	"Tab = autocomplete | Up/Down = history | Ctrl+L = clear.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Store [B]</b></font>',
	"Buy hardware, cable spools and spare parts. Ghost placement:",
	"R = rotate, click = place, Esc/right-click = cancel.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Workbench</b></font>',
	"Assemble custom servers (Chassis &gt; Mobo &gt; CPU &gt; RAM &gt; Storage &gt; PSU),",
	"power the bench, install OS, pass stress-test, ship the crate to the dock.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Contracts &amp; income</b></font>',
	"Accept tickets at the NOC desk. VPS income ticks every 15s while VMs are healthy.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Incidents</b></font>',
	"During peak hours (11:00-17:00) outages fire: CableFault, DDoS Flood,",
	"Noisy Neighbor, Drive Failure, Service Crash. Type 'incident' in the",
	"terminal for fix steps. Resolve before SLA expires or reputation drops.",
	"",
	'<font color="rgb(255, 216, 102)"><b>Saving</b></font>',
	"Autosave runs periodically. MENU &gt; SAVE GAME saves instantly (needs a",
	"published place with Studio API access; dev servers in Studio can't save).",
}, "\n")

---------------------------------------------------------------------
-- State & handlers
---------------------------------------------------------------------

local menuOpen = false
local saving = false
local resetArmed = false
local resetArmToken = 0

local function setStatus(text: string, color: Color3?)
	status.Text = text
	status.TextColor3 = color or COLOR_GREY
end

local function showGuide(show: boolean)
	guideFrame.Visible = show
	buttonsHolder.Visible = not show
	titleHint.Text = if show then "[Tab] close" else "[Tab] close"
end

local function setMenuOpen(open: boolean)
	menuOpen = open
	gui.Enabled = open
	resetArmed = false
	resetArmToken += 1
	resetBtn.Text = "RESET DATA"
	resetBtn.BackgroundColor3 = COLOR_BAR
	showGuide(false)
	setStatus("")
end

resumeBtn.MouseButton1Click:Connect(function()
	setMenuOpen(false)
end)

dim.MouseButton1Click:Connect(function()
	setMenuOpen(false)
end)

saveBtn.MouseButton1Click:Connect(function()
	if saving then
		return
	end
	if saveGameRemote == nil then
		setStatus("save unavailable (remote missing)", COLOR_RED)
		return
	end
	saving = true
	setStatus("saving ...", COLOR_GREY)
	local okCall, res1, res2 = pcall(function()
		return (saveGameRemote :: any):InvokeServer()
	end)
	saving = false
	if not okCall then
		setStatus("save failed: " .. tostring(res1), COLOR_RED)
		return
	end
	if res1 == true then
		setStatus("game saved", COLOR_GREEN)
	else
		setStatus(tostring(res2), COLOR_YELLOW)
	end
end)

guideBtn.MouseButton1Click:Connect(function()
	showGuide(true)
end)

guideBack.MouseButton1Click:Connect(function()
	showGuide(false)
end)

resetBtn.MouseButton1Click:Connect(function()
	if not resetArmed then
		resetArmed = true
		resetArmToken += 1
		local token = resetArmToken
		resetBtn.Text = "CLICK AGAIN TO WIPE SAVE"
		resetBtn.BackgroundColor3 = COLOR_RED_BG
		setStatus("this wipes your save and rebuilds the lab", COLOR_YELLOW)
		task.delay(4, function()
			if resetArmed and token == resetArmToken then
				resetArmed = false
				resetBtn.Text = "RESET DATA"
				resetBtn.BackgroundColor3 = COLOR_BAR
				setStatus("")
			end
		end)
		return
	end
	resetArmed = false
	if resetRemote ~= nil then
		(resetRemote :: any):FireServer()
	end
	setMenuOpen(false)
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if input.KeyCode ~= Enum.KeyCode.Tab or gameProcessed then
		return
	end
	-- Terminal memegang Tab saat window-nya visible (autocomplete).
	local term = playerGui:FindFirstChild("NetSimTerminal")
	local termWin = if term ~= nil then term:FindFirstChild("Window") else nil
	if termWin ~= nil and termWin.Visible then
		return
	end
	setMenuOpen(not menuOpen)
end)
