--!strict
--[[
	SessionManager (ModuleScript, ServerScriptService/Core)
	Penyimpanan & lifecycle session per pemain: plot, state, terminal, flags.
	Tidak berisi game logic - murni state store.
]]

local Sessions: { [Player]: any } = {}
local usedPlots: { [number]: Player } = {}
local plotCount = 4
local constants = nil

local SessionManager = {}

function SessionManager.Init(deps: { [string]: any })
	constants = deps.constants
	plotCount = constants.PLOT_COUNT
end

function SessionManager.GetSession(player: Player): any?
	return Sessions[player]
end

function SessionManager.GetAllSessions(): { [Player]: any }
	return Sessions
end

function SessionManager.ClaimNextPlot(): number?
	for i = 1, plotCount do
		if usedPlots[i] == nil then
			return i
		end
	end
	return nil
end

function SessionManager.CreateSession(player: Player, plotIndex: number): any
	local constantsV = constants :: any
	local session = {
		player = player,
		plotIndex = plotIndex,
		balance = constantsV.ECONOMY.startBalance,
		reputation = constantsV.ECONOMY.startReputation,
		day = 1,
		terminal = { mode = "Disconnected", targetDeviceId = nil, sshStack = {} },
		devices = {},
		deviceModels = {},
		racks = {},
		rackModels = {},
		cables = {},
		pendingCableDeviceId = nil,
		pendingCablePortId = nil,
		pendingCableHighlight = nil,
		consoleLink = nil,
		pendingPlacementItemId = nil,
		workbench = {
			chassis = nil,
			mobo = nil,
			cpuCount = 0,
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
	}
	Sessions[player] = session
	usedPlots[plotIndex] = player
	return session
end

function SessionManager.DeleteSession(player: Player)
	local session = Sessions[player]
	if session == nil then
		return
	end
	local facility = session.facility
	if facility and facility.root then
		facility.root:Destroy()
	end
	if session.consoleLink and session.consoleLink.beam then
		session.consoleLink.beam:Destroy()
	end
	usedPlots[session.plotIndex] = nil
	Sessions[player] = nil
end

function SessionManager.NextDeviceId(session: any, prefix: string): string
	session.deviceCounter += 1
	return prefix .. "_" .. tostring(session.deviceCounter)
end

function SessionManager.NextCableId(session: any): string
	session.cableCounter += 1
	return "cbl_" .. tostring(session.cableCounter)
end

return SessionManager
