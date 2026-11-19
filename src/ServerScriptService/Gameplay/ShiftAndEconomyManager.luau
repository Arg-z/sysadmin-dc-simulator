--!strict
--[[
	ShiftAndEconomyManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1 + Fase 3 shift economy.

	Economy tick (every ECONOMY.tickSeconds = 5s) per session:
	  - Shift clock: 08:00 -> 18:00 at SHIFT.secondsPerGameHour (30 real
	    seconds per in-game hour). At 18:00 the day settles: base bonus +
	    uptime bonus + perfect-shift bonus - incident failure penalties;
	    then day += 1 and the clock resets to 08:00.
	  - VM load jitter: running VMs get a smoothed currentLoadPercent toward a
	    random 35..95 target, capped by cpuThrottlePercent (status "throttled"
	    while a throttle limit > 0 is set); stopped VMs sit at 0. A Fase 3
	    "noisy neighbor" VM ignores its limit and pins load at 100 until the
	    incident is resolved. DDoSed hosts report 100% load.
	  - Device loadPercent = sum(vm.cpu * vmLoad / 100) / specs.cpu * 100.
	  - Thermal sim: temperatureC = 30 + loadPercent * 0.45; at >= 80 C the
	    model's "OverheatSmoke" ParticleEmitter is enabled, otherwise disabled.
	  - Power cost per tick: sum of powered device powerWatts + 40 W per rack
	    with pduPowered; balance -= watts * electricityPerWattPerTick (clamp >= 0).
	  - Payout every ECONOMY.payoutInterval (15s = 3 ticks): per VM hosted on a
	    powered device that has an IP, is not DDoSed and has no failed drive:
	    cpu*vpsCpuRate + ram*vpsRamRate + disk*vpsDiskRate. Noisy VMs earn 0.
	  - cabling.Update(session): console cable distance check.
	  - BuildSnapshot -> StateSyncRemote:FireClient.
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
	noisy: boolean?,
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

--[[ Total uptime percent: healthy producing VMs / total VMs (100 when no VM
	 exists). DDoSed hosts and noisy VMs do not count as producing. ]]
local function computeUptimePercent(session: SessionLike): number
	local total = 0
	local producing = 0
	for _, node in pairs(session.devices) do
		for _, vm: VMLike in pairs(node.vms) do
			total += 1
			if node.isPowered and node.ip ~= nil and vm.status ~= "stopped"
				and node.isUnderDDoS ~= true and vm.noisy ~= true then
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
			elseif vm.noisy == true then
				-- Fase 3 Noisy Neighbor: the VM ignores its throttle until the
				-- incident is resolved by throttling/deleting it.
				vm.currentLoadPercent = 100
				vm.status = "running"
				totalLoad += vm.cpu
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
		if node.isUnderDDoS == true then
			loadPercent = 100 -- flood traffic saturates the host
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

--[[ VPS income every payoutInterval: per VM on a powered host with an IP set.
	 Fase 3: DDoSed hosts and hosts with a failed drive earn nothing, and a
	 noisy-neighbor VM earns nothing until the incident is resolved. ]]
local function payVpsIncome(session: SessionLike)
	local economy = constants.ECONOMY
	local income = 0
	for _, node in pairs(session.devices) do
		if node.isPowered and node.ip ~= nil and node.isUnderDDoS ~= true and node.hasDegradedDrive ~= true then
			for _, vm: VMLike in pairs(node.vms) do
				if vm.noisy ~= true and vm.status ~= "stopped" then
					income += vm.cpu * economy.vpsCpuRatePerPayout
					income += vm.ram * economy.vpsRamRatePerPayout
					income += vm.disk * economy.vpsDiskRatePerPayout
				end
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

---------------------------------------------------------------------
-- Fase 3: shift clock + daily settlement
---------------------------------------------------------------------

-- "HH:MM" for the current in-game time.
local function formatClock(clockMinutes: number): string
	local total = math.floor(clockMinutes) % (24 * 60)
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

-- Shift phase label for HUD / NOC (English).
local function getShiftPhase(session: SessionLike): string
	local shiftCfg = constants.SHIFT
	local minutes = session.shift.clockMinutes
	if minutes >= shiftCfg.peakStartMinutes and minutes < shiftCfg.peakEndMinutes then
		return "PEAK HOURS"
	elseif minutes >= shiftCfg.peakEndMinutes then
		return "CLOSING"
	end
	return "SHIFT"
end

-- Number of Active incident tickets (alarm + telemetry use this).
local function countActiveIncidents(session: SessionLike): number
	local count = 0
	for _, t in ipairs(session.tickets or {}) do
		if t.status == "Active" and t.category == "Incident" then
			count += 1
		end
	end
	return count
end

local function sendShiftHint(session: SessionLike, message: string)
	if remotesFolder == nil then
		return
	end
	local opener = remotesFolder:FindFirstChild("OpenTerminalEvent")
	if opener ~= nil then
		opener:FireClient(session.player, { action = "hint", message = message })
	end
end

local function playShiftSFX(session: SessionLike, name: string)
	if remotesFolder == nil then
		return
	end
	local sfx = remotesFolder:FindFirstChild("PlaySFXRemote")
	if sfx ~= nil then
		sfx:FireClient(session.player, name)
	end
end

--[[ End-of-day settlement: base + uptime + perfect shift - incident penalties.
	 Resets the stats, advances the day and drops the clock back to 08:00. ]]
local function settleDay(session: SessionLike)
	local shiftCfg = constants.SHIFT
	local shift = session.shift
	local stats = shift.stats
	local uptime = computeUptimePercent(session)
	local uptimeBonus = math.floor(uptime * shiftCfg.settlementUptimeBonusPerPercent)
	local perfectBonus = if stats.incidentsFailed == 0 then shiftCfg.settlementPerfectBonus else 0
	local penalty = stats.incidentsFailed * shiftCfg.incidentFailurePenalty
	local amount = shiftCfg.settlementBaseBonus + uptimeBonus + perfectBonus - penalty
	session.balance = math.max(0, session.balance + amount)
	if stats.incidentsFailed == 0 then
		session.reputation += 2
	end

	local text = string.format(
		"Day %d Settlement: uptime %.1f%% | contracts %d | incidents %d resolved, %d failed | bonus $%d, penalty $%d, net %s$%d",
		session.day,
		uptime,
		stats.contractsCompleted,
		stats.incidentsResolved,
		stats.incidentsFailed,
		shiftCfg.settlementBaseBonus + uptimeBonus + perfectBonus,
		penalty,
		if amount >= 0 then "+" else "-",
		math.abs(amount)
	)
	shift.lastSettlementText = text
	shift.lastSettlementAmount = amount
	shift.stats = { contractsCompleted = 0, incidentsResolved = 0, incidentsFailed = 0 }
	session.day += 1
	shift.clockMinutes = shiftCfg.startMinutes

	playShiftSFX(session, if amount >= 0 then "cash" else "error")
	sendShiftHint(session, text .. " - Day " .. tostring(session.day) .. " started.")
end

-- Advance the clock by one economy tick; settles the day at 18:00.
local function advanceShift(session: SessionLike)
	local shiftCfg = constants.SHIFT
	local stepMinutes = constants.ECONOMY.tickSeconds / shiftCfg.secondsPerGameHour * 60
	session.shift.clockMinutes += stepMinutes
	if session.shift.clockMinutes >= shiftCfg.endMinutes then
		settleDay(session)
	end
end

-- Mirror balance/reputation into the Roblox leaderboard (created in MainServer).
local function updateLeaderstats(session: SessionLike)
	local player = session.player
	if player == nil then
		return
	end
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats == nil then
		return
	end
	local balanceValue = leaderstats:FindFirstChild("Cash")
	if balanceValue ~= nil and balanceValue:IsA("IntValue") then
		balanceValue.Value = math.floor(session.balance)
	end
	local reputationValue = leaderstats:FindFirstChild("Reputation")
	if reputationValue ~= nil and reputationValue:IsA("IntValue") then
		reputationValue.Value = math.floor(session.reputation)
	end
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
			incidentType = t.incidentType,
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
		clockText = formatClock(session.shift.clockMinutes),
		shiftPhase = getShiftPhase(session),
		incidentCount = countActiveIncidents(session),
		lastSettlement = session.shift.lastSettlementText,
		settlementAmount = session.shift.lastSettlementAmount,
		devices = deviceSnapshots,
		vms = vmRows,
		objectives = computeObjectives(session),
		tickets = ticketRows,
	}
	return snapshot
end

--[[ Immediately build and push a snapshot to this session's player. ]]
function ShiftAndEconomyManager.ForceSync(session: SessionLike)
	updateLeaderstats(session)
	local remote = getRemote()
	if remote == nil then
		return
	end
	remote:FireClient(session.player, ShiftAndEconomyManager.BuildSnapshot(session))
end

--[[ One economy tick for one session. ]]
local function tickSession(session: SessionLike, isPayoutTick: boolean)
	advanceShift(session)
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
