--!strict
--[[
	AudioAndEffectsClient (LocalScript, StarterPlayer/StarterPlayerScripts)
	Bank SFX client-side memakai asset bawaan rbxasset:// saja (tanpa aset eksternal):
	- plug  -> rbxasset://sounds/snap.mp3                (volume 0.6)
	- key   -> rbxasset://sounds/electronicpingshort.wav (pitch 1.6, volume 0.35)
	- error -> rbxasset://sounds/electronicpingshort.wav (pitch 0.6, volume 0.5)
	- cash  -> rbxasset://sounds/electronicpingshort.wav (pitch 1.2, volume 0.5)

	PlaySFXRemote.OnClientEvent(name) -> mainkan sound yang cocok (clone + Play agar
	overlap aman). Blip ketikan: TextBox "InputBox" di ScreenGui "NetSimTerminal"
	(dibuat TerminalClient) di-watch GetPropertyChangedSignal("Text"), throttle 80ms.
	Di-binding lewat ChildAdded PlayerGui + scan awal + DescendantAdded.

	Komentar kode Bahasa Inggris; tidak ada teks GUI (script ini tanpa UI).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 180) :: any
if remotesFolder == nil then
	warn("[AudioAndEffectsClient] ReplicatedStorage.Remotes tidak ditemukan (timeout 180s)")
	return
end

local playSfxRemote = remotesFolder:WaitForChild("PlaySFXRemote") :: RemoteEvent

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

-- ===== Typing blip on the terminal input TextBox =====
local keySound = soundBank.key :: Sound
local lastBlipTime = 0
local BLIP_THROTTLE_SECONDS = 0.08

local function bindTextBox(box: TextBox)
	if box:GetAttribute("NetSimSfxHooked") == true then
		return
	end
	box:SetAttribute("NetSimSfxHooked", true)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local now = os.clock()
		if now - lastBlipTime < BLIP_THROTTLE_SECONDS then
			return
		end
		lastBlipTime = now
		-- Restart the shared blip sound (no clone per keystroke)
		keySound.TimePosition = 0
		keySound:Play()
	end)
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
