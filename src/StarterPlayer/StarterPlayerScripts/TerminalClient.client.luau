--!strict
--[[
	TerminalClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	GUI Terminal: local shell / console device / SSH session.

	Protocol (CONTRACT.md Section 3):
	- OpenTerminalEvent (RE): server->client {action="open", mode, deviceName, deviceId} |
	  {action="detach"} | {action="hint", message}; client->server {action="request_shell"}.
	- ExecuteCommand (RF): InvokeServer(rawText) -> {lines = {string}}, RichText allowed,
	  single line "__CLEAR__" = clear buffer.
	- TerminalPushOutput (RE): server->client {lines = {string}} (async completion).

	Laptop tool "TechnicianLaptop" Activated -> FireServer({action="request_shell"}).
	Hooked via player.Character ChildAdded + CharacterAdded re-hook.
	History Up/Down + Tab autocomplete work even while the TextBox is focused
	(UserInputService.InputBegan WITHOUT gameProcessed filter, gated on window visible).
	All GUI strings in Indonesian (game language), code comments in English.
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
	warn("[TerminalClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local executeRemote = remotesFolder:WaitForChild("ExecuteCommand") :: RemoteFunction
local pushOutputRemote = remotesFolder:WaitForChild("TerminalPushOutput") :: RemoteEvent
local openTerminalRemote = remotesFolder:WaitForChild("OpenTerminalEvent") :: RemoteEvent

-- ===== Dark theme palette (#0D1117 base) =====
local COLOR_BG = Color3.fromRGB(13, 17, 23)
local COLOR_BAR = Color3.fromRGB(22, 27, 34)
local COLOR_OUTPUT = Color3.fromRGB(8, 11, 15)
local COLOR_BORDER = Color3.fromRGB(48, 54, 61)
local COLOR_GREEN = Color3.fromRGB(0, 255, 102)
local COLOR_BLUE = Color3.fromRGB(88, 166, 255)
local COLOR_RED = Color3.fromRGB(255, 85, 85)
local COLOR_YELLOW = Color3.fromRGB(255, 216, 102)
local COLOR_GREY = Color3.fromRGB(139, 148, 158)
local COLOR_TEXT = Color3.fromRGB(201, 209, 217)

-- ===== GUI build =====
local gui = Instance.new("ScreenGui")
gui.Name = "NetSimTerminal"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.IgnoreGuiInset = false
gui.Parent = playerGui

local window = Instance.new("Frame")
window.Name = "Window"
window.AnchorPoint = Vector2.new(0, 0.5)
window.Position = UDim2.new(1, -572, 0.5, 0) -- right-center, safe on 1280x720
window.Size = UDim2.new(0, 560, 0, 340)
window.BackgroundColor3 = COLOR_BG
window.BorderSizePixel = 0
window.Visible = false
window.Parent = gui
local windowCorner = Instance.new("UICorner")
windowCorner.CornerRadius = UDim.new(0, 10)
windowCorner.Parent = window

local windowStroke = Instance.new("UIStroke")
windowStroke.Color = COLOR_BORDER
windowStroke.Thickness = 1
windowStroke.Parent = window

-- Top bar: mode label + hint overlay + close button
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 34)
topBar.BackgroundColor3 = COLOR_BAR
topBar.BorderSizePixel = 0
topBar.Parent = window
local topBarCorner = Instance.new("UICorner")
topBarCorner.CornerRadius = UDim.new(0, 10)
topBarCorner.Parent = topBar

local modeLabel = Instance.new("TextLabel")
modeLabel.Name = "ModeLabel"
modeLabel.Size = UDim2.new(1, -60, 1, 0)
modeLabel.Position = UDim2.new(0, 12, 0, 0)
modeLabel.BackgroundTransparency = 1
modeLabel.Font = Enum.Font.RobotoMono
modeLabel.TextSize = 14
modeLabel.TextXAlignment = Enum.TextXAlignment.Left
modeLabel.TextColor3 = COLOR_GREEN
modeLabel.Text = "[LOCAL SHELL]"
modeLabel.Parent = topBar

-- Hint overlay shown inside the bar area for 3 seconds
local hintLabel = Instance.new("TextLabel")
hintLabel.Name = "HintLabel"
hintLabel.Size = UDim2.new(1, -60, 1, 0)
hintLabel.Position = UDim2.new(0, 12, 0, 0)
hintLabel.BackgroundTransparency = 1
hintLabel.Font = Enum.Font.RobotoMono
hintLabel.TextSize = 13
hintLabel.TextXAlignment = Enum.TextXAlignment.Left
hintLabel.TextTruncate = Enum.TextTruncate.AtEnd
hintLabel.TextColor3 = COLOR_YELLOW
hintLabel.Text = ""
hintLabel.Visible = false
hintLabel.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 28, 0, 26)
closeBtn.Position = UDim2.new(1, -34, 0, 4)
closeBtn.BackgroundColor3 = COLOR_BORDER
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 13
closeBtn.TextColor3 = COLOR_RED
closeBtn.Text = "X"
closeBtn.AutoButtonColor = true
closeBtn.Parent = topBar
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

-- Output: ScrollingFrame + one RichText TextLabel (AutomaticSize Y)
local outputScroll = Instance.new("ScrollingFrame")
outputScroll.Name = "OutputScroll"
outputScroll.Position = UDim2.new(0, 8, 0, 40)
outputScroll.Size = UDim2.new(1, -16, 1, -40 - 38)
outputScroll.BackgroundColor3 = COLOR_OUTPUT
outputScroll.BorderSizePixel = 0
outputScroll.ScrollBarThickness = 6
outputScroll.ScrollBarImageColor3 = COLOR_BORDER
outputScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
outputScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
outputScroll.Parent = window
local outputPadding = Instance.new("UIPadding")
outputPadding.PaddingBottom = UDim.new(0, 6)
outputPadding.Parent = outputScroll

local outputLabel = Instance.new("TextLabel")
outputLabel.Name = "OutputLabel"
outputLabel.Size = UDim2.new(1, -8, 0, 0)
outputLabel.Position = UDim2.new(0, 4, 0, 4)
outputLabel.BackgroundTransparency = 1
outputLabel.RichText = true
outputLabel.AutomaticSize = Enum.AutomaticSize.Y
outputLabel.TextWrapped = true
outputLabel.Font = Enum.Font.RobotoMono
outputLabel.TextSize = 13
outputLabel.TextXAlignment = Enum.TextXAlignment.Left
outputLabel.TextYAlignment = Enum.TextYAlignment.Top
outputLabel.TextColor3 = COLOR_TEXT
outputLabel.Text = ""
outputLabel.Parent = outputScroll

-- Input TextBox (bottom). Name "InputBox" is referenced by AudioAndEffectsClient.
local inputBox = Instance.new("TextBox")
inputBox.Name = "InputBox"
inputBox.Position = UDim2.new(0, 8, 1, -34)
inputBox.Size = UDim2.new(1, -16, 0, 28)
inputBox.BackgroundColor3 = COLOR_BAR
inputBox.Font = Enum.Font.RobotoMono
inputBox.TextSize = 14
inputBox.TextColor3 = COLOR_BLUE
inputBox.PlaceholderText = "type help; enter = kirim"
inputBox.PlaceholderColor3 = COLOR_GREY
inputBox.ClearTextOnFocus = false
inputBox.Text = ""
inputBox.TextXAlignment = Enum.TextXAlignment.Left
inputBox.Parent = window
local inputCorner = Instance.new("UICorner")
inputCorner.CornerRadius = UDim.new(0, 6)
inputCorner.Parent = inputBox
local inputStroke = Instance.new("UIStroke")
inputStroke.Color = COLOR_BORDER
inputStroke.Thickness = 1
inputStroke.Parent = inputBox

-- ===== Terminal state =====
local buffer: { string } = {}
local history: { string } = {}
local historyIndex = 1
local hintToken = 0
local MAX_BUFFER_LINES = 500

local COMMANDS = {
	"help", "clear", "ping", "traceroute", "ip a", "ip set", "ssh", "exit",
	"top", "vm create", "vm list", "vm throttle", "vm delete", "install-os", "stress-test",
}

local function scrollToEnd()
	task.defer(function()
		-- Overshoot; the ScrollingFrame clamps to the canvas bounds on the next layout pass.
		outputScroll.CanvasPosition = Vector2.new(0, 1e9)
	end)
end

local function appendLines(lines: { string })
	for _, line in ipairs(lines) do
		table.insert(buffer, tostring(line))
	end
	while #buffer > MAX_BUFFER_LINES do
		table.remove(buffer, 1)
	end
	outputLabel.Text = table.concat(buffer, "\n")
	scrollToEnd()
end

local function clearBuffer()
	buffer = {}
	outputLabel.Text = ""
	outputScroll.CanvasPosition = Vector2.new(0, 0)
end

local function refocusInput()
	if not window.Visible then
		return
	end
	task.defer(function()
		if window.Visible then
			inputBox:CaptureFocus()
		end
	end)
end

local function titleFor(mode: string?, deviceName: string?): string
	if mode == "LocalConsole" then
		return "[CONSOLE: " .. (deviceName or "?") .. "]"
	elseif mode == "RemoteSSH" then
		return "[SSH: " .. (deviceName or "?") .. "]"
	end
	return "[LOCAL SHELL]"
end

-- Hint message shown in the bar area for 3 seconds
local function showHint(message: string)
	hintToken += 1
	local myToken = hintToken
	hintLabel.Text = message
	hintLabel.Visible = true
	modeLabel.Visible = false
	task.delay(3, function()
		if hintToken == myToken then
			hintLabel.Visible = false
			modeLabel.Visible = true
		end
	end)
end

-- ===== Command history + Tab autocomplete =====
local function historyUp()
	if #history == 0 then
		return
	end
	historyIndex = math.max(1, math.min(historyIndex - 1, #history))
	inputBox.Text = history[historyIndex] or ""
end

local function historyDown()
	if #history == 0 then
		return
	end
	historyIndex = math.min(#history + 1, historyIndex + 1)
	if historyIndex <= #history then
		inputBox.Text = history[historyIndex] or ""
	else
		inputBox.Text = ""
	end
end

local function tabComplete()
	local current = inputBox.Text
	if #current == 0 then
		return
	end
	local lower = string.lower(current)
	local matches: { string } = {}
	for _, cmd in ipairs(COMMANDS) do
		if string.sub(cmd, 1, #lower) == lower then
			table.insert(matches, cmd)
		end
	end
	if #matches == 0 then
		return
	end
	if #matches == 1 then
		inputBox.Text = matches[1] .. " "
		return
	end
	-- Complete up to the longest common prefix of all matches
	local prefix = matches[1]
	for i = 2, #matches do
		local other = matches[i]
		local maxLen = math.min(#prefix, #other)
		local keep = 0
		for j = 1, maxLen do
			if string.sub(prefix, j, j) == string.sub(other, j, j) then
				keep = j
			else
				break
			end
		end
		prefix = string.sub(prefix, 1, keep)
		if #prefix == 0 then
			break
		end
	end
	if #prefix > #lower then
		inputBox.Text = prefix
	end
end

-- UIS.InputBegan without gameProcessed filter: Up/Down/Tab must work while
-- the TextBox has focus (gameProcessed == true in that case).
UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if not window.Visible then
		return
	end
	if input.KeyCode == Enum.KeyCode.Up then
		historyUp()
	elseif input.KeyCode == Enum.KeyCode.Down then
		historyDown()
	elseif input.KeyCode == Enum.KeyCode.Tab then
		tabComplete()
	end
end)

-- ===== Enter = send command =====
inputBox.FocusLost:Connect(function(enterPressed: boolean)
	if not enterPressed then
		return
	end
	local raw = inputBox.Text
	inputBox.Text = ""
	historyIndex = #history + 1
	if raw == nil or #raw == 0 then
		refocusInput()
		return
	end

	table.insert(history, raw)
	historyIndex = #history + 1

	-- Local echo of the typed command (escaped before embedding in RichText)
	appendLines({
		string.format('<font color="#58A6FF">&gt; %s</font>', NetworkUtils.EscapeRich(raw)),
	})

	local ok, result = pcall(function(): any
		return (executeRemote :: any):InvokeServer(raw)
	end)
	if not ok then
		appendLines({ '<font color="#FF5555">[terminal] gagal mengirim perintah ke server</font>' })
	else
		local lines = (result :: any).lines
		if type(lines) == "table" then
			if #lines == 1 and lines[1] == "__CLEAR__" then
				clearBuffer()
			else
				local strs: { string } = {}
				for _, line in ipairs(lines :: { any }) do
					table.insert(strs, tostring(line))
				end
				appendLines(strs)
			end
		end
	end
	refocusInput()
end)

-- ===== Server -> client =====
openTerminalRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local action = payload.action
	if action == "open" then
		window.Visible = true
		modeLabel.Visible = true
		hintLabel.Visible = false
		modeLabel.Text = titleFor(payload.mode, payload.deviceName)
		refocusInput()
	elseif action == "detach" then
		-- Keep the window open, just fall back to the local shell title
		modeLabel.Visible = true
		hintLabel.Visible = false
		modeLabel.Text = "[LOCAL SHELL]"
	elseif action == "hint" then
		showHint(tostring(payload.message or ""))
	end
end)

pushOutputRemote.OnClientEvent:Connect(function(lines: any)
	if type(lines) ~= "table" then
		return
	end
	local strs: { string } = {}
	for _, line in ipairs(lines :: { any }) do
		table.insert(strs, tostring(line))
	end
	if #strs > 0 then
		appendLines(strs)
	end
end)

closeBtn.MouseButton1Click:Connect(function()
	inputBox:ReleaseFocus()
	window.Visible = false
end)

-- ===== Laptop tool hook (Activated -> request_shell) =====
local function bindTool(tool: Tool)
	if tool:GetAttribute("NetSimTermHooked") == true then
		return
	end
	tool:SetAttribute("NetSimTermHooked", true)
	tool.Activated:Connect(function()
		openTerminalRemote:FireServer({ action = "request_shell" })
	end)
end

local function bindCharacter(char: Model)
	char.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Tool") and child.Name == "TechnicianLaptop" then
			bindTool(child :: Tool)
		end
	end)
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("Tool") and child.Name == "TechnicianLaptop" then
			bindTool(child :: Tool)
		end
	end
end

player.CharacterAdded:Connect(function(char: Model)
	bindCharacter(char)
end)
if player.Character ~= nil then
	bindCharacter(player.Character :: Model)
end

-- ===== Welcome banner (Indonesian) =====
appendLines({
	'<font color="#00FF66">[NetSim Terminal] Selamat datang, teknisi.</font>',
	'<font color="#8B949E">Ketik <b>help</b> untuk daftar perintah. Panah atas/bawah = riwayat, Tab = autocomplete, enter = kirim.</font>',
})
