--!strict
--[[
	ShiftAndEconomyManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1.

	Economy tick (every ECONOMY.tickSeconds = 5s) per session:
	  - VM load jitter: running VMs get a smoothed currentLoadPercent toward a
	    random 35..95 target, capped by cpuThrottlePercent (status "throttled"
	    while a throttle limit > 0 is set); stopped VMs sit at 0.
	  - Device loadPercent = sum(vm.cpu * vmLoad / 100) / specs.cpu * 100.
	  - Thermal sim: temperatureC = 30 + loadPercent * 0.45; at >= 80 C the
	    model's "OverheatSmoke" ParticleEmitter is enabled, otherwise disabled.
	  - Power cost per tick: sum of powered device powerWatts + 40 W per rack
	    with pduPowered; balance -= watts * electricityPerWattPerTick (clamp >= 0).
	  - Payout every ECONOMY.payoutInterval (15s = 3 ticks): per VM hosted on a
	    powered device that has an IP: cpu*vpsCpuRate + ram*vpsRamRate + disk*vpsDiskRate.
	  - cabling.Update(session): console cable distance check.
	  - BuildSnapshot -> StateSyncRemote:FireClient.

	Fase 1 runs 24/7 (no shift clock / daily settlement - that is Fase 3 scope,
	see CONTRACT.md Section 9). clockText in the snapshot reflects that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkTypes = require(ReplicatedStorage.Shared.NetworkTypes)
local PlotConstants = require(ReplicatedStorage.Shared.PlotConstants)

local ShiftAndEconomyManager = {}

type FacilitySnapshot = NetworkTypes.FacilitySnapshot
type DeviceSnapshot = NetworkTypes.DeviceSnapshot
type VMStatus = NetworkTypes.VMStatus

type VMSnapshotRow = {
	name: string,
	hostId: string,
	cpu: number,
	ram: number,
	disk: number,
	ip: string?,
	status: VMStatus,
	loadPercent: number,
}

type VMLike = {
	name: string,
	cpu: number,
	ram: number,
	disk: number,
	assignedIp: string?,
	cpuThrottlePercent: number,
	currentLoadPercent: number,
	status: VMStatus,
}

-- Session tables are constructed by SessionManager (Agent A) and cross-module
-- state is intentionally dynamic; only the snapshot output is strictly typed.
type SessionLike = any

local sessions: any = nil
local graph: any = nil
local constants: any = PlotConstants
local remotesFolder: any = nil
local cabling: any = nil
local stateSyncRemote: any = nil

local rng = Random.new()
local tickCounter = 0

-- Fraction of the distance to the new jitter target applied per tick (smoothing).
local LOAD_SMOOTHING = 0.4
-- Room/base temperature used when a device carries no meaningful load.
local BASE_TEMP_C = 30
-- Smoke kicks in at this temperature (per spec: >= 80 C enables OverheatSmoke).
local SMOKE_TEMP_C = 80
-- Fixed idle draw of a powered rack PDU (watts), per contract Section 6.
local RACK_IDLE_WATTS = 40

local function getRemote(): any
	if stateSyncRemote ~= nil and stateSyncRemote.Parent ~= nil then
		return stateSyncRemote
	end
	if remotesFolder == nil then
		return nil
	end
	local remote = remotesFolder:FindFirstChild("StateSyncRemote")
	if remote ~= nil then
		stateSyncRemote = remote
	end
	return stateSyncRemote
end

--[[ Total uptime percent: producing VMs / total VMs (100 when no VM exists).
	 A VM counts as producing when its host is powered, has an IP, and the VM
	 is not stopped. ]]
local function computeUptimePercent(session: SessionLike): number
	local total = 0
	local producing = 0
	for _, node in pairs(session.devices) do
		for _, vm: VMLike in pairs(node.vms) do
			total += 1
			if node.isPowered and node.ip ~= nil and vm.status ~= "stopped" then
				producing += 1
			end
		end
	end
	if total == 0 then
		return 100
	end
	return (producing / total) * 100
end

--[[ Live power draw in watts: powered devices' powerWatts + 40 W per powered rack. ]]
local function computePowerWatts(session: SessionLike): number
	local watts = 0
	for _, node in pairs(session.devices) do
		if node.isPowered then
			local specs = node.specs
			watts += (specs ~= nil and specs.powerWatts) or 0
		end
	end
	for _, rack in pairs(session.racks) do
		if rack.pduPowered then
			watts += RACK_IDLE_WATTS
		end
	end
	return watts
end

--[[ VM load jitter + device load aggregation + thermal sim + overheat smoke. ]]
local function applyLoadAndThermal(session: SessionLike)
	for deviceId, node in pairs(session.devices) do
		local model = session.deviceModels[deviceId]
		local specs = node.specs
		local hostCpu = (specs ~= nil and specs.cpu) or 0
		local totalLoad = 0

		for _, vm: VMLike in pairs(node.vms) do
			if vm.status == "stopped" then
				vm.currentLoadPercent = 0
			else
				local throttle = vm.cpuThrottlePercent or 0
				local target = rng:NextInteger(35, 95)
				if throttle > 0 then
					-- Throttle limit caps the load; status stays throttled while set.
					target = math.min(target, throttle)
					vm.status = "throttled"
				end
				local current = vm.currentLoadPercent or 0
				current += (target - current) * LOAD_SMOOTHING
				vm.currentLoadPercent = math.clamp(current, 0, 100)
				totalLoad += vm.cpu * vm.currentLoadPercent / 100
			end
		end

		local loadPercent = 0
		if hostCpu > 0 then
			loadPercent = math.clamp(totalLoad / hostCpu * 100, 0, 100)
		end
		-- loadPercent lives as a dynamic node field (DeviceSnapshot needs it).
		node.loadPercent = loadPercent
		node.temperatureC = BASE_TEMP_C + loadPercent * 0.45

		if model ~= nil then
			local smoking = node.temperatureC >= SMOKE_TEMP_C
			for _, desc in ipairs(model:GetDescendants()) do
				if desc:IsA("ParticleEmitter") and desc.Name == "OverheatSmoke" then
					desc.Enabled = smoking
				end
			end
		end
	end
end

--[[ Electricity bill for this tick (clamped so balance never goes negative). ]]
local function chargeElectricity(session: SessionLike)
	local watts = computePowerWatts(session)
	local cost = watts * constants.ECONOMY.electricityPerWattPerTick
	session.balance = math.max(0, session.balance - cost)
end

--[[ VPS income every payoutInterval: per VM on a powered host with an IP set. ]]
local function payVpsIncome(session: SessionLike)
	local economy = constants.ECONOMY
	local income = 0
	for _, node in pairs(session.devices) do
		if node.isPowered and node.ip ~= nil then
			for _, vm: VMLike in pairs(node.vms) do
				income += vm.cpu * economy.vpsCpuRatePerPayout
				income += vm.ram * economy.vpsRamRatePerPayout
				income += vm.disk * economy.vpsDiskRatePerPayout
			end
		end
	end
	if income > 0 then
		session.balance += income
	end
end

--[[ Objective booleans computed live from session state (keys fixed by contract). ]]
local function computeObjectives(session: SessionLike): { [string]: boolean }
	local objectives: { [string]: boolean } = {}

	local bm = session.devices["bm_starter_1"]
	local cableWired = false
	if bm ~= nil then
		for _, port in pairs(bm.ports) do
			if port.connectedToDeviceId ~= nil and port.portType ~= "Console" then
				cableWired = true
				break
			end
		end
	end
	objectives.cableWired = cableWired
	objectives.ipSetStarter = bm ~= nil and bm.ip ~= nil
	objectives.osInstalledStarter = bm ~= nil and bm.osInstalled ~= nil
	objectives.pingGateway = session.flags.pingGateway == true
	objectives.vmCreated = ShiftAndEconomyManager.sessionHasAnyVM(session)

	local wb = session.workbench
	objectives.benchBuilt = wb ~= nil and wb.psu ~= nil
	local benchNode = session.devices["bench_1"]
	objectives.benchOsInstalled = benchNode ~= nil and benchNode.osInstalled ~= nil
	objectives.stressPassed = wb ~= nil and wb.tested == true
	objectives.shipped = wb ~= nil and wb.shipped == true

	return objectives
end

function ShiftAndEconomyManager.sessionHasAnyVM(session: SessionLike): boolean
	for _, node in pairs(session.devices) do
		if next(node.vms) ~= nil then
			return true
		end
	end
	return false
end

--[[ Build the full FacilitySnapshot for a session (shape = NetworkTypes.FacilitySnapshot). ]]
function ShiftAndEconomyManager.BuildSnapshot(session: SessionLike): FacilitySnapshot
	local deviceSnapshots: { DeviceSnapshot } = {}
	local vmRows: { VMSnapshotRow } = {}
	local tempSum = 0
	local poweredCount = 0

	for id, node in pairs(session.devices) do
		-- peers = names of devices connected on any port (deduped)
		local peers: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, port in pairs(node.ports) do
			local peerId = port.connectedToDeviceId
			if peerId ~= nil then
				local peer = session.devices[peerId]
				local peerName = if peer ~= nil then peer.name else peerId
				if not seen[peerName] then
					seen[peerName] = true
					table.insert(peers, peerName)
				end
			end
		end

		local vmCount = 0
		for _, vm: VMLike in pairs(node.vms) do
			vmCount += 1
			table.insert(vmRows, {
				name = vm.name,
				hostId = id,
				cpu = vm.cpu,
				ram = vm.ram,
				disk = vm.disk,
				ip = vm.assignedIp,
				status = vm.status,
				loadPercent = vm.currentLoadPercent or 0,
			})
		end

		if node.isPowered then
			tempSum += node.temperatureC or BASE_TEMP_C
			poweredCount += 1
		end

		local snapshot: DeviceSnapshot = {
			id = id,
			name = node.name,
			deviceType = node.deviceType,
			ip = node.ip,
			isPowered = node.isPowered,
			temperatureC = node.temperatureC or BASE_TEMP_C,
			loadPercent = node.loadPercent or 0,
			vmCount = vmCount,
			peers = peers,
		}
		table.insert(deviceSnapshots, snapshot)
	end

	local avgTempC = if poweredCount > 0 then tempSum / poweredCount else 0

	local ticketRows = {}
	for _, t in ipairs(session.tickets or {}) do
		table.insert(ticketRows, {
			id = t.id,
			category = t.category,
			title = t.title,
			description = t.description,
			rewardPayout = t.rewardPayout,
			status = t.status,
			requirementsText = t.requirementsText or "",
			slaRemainingSec = t.slaRemainingSec,
			payoutIntervalSec = t.payoutIntervalSec,
			validationText = t.validationText or "",
			vlanId = t.vlanId,
		})
	end

	local snapshot: FacilitySnapshot = {
		plotIndex = session.plotIndex,
		balance = session.balance,
		reputation = session.reputation,
		uptimePercent = computeUptimePercent(session),
		powerWatts = computePowerWatts(session),
		avgTempC = avgTempC,
		storm = session.broadcastStorm == true,
		day = session.day,
		-- Fase 1 has no shift clock yet (Fase 3 scope); the lab runs 24/7.
		clockText = "24/7",
		devices = deviceSnapshots,
		vms = vmRows,
		objectives = computeObjectives(session),
		tickets = ticketRows,
	}
	return snapshot
end

--[[ Immediately build and push a snapshot to this session's player. ]]
function ShiftAndEconomyManager.ForceSync(session: SessionLike)
	local remote = getRemote()
	if remote == nil then
		return
	end
	remote:FireClient(session.player, ShiftAndEconomyManager.BuildSnapshot(session))
end

--[[ One economy tick for one session. ]]
local function tickSession(session: SessionLike, isPayoutTick: boolean)
	applyLoadAndThermal(session)
	chargeElectricity(session)
	if isPayoutTick then
		payVpsIncome(session)
	end
	if cabling ~= nil and type(cabling.Update) == "function" then
		cabling.Update(session) -- console cable distance check (> 18 studs detaches)
	end
	ShiftAndEconomyManager.ForceSync(session)
end

function ShiftAndEconomyManager.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	constants = deps.constants or PlotConstants
	remotesFolder = deps.remotesFolder
	cabling = deps.cabling
	if remotesFolder ~= nil then
		stateSyncRemote = remotesFolder:FindFirstChild("StateSyncRemote")
	end
end

--[[ Main loop: every ECONOMY.tickSeconds, tick every session; payout every
	 ECONOMY.payoutInterval (tracked via a tick counter, 15s / 5s = every 3rd tick). ]]
function ShiftAndEconomyManager.Start()
	local economy = constants.ECONOMY
	local tickSeconds = economy.tickSeconds
	local payoutEvery = math.max(1, math.floor(economy.payoutInterval / tickSeconds + 0.5))

	task.spawn(function()
		while true do
			task.wait(tickSeconds)
			tickCounter += 1
			local isPayoutTick = (tickCounter % payoutEvery == 0)
			local allSessions = if sessions ~= nil then sessions.GetAllSessions() else nil
			if allSessions ~= nil then
				for _, session in pairs(allSessions) do
					local ok, err = pcall(tickSession, session, isPayoutTick)
					if not ok then
						warn("[ShiftAndEconomyManager] tick error: " .. tostring(err))
					end
				end
			end
		end
	end)
end

return ShiftAndEconomyManager
