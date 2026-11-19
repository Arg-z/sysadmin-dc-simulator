--!strict
--[[
	SessionManager (ModuleScript, ServerScriptService/Core)
	Per-player session store and lifecycle management:
	- plot claiming / releasing (one lab plot per player)
	- session creation with every CONTRACT section 4 field initialized
	- session deletion (facility teardown, console beam cleanup, plot release)
	- id counters for devices ("prefix_N") and cables ("cbl_N")
	Pure state store: no gameplay logic lives here. Other server modules
	receive the session table through their own deps injection.
]]

local SessionManager = {}

local Sessions: { [Player]: any } = {} -- player -> session table
local UsedPlots: { [number]: Player } = {} -- plotIndex -> owning player
local PlotCount = 4
local Constants: any = nil -- PlotConstants module, injected via Init

---------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------

-- Init(deps: { constants = PlotConstants })
function SessionManager.Init(deps: { [string]: any })
	Constants = deps.constants
	PlotCount = Constants.PLOT_COUNT
end

-- Returns the live session of a player, or nil when none exists yet.
function SessionManager.GetSession(player: Player): any?
	return Sessions[player]
end

-- Returns the shared sessions table keyed by Player.
function SessionManager.GetAllSessions(): { [Player]: any }
	return Sessions
end

-- Returns the first free plot index (1..PLOT_COUNT) or nil when all taken.
function SessionManager.ClaimNextPlot(): number?
	for i = 1, PlotCount do
		if UsedPlots[i] == nil then
			return i
		end
	end
	return nil
end

-- Creates and registers a session containing every field of CONTRACT
-- section 4 (including workbench with all WorkbenchState fields and tickets).
function SessionManager.CreateSession(player: Player, plotIndex: number): any
	local econ = Constants.ECONOMY
	local session = {
		player = player,
		plotIndex = plotIndex,
		balance = econ.startBalance,
		reputation = econ.startReputation,
		day = 1,
		terminal = {
			mode = "Disconnected",
			targetDeviceId = nil,
			sshStack = {},
		},
		devices = {},
		deviceModels = {},
		racks = {},
		rackModels = {},
		cables = {},
		pendingCableDeviceId = nil,
		pendingCablePortId = nil,
		pendingCableHighlight = nil,
		pendingCableColor = nil,
		consoleLink = nil,
		pendingPlacementItemId = nil,
		workbench = {
			chassis = nil,
			mobo = nil,
			cpuCount = 0,
			cpuCores = 0,
			cpuSockets = 0,
			ramSlotsUsed = 0,
			ramSlots = 0,
			ramGb = 0,
			storageBaysUsed = 0,
			storageBays = 0,
			storageGb = 0,
			psu = nil,
			powered = false,
			osInstalled = nil,
			installing = false,
			stressRunning = false,
			tested = false,
			shipped = false,
			deviceId = nil,
			totalSpent = 0,
			snapIndex = nil,
			benchModel = nil,
			lastCpuId = nil,
			lastRamId = nil,
		},
		facility = {},
		flags = {},
		hookedDevices = {},
		vmIpCounter = {},
		cableCounter = 0,
		deviceCounter = 0,
		broadcastStorm = false,
		loadedFromSave = false,
		noSaveWarned = false,
		tickets = {}, -- ContractTicket-like rows (filled by ContractAndIncidentManager)
		cableSpools = {
			LAN_Blue = Constants.CABLES.starter.LAN_Blue,
			WAN_Yellow = Constants.CABLES.starter.WAN_Yellow,
			Mgmt_Red = Constants.CABLES.starter.Mgmt_Red,
		},
		selectedCableColor = "LAN_Blue",
		carry = nil,
		colocation = { crates = {}, byTicket = {} },
		rackSlots = {},
		-- Fase 3: shift clock, incident state, spare parts
		shift = {
			clockMinutes = Constants.SHIFT.startMinutes,
			stats = { contractsCompleted = 0, incidentsResolved = 0, incidentsFailed = 0 },
			lastSettlementText = nil,
			lastSettlementAmount = nil,
		},
		incidentFaults = {},
		incidentCooldownSec = 0,
		incidentRotationIndex = 0,
		spareParts = { hdd = 0 },
		journal = {},
		stormLit = false,
	}
	Sessions[player] = session
	UsedPlots[plotIndex] = player
	return session
end

-- Removes a session: destroys the pending cable highlight, the console beam
-- and the facility root (room, devices, cables folder all hang under it),
-- then releases the plot. Safe to call even on a half-built session.
function SessionManager.DeleteSession(player: Player)
	local session = Sessions[player]
	if session == nil then
		return
	end
	if session.pendingCableHighlight ~= nil then
		session.pendingCableHighlight:Destroy()
		session.pendingCableHighlight = nil
	end
	if session.consoleLink ~= nil and session.consoleLink.beam ~= nil then
		session.consoleLink.beam:Destroy()
	end
	session.consoleLink = nil
	if session.carry ~= nil and session.carry.conn ~= nil then
		session.carry.conn:Disconnect()
	end
	session.carry = nil
	local facility = session.facility
	if facility ~= nil and facility.root ~= nil then
		facility.root:Destroy()
	end
	session.facility = {}
	UsedPlots[session.plotIndex] = nil
	Sessions[player] = nil
end

---------------------------------------------------------------------
-- Id counters
---------------------------------------------------------------------

-- "prefix_N" using the per-session device counter.
function SessionManager.NextDeviceId(session: any, prefix: string): string
	session.deviceCounter += 1
	return prefix .. "_" .. tostring(session.deviceCounter)
end

-- "cbl_N" using the per-session cable counter.
function SessionManager.NextCableId(session: any): string
	session.cableCounter += 1
	return "cbl_" .. tostring(session.cableCounter)
end

return SessionManager
