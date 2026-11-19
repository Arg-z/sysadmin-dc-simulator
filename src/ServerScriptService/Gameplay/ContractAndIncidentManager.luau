--!strict
--[[
	ContractAndIncidentManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1 + 2 + 3.

	FASE 3 SCOPE: incident engine on top of the contract pool.
	  - Four incidents: Cable Fault, DDoS Flood, Noisy Neighbor and Remote
	    Hands Drive Failure.
	  - New incidents only spawn during peak hours 11:00-17:00, one every
	    INCIDENTS.spawnCooldownSeconds, at most INCIDENTS.maxActive alive.
	    Types rotate so a full shift exposes all four.
	  - Each incident is an Active ticket with category "Incident" and a live
	    SLA countdown; resolving pays an incentive + reputation, failing the
	    SLA costs reputation and the effect is cleared.
	  - The alarm beacon (facility.beaconLens / beaconLight) pulses red and
	    plays a looping klaxon while any incident is active. Faulty cable
	    beams and port LEDs flash until repaired.
	  - Resolution hooks:
	      CableFault    -> cut + re-cable the same device/port pair
	      DDoSFlood     -> 'ddos block <attackerIp>' on the router
	      NoisyNeighbor -> 'vm throttle <name> --limit 40' (or delete the VM)
	      DriveFailure  -> buy replacement_hdd + 'drive replace <bay>'

	Ticket flow (tickets live in session.tickets):
	  - Loop every 5s per session: top up to 3 Available contract tickets,
	    spawn/validate incidents, validate Active contracts.
	  - CloudVPS, CustomBuild and Colocation behave exactly as in Fase 2.
	  - ContractActionRemote {action="accept"} only accepts non-incident
	    Available tickets (max 2 Active contracts; incidents do not count).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkTypes = require(ReplicatedStorage.Shared.NetworkTypes)

local ContractAndIncidentManager = {}

type TicketCategory = NetworkTypes.TicketCategory
type TicketStatus = NetworkTypes.TicketStatus

--[[ ContractTicket plus the UI-only requirementsText row. ]]
export type TicketRow = NetworkTypes.ContractTicket & {
	requirementsText: string,
}

type SessionLike = any

local MAX_AVAILABLE_TICKETS = 3
local MAX_ACTIVE_TICKETS = 2
local LOOP_SECONDS = 5
local COMPLETED_LINGER_SECONDS = 8
local DEFAULT_SLA_SECONDS = 300
local CATEGORY_ORDER: { string } = { "CloudVPS", "Colocation", "CustomBuild" }

local sessions: any = nil
local graph: any = nil
local constants: any = nil
local remotesFolder: any = nil
local workbench: any = nil
local carry: any = nil

local contractRemote: any = nil
local playSFXRemote: any = nil
local openTerminalRemote: any = nil
local acceptBound = false

local rng = Random.new()
local ticketCounter = 0
local incidentCounter = 0

local LED_RED = Color3.fromRGB(255, 80, 80)
local LED_OFF = Color3.fromRGB(70, 70, 70)
local BEACON_RED = Color3.fromRGB(220, 40, 40)
local ALARM_SOUND_ID = "rbxassetid://4530741431" -- emergency siren loop (16s)

-- Eight invented global client names for contract flavor.
local CLIENT_NAMES = {
	"Apex Cloud Systems",
	"Nexus Data Labs",
	"BitStream Studios",
	"Aether Media Group",
	"Nova Digital Co-op",
	"Silicon Forge Hardware",
	"Espresso Cloud Dev",
	"HyperScale Ventures",
}

local function randomChoice(list: { any }): any
	return list[rng:NextInteger(1, #list)]
end

local function getRemotes()
	if contractRemote == nil and remotesFolder ~= nil then
		contractRemote = remotesFolder:FindFirstChild("ContractActionRemote")
	end
	if playSFXRemote == nil and remotesFolder ~= nil then
		playSFXRemote = remotesFolder:FindFirstChild("PlaySFXRemote")
	end
	if openTerminalRemote == nil and remotesFolder ~= nil then
		openTerminalRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
	end
end

local function playSFX(session: SessionLike, name: string)
	if playSFXRemote ~= nil then
		playSFXRemote:FireClient(session.player, name)
	end
end

local function sendHint(session: SessionLike, message: string)
	if openTerminalRemote ~= nil then
		openTerminalRemote:FireClient(session.player, { action = "hint", message = message })
	end
end

local function nextTicketId(): string
	ticketCounter += 1
	return string.format("tkt_%d_%d", math.floor(os.clock() * 1000), ticketCounter)
end

local function nextIncidentId(): string
	incidentCounter += 1
	return string.format("inc_%d_%d", math.floor(os.clock() * 1000), incidentCounter)
end

local function linkKey(devA: string, portA: string, devB: string, portB: string): string
	if graph ~= nil and type(graph.LinkKey) == "function" then
		return graph.LinkKey(devA, portA, devB, portB)
	end
	local left = devA .. "|" .. portA
	local right = devB .. "|" .. portB
	return if left <= right then left .. ">" .. right else right .. ">" .. left
end

local function countActiveIncidents(session: SessionLike): number
	local count = 0
	for _, t in ipairs(session.tickets or {}) do
		if t.status == "Active" and t.category == "Incident" then
			count += 1
		end
	end
	return count
end

local function recordContractCompletion(session: SessionLike)
	if session.shift ~= nil and session.shift.stats ~= nil then
		session.shift.stats.contractsCompleted += 1
	end
end

-- Forward declaration: defined with the contract validators below, but the
-- incident resolve/fail helpers (defined first) already schedule removal.
local scheduleRemoval: (SessionLike, string) -> ()

---------------------------------------------------------------------
-- Ticket factories
---------------------------------------------------------------------

local function makeCloudVPSTicket(): TicketRow
	local clientName = randomChoice(CLIENT_NAMES) :: string
	local cpu = rng:NextInteger(2, 8)
	local ram = rng:NextInteger(4, 32)
	local disk = rng:NextInteger(50, 500)
	local reward = math.max(120, math.floor(cpu * 60 + ram * 2 + disk * 0.1))

	local ticket: TicketRow = {
		id = nextTicketId(),
		category = "CloudVPS" :: TicketCategory,
		clientName = clientName,
		title = string.format("Cloud VPS %d vCPU", cpu),
		description = string.format(
			"%s ordered a VPS: %d vCPU / %dGB RAM / %dGB disk. Provision a matching VM on your bare-metal server. SLA %d seconds.",
			clientName,
			cpu,
			ram,
			disk,
			DEFAULT_SLA_SECONDS
		),
		requirements = { cpu = cpu, ram = ram, disk = disk },
		rewardPayout = reward,
		payoutIntervalSec = nil,
		slaRemainingSec = nil,
		runtimeRemainingSec = nil,
		vlanId = nil,
		targetIp = nil,
		phase = nil,
		validationText = "Waiting for matching VM",
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = string.format(
			"VM >= %d vCPU / %dGB RAM / %dGB disk on powered bare-metal with OS installed",
			cpu,
			ram,
			disk
		),
	}
	return ticket
end

local function makeCustomBuildTicket(): TicketRow
	local clientName = randomChoice(CLIENT_NAMES) :: string
	local reward = rng:NextInteger(250, 600)

	local ticket: TicketRow = {
		id = nextTicketId(),
		category = "CustomBuild" :: TicketCategory,
		clientName = clientName,
		title = "Custom Server Build",
		description = string.format(
			"%s ordered a custom-assembled server, paid upfront once the crate ships from the dock. SLA %d seconds.",
			clientName,
			DEFAULT_SLA_SECONDS
		),
		requirements = {},
		rewardPayout = reward,
		payoutIntervalSec = nil,
		slaRemainingSec = nil,
		runtimeRemainingSec = nil,
		vlanId = nil,
		targetIp = nil,
		phase = nil,
		validationText = "Assemble + install OS + stress test + ship",
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = "Assemble server on workbench + install OS + stress test + ship",
	}
	return ticket
end

local function makeColocationTicket(): TicketRow
	local clientName = randomChoice(CLIENT_NAMES) :: string
	local vlanChoices: { number } = constants.COLOCATION.vlanChoices
	local vlanId = randomChoice(vlanChoices) :: number
	local ip = string.format("10.20.%d.%d", vlanId, rng:NextInteger(10, 200))
	local reward = rng:NextInteger(35, 70)
	local colo = constants.COLOCATION

	local ticket: TicketRow = {
		id = nextTicketId(),
		category = "Colocation" :: TicketCategory,
		clientName = clientName,
		title = string.format("Colocation VLAN %d", vlanId),
		description = string.format(
			"%s is shipping a physical server to host in your rack. Mount the unit, wire to switch VLAN %d, turn PDU ON, and ensure reachability from the gateway. Pays $%d every %ds for %ds.",
			clientName,
			vlanId,
			reward,
			colo.payoutIntervalSeconds,
			colo.runtimeSeconds
		),
		requirements = { vlanId = vlanId, ip = ip },
		rewardPayout = reward,
		payoutIntervalSec = colo.payoutIntervalSeconds,
		slaRemainingSec = nil,
		runtimeRemainingSec = nil,
		vlanId = vlanId,
		targetIp = ip,
		phase = nil,
		validationText = "Accept contract to dispatch crate to dock",
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = string.format(
			"Mount %dU crate in rack, wire to switch VLAN %d, PDU ON, reachable from gateway. SLA %ds.",
			colo.uSize,
			vlanId,
			colo.slaSeconds
		),
	}
	return ticket
end

---------------------------------------------------------------------
-- Fase 3: incident engine
---------------------------------------------------------------------

--[[ Pick a live non-console cable to sabotage. Prefers data cables over the
	 WAN uplink so the early-game internet path is not the first casualty. ]]
local function findCableTarget(session: SessionLike): any?
	local dataCandidates: { any } = {}
	local allCandidates: { any } = {}
	for _, cable in pairs(session.cables) do
		local a = session.devices[cable.aDeviceId]
		local b = session.devices[cable.bDeviceId]
		if a ~= nil and b ~= nil then
			local pa = a.ports[cable.aPortId]
			local pb = b.ports[cable.bPortId]
			if pa ~= nil and pb ~= nil
				and pa.connectedToDeviceId == cable.bDeviceId
				and pb.connectedToDeviceId == cable.aDeviceId then
				local key = linkKey(cable.aDeviceId, cable.aPortId, cable.bDeviceId, cable.bPortId)
				if session.incidentFaults[key] ~= true then
					local entry = { cable = cable, key = key }
					table.insert(allCandidates, entry)
					if cable.color ~= "WAN_Yellow" then
						table.insert(dataCandidates, entry)
					end
				end
			end
		end
	end
	local pool = if #dataCandidates > 0 then dataCandidates else allCandidates
	if #pool == 0 then
		return nil
	end
	return randomChoice(pool)
end

--[[ Pick a powered server with an IP (preferring one that hosts VMs). ]]
local function findDDoSTarget(session: SessionLike): any?
	local primary: { any } = {}
	local secondary: { any } = {}
	for _, node in pairs(session.devices) do
		if node.isPowered and node.ip ~= nil and node.isUnderDDoS ~= true then
			if node.deviceType == "BareMetal" or node.deviceType == "ColocationServer" then
				table.insert(primary, node)
			elseif node.deviceType == "Router" then
				table.insert(secondary, node)
			end
		end
	end
	if #primary > 0 then
		return randomChoice(primary)
	end
	if #secondary > 0 then
		return randomChoice(secondary)
	end
	return nil
end

--[[ Pick a running VM on a powered server and return (node, vm). ]]
local function findNoisyTarget(session: SessionLike): (any?, any?)
	local candidates: { any } = {}
	for _, node in pairs(session.devices) do
		if node.isPowered and (node.deviceType == "BareMetal" or node.deviceType == "ColocationServer") then
			for _, vm in pairs(node.vms) do
				if vm.status ~= "stopped" and vm.noisy ~= true then
					table.insert(candidates, { node = node, vm = vm })
				end
			end
		end
	end
	if #candidates == 0 then
		return nil, nil
	end
	local entry = randomChoice(candidates)
	return entry.node, entry.vm
end

--[[ Pick a powered server without a failed drive (prefers one hosting VMs). ]]
local function findDriveTarget(session: SessionLike): any?
	local primary: { any } = {}
	local fallback: { any } = {}
	for _, node in pairs(session.devices) do
		if node.isPowered and (node.deviceType == "BareMetal" or node.deviceType == "ColocationServer")
			and node.hasDegradedDrive ~= true then
			if next(node.vms) ~= nil then
				table.insert(primary, node)
			else
				table.insert(fallback, node)
			end
		end
	end
	local pool = if #primary > 0 then primary else fallback
	if #pool == 0 then
		return nil
	end
	return randomChoice(pool)
end

--[[ Pick a powered OS-installed host with a running service and no crash. ]]
local function findServiceTarget(session: SessionLike): any?
	local pool: { any } = {}
	for _, node in pairs(session.devices) do
		if node.isPowered and node.osInstalled ~= nil and node.services ~= nil then
			local hasRunning = false
			local hasCrashed = false
			for _, state in pairs(node.services) do
				if state == "running" then
					hasRunning = true
				end
				if state == "crashed" then
					hasCrashed = true
				end
			end
			if hasRunning and not hasCrashed then
				table.insert(pool, node)
			end
		end
	end
	if #pool == 0 then
		return nil
	end
	return randomChoice(pool)
end

--[[ Build the Active incident ticket row + instruction text. ]]
local function makeIncidentTicket(incidentType: string, data: any): TicketRow
	local cfg = constants.INCIDENTS
	local title: string
	local description: string
	local requirementsText: string
	local validationText: string

	if incidentType == "CableFault" then
		title = "INCIDENT: Cable Fault"
		description = string.format(
			"NOC detected a dead link between %s:%s and %s:%s. Cut the damaged cable with WireCutter and re-cable the same port pair. SLA %d seconds.",
			data.aName, data.aPort, data.bName, data.bPort, cfg.slaSeconds
		)
		requirementsText = string.format("Replace cable %s:%s <-> %s:%s", data.aName, data.aPort, data.bName, data.bPort)
		validationText = "Damaged cable - cut and replace"
	elseif incidentType == "DDoSFlood" then
		title = "INCIDENT: DDoS Flood"
		description = string.format(
			"%s (%s) is flooded with traffic from %s. Open the router console and run 'ddos block %s' to mitigate. SLA %d seconds.",
			data.deviceName, data.deviceIp, data.attackerIp, data.attackerIp, cfg.slaSeconds
		)
		requirementsText = string.format("On router: ddos block %s", data.attackerIp)
		validationText = string.format("Active DDoS from %s", data.attackerIp)
	elseif incidentType == "NoisyNeighbor" then
		title = "INCIDENT: Noisy Neighbor"
		description = string.format(
			"VM '%s' on %s is ignoring limits and pinning host CPU at 100%%. Throttle it to max %d%% or delete the VM. SLA %d seconds.",
			data.vmName, data.deviceName, data.limit, cfg.slaSeconds
		)
		requirementsText = string.format("vm throttle %s --limit %d (or vm delete %s)", data.vmName, data.limit, data.vmName)
		validationText = "Noisy neighbor ignoring CPU limit"
	elseif incidentType == "DriveFailure" then
		title = "INCIDENT: Drive Failure"
		description = string.format(
			"Remote hands reported failed drive bay %d on %s. Buy replacement_hdd in Store > Component, then run 'drive replace %d' on the server console. SLA %d seconds.",
			data.bay, data.deviceName, data.bay, cfg.slaSeconds
		)
		requirementsText = string.format("Buy replacement_hdd + 'drive replace %d' on %s", data.bay, data.deviceName)
		validationText = string.format("Drive bay %d failed", data.bay)
	else
		title = "INCIDENT: Service Crash"
		description = string.format(
			"%s on %s: %s.service entered failed state (core dumped). Host income is paused until the unit is back up. Run 'systemctl restart %s' on the server console. SLA %d seconds.",
			data.service, data.deviceName, data.service, data.service, cfg.slaSeconds
		)
		requirementsText = string.format("systemctl restart %s on %s", data.service, data.deviceName)
		validationText = string.format("%s.service crashed", data.service)
	end

	local ticket: TicketRow = {
		id = nextIncidentId(),
		category = "Incident" :: TicketCategory,
		clientName = "NOC Internal",
		title = title,
		description = description,
		requirements = {},
		rewardPayout = cfg.rewards[incidentType] or 150,
		payoutIntervalSec = nil,
		slaRemainingSec = cfg.slaSeconds,
		runtimeRemainingSec = nil,
		vlanId = nil,
		targetIp = nil,
		phase = nil,
		validationText = validationText,
		targetDeviceId = data.deviceId,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Active" :: TicketStatus,
		requirementsText = requirementsText,
		incidentType = incidentType,
		incidentData = data,
	}
	return ticket
end

--[[ Apply the physical/logical effect of an incident and register the ticket.
	 Returns true when a valid target existed. ]]
local function spawnIncident(session: SessionLike, incidentType: string): boolean
	local cfg = constants.INCIDENTS
	local data: any

	if incidentType == "CableFault" then
		local target = findCableTarget(session)
		if target == nil then
			return false
		end
		local cable = target.cable
		local a = session.devices[cable.aDeviceId]
		local b = session.devices[cable.bDeviceId]
		data = {
			key = target.key,
			aDeviceId = cable.aDeviceId,
			aPort = cable.aPortId,
			bDeviceId = cable.bDeviceId,
			bPort = cable.bPortId,
			aName = a.name,
			bName = b.name,
			deviceId = cable.aDeviceId,
		}
		session.incidentFaults[target.key] = true
	elseif incidentType == "DDoSFlood" then
		local node = findDDoSTarget(session)
		if node == nil then
			return false
		end
		-- Pick an attacker IP that no router has already blocked, so a prior
		-- 'ddos block <ip>' actually keeps that source from attacking again.
		local attackerIp: string? = nil
		for _ = 1, 24 do
			local candidate = string.format("203.0.113.%d", rng:NextInteger(2, 254))
			local blocked = false
			for _, other in pairs(session.devices) do
				if other.blockedIps ~= nil and other.blockedIps[candidate] == true then
					blocked = true
					break
				end
			end
			if not blocked then
				attackerIp = candidate
				break
			end
		end
		if attackerIp == nil then
			return false -- every public source IP is already blocked
		end
		node.isUnderDDoS = true
		node.ddosAttackerIp = attackerIp
		data = {
			deviceId = node.id,
			deviceName = node.name,
			deviceIp = node.ip,
			attackerIp = attackerIp,
		}
	elseif incidentType == "NoisyNeighbor" then
		local node, vm = findNoisyTarget(session)
		if node == nil or vm == nil then
			return false
		end
		vm.noisy = true
		data = {
			deviceId = node.id,
			deviceName = node.name,
			vmName = vm.name,
			limit = cfg.noisyThrottleLimit,
		}
	elseif incidentType == "DriveFailure" then
		local node = findDriveTarget(session)
		if node == nil then
			return false
		end
		local bay = rng:NextInteger(1, 4)
		node.hasDegradedDrive = true
		node.degradedBayIndex = bay
		-- Seed SMART counters so 'smartctl' tells the failure story.
		node.smartReallocated = rng:NextInteger(48, 96)
		node.smartPending = rng:NextInteger(4, 16)
		node.smartHealth = math.max(4, 100 - math.floor(node.smartReallocated / 12))
		data = {
			deviceId = node.id,
			deviceName = node.name,
			bay = bay,
		}
	else -- ServiceCrash
		local node = findServiceTarget(session)
		if node == nil then
			return false
		end
		local candidates: { string } = {}
		for name, state in pairs(node.services) do
			if state == "running" and name ~= "sshd" then
				table.insert(candidates, name)
			end
		end
		if #candidates == 0 then
			return false
		end
		local svc = randomChoice(candidates)
		node.services[svc] = "crashed"
		data = {
			deviceId = node.id,
			deviceName = node.name,
			service = svc,
		}
	end

	local ticket = makeIncidentTicket(incidentType, data)
	table.insert(session.tickets, ticket)
	if graph ~= nil and type(graph.Journal) == "function" then
		graph.Journal(session, "err", "incidentd", ticket.title .. " - " .. tostring(data.deviceName or data.aName or "lab"))
	end
	playSFX(session, "klaxon")
	sendHint(session, string.format("%s - SLA %ds. Check TicketMonitor or type 'incident'.", ticket.title, cfg.slaSeconds))
	return true
end

--[[ Remove every effect attached to an incident (used by resolve and fail). ]]
local function clearIncidentEffect(session: SessionLike, ticket: any)
	local incidentType = ticket.incidentType
	local data = ticket.incidentData
	if type(data) ~= "table" then
		return
	end
	if incidentType == "CableFault" then
		session.incidentFaults[data.key] = nil
	elseif incidentType == "DDoSFlood" then
		local node = session.devices[data.deviceId]
		if node ~= nil then
			node.isUnderDDoS = false
			node.ddosAttackerIp = nil
			if graph ~= nil and type(graph.UpdateDeviceLED) == "function" then
				graph.UpdateDeviceLED(session, data.deviceId)
			end
		end
	elseif incidentType == "NoisyNeighbor" then
		local node = session.devices[data.deviceId]
		if node ~= nil then
			local vm = node.vms[data.vmName]
			if vm ~= nil then
				vm.noisy = nil
			end
		end
	elseif incidentType == "DriveFailure" then
		local node = session.devices[data.deviceId]
		if node ~= nil then
			node.hasDegradedDrive = false
			node.degradedBayIndex = nil
			if graph ~= nil and type(graph.UpdateDeviceLED) == "function" then
				graph.UpdateDeviceLED(session, data.deviceId)
			end
		end
	elseif incidentType == "ServiceCrash" then
		-- A crashed service stays failed until the admin restarts it, even
		-- when the SLA expires; the reputation hit is the penalty.
	end
end

--[[ Check whether the player already fixed the incident. Returns (resolved, note). ]]
local function checkIncidentResolved(session: SessionLike, ticket: any): (boolean, string)
	local incidentType = ticket.incidentType
	local data = ticket.incidentData
	if type(data) ~= "table" then
		return true, "Invalid incident data"
	end

	if incidentType == "CableFault" then
		if session.incidentFaults[data.key] ~= true then
			return true, "Replacement cable installed - link restored"
		end
		return false, string.format("Cut + re-cable %s:%s <-> %s:%s", data.aName, data.aPort, data.bName, data.bPort)
	elseif incidentType == "DDoSFlood" then
		local node = session.devices[data.deviceId]
		if node == nil or node.isUnderDDoS ~= true then
			return true, "DDoS attack mitigated"
		end
		return false, string.format("DDoS from %s - run 'ddos block %s' on router", data.attackerIp, data.attackerIp)
	elseif incidentType == "NoisyNeighbor" then
		local node = session.devices[data.deviceId]
		if node == nil then
			return true, "Host removed"
		end
		local vm = node.vms[data.vmName]
		if vm == nil then
			return true, "Noisy VM deleted"
		end
		if vm.noisy ~= true then
			return true, "Noisy neighbor throttled"
		end
		local limit = data.limit or constants.INCIDENTS.noisyThrottleLimit
		if (vm.cpuThrottlePercent or 0) > 0 and vm.cpuThrottlePercent <= limit then
			vm.noisy = nil
			return true, string.format("VM %s throttled to %d%% - host stable", data.vmName, vm.cpuThrottlePercent)
		end
		return false, string.format("VM %s still at 100%% - 'vm throttle %s --limit %d'", data.vmName, data.vmName, limit)
	elseif incidentType == "DriveFailure" then
		local node = session.devices[data.deviceId]
		if node == nil or node.hasDegradedDrive ~= true then
			return true, "Replacement drive installed"
		end
		return false, string.format("Drive bay %d failed - 'drive replace %d' (+ replacement_hdd)", data.bay, data.bay)
	elseif incidentType == "ServiceCrash" then
		local node = session.devices[data.deviceId]
		if node == nil then
			return true, "Host removed"
		end
		if node.services == nil or node.services[data.service] ~= "crashed" then
			return true, data.service .. ".service restarted"
		end
		return false, string.format("%s.service crashed - 'systemctl restart %s'", data.service, data.service)
	end
	return true, "Unknown incident"
end

local function resolveIncident(session: SessionLike, ticket: any, note: string)
	clearIncidentEffect(session, ticket)
	if graph ~= nil and type(graph.Journal) == "function" then
		graph.Journal(session, "info", "incidentd", "Resolved: " .. ticket.title .. " (" .. note .. ")")
	end
	ticket.status = "Completed"
	ticket.validationText = note
	session.balance += ticket.rewardPayout
	session.reputation += 1
	if session.shift ~= nil and session.shift.stats ~= nil then
		session.shift.stats.incidentsResolved += 1
	end
	playSFX(session, "cash")
	sendHint(session, string.format("Incident resolved: %s +$%d (%s)", ticket.title, ticket.rewardPayout, note))
	scheduleRemoval(session, ticket.id)
end

local function failIncident(session: SessionLike, ticket: any, reason: string)
	clearIncidentEffect(session, ticket)
	if graph ~= nil and type(graph.Journal) == "function" then
		graph.Journal(session, "warning", "incidentd", "SLA failed: " .. ticket.title .. " (" .. reason .. ")")
	end
	ticket.status = "Failed"
	ticket.validationText = reason
	session.reputation = math.max(0, session.reputation - 2)
	if session.shift ~= nil and session.shift.stats ~= nil then
		session.shift.stats.incidentsFailed += 1
	end
	playSFX(session, "error")
	sendHint(session, string.format("Incident failed: %s (%s)", ticket.title, reason))
	scheduleRemoval(session, ticket.id)
end

--[[ Top up Available tickets, always filling the category with the fewest
	 Available rows so the three pillars rotate naturally. ]]
local function generateTickets(session: SessionLike)
	local available: { [string]: number } = { CloudVPS = 0, Colocation = 0, CustomBuild = 0 }
	for _, t in ipairs(session.tickets) do
		if t.status == "Available" and available[t.category] ~= nil then
			available[t.category] += 1
		end
	end

	local totalAvailable = available.CloudVPS + available.Colocation + available.CustomBuild
	while totalAvailable < MAX_AVAILABLE_TICKETS do
		local category = CATEGORY_ORDER[1]
		local lowest = available[category]
		for _, candidate in ipairs(CATEGORY_ORDER) do
			if available[candidate] < lowest then
				lowest = available[candidate]
				category = candidate
			end
		end

		local ticket: TicketRow
		if category == "CloudVPS" then
			ticket = makeCloudVPSTicket()
		elseif category == "Colocation" then
			ticket = makeColocationTicket()
		else
			ticket = makeCustomBuildTicket()
		end
		table.insert(session.tickets, ticket)
		available[category] += 1
		totalAvailable += 1
	end
end

---------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------

--[[ CloudVPS done when a powered BareMetal with an OS hosts a big-enough VM. ]]
local function cloudVPSComplete(session: SessionLike, requirements: any): boolean
	local reqCpu = (type(requirements) == "table" and requirements.cpu) or 0
	local reqRam = (type(requirements) == "table" and requirements.ram) or 0
	local reqDisk = (type(requirements) == "table" and requirements.disk) or 0
	for _, node in pairs(session.devices) do
		if node.deviceType == "BareMetal" and node.osInstalled ~= nil and node.isPowered then
			for _, vm in pairs(node.vms) do
				if vm.cpu >= reqCpu and vm.ram >= reqRam and vm.disk >= reqDisk then
					return true
				end
			end
		end
	end
	return false
end

--[[ Keep a finished row visible for one or two syncs, then remove it. ]]
function scheduleRemoval(session: SessionLike, ticketId: string)
	local player = session.player
	task.delay(COMPLETED_LINGER_SECONDS, function()
		if sessions.GetSession(player) ~= session then
			return
		end
		for idx = #session.tickets, 1, -1 do
			local row = session.tickets[idx]
			if row.id == ticketId and (row.status == "Completed" or row.status == "Failed") then
				table.remove(session.tickets, idx)
			end
		end
	end)
end

local function completeColocation(session: SessionLike, ticket: any)
	ticket.status = "Completed"
	ticket.phase = "closed"
	ticket.validationText = "Contract completed - client retrieved server"
	session.reputation += 2
	recordContractCompletion(session)
	playSFX(session, "cash")
	sendHint(session, string.format("Colocation contract completed: %s (all payouts delivered)", ticket.title))
	local coloCleanup = constants.COLOCATION.cleanupDelaySeconds
	task.delay(coloCleanup, function()
		if sessions.GetSession(session.player) == session then
			if carry ~= nil then
				carry.CleanupTicket(session, ticket)
			end
		end
	end)
	scheduleRemoval(session, ticket.id)
end

--[[ Counts down a non-colocation SLA. Returns true when it just expired. ]]
local function tickSla(ticket: any): boolean
	if ticket.slaRemainingSec == nil then
		ticket.slaRemainingSec = DEFAULT_SLA_SECONDS
	end
	ticket.slaRemainingSec = math.max(0, ticket.slaRemainingSec - LOOP_SECONDS)
	return ticket.slaRemainingSec <= 0
end

local function failContract(session: SessionLike, ticket: any, reason: string)
	ticket.status = "Failed"
	ticket.validationText = reason
	playSFX(session, "error")
	sendHint(session, string.format("Contract failed: %s (%s)", ticket.title, reason))
	scheduleRemoval(session, ticket.id)
end

local function failColocation(session: SessionLike, ticket: any, reason: string)
	ticket.status = "Failed"
	ticket.phase = "closed"
	ticket.validationText = reason
	playSFX(session, "error")
	sendHint(session, string.format("Colocation contract failed: %s (%s)", ticket.title, reason))
	if carry ~= nil then
		carry.CleanupTicket(session, ticket)
	end
	scheduleRemoval(session, ticket.id)
end

--[[ Mark completed Active tickets, pay out, and schedule removal from the list. ]]
local function validateActiveTickets(session: SessionLike)
	for _, t in ipairs(session.tickets) do
		if t.status ~= "Active" then
			continue
		end

		if t.category == "CloudVPS" then
			if cloudVPSComplete(session, t.requirements) then
				t.status = "Completed"
				session.balance += t.rewardPayout
				session.reputation += 1
				recordContractCompletion(session)
				playSFX(session, "cash")
				sendHint(session, string.format("Contract completed: %s +$%d", t.title, t.rewardPayout))
				scheduleRemoval(session, t.id)
			elseif tickSla(t) then
				failContract(session, t, "SLA expired before VM was ready")
				continue
			else
				t.validationText = string.format("Waiting for matching VM - SLA %ds", t.slaRemainingSec)
			end
		elseif t.category == "CustomBuild" then
			-- session.workbench is the live state source (deps.workbench is the
			-- module handle kept for API compliance with the contract).
			if session.workbench.shipped == true then
				t.status = "Completed"
				session.balance += t.rewardPayout
				session.reputation += 1
				recordContractCompletion(session)
				playSFX(session, "cash")
				sendHint(session, string.format("Contract completed: %s +$%d", t.title, t.rewardPayout))
				scheduleRemoval(session, t.id)
			elseif tickSla(t) then
				failContract(session, t, "SLA expired before build was shipped")
				continue
			else
				t.validationText = string.format("Waiting for build shipment - SLA %ds", t.slaRemainingSec)
			end
		elseif t.category == "Incident" then
			-- Fase 3: peak hours end at 17:00; unresolved incidents escalate.
			local clockMinutes = if session.shift ~= nil then session.shift.clockMinutes else 0
			if clockMinutes >= constants.SHIFT.peakEndMinutes then
				failIncident(session, t, "Peak hours ended before incident was resolved")
				continue
			end
			local resolved, note = checkIncidentResolved(session, t)
			t.validationText = note
			if resolved then
				resolveIncident(session, t, note)
			else
				t.slaRemainingSec = math.max(0, (t.slaRemainingSec or constants.INCIDENTS.slaSeconds) - LOOP_SECONDS)
				if t.slaRemainingSec <= 0 then
					failIncident(session, t, "SLA expired - incident unresolved")
				end
			end
		elseif t.category == "Colocation" then
			if t.phase == "running" then
				t.runtimeRemainingSec = math.max(0, (t.runtimeRemainingSec or 0) - LOOP_SECONDS)
				t.payoutTimer = (t.payoutTimer or 0) + LOOP_SECONDS
				local interval = t.payoutIntervalSec or constants.COLOCATION.payoutIntervalSeconds
				if t.payoutTimer >= interval then
					t.payoutTimer -= interval
					session.balance += t.rewardPayout
					playSFX(session, "cash")
					sendHint(session, string.format("%s: colocation payout +$%d", t.title, t.rewardPayout))
				end
				if t.runtimeRemainingSec <= 0 then
					completeColocation(session, t)
				else
					t.validationText = string.format("Service running - %ds left", t.runtimeRemainingSec)
				end
			elseif t.status == "Active" then
				if t.slaRemainingSec == nil then
					t.slaRemainingSec = constants.COLOCATION.slaSeconds
				end
				t.slaRemainingSec = math.max(0, t.slaRemainingSec - LOOP_SECONDS)
				if t.slaRemainingSec <= 0 then
					failColocation(session, t, "SLA expired before server was validated")
					continue
				end
				if carry ~= nil then
					local ready, message = carry.EvaluateColo(session, t)
					t.validationText = message
					if ready then
						t.phase = "running"
						t.runtimeRemainingSec = constants.COLOCATION.runtimeSeconds
						t.payoutTimer = 0
						playSFX(session, "cash")
						sendHint(session, string.format("Colocation online: %s - payout every %ds", t.title, t.payoutIntervalSec or 10))
					elseif t.phase == "mounted" and t.slaRemainingSec <= 30 then
						sendHint(session, string.format("SLA %s has %ds left: %s", t.title, t.slaRemainingSec, message))
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- Accept
---------------------------------------------------------------------

--[[ ContractActionRemote handler: {action="accept", ticketId} -> Available -> Active. ]]
local function onAccept(player: Player, payload: any)
	if type(payload) ~= "table" or payload.action ~= "accept" then
		return
	end
	local session = sessions.GetSession(player)
	if session == nil then
		return
	end
	local ticketId = payload.ticketId
	if type(ticketId) ~= "string" then
		return
	end

	local activeCount = 0
	for _, t in ipairs(session.tickets) do
		if t.status == "Active" and t.category ~= "Incident" then
			activeCount += 1
		end
	end
	if activeCount >= MAX_ACTIVE_TICKETS then
		sendHint(session, string.format("Maximum %d active contracts allowed. Complete one first.", MAX_ACTIVE_TICKETS))
		return
	end

	for _, t in ipairs(session.tickets) do
		if t.id == ticketId and t.status == "Available" then
			t.status = "Active"
			playSFX(session, "key")

			if t.category == "Colocation" then
				t.phase = "delivery"
				t.slaRemainingSec = constants.COLOCATION.slaSeconds
				t.runtimeRemainingSec = constants.COLOCATION.runtimeSeconds
				t.validationText = "Crate in transit to loading dock"
				local delivery = constants.COLOCATION.deliveryDelaySeconds
				task.delay(delivery, function()
					if sessions.GetSession(player) ~= session then
						return
					end
					local live: any? = nil
					for _, row in ipairs(session.tickets) do
						if row.id == ticketId and row.status == "Active" then
							live = row
							break
						end
					end
					if live == nil then
						return
					end
					if carry ~= nil then
						carry.SpawnCrate(session, live)
					end
					live.phase = "crate"
					live.validationText = "Pick up crate at dock and mount in rack"
				end)
				sendHint(session, string.format("Colocation contract accepted: %s. Crate arrives in %ds.", t.title, delivery))
			else
				t.slaRemainingSec = DEFAULT_SLA_SECONDS
				t.validationText = "Contract active - complete before SLA expires"
				sendHint(session, string.format("Contract accepted: %s (SLA %ds)", t.title, DEFAULT_SLA_SECONDS))
			end
			return
		end
	end
end

---------------------------------------------------------------------
-- Fase 3: incident spawning + alarm beacon
---------------------------------------------------------------------

--[[ Peak-hours incident spawner: one incident every
	 INCIDENTS.spawnCooldownSeconds, max INCIDENTS.maxActive alive.
	 The type order rotates so every incident type is exercised. ]]
local function tickIncidents(session: SessionLike)
	if session.shift == nil then
		return
	end
	local cfg = constants.INCIDENTS
	session.incidentCooldownSec = math.max(0, (session.incidentCooldownSec or 0) - LOOP_SECONDS)
	local clock = session.shift.clockMinutes
	if clock < constants.SHIFT.peakStartMinutes or clock >= constants.SHIFT.peakEndMinutes then
		return
	end
	if countActiveIncidents(session) >= cfg.maxActive or session.incidentCooldownSec > 0 then
		return
	end
	local types = cfg.types
	for _ = 1, #types do
		session.incidentRotationIndex = (session.incidentRotationIndex % #types) + 1
		local incidentType = types[session.incidentRotationIndex]
		if spawnIncident(session, incidentType) then
			session.incidentCooldownSec = cfg.spawnCooldownSeconds
			return
		end
	end
	-- No valid target yet (player has no cable/VM/server): retry quickly.
	session.incidentCooldownSec = 10
end

local function ensureAlarmSound(lens: BasePart): Sound?
	local existing = lens:FindFirstChild("AlarmKlaxon")
	if existing ~= nil then
		if existing:IsA("Sound") then
			if not existing.IsPlaying then
				existing:Play()
			end
			return existing
		end
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = "AlarmKlaxon"
	sound.SoundId = ALARM_SOUND_ID
	sound.Looped = true
	sound.PlaybackSpeed = 1.0
	sound.Volume = 0.5
	sound.RollOffMinDistance = 8
	sound.RollOffMaxDistance = 80
	sound.Parent = lens
	sound:Play()
	return sound
end

local function findCableByKey(session: SessionLike, key: string): any?
	for _, cable in pairs(session.cables) do
		if linkKey(cable.aDeviceId, cable.aPortId, cable.bDeviceId, cable.bPortId) == key then
			return cable
		end
	end
	return nil
end

--[[ Fast visual updater (0.25s): beacon pulse + klaxon + flashing LEDs for
	 DDoS/drive/cable faults and broadcast storms. ]]
local function updateAlarmVisuals(session: SessionLike)
	local facility = session.facility
	if type(facility) ~= "table" then
		return
	end
	local lens = facility.beaconLens
	local light = facility.beaconLight
	local active = countActiveIncidents(session)
	local now = os.clock()

	if lens ~= nil and lens:IsA("BasePart") then
		if active > 0 then
			local pulse = 0.5 + 0.5 * math.sin(now * 9)
			lens.Color = Color3.fromRGB(255, 35 + math.floor(70 * pulse), 35)
			ensureAlarmSound(lens)
			if light ~= nil and light:IsA("PointLight") then
				light.Enabled = true
				light.Brightness = 1.5 + 3.0 * pulse
			end
		else
			lens.Color = BEACON_RED
			if light ~= nil and light:IsA("PointLight") then
				light.Brightness = 0
				light.Enabled = false
			end
			local sound = lens:FindFirstChild("AlarmKlaxon")
			if sound ~= nil and sound:IsA("Sound") and sound.IsPlaying then
				sound:Stop()
			end
		end
	end

	-- Port/status LED flash on the 3 Hz beat.
	local lit = (math.floor(now * 3) % 2) == 0
	local storm = session.broadcastStorm == true
	for deviceId, node in pairs(session.devices) do
		local model = session.deviceModels[deviceId]
		if model ~= nil then
			if node.isUnderDDoS == true or node.hasDegradedDrive == true then
				local led = model:FindFirstChild("StatusLED", true)
				if led ~= nil and led:IsA("BasePart") then
					led.Color = if lit then LED_RED else LED_OFF
				end
			end
			for portId, port in pairs(node.ports) do
				local faulted = false
				if session.incidentFaults ~= nil and port.connectedToDeviceId ~= nil then
					faulted = session.incidentFaults[linkKey(deviceId, portId, port.connectedToDeviceId, port.connectedToPortId or "")] == true
				end
				if faulted or (storm and port.linkUp) then
					local portLed = model:FindFirstChild("PortLED_" .. portId, true)
					if portLed ~= nil and portLed:IsA("BasePart") then
						portLed.Color = if lit then LED_RED else LED_OFF
					end
				end
			end
		end
	end

	-- Restore normal LEDs when the storm clears.
	if storm then
		session.stormLit = true
	elseif session.stormLit == true then
		session.stormLit = false
		if graph ~= nil and type(graph.UpdateDeviceLED) == "function" then
			for deviceId in pairs(session.devices) do
				graph.UpdateDeviceLED(session, deviceId)
			end
		end
	end

	-- Faulted cable beams flicker until the pair is re-cabled.
	local faultedKeys: { [string]: boolean } = {}
	for _, t in ipairs(session.tickets or {}) do
		if t.status == "Active" and t.incidentType == "CableFault" and type(t.incidentData) == "table" then
			faultedKeys[t.incidentData.key] = true
		end
	end
	for _, cable in pairs(session.cables) do
		local key = linkKey(cable.aDeviceId, cable.aPortId, cable.bDeviceId, cable.bPortId)
		local isFaulted = faultedKeys[key] == true
		for _, beam in ipairs({ cable.beam, cable.sheath, cable.beam2, cable.sheath2, cable.beam3, cable.sheath3 }) do
			if beam ~= nil and beam.Parent ~= nil then
				local base = if beam.Name:find("Sheath") ~= nil then 0.25 else 0.02
				if isFaulted then
					beam.Transparency = NumberSequence.new(if lit then base + 0.1 else 0.9)
				elseif beam:GetAttribute("Faulted") == true then
					beam.Transparency = NumberSequence.new(base)
				end
				beam:SetAttribute("Faulted", isFaulted)
			end
		end
	end
end

local function bindAccept()
	if acceptBound or remotesFolder == nil then
		return
	end
	getRemotes()
	if contractRemote ~= nil then
		contractRemote.OnServerEvent:Connect(onAccept)
		acceptBound = true
	end
end

function ContractAndIncidentManager.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	constants = deps.constants
	remotesFolder = deps.remotesFolder
	workbench = deps.workbench
	carry = deps.carry
	getRemotes()
	bindAccept()
end

--[[ Main loop: every 5s per session, top up Available tickets, spawn/validate
	 incidents and validate Active contracts. A second 0.25s loop keeps the
	 alarm beacon, klaxon, flashing LEDs and faulted cable beams alive. ]]
function ContractAndIncidentManager.Start()
	bindAccept()
	task.spawn(function()
		while true do
			task.wait(LOOP_SECONDS)
			if sessions == nil then
				continue
			end
			local allSessions = sessions.GetAllSessions()
			for _, session in pairs(allSessions) do
				local ok, err = pcall(function()
					generateTickets(session)
					tickIncidents(session)
					validateActiveTickets(session)
				end)
				if not ok then
					warn("[ContractAndIncidentManager] tick error: " .. tostring(err))
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.25)
			if sessions == nil then
				continue
			end
			for _, session in pairs(sessions.GetAllSessions()) do
				local ok, err = pcall(updateAlarmVisuals, session)
				if not ok then
					warn("[ContractAndIncidentManager] alarm error: " .. tostring(err))
				end
			end
		end
	end)
end

return ContractAndIncidentManager
