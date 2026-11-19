--!strict
--[[
	AudioAndEffectsClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	Bank SFX client-side memakai asset bawaan rbxasset:// saja (tanpa aset eksternal):
	- plug  -> rbxasset://sounds/snap.mp3                (volume 0.6)
	- key   -> rbxasset://sounds/electronicpingshort.wav (pitch 1.6, volume 0.35)
	- error -> rbxasset://sounds/electronicpingshort.wav (pitch 0.6, volume 0.5)
	- cash  -> rbxasset://sounds/electronicpingshort.wav (pitch 1.2, volume 0.5)

	PlaySFXRemote.OnClientEvent(name) -> mainkan sound yang cocok (clone + Play agar
	overlap aman). Terminal input TextBox "InputBox" di ScreenGui "NetSimTerminal"
	(dibuat TerminalClient) di-binding lewat ChildAdded PlayerGui + scan awal +
	DescendantAdded untuk pose mengetik (tanpa suara ketikan).  

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

-- ===== Sound bank (built-in rbxasset assets only) =====
local ASSET_PLUG = "rbxasset://sounds/snap.mp3"
local ASSET_BLIP = "rbxasset://sounds/electronicpingshort.wav"

local function makeSound(name: string, asset: string, speed: number, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.Name = "NetSimSFX_" .. name
	sound.SoundId = asset
	sound.PlaybackSpeed = speed
	sound.Volume = volume
	sound.Parent = SoundService
	return sound
end

local soundBank: { [string]: Sound } = {
	plug = makeSound("plug", ASSET_PLUG, 1.0, 0.6),
	key = makeSound("key", ASSET_BLIP, 1.6, 0.35),
	error = makeSound("error", ASSET_BLIP, 0.6, 0.5),
	cash = makeSound("cash", ASSET_BLIP, 1.2, 0.5),
	-- Fase 3: alarm klaxon for incidents. The beacon also owns a spatial
	-- looping klaxon server-side; this bank entry is the 2D fallback.
	klaxon = makeSound("klaxon", ASSET_BLIP, 0.45, 0.45),
	drive = makeSound("drive", ASSET_PLUG, 0.65, 0.4),
}

-- Play a short-lived clone so overlapping triggers do not cut each other off
local function playClone(base: Sound)
	local clone = base:Clone()
	clone.Name = base.Name .. "_OneShot"
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Connect(function()
		clone:Destroy()
	end)
	-- Safety net in case Ended never fires (e.g. sound looping properties changed)
	task.delay(4, function()
		if clone.Parent ~= nil then
			clone:Destroy()
		end
	end)
end

local function playNamed(name: string)
	local base = soundBank[name]
	if base ~= nil then
		playClone(base)
	end
end

playSfxRemote.OnClientEvent:Connect(function(name: any)
	if type(name) == "string" then
		playNamed(name)
	end
end)

-- ===== Fase 3: spatial AC fan hum =====
-- A low-pitched looping built-in blip acts as a server-room drone. Sounds are
-- local-only (parented client-side to the AC fan part), so no assets leak into
-- the place file and each client hears its own room.
local FAN_HUM_SPEED = 0.11
local FAN_HUM_VOLUME = 0.07

local function attachFanHum(plotIndex: number)
	local plots = Workspace:FindFirstChild("Plots")
	if plots == nil then
		return
	end
	local plot = plots:FindFirstChild("Plot" .. tostring(plotIndex))
	if plot == nil then
		return
	end
	local acModel = plot:FindFirstChild("AC_Unit", true)
	local fan = if acModel ~= nil then acModel:FindFirstChild("ACFan", true) else nil
	if fan == nil or not fan:IsA("BasePart") then
		return
	end
	if fan:FindFirstChild("NetSimFanHum") ~= nil then
		return
	end
	local hum = Instance.new("Sound")
	hum.Name = "NetSimFanHum"
	hum.SoundId = ASSET_BLIP
	hum.Looped = true
	hum.PlaybackSpeed = FAN_HUM_SPEED
	hum.Volume = FAN_HUM_VOLUME
	hum.RollOffMinDistance = 4
	hum.RollOffMaxDistance = 34
	hum.Parent = fan
	hum:Play()
end

stateSyncRemote.OnClientEvent:Connect(function(payload: any)
	if type(payload) == "table" and type(payload.plotIndex) == "number" then
		attachFanHum(payload.plotIndex)
	end
end)

task.spawn(function()
	-- Fallback: attach for every plot once the world exists (far plots are
	-- outside the rolloff range, so this stays quiet and cheap).
	task.wait(3)
	local plots = Workspace:WaitForChild("Plots", 60)
	if plots == nil then
		return
	end
	for _, child in ipairs(plots:GetChildren()) do
		local suffix = string.match(child.Name, "^Plot(%d+)$")
		if suffix ~= nil then
			attachFanHum(tonumber(suffix) :: number)
		end
	end
end)

-- ===== Fase 3: arm-typing pose =====
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

-- ===== Terminal input TextBox hook (arm-typing pose only; typing sound removed) =====
local function bindTextBox(box: TextBox)
	if box:GetAttribute("NetSimSfxHooked") == true then
		return
	end
	box:SetAttribute("NetSimSfxHooked", true)
	bindTypingPose(box)
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
