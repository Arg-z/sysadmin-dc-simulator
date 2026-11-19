--!strict
--[[
	ContractAndIncidentManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1 + Fase 2 contract pool.

	FASE 2 SCOPE: three contract pillars (CloudVPS, Colocation, CustomBuild)
	with a live SLA. There is still intentionally NO incident engine in this
	file: Cable Fault, DDoS Flood, Noisy Neighbor and Remote Hands Drive
	Failure are Fase 3 scope per CONTRACT.md Section 9 (the AlarmBeacon stays
	decorative).

	Ticket flow (tickets live in session.tickets as an array of
	ContractTicket-like tables, plus a requirementsText field for the UI):
	  - Loop every 5s per session: top up to 3 Available tickets, always
	    filling the category with the fewest Available rows.
	  - CloudVPS specs: cpu 2..8, ram 4..32, disk 50..500; reward scaled
	    (cpu*60 + ram*2 + disk*0.1, minimum 120).
	  - CustomBuild: reward 250..600, fixed requirementsText.
	  - Colocation: client wants a server hosted in the player's rack on a
	    dedicated VLAN. Accept -> crate spawns at the dock after 3s ->
	    carry/mount -> cable + switch VLAN + PDU ON -> reachable from the
	    gateway. SLA 240s. While running, the client pays rewardPayout every
	    10s for 60s, then collects the server.
	  - ContractActionRemote {action="accept", ticketId}: Available -> Active,
	    max 2 Active tickets per session.
	  - Active validation each pass:
	      CloudVPS    = any powered BareMetal with an OS hosts a big-enough VM.
	      CustomBuild = session.workbench.shipped.
	      Colocation  = CarryAndMountSystem.EvaluateColo (powered, VLAN match,
	                    gateway reachability).
	  - Completion pays the reward, reputation and SFX; Failed (SLA expiry)
	    plays the error SFX. Both linger briefly before removal.
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
			"%s sewa VPS: %d vCPU / %dGB RAM / %dGB disk. Jalankan VM-nya di bare-metal kamu. SLA %d detik.",
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
		validationText = "Menunggu VM yang cocok",
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
			"%s pesan server rakitan custom, bayaran di depan setelah unit dikirim dari dock. SLA %d detik.",
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
		validationText = "Rakit + install OS + stress test + ship",
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = "Rakit server di workbench + install OS + stress test + ship",
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
			"%s kirim server fisik untuk di-hosting di rack kamu. Pasang unit, kabel ke switch VLAN %d, nyalakan PDU, lalu pastikan reachable dari gateway. Kontrak $%d tiap %d detik selama %d detik.",
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
		validationText = "Terima kontrak untuk memanggil crate ke dock",
		targetDeviceId = nil,
		targetRackId = nil,
		targetUSlot = nil,
		status = "Available" :: TicketStatus,
		requirementsText = string.format(
			"Mount crate %dU di rack, kabel ke switch VLAN %d, PDU ON, ping dari gateway OK. SLA %d detik.",
			colo.uSize,
			vlanId,
			colo.slaSeconds
		),
	}
	return ticket
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
local function scheduleRemoval(session: SessionLike, ticketId: string)
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
	ticket.validationText = "Kontrak selesai - klien mengambil server"
	session.reputation += 2
	playSFX(session, "cash")
	sendHint(session, string.format("Kontrak colocation selesai: %s (semua payout sudah dibayar)", ticket.title))
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
	sendHint(session, string.format("Kontrak gagal: %s (%s)", ticket.title, reason))
	scheduleRemoval(session, ticket.id)
end

local function failColocation(session: SessionLike, ticket: any, reason: string)
	ticket.status = "Failed"
	ticket.phase = "closed"
	ticket.validationText = reason
	playSFX(session, "error")
	sendHint(session, string.format("Kontrak colocation gagal: %s (%s)", ticket.title, reason))
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
				playSFX(session, "cash")
				sendHint(session, string.format("Kontrak selesai: %s +$%d", t.title, t.rewardPayout))
				scheduleRemoval(session, t.id)
			elseif tickSla(t) then
				failContract(session, t, "SLA habis sebelum VM siap")
				continue
			else
				t.validationText = string.format("Menunggu VM yang cocok - SLA %ds", t.slaRemainingSec)
			end
		elseif t.category == "CustomBuild" then
			-- session.workbench is the live state source (deps.workbench is the
			-- module handle kept for API compliance with the contract).
			if session.workbench.shipped == true then
				t.status = "Completed"
				session.balance += t.rewardPayout
				session.reputation += 1
				playSFX(session, "cash")
				sendHint(session, string.format("Kontrak selesai: %s +$%d", t.title, t.rewardPayout))
				scheduleRemoval(session, t.id)
			elseif tickSla(t) then
				failContract(session, t, "SLA habis sebelum build dikirim")
				continue
			else
				t.validationText = string.format("Menunggu build dikirim - SLA %ds", t.slaRemainingSec)
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
					sendHint(session, string.format("%s: payout colocation +$%d", t.title, t.rewardPayout))
				end
				if t.runtimeRemainingSec <= 0 then
					completeColocation(session, t)
				else
					t.validationText = string.format("Layanan jalan - sisa %d dtk", t.runtimeRemainingSec)
				end
			elseif t.status == "Active" then
				if t.slaRemainingSec == nil then
					t.slaRemainingSec = constants.COLOCATION.slaSeconds
				end
				t.slaRemainingSec = math.max(0, t.slaRemainingSec - LOOP_SECONDS)
				if t.slaRemainingSec <= 0 then
					failColocation(session, t, "SLA habis sebelum server valid")
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
						sendHint(session, string.format("Colocation aktif: %s - payout tiap %d dtk", t.title, t.payoutIntervalSec or 10))
					elseif t.phase == "mounted" and t.slaRemainingSec <= 30 then
						sendHint(session, string.format("SLA %s tinggal %d dtk: %s", t.title, t.slaRemainingSec, message))
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

			if t.category == "Colocation" then
				t.phase = "delivery"
				t.slaRemainingSec = constants.COLOCATION.slaSeconds
				t.runtimeRemainingSec = constants.COLOCATION.runtimeSeconds
				t.validationText = "Crate sedang dikirim ke dock"
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
					live.validationText = "Angkat crate di dock, lalu pasang di rack"
				end)
				sendHint(session, string.format("Kontrak colocation diterima: %s. Crate tiba %d detik lagi.", t.title, delivery))
			else
				t.slaRemainingSec = DEFAULT_SLA_SECONDS
				t.validationText = "Kontrak aktif - selesaikan sebelum SLA habis"
				sendHint(session, string.format("Kontrak diterima: %s (SLA %d dtk)", t.title, DEFAULT_SLA_SECONDS))
			end
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
	carry = deps.carry
	getRemotes()
	bindAccept()
end

--[[ Main loop: every 5s per session, top up Available tickets and validate
	 Active tickets. (Incident generation joins this loop in Fase 3.) ]]
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
