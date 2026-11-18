--!strict
--[[
	ContractAndIncidentManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1.

	FASE 1 SCOPE: CloudVPS + CustomBuild tickets only. There is intentionally
	NO incident engine in this file: Cable Fault, DDoS Flood, Noisy Neighbor
	and Remote Hands Drive Failure are Fase 3 scope per CONTRACT.md Section 9
	(the AlarmBeacon stays decorative in Fase 1). This comment is the explicit
	scope marker required by the contract.

	Ticket flow (tickets live in session.tickets as an array of
	ContractTicket-like tables, plus a requirementsText field for the UI):
	  - Loop every 10s per session: top up to 3 Available tickets, alternating
	    CloudVPS / CustomBuild, with random invented client names.
	  - CloudVPS specs: cpu 2..8, ram 4..32, disk 50..500; reward scaled
	    (cpu*60 + ram*2 + disk*0.1, minimum 120).
	  - CustomBuild: reward 250..600, fixed requirementsText.
	  - ContractActionRemote {action="accept", ticketId}: Available -> Active,
	    max 2 Active tickets per session.
	  - Active validation each pass:
	      CloudVPS  = any powered BareMetal with an OS installed hosts a VM with
	                  cpu >= req.cpu and ram >= req.ram and disk >= req.disk.
	      CustomBuild = session.workbench.shipped.
	  - On completion: balance += rewardPayout, reputation += 1, status
	    "Completed", PlaySFXRemote "cash", hint via OpenTerminalEvent, and the
	    ticket is removed from session.tickets after a short delay (next syncs).
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
local LOOP_SECONDS = 10
local COMPLETED_LINGER_SECONDS = 8

local sessions: any = nil
local graph: any = nil
local constants: any = nil
local remotesFolder: any = nil
local workbench: any = nil

local contractRemote: any = nil
local playSFXRemote: any = nil
local openTerminalRemote: any = nil
local acceptBound = false

local rng = Random.new()
local ticketCounter = 0

-- Eight invented client names for contract flavor.
local CLIENT_NAMES = {
	"PT Andalan Cloud",
	"CV Mitra Data",
	"Kafe BitRasa",
	"Studio Arus Media",
	"Koperasi Digital Nusa",
	"Toko Kompona",
	"Warung Kopi Server",
	"Startup Lokal Dev",
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
			"%s sewa VPS: %d vCPU / %dGB RAM / %dGB disk. Jalankan VM-nya di bare-metal kamu.",
			clientName,
			cpu,
			ram,
			disk
		),
		requirements = { cpu = cpu, ram = ram, disk = disk },
		rewardPayout = reward,
		payoutIntervalSec = nil,
		slaRemainingSec = nil,
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = string.format(
			"VM >= %d vCPU / %dGB RAM / %dGB disk di bare-metal powered + OS ter-install",
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
			"%s pesan server rakitan custom, bayaran di depan setelah unit dikirim dari dock.",
			clientName
		),
		requirements = {},
		rewardPayout = reward,
		payoutIntervalSec = nil,
		slaRemainingSec = nil,
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = "Rakit server di workbench + install OS + stress test + ship",
	}
	return ticket
end

--[[ Top up to MAX_AVAILABLE_TICKETS Available tickets, alternating categories
	 by always filling the category that currently has fewer Available tickets. ]]
local function generateTickets(session: SessionLike)
	local available: { [string]: number } = { CloudVPS = 0, CustomBuild = 0 }
	for _, t in ipairs(session.tickets) do
		if t.status == "Available" and (t.category == "CloudVPS" or t.category == "CustomBuild") then
			available[t.category] += 1
		end
	end

	local totalAvailable = available.CloudVPS + available.CustomBuild
	while totalAvailable < MAX_AVAILABLE_TICKETS do
		local category: TicketCategory = if available.CloudVPS <= available.CustomBuild
			then "CloudVPS"
			else "CustomBuild"
		local ticket = if category == "CloudVPS" then makeCloudVPSTicket() else makeCustomBuildTicket()
		table.insert(session.tickets, ticket)
		available[category] += 1
		totalAvailable += 1
	end
end

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

--[[ Mark completed Active tickets, pay out, and schedule removal from the list. ]]
local function validateActiveTickets(session: SessionLike)
	for _, t in ipairs(session.tickets) do
		if t.status ~= "Active" then
			continue
		end

		local done = false
		if t.category == "CloudVPS" then
			done = cloudVPSComplete(session, t.requirements)
		elseif t.category == "CustomBuild" then
			-- session.workbench is the live state source (deps.workbench is the
			-- module handle kept for API compliance with the contract).
			done = session.workbench.shipped == true
		end

		if done then
			t.status = "Completed"
			session.balance += t.rewardPayout
			session.reputation += 1
			playSFX(session, "cash")
			sendHint(session, string.format("Kontrak selesai: %s +$%d", t.title, t.rewardPayout))

			-- Keep the Completed row visible for one or two syncs, then remove it.
			local ticketId = t.id
			local player = session.player
			task.delay(COMPLETED_LINGER_SECONDS, function()
				if sessions.GetSession(player) ~= session then
					return
				end
				for idx = #session.tickets, 1, -1 do
					local row = session.tickets[idx]
					if row.id == ticketId and row.status == "Completed" then
						table.remove(session.tickets, idx)
					end
				end
			end)
		end
	end
end

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
		if t.status == "Active" then
			activeCount += 1
		end
	end
	if activeCount >= MAX_ACTIVE_TICKETS then
		sendHint(session, string.format("Maksimal %d kontrak aktif. Selesaikan dulu salah satunya.", MAX_ACTIVE_TICKETS))
		return
	end

	for _, t in ipairs(session.tickets) do
		if t.id == ticketId and t.status == "Available" then
			t.status = "Active"
			playSFX(session, "key")
			sendHint(session, "Kontrak diterima: " .. t.title)
			return
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
	getRemotes()
	bindAccept()
end

--[[ Main loop: every 10s per session, top up Available tickets and validate
	 Active tickets. (Incident generation/SLA countdown joins this loop in Fase 3.) ]]
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
					validateActiveTickets(session)
				end)
				if not ok then
					warn("[ContractAndIncidentManager] tick error: " .. tostring(err))
				end
			end
		end
	end)
end

return ContractAndIncidentManager
