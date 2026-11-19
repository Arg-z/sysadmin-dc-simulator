--!strict
--[[
	AudioAndEffectsClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	Realistic layered sound design for the data-center lab.

	SFX bank (Creator Store assets, all verified loadable; free to use):
	- plug  -> 9119730203  plastic switch click (0.4s)   - cable seat / power
	- key   -> 4724430129  mechanical keystroke (0.1s)   - terminal typing
	- error -> 16903690359 warning beep (0.5s)           - denied actions
	- cash  -> 1319346243  coins in register (1.4s)      - payouts
	- drive -> 122348903689986 drive seat thunk (0.3s)   - hot-swap HDD
	- klaxon-> 4530741431  emergency siren (16.1s)       - 2D incident fallback

	Spatial ambience layers (client-side only, attached to facility parts):
	- room  -> 9112825488  machine-room presence loop (Pro Sound Effects, 59s)
	- AC    -> 329997777   air-conditioner whoosh loop (74s) on the AC fan
	- rack  -> 140319299279554 box-fan whir loop (213s) on every server rack

	PlaySFXRemote.OnClientEvent(name) plays the matching one-shot (clone + Play
	so overlaps never cut each other, with small random pitch/volume variation
	so repeated triggers do not sound machine-gun identical). Terminal input
	TextBox "InputBox" in ScreenGui "NetSimTerminal" drives both the arm-typing
	pose and per-keystroke mechanical sounds (throttled).

	Komentar kode Bahasa Inggris; tidak ada teks GUI (script ini tanpa UI).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[AudioAndEffectsClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local playSfxRemote = remotesFolder:WaitForChild("PlaySFXRemote") :: RemoteEvent
local stateSyncRemote = remotesFolder:WaitForChild("StateSyncRemote") :: RemoteEvent

-- Subtle room reverb: concrete walls + raised floor give a short hard tail.
SoundService.AmbientReverb = Enum.ReverbType.Room
SoundService.RespectFilteringEnabled = true

-- ===== Sound bank =====
local ASSETS = {
	plug = "rbxassetid://9119730203",
	key = "rbxassetid://4724430129",
	error = "rbxassetid://16903690359",
	cash = "rbxassetid://1319346243",
	drive = "rbxassetid://122348903689986",
	klaxon = "rbxassetid://4530741431",
	room = "rbxassetid://9112825488",
	ac = "rbxassetid://329997777",
	rack = "rbxassetid://140319299279554",
}

type BankEntry = { asset: string, speed: number, volume: number }
local BANK: { [string]: BankEntry } = {
	plug = { asset = ASSETS.plug, speed = 1.0, volume = 0.6 },
	key = { asset = ASSETS.key, speed = 1.0, volume = 0.32 },
	error = { asset = ASSETS.error, speed = 0.85, volume = 0.5 },
	cash = { asset = ASSETS.cash, speed = 1.0, volume = 0.5 },
	drive = { asset = ASSETS.drive, speed = 0.75, volume = 0.55 },
	klaxon = { asset = ASSETS.klaxon, speed = 1.0, volume = 0.3 },
}

local function makeSound(name: string, asset: string, speed: number, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.Name = "NetSimSFX_" .. name
	sound.SoundId = asset
	sound.PlaybackSpeed = speed
	sound.Volume = volume
	sound.Parent = SoundService
	return sound
end

local soundBank: { [string]: Sound } = {}
for name, entry in pairs(BANK) do
	soundBank[name] = makeSound(name, entry.asset, entry.speed, entry.volume)
end

-- Play a short-lived clone so overlapping triggers do not cut each other off.
-- jitter adds human-scale variation to repeated mechanical sounds.
local function playClone(base: Sound, jitter: number?)
	local clone = base:Clone()
	clone.Name = base.Name .. "_OneShot"
	local j = jitter or 0
	if j > 0 then
		clone.PlaybackSpeed = base.PlaybackSpeed * (1 + (math.random() * 2 - 1) * j)
		clone.Volume = base.Volume * (1 + (math.random() * 2 - 1) * j * 0.6)
	end
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Connect(function()
		clone:Destroy()
	end)
	-- Safety net in case Ended never fires (e.g. sound looping properties changed)
	task.delay(6, function()
		if clone.Parent ~= nil then
			clone:Destroy()
		end
	end)
end

local function playNamed(name: string)
	local base = soundBank[name]
	if base ~= nil then
		playClone(base, if name == "key" or name == "plug" or name == "drive" then 0.12 else 0.03)
	end
end

playSfxRemote.OnClientEvent:Connect(function(name: any)
	if type(name) == "string" then
		playNamed(name)
	end
end)

-- ===== Spatial ambience layers =====
-- Sounds are local-only (parented client-side to facility parts), so no assets
-- leak into the place file and each client hears its own room. Rolloff keeps
-- far plots silent; the room layer is wide, the rack/AC layers are close.
local function makeLayer(parent: Instance, name: string, asset: string, volume: number, minDist: number, maxDist: number, speed: number): Sound
	local layer = Instance.new("Sound")
	layer.Name = name
	layer.SoundId = asset
	layer.Looped = true
	layer.Volume = volume
	layer.PlaybackSpeed = speed
	layer.RollOffMinDistance = minDist
	layer.RollOffMaxDistance = maxDist
	layer.RollOffMode = Enum.RollOffMode.InverseTapered
	layer.Parent = parent
	layer:Play()
	return layer
end

local function attachLayers(plotIndex: number)
	local plots = Workspace:FindFirstChild("Plots")
	if plots == nil then
		return
	end
	local plot = plots:FindFirstChild("Plot" .. tostring(plotIndex))
	if plot == nil then
		return
	end
	local facility = plot:FindFirstChild("Facility")
	if facility == nil then
		return
	end

	-- Room presence: wide machine-room loop centered on the floor.
	local floor = facility:FindFirstChild("RoomFloor")
	if floor ~= nil and floor:IsA("BasePart") and floor:FindFirstChild("NetSimRoomLayer") == nil then
		makeLayer(floor, "NetSimRoomLayer", ASSETS.room, 0.4, 10, 60, 1.0)
	end

	-- AC whoosh on the fan part.
	local acModel = facility:FindFirstChild("AC_Unit", true)
	local fan = if acModel ~= nil then acModel:FindFirstChild("ACFan", true) else nil
	if fan ~= nil and fan:IsA("BasePart") and fan:FindFirstChild("NetSimACLayer") == nil then
		makeLayer(fan, "NetSimACLayer", ASSETS.ac, 0.45, 4, 30, 1.0)
	end

	-- Fan whir on every rack cabinet (12U starter + any purchased 24U).
	for _, desc in ipairs(facility:GetDescendants()) do
		if desc:IsA("Model") and string.match(desc.Name, "^Server Rack") ~= nil then
			local root = desc:FindFirstChildWhichIsA("BasePart")
			if root ~= nil and desc:GetAttribute("NetSimRackLayer") ~= true then
				desc:SetAttribute("NetSimRackLayer", true)
				makeLayer(root, "NetSimRackLayer", ASSETS.rack, 0.3, 3, 20, 0.9 + math.random() * 0.2)
			end
		end
	end
end

stateSyncRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) == "table" and type(payload.plotIndex) == "number" then
		attachLayers(payload.plotIndex)
	end
end)

task.spawn(function()
	-- Fallback: attach for every plot once the world exists (far plots are
	-- outside the rolloff range, so this stays quiet and cheap). Re-scan a
	-- few times so racks bought later still get their whir layer.
	for pass = 1, 4 do
		task.wait(if pass == 1 then 3 else 20)
		local plots = Workspace:WaitForChild("Plots", 60)
		if plots == nil then
			return
		end
		for _, child in ipairs(plots:GetChildren()) do
			local suffix = string.match(child.Name, "^Plot(%d+)$")
			if suffix ~= nil then
				attachLayers(tonumber(suffix) :: number)
			end
		end
	end
end)

-- ===== Per-keystroke mechanical typing sounds =====
local lastKeySound = 0
local function onTypingTextChanged()
	local now = os.clock()
	if now - lastKeySound < 0.045 then
		return -- throttle: fast typists / paste bursts stay sane
	end
	lastKeySound = now
	local base = soundBank.key
	if base ~= nil then
		playClone(base, 0.18)
	end
end

-- ===== Arm-typing pose =====
-- While the terminal input is focused, bend the right wrist/elbow slightly.
-- Motor6D.Transform is reapplied in RenderStepped (after animation), and
-- restored to identity on focus loss.
local typing = false
local typingTime = 0
local activeMotor: Motor6D? = nil

local function findRightWrist(char: Model): Motor6D?
	local hand = char:FindFirstChild("RightHand")
	if hand ~= nil then
		local wrist = hand:FindFirstChild("RightWrist")
		if wrist ~= nil and wrist:IsA("Motor6D") then
			return wrist
		end
	end
	-- R6 fallback: the whole right arm is driven by "Right Shoulder".
	local arm = char:FindFirstChild("Right Arm")
	if arm ~= nil then
		local shoulder = arm:FindFirstChild("Right Shoulder")
		if shoulder ~= nil and shoulder:IsA("Motor6D") then
			return shoulder
		end
	end
	return nil
end

RunService.RenderStepped:Connect(function(dt: number)
	if not typing and activeMotor == nil then
		return
	end
	local char = player.Character
	local motor = if char ~= nil then findRightWrist(char) else nil
	if motor ~= activeMotor then
		if activeMotor ~= nil then
			activeMotor.Transform = CFrame.new()
		end
		activeMotor = motor
	end
	if motor == nil then
		typing = false
		return
	end
	if typing then
		typingTime += dt
		local bob = math.sin(typingTime * 14) * math.rad(5)
		motor.Transform = CFrame.Angles(math.rad(-14) + bob, 0, math.rad(6))
	else
		motor.Transform = CFrame.new()
		activeMotor = nil
	end
end)

local function bindTypingPose(box: TextBox)
	if box:GetAttribute("NetSimPoseHooked") == true then
		return
	end
	box:SetAttribute("NetSimPoseHooked", true)
	box.Focused:Connect(function()
		typing = true
		typingTime = 0
	end)
	box.FocusLost:Connect(function()
		typing = false
	end)
end

-- ===== Terminal input TextBox hook (pose + keystroke sounds) =====
local function bindTextBox(box: TextBox)
	if box:GetAttribute("NetSimSfxHooked") == true then
		return
	end
	box:SetAttribute("NetSimSfxHooked", true)
	bindTypingPose(box)
	box:GetPropertyChangedSignal("Text"):Connect(onTypingTextChanged)
end

local function bindTerminalGui(terminalGui: Instance)
	-- Bind any existing input box
	for _, desc in ipairs(terminalGui:GetDescendants()) do
		if desc:IsA("TextBox") and desc.Name == "InputBox" then
			bindTextBox(desc :: TextBox)
		end
	end
	-- And any input box added later (TerminalClient may still be building its UI)
	terminalGui.DescendantAdded:Connect(function(desc: Instance)
		if desc:IsA("TextBox") and desc.Name == "InputBox" then
			bindTextBox(desc :: TextBox)
		end
	end)
end

-- Watch PlayerGui for the terminal ScreenGui (created by TerminalClient)
local function scanPlayerGui()
	for _, child in ipairs(playerGui:GetChildren()) do
		if child.Name == "NetSimTerminal" and child:IsA("ScreenGui") then
			bindTerminalGui(child)
		end
	end
end

playerGui.ChildAdded:Connect(function(child: Instance)
	if child.Name == "NetSimTerminal" and child:IsA("ScreenGui") then
		-- Defer one frame so TerminalClient finishes adding its children first
		task.defer(bindTerminalGui, child)
	end
end)
scanPlayerGui()
