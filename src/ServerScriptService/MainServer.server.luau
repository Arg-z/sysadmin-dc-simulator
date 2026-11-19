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
local CarryAndMountSystem = require(script.Parent.Physical.CarryAndMountSystem)
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
CarryAndMountSystem.Init({
	sessions = SessionManager,
	placement = PlacementSystem,
	graph = NetworkGraph,
	modelFactory = ModelFactory,
	constants = PlotConstants,
	catalog = HardwareCatalog,
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
	carry = CarryAndMountSystem,
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
	placement = PlacementSystem,
	carry = CarryAndMountSystem,
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
-- Fase 2: wire cutter fisik (klik port tersambung = potong kabel)
local starterCutter = ModelFactory.BuildWireCutter()
starterCutter.Parent = StarterPack

-- ===== Player lifecycle =====
-- Roblox leaderboard (Fase 3 polish): Cash + Reputation, values mirrored by
-- ShiftAndEconomyManager.ForceSync on every snapshot.
local function ensureLeaderstats(player: Player, session: any)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats == nil then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end
	local cash = leaderstats:FindFirstChild("Cash")
	if cash == nil then
		cash = Instance.new("IntValue")
		cash.Name = "Cash"
		cash.Parent = leaderstats
	end
	local reputation = leaderstats:FindFirstChild("Reputation")
	if reputation == nil then
		reputation = Instance.new("IntValue")
		reputation.Name = "Reputation"
		reputation.Parent = leaderstats
	end
	local cashValue = cash :: IntValue
	local reputationValue = reputation :: IntValue
	cashValue.Value = math.floor(session.balance)
	reputationValue.Value = math.floor(session.reputation)
end

local function buildSession(player: Player)
	local session = SessionManager.GetSession(player)
	if session ~= nil then
		return -- already owns a lab
	end
	local plotIndex = SessionManager.ClaimNextPlot()
	if plotIndex == nil then
		player:Kick("All server labs are full (4 players). Please try again later.")
		return
	end
	session = SessionManager.CreateSession(player, plotIndex)
	ensureLeaderstats(player, session)
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
		local hasLaptop = backpack:FindFirstChild("TechnicianLaptop") ~= nil
			or (player.Character ~= nil and player.Character:FindFirstChild("TechnicianLaptop") ~= nil)
		if not hasLaptop then
			local laptop = ModelFactory.BuildLaptop()
			laptop.Parent = backpack
		end
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
	-- Follow-up sync once client LocalScripts finish initializing
	task.delay(1.5, function()
		local live = SessionManager.GetSession(player)
		if live == session then
			ShiftAndEconomyManager.ForceSync(live)
		end
	end)
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

-- ===== SaveGameRemote: manual save dari Tab menu, balikin status ke client =====
local saveGameRemote = remotes:FindFirstChild("SaveGameRemote")
if saveGameRemote then
	(saveGameRemote :: any).OnServerInvoke = function(player: Player): (boolean, string)
		local session = SessionManager.GetSession(player)
		if session == nil then
			return false, "Session not ready yet"
		end
		local ok = DataPersistenceManager.Save(session)
		return ok, if ok then "Game saved" else "Saving unavailable (DataStore off)"
	end
end
