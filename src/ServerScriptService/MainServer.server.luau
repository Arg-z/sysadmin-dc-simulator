--!strict
--[[
	MainServer (Script, ServerScriptService)
	Orkestrator: init order seluruh modul (dependency injection), lifecycle
	pemain (klaim lab, build facility, hook interaksi, load save, teleport),
	ResetDataRemote, rotasi fan AC, BindToClose.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPack = game:GetService("StarterPack")

local Shared = ReplicatedStorage.Shared
local ModelFactory = require(Shared.ModelFactory)
local PlotConstants = require(Shared.PlotConstants)
local HardwareCatalog = require(Shared.HardwareCatalog)

local WorldAndAssetBuilder = require(script.Parent.Bootstrap.WorldAndAssetBuilder)
local SessionManager = require(script.Parent.Core.SessionManager)
local NetworkGraph = require(script.Parent.Core.NetworkGraph)
local CommandExecutor = require(script.Parent.Core.CommandExecutor)
local RackAndCablingSystem = require(script.Parent.Physical.RackAndCablingSystem)
local PlacementSystem = require(script.Parent.Physical.PlacementSystem)
local WorkbenchBuilderSystem = require(script.Parent.Physical.WorkbenchBuilderSystem)
local ShiftAndEconomyManager = require(script.Parent.Gameplay.ShiftAndEconomyManager)
local ContractAndIncidentManager = require(script.Parent.Gameplay.ContractAndIncidentManager)
local DataPersistenceManager = require(script.Parent.Gameplay.DataPersistenceManager)

-- ===== Init order (dependency injection; tidak ada require cycle) =====
local remotes = WorldAndAssetBuilder.EnsureRemotes()
WorldAndAssetBuilder.SetupLighting()

SessionManager.Init({ constants = PlotConstants })
NetworkGraph.Init({})
RackAndCablingSystem.Init({ sessions = SessionManager, graph = NetworkGraph, remotesFolder = remotes })
WorkbenchBuilderSystem.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	catalog = HardwareCatalog,
	constants = PlotConstants,
	modelFactory = ModelFactory,
	cabling = RackAndCablingSystem,
	remotesFolder = remotes,
})
PlacementSystem.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	catalog = HardwareCatalog,
	constants = PlotConstants,
	modelFactory = ModelFactory,
	workbench = WorkbenchBuilderSystem,
	cabling = RackAndCablingSystem,
	remotesFolder = remotes,
})
ShiftAndEconomyManager.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	constants = PlotConstants,
	remotesFolder = remotes,
	cabling = RackAndCablingSystem,
})
ContractAndIncidentManager.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	constants = PlotConstants,
	remotesFolder = remotes,
	workbench = WorkbenchBuilderSystem,
})
DataPersistenceManager.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	constants = PlotConstants,
	placement = PlacementSystem,
	workbench = WorkbenchBuilderSystem,
	remotesFolder = remotes,
})
CommandExecutor.Init({
	sessions = SessionManager,
	graph = NetworkGraph,
	utils = require(Shared.NetworkUtils),
	catalog = HardwareCatalog,
	constants = PlotConstants,
	workbench = WorkbenchBuilderSystem,
	cabling = RackAndCablingSystem,
	remotesFolder = remotes,
})

-- ===== Loop global =====
ShiftAndEconomyManager.Start()
ContractAndIncidentManager.Start()
DataPersistenceManager.Start()

-- Rotasi fan AC (semua facility aktif)
RunService.Heartbeat:Connect(function(dt: number)
	WorldAndAssetBuilder.UpdateFans(dt)
end)

-- Laptop tool ke StarterPack: setiap respawn otomatis dapat
local starterLaptop = ModelFactory.BuildLaptop()
starterLaptop.Parent = StarterPack

-- ===== Lifecycle pemain =====
local function buildSession(player: Player)
	local session = SessionManager.GetSession(player)
	if session ~= nil then
		return -- sudah punya lab
	end
	local plotIndex = SessionManager.ClaimNextPlot()
	if plotIndex == nil then
		player:Kick("Semua lab penuh (4 pemain). Coba lagi nanti.")
		return
	end
	session = SessionManager.CreateSession(player, plotIndex)
	WorldAndAssetBuilder.BuildFacility(session)

	-- hook interaksi starter devices + facility
	for deviceId, _ in pairs(session.devices) do
		RackAndCablingSystem.HookDevice(session, deviceId)
	end
	RackAndCablingSystem.HookFacility(session)
	WorkbenchBuilderSystem.HookBenchSwitch(session)

	-- laptop langsung ke backpack (StarterPack mengurus respawn berikutnya)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		local laptop = ModelFactory.BuildLaptop()
		laptop.Parent = backpack
	end

	-- load save (Apply memulihkan device, kabel, workbench, tiket, uang)
	local data = DataPersistenceManager.Load(player)
	if data ~= nil then
		DataPersistenceManager.Apply(session, data)
	end

	-- teleport ke lab pemain
	local facility = session.facility
	local function onCharacter(char: Model)
		task.wait(0.3)
		if char.Parent and facility.spawnCF then
			char:PivotTo(facility.spawnCF :: CFrame)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	ShiftAndEconomyManager.ForceSync(session)
end

local function rebuildSession(player: Player)
	local old = SessionManager.GetSession(player)
	if old ~= nil then
		SessionManager.DeleteSession(player)
	end
	buildSession(player)
end

Players.PlayerAdded:Connect(buildSession)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(buildSession, p)
end

Players.PlayerRemoving:Connect(function(player)
	local session = SessionManager.GetSession(player)
	if session ~= nil then
		DataPersistenceManager.Save(session)
	end
	SessionManager.DeleteSession(player)
end)

game:BindToClose(function()
	DataPersistenceManager.SaveAll()
end)

-- ===== ResetDataRemote: wipe save + rebuild lab dari nol =====
-- (binding lain sudah dilakukan masing-masing modul di Init masing-masing)
local resetRemote = remotes:FindFirstChild("ResetDataRemote")
if resetRemote then
	(resetRemote :: any).OnServerEvent:Connect(function(player)
		DataPersistenceManager.WipeSave(player)
		rebuildSession(player)
	end)
end
