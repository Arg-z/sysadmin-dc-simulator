--!strict
--[[
	TerminalClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	GUI Terminal yang dioptimalkan untuk PC (keyboard + mouse):
	- Ukuran desktop lega (680x430), bisa di-drag lewat TopBar.
	- Tutup cepat: klik tombol "X [~]" (MouseButton1Down, tidak bentrok dengan
	  TextBox focus maupun Tool.Activated), tekan [~] / [F2] / [Ctrl+W],
	  klik tombol "TERMINAL [~]" di HUD, atau ketik "close" / "quit".
	- Modal = true pada closeBtn agar kursor mouse otomatis bebas meski pemain
	  sedang mode First-Person / ShiftLock di PC.
	- History Up/Down, Tab autocomplete, Ctrl+L clear layar, scroll wheel mulus.
	- Tool "TechnicianLaptop" Activated tidak akan membuka ulang terminal saat
	  pemain mengklik tombol UI atau baru saja menutup terminal.

	Protocol (CONTRACT.md Section 3):
	- OpenTerminalEvent (RE): server->client {action="open", mode, deviceName, deviceId} |
	  {action="detach"} | {action="hint", message}; client->server {action="request_shell"}.
	- ExecuteCommand (RF): InvokeServer(rawText) -> {lines = {string}}, RichText allowed,
	  single line "__CLEAR__" = clear buffer.
	- TerminalPushOutput (RE): server->client {lines = {string}} (async completion).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
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
local COLOR_RED_BG = Color3.fromRGB(145, 40, 48)
local COLOR_YELLOW = Color3.fromRGB(255, 216, 102)
local COLOR_GREY = Color3.fromRGB(139, 148, 158)
local COLOR_TEXT = Color3.fromRGB(201, 209, 217)

-- ===== GUI build (PC-optimized desktop window) =====
local gui = Instance.new("ScreenGui")
gui.Name = "NetSimTerminal"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.IgnoreGuiInset = false
gui.Parent = playerGui

local window = Instance.new("Frame")
window.Name = "Window"
window.AnchorPoint = Vector2.new(0.5, 0.5)
window.Position = UDim2.new(0.62, 0, 0.52, 0) -- comfortable right-of-center PC placement
window.Size = UDim2.new(0, 680, 0, 430)
window.BackgroundColor3 = COLOR_BG
window.BorderSizePixel = 0
window.Active = true -- absorb mouse clicks inside window so Tool.Activated does not trigger
window.Visible = false
window.Parent = gui
local windowCorner = Instance.new("UICorner")
windowCorner.CornerRadius = UDim.new(0, 10)
windowCorner.Parent = window
local windowStroke = Instance.new("UIStroke")
windowStroke.Color = COLOR_BORDER
windowStroke.Thickness = 1.5
windowStroke.Parent = window
local sizeConstraint = Instance.new("UISizeConstraint")
sizeConstraint.MinSize = Vector2.new(460, 280)
sizeConstraint.MaxSize = Vector2.new(960, 680)
sizeConstraint.Parent = window

-- Top bar (draggable on PC): mode label + shortcut hint + close button
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = COLOR_BAR
topBar.BorderSizePixel = 0
topBar.Active = true
topBar.Parent = window
local topBarCorner = Instance.new("UICorner")
topBarCorner.CornerRadius = UDim.new(0, 10)
topBarCorner.Parent = topBar

local modeLabel = Instance.new("TextLabel")
modeLabel.Name = "ModeLabel"
modeLabel.Size = UDim2.new(1, -240, 1, 0)
modeLabel.Position = UDim2.new(0, 12, 0, 0)
modeLabel.BackgroundTransparency = 1
modeLabel.Font = Enum.Font.RobotoMono
modeLabel.TextSize = 14
modeLabel.TextXAlignment = Enum.TextXAlignment.Left
modeLabel.TextColor3 = COLOR_GREEN
modeLabel.Text = "[LOCAL SHELL]"
modeLabel.Parent = topBar

local hotkeyHint = Instance.new("TextLabel")
hotkeyHint.Name = "HotkeyHint"
hotkeyHint.Size = UDim2.new(0, 160, 1, 0)
hotkeyHint.Position = UDim2.new(1, -234, 0, 0)
hotkeyHint.BackgroundTransparency = 1
hotkeyHint.Font = Enum.Font.Gotham
hotkeyHint.TextSize = 11
hotkeyHint.TextXAlignment = Enum.TextXAlignment.Right
hotkeyHint.TextColor3 = COLOR_GREY
hotkeyHint.Text = "drag bar | [~]/[F2] tutup"
hotkeyHint.Parent = topBar

-- Hint overlay shown inside the bar area for 3 seconds
local hintLabel = Instance.new("TextLabel")
hintLabel.Name = "HintLabel"
hintLabel.Size = UDim2.new(1, -86, 1, 0)
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

-- Close button: Modal=true frees mouse cursor in First-Person / ShiftLock on PC
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseButton"
closeBtn.Size = UDim2.new(0, 62, 0, 26)
closeBtn.Position = UDim2.new(1, -68, 0, 5)
closeBtn.BackgroundColor3 = COLOR_RED_BG
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Text = "X [~]"
closeBtn.AutoButtonColor = true
closeBtn.Modal = true
closeBtn.Active = true
closeBtn.ZIndex = 10
closeBtn.Parent = topBar
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

-- Output: ScrollingFrame + one RichText TextLabel (AutomaticSize Y)
local outputScroll = Instance.new("ScrollingFrame")
outputScroll.Name = "OutputScroll"
outputScroll.Position = UDim2.new(0, 10, 0, 42)
outputScroll.Size = UDim2.new(1, -20, 1, -86)
outputScroll.BackgroundColor3 = COLOR_OUTPUT
outputScroll.BorderSizePixel = 0
outputScroll.ScrollBarThickness = 7
outputScroll.ScrollBarImageColor3 = COLOR_BORDER
outputScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
outputScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
outputScroll.Active = true
outputScroll.Parent = window
local outputPadding = Instance.new("UIPadding")
outputPadding.PaddingLeft = UDim.new(0, 6)
outputPadding.PaddingRight = UDim.new(0, 6)
outputPadding.PaddingTop = UDim.new(0, 4)
outputPadding.PaddingBottom = UDim.new(0, 8)
outputPadding.Parent = outputScroll

local outputLabel = Instance.new("TextLabel")
outputLabel.Name = "OutputLabel"
outputLabel.Size = UDim2.new(1, -8, 0, 0)
outputLabel.Position = UDim2.new(0, 0, 0, 0)
outputLabel.BackgroundTransparency = 1
outputLabel.RichText = true
outputLabel.AutomaticSize = Enum.AutomaticSize.Y
outputLabel.TextWrapped = true
outputLabel.Font = Enum.Font.RobotoMono
outputLabel.TextSize = 14
outputLabel.TextXAlignment = Enum.TextXAlignment.Left
outputLabel.TextYAlignment = Enum.TextYAlignment.Top
outputLabel.TextColor3 = COLOR_TEXT
outputLabel.Text = ""
outputLabel.Parent = outputScroll

-- Input TextBox (bottom). Name "InputBox" is referenced by AudioAndEffectsClient.
local inputBox = Instance.new("TextBox")
inputBox.Name = "InputBox"
inputBox.Position = UDim2.new(0, 10, 1, -38)
inputBox.Size = UDim2.new(1, -20, 0, 30)
inputBox.BackgroundColor3 = COLOR_BAR
inputBox.Font = Enum.Font.RobotoMono
inputBox.TextSize = 14
inputBox.TextColor3 = COLOR_BLUE
inputBox.PlaceholderText = "ketik help | Enter=kirim | Tab=lengkapi | Up/Down=riwayat | [~]/[F2]=tutup"
inputBox.PlaceholderColor3 = COLOR_GREY
inputBox.ClearTextOnFocus = false
inputBox.Text = ""
inputBox.TextXAlignment = Enum.TextXAlignment.Left
inputBox.Parent = window
local inputPad = Instance.new("UIPadding")
inputPad.PaddingLeft = UDim.new(0, 8)
inputPad.PaddingRight = UDim.new(0, 8)
inputPad.Parent = inputBox
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
local openToken = 0
local lastCloseTime = 0
local MAX_BUFFER_LINES = 500

local COMMANDS = {
	"help", "clear", "close", "ping", "traceroute", "ip a", "ip set", "ssh", "exit",
	"top", "vm create", "vm list", "vm throttle", "vm delete", "install-os", "stress-test", "ship",
	"vlan list", "vlan set", "switch port", "switch list",
	"cable", "cable use", "cable buy", "cable cut", "mount list", "mount",
}

local function scrollToEnd()
	task.defer(function()
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
	openToken += 1
	local myToken = openToken
	task.defer(function()
		if window.Visible and openToken == myToken then
			inputBox:CaptureFocus()
		end
	end)
end

local function closeTerminal()
	openToken += 1 -- invalidate any pending refocusInput
	lastCloseTime = os.clock()
	window.Visible = false
	if inputBox:IsFocused() then
		inputBox:ReleaseFocus()
	end
end

local function toggleTerminal()
	if window.Visible then
		closeTerminal()
	else
		openTerminalRemote:FireServer({ action = "request_shell" })
	end
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
	hotkeyHint.Visible = false
	task.delay(3, function()
		if hintToken == myToken then
			hintLabel.Visible = false
			modeLabel.Visible = true
			hotkeyHint.Visible = true
		end
	end)
end

-- ===== PC TopBar Dragging =====
local dragging = false
local dragStartMouse = Vector2.new(0, 0)
local dragStartPos = window.Position

topBar.InputBegan:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStartMouse = Vector2.new(input.Position.X, input.Position.Y)
		dragStartPos = window.Position
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartMouse
		window.Position = UDim2.new(
			dragStartPos.X.Scale,
			dragStartPos.X.Offset + delta.X,
			dragStartPos.Y.Scale,
			dragStartPos.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)

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
	local current = string.gsub(inputBox.Text, "\t", "")
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
		inputBox.Text = current
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
	else
		inputBox.Text = current
	end
end

-- ===== PC Keyboard Shortcuts =====
-- [~] (Backquote) and [F2] toggle terminal anytime (works even while typing in inputBox).
-- While open: Up/Down = history, Tab = autocomplete, Ctrl+L = clear, Ctrl+W = close.
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	local key = input.KeyCode
	if key == Enum.KeyCode.Backquote or key == Enum.KeyCode.F2 then
		if window.Visible then
			-- Strip stray backtick if typed into TextBox right before close
			task.defer(function()
				inputBox.Text = string.gsub(inputBox.Text, "`", "")
			end)
			closeTerminal()
		elseif not gameProcessed then
			toggleTerminal()
		end
		return
	end

	if not window.Visible then
		return
	end

	local ctrlHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if ctrlHeld and key == Enum.KeyCode.W then
		closeTerminal()
		return
	elseif ctrlHeld and key == Enum.KeyCode.L then
		clearBuffer()
		return
	end

	if key == Enum.KeyCode.Up then
		historyUp()
	elseif key == Enum.KeyCode.Down then
		historyDown()
	elseif key == Enum.KeyCode.Tab then
		task.defer(function()
			tabComplete()
			refocusInput()
		end)
	end
end)

-- ===== Enter = send command =====
inputBox.FocusLost:Connect(function(enterPressed: boolean)
	if not enterPressed or not window.Visible then
		return
	end
	local raw = string.gsub(inputBox.Text, "`", "")
	inputBox.Text = ""
	historyIndex = #history + 1
	if raw == nil or #raw == 0 then
		refocusInput()
		return
	end

	local trimmedLower = string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	if trimmedLower == "close" or trimmedLower == "quit" then
		closeTerminal()
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
		-- Ignore stale open packets right after an explicit close
		if os.clock() - lastCloseTime < 0.2 then
			return
		end
		window.Visible = true
		modeLabel.Visible = true
		hotkeyHint.Visible = true
		hintLabel.Visible = false
		modeLabel.Text = titleFor(payload.mode, payload.deviceName)
		refocusInput()
	elseif action == "detach" then
		modeLabel.Visible = true
		hotkeyHint.Visible = true
		hintLabel.Visible = false
		modeLabel.Text = "[LOCAL SHELL]"
	elseif action == "hint" then
		showHint(tostring(payload.message or ""))
	end
end)

pushOutputRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local rawLines = if type(payload.lines) == "table" then payload.lines else payload
	local strs: { string } = {}
	for _, line in ipairs(rawLines :: { any }) do
		table.insert(strs, tostring(line))
	end
	if #strs > 0 then
		appendLines(strs)
	end
end)

-- Fire close on MouseButton1Down so a single click closes immediately even while
-- inputBox is focused (and before Tool.Activated could ever react to the click).
closeBtn.MouseButton1Down:Connect(closeTerminal)
closeBtn.MouseButton1Click:Connect(closeTerminal)

-- ===== Cross-script toggle: HudClient's "TERMINAL [~]" button fires this =====
local toggleBindable = Instance.new("BindableEvent")
toggleBindable.Name = "NetSimToggleTerminal"
toggleBindable.Parent = playerGui
toggleBindable.Event:Connect(toggleTerminal)

-- ===== Laptop tool hook (Activated -> request_shell, guarded against UI clicks) =====
local function isPointerOverInteractiveGui(): boolean
	local pos = UserInputService:GetMouseLocation()
	local topLeftInset = GuiService:GetGuiInset()
	local objs = playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y - topLeftInset.Y)
	for _, obj in ipairs(objs) do
		if obj.Visible and (obj:IsA("GuiButton") or obj:IsA("TextBox") or obj.Active) then
			return true
		end
	end
	return false
end

local function bindTool(tool: Tool)
	if tool:GetAttribute("NetSimTermHooked") == true then
		return
	end
	tool:SetAttribute("NetSimTermHooked", true)
	tool.Activated:Connect(function()
		-- Do not re-open if terminal is already visible, just closed, or clicking a UI element
		if window.Visible then
			return
		end
		if os.clock() - lastCloseTime < 0.45 then
			return
		end
		if isPointerOverInteractiveGui() then
			return
		end
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

-- ===== Welcome banner (Indonesian, PC controls) =====
appendLines({
	'<font color="#00FF66">[NetSim Terminal] Selamat datang, teknisi.</font>',
	'<font color="#8B949E">Ketik <b>help</b> untuk daftar perintah. [~] / [F2] / klik X = tutup | Tab = autocomplete | Up/Down = riwayat | Ctrl+L = clear.</font>',
})
