--!strict
--[[
	DataPersistenceManager (ModuleScript, ServerScriptService/Gameplay)
	AGENT C - Fase 1 + 2.

	DataStore "NetSimDC_v1", key "lab_"..UserId. Every DataStore access is
	wrapped in pcall; if GetDataStore itself fails, a session-independent flag
	is set and a warning is emitted once - persistence silently disables
	itself instead of ever breaking a session.

	Reset flow (contract Section 6): MainServer owns ResetDataRemote. On reset
	it calls DataPersistenceManager.WipeSave(player), then deletes and rebuilds
	the session via SessionManager.CreateSession + WorldAndAssetBuilder.
	PlayerRemoving is likewise handled by MainServer calling Save(session);
	this module only provides the autosave loop (Start, every 120s).

	Saved payload:
	  balance, reputation, cableSpools, selectedCableColor,
	  racks = freeform racks (item, world position, rotation, PDU state),
	  devices  = array over session.devices EXCEPT "isp_uplink":
	             { id, name, itemId, deviceType, contractId, freeform, posX,
	               posZ, rotY, rackId, uSlot, ip, gateway, subnetMask,
	               osInstalled, isPowered,
	               ports = { [portId] = { peer?, peerPort?, color?, vlan } },
	               vms = { VMData... } }
	             "bench_1" saves PORTS ONLY (the workbench payload covers the
	             node itself; ports must survive for the link pass).
	  workbench = WorkbenchBuilderSystem.Serialize(session)
	  tickets   = Active CloudVPS/CustomBuild tickets (Colocation contracts are
	              short-lived and reference a physical crate, so they are not
	              persisted; mounted servers are saved as rack devices).

	Apply(session, data):
	  loadedFromSave = true FIRST (suppresses AutoCable during restore) ->
	  balance/reputation/cable inventory -> freeform racks restored ->
	  starter device config (bm_starter_1, sw_main_1, isp_router_1) ->
	  freeform devices re-placed via PlacementSystem.PlaceDevice(config) ->
	  rack devices re-mounted via PlacementSystem.MountDevice(config) ->
	  workbench.ApplyState (so bench_1 exists before cables) -> link pass
	  (graph.ConnectPorts per saved peer, deduped by sorted "dev|port" pair,
	  covers starter + bench + placed links) -> VLAN restore -> tickets
	  restore -> loadedFromSave = false -> graph.UpdateDeviceLED -> ForceSync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkTypes = require(ReplicatedStorage.Shared.NetworkTypes)
local PlotConstants = require(ReplicatedStorage.Shared.PlotConstants)

local DataPersistenceManager = {}

type SessionLike = any

-- ShiftAndEconomyManager lives next to this module; used only for the final
-- ForceSync after Apply so the client immediately receives the restored state.
local Economy: any = nil
do
	local ok, mod = pcall(require, script.Parent.ShiftAndEconomyManager)
	if ok then
		Economy = mod
	end
end

local DATASTORE_NAME = "NetSimDC_v1"
local KEY_PREFIX = "lab_"

-- Save payload schema version. Apply() ignores payloads written by a
-- newer build so a partial update cannot corrupt a save it cannot read.
local SAVE_VERSION = 1
local AUTOSAVE_SECONDS = 120

-- Session-independent DataStore availability flag (set once in Init).
local store: any = nil
local storeOk = false
local storeUnavailableWarned = false

local sessions: any = nil
local graph: any = nil
local constants: any = PlotConstants
local placement: any = nil
local workbench: any = nil

local STARTER_IDS = { "bm_starter_1", "sw_main_1", "isp_router_1" }
local ISP_ID = "isp_uplink"
local BENCH_ID = "bench_1"

local function warnStoreUnavailableOnce()
	if not storeUnavailableWarned then
		storeUnavailableWarned = true
		warn("[DataPersistenceManager] DataStore unavailable - saving/loading disabled for this server.")
	end
end

function DataPersistenceManager.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	constants = deps.constants or PlotConstants
	placement = deps.placement
	workbench = deps.workbench

	local ok, result = pcall(function()
		return game:GetService("DataStoreService"):GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		store = result
		storeOk = true
	else
		store = nil
		storeOk = false
		warnStoreUnavailableOnce()
	end
end

--[[ Load the saved payload for a player, nil when nothing/failure. ]]
function DataPersistenceManager.Load(player: Player): any?
	if not storeOk then
		warnStoreUnavailableOnce()
		return nil
	end
	-- Same transient-failure retry as Save: a throttled load must not be
	-- mistaken for an empty save (a fresh lab would then overwrite it).
	local ok: boolean, data: any
	for attempt = 1, 3 do
		local attemptOk, attemptData = pcall(function()
			return store:GetAsync(KEY_PREFIX .. tostring(player.UserId))
		end)
		ok, data = attemptOk, attemptData
		if ok then
			break
		end
		if attempt < 3 then
			task.wait(attempt) -- 1s, then 2s before the last try
		end
	end
	if not ok then
		warn("[DataPersistenceManager] LoadAsync failed for userId " .. tostring(player.UserId) .. ": " .. tostring(data))
		return nil
	end
	return data
end

--[[ Serialize one VMData row (plain, DataStore-safe). ]]
local function serializeVM(vm: any): { [string]: any }
	return {
		name = vm.name,
		cpu = vm.cpu,
		ram = vm.ram,
		disk = vm.disk,
		assignedIp = vm.assignedIp,
		cpuThrottlePercent = vm.cpuThrottlePercent,
		currentLoadPercent = vm.currentLoadPercent,
		status = vm.status,
	}
end

--[[ requirements reduced to the persistable cpu/ram/disk triple (or nil). ]]
local function serializeRequirements(req: any): { [string]: number }?
	if type(req) == "table" and req.cpu ~= nil then
		return { cpu = req.cpu, ram = req.ram, disk = req.disk }
	end
	return nil
end

--[[ Save one session (balance, reputation, devices, workbench, active tickets). ]]
function DataPersistenceManager.Save(session: SessionLike): boolean
	if not storeOk then
		warnStoreUnavailableOnce()
		return false
	end
	if type(session) ~= "table" or session.player == nil then
		return false
	end

	local devices: { any } = {}
	for id, node in pairs(session.devices) do
		if id == ISP_ID then
			continue -- ISP uplink is rebuilt fresh by BuildFacility every join
		end

		-- ports: connected links plus non-default VLANs (Fase 2 switch config)
		local ports: { [string]: { [string]: any } } = {}
		for portId, port in pairs(node.ports) do
			if port.connectedToDeviceId ~= nil or port.vlanId ~= 1 or port.isTrunk == true then
				ports[portId] = {
					peer = port.connectedToDeviceId,
					peerPort = port.connectedToPortId,
					color = port.cableColor,
					vlan = port.vlanId,
					trunk = port.isTrunk == true,
				}
			end
		end

		if id == BENCH_ID then
			-- bench_1 node data is covered by the workbench payload; keep its
			-- cables only so the link pass can restore them.
			if next(ports) ~= nil then
				table.insert(devices, { id = BENCH_ID, ports = ports })
			end
			continue
		end

		local vms: { any } = {}
		for _, vm in pairs(node.vms) do
			table.insert(vms, serializeVM(vm))
		end

		table.insert(devices, {
			id = id,
			name = node.name,
			itemId = node.itemId,
			deviceType = node.deviceType,
			contractId = node.contractId,
			freeform = node.freeform == true,
			posX = node.posX,
			posZ = node.posZ,
			rotY = node.rotY,
			rackId = node.rackId,
			uSlot = node.uSlot,
			ip = node.ip,
			gateway = node.gateway,
			subnetMask = node.subnetMask,
			osInstalled = node.osInstalled,
			isPowered = node.isPowered == true,
			ports = ports,
			vms = vms,
		})
	end

	-- Freeform racks (the starter rack is rebuilt by WorldAndAssetBuilder).
	local racks: { any } = {}
	for rackId, rack in pairs(session.racks) do
		if rackId ~= "rack_main_1" then
			local model = session.rackModels[rackId]
			if model ~= nil then
				local cf = model:GetPivot()
				local _rx, rotY, _rz = cf:ToOrientation()
				table.insert(racks, {
					rackId = rackId,
					itemId = rack.itemId,
					posX = cf.Position.X,
					posZ = cf.Position.Z,
					rotY = rotY,
					pduPowered = rack.pduPowered == true,
				})
			end
		end
	end

	local tickets: { any } = {}
	for _, t in ipairs(session.tickets or {}) do
		-- Colocation contracts are short live sessions and reference a physical
		-- crate; they are not persisted. Fase 3 incidents reference live cable/
		-- VM/device state, so they are not persisted either (their effects are
		-- cleared on rejoin).
		if t.status == "Active" and t.category ~= "Colocation" and t.category ~= "Incident" then
			table.insert(tickets, {
				id = t.id,
				category = t.category,
				clientName = t.clientName,
				title = t.title,
				description = t.description,
				rewardPayout = t.rewardPayout,
				requirements = serializeRequirements(t.requirements),
				status = t.status,
				requirementsText = t.requirementsText,
			})
		end
	end

	local payload: { [string]: any } = {
		v = SAVE_VERSION,
		balance = session.balance,
		reputation = session.reputation,
		day = session.day,
		shiftClockMinutes = if session.shift ~= nil then session.shift.clockMinutes else nil,
		spareParts = session.spareParts,
		devices = devices,
		racks = racks,
		cableSpools = session.cableSpools,
		selectedCableColor = session.selectedCableColor,
		workbench = (workbench ~= nil and type(workbench.Serialize) == "function") and workbench.Serialize(session) or nil,
		tickets = tickets,
	}

	local key = KEY_PREFIX .. tostring(session.player.UserId)
	-- DataStore throttling and transient failures are common; retry with a
	-- short backoff before giving up so an autosave is not lost on one error.
	local ok: boolean = false
	local err: any = nil
	for attempt = 1, 3 do
		local attemptOk, attemptErr = pcall(function()
			store:SetAsync(key, payload)
		end)
		ok, err = attemptOk, attemptErr
		if ok then
			break
		end
		if attempt < 3 then
			task.wait(attempt) -- 1s, then 2s before the last try
		end
	end
	if not ok then
		-- Warn once per session so a broken DataStore does not spam the output.
		if not session.noSaveWarned then
			session.noSaveWarned = true
			warn("[DataPersistenceManager] Save failed for userId " .. tostring(session.player.UserId) .. ": " .. tostring(err))
		end
		return false
	end
	return true
end

--[[ Rebuild VM tables onto a node; returns the highest used 10.0.0.x octet
	 (base 1 when none) so vmIpCounter can continue after the restored VMs
	 without colliding with any restored IP. ]]
local function restoreVMs(session: SessionLike, node: any, hostNewId: string, vmArray: any): number
	local maxOctet = 1
	if type(vmArray) == "table" then
		for _, v in ipairs(vmArray) do
			if type(v) == "table" and type(v.name) == "string" and #v.name > 0 then
				local vm = {
					name = v.name,
					cpu = tonumber(v.cpu) or 1,
					ram = tonumber(v.ram) or 1,
					disk = tonumber(v.disk) or 5,
					assignedIp = (type(v.assignedIp) == "string") and v.assignedIp or nil,
					cpuThrottlePercent = tonumber(v.cpuThrottlePercent) or 0,
					currentLoadPercent = tonumber(v.currentLoadPercent) or 0,
					status = if v.status == "throttled" or v.status == "stopped" then v.status else "running",
				}
				node.vms[vm.name] = vm
				if vm.assignedIp ~= nil then
					local octet = tonumber(string.match(vm.assignedIp, "^10%.0%.0%.(%d+)$"))
					if octet ~= nil and octet > maxOctet then
						maxOctet = octet
					end
				end
			end
		end
	end
	session.vmIpCounter[hostNewId] = maxOctet + 1
	return maxOctet
end

--[[ Sorted-pair dedupe key for a cable connection ("devA|portA>devB|portB"). ]]
local function pairKey(devA: string, portA: string, devB: string, portB: string): string
	local left = devA .. "|" .. portA
	local right = devB .. "|" .. portB
	return if left <= right then left .. ">" .. right else right .. ">" .. left
end

--[[ Restore a saved payload onto a freshly built session. ]]
function DataPersistenceManager.Apply(session: SessionLike, data: any)
	if type(data) ~= "table" then
		return
	end

-- Future-versioned saves are not understood by this build; ignore them
-- instead of partially applying fields and then overwriting on autosave.
	local version = tonumber(data.v) or 1
	if version > SAVE_VERSION then
		warn("[DataPersistenceManager] Save data is from a newer build (v" .. tostring(version) .. "); not applying")
		return
	end

	-- Must be set before any placement so AutoCable stays suppressed.
	session.loadedFromSave = true

	if tonumber(data.balance) ~= nil then
		session.balance = tonumber(data.balance) :: number
	end
	if tonumber(data.reputation) ~= nil then
		session.reputation = tonumber(data.reputation) :: number
	end
	if tonumber(data.day) ~= nil then
		session.day = math.max(1, math.floor(tonumber(data.day) :: number))
	end
	-- Fase 3: resume the shift clock when the saved time is inside 08:00-18:00.
	if session.shift ~= nil and tonumber(data.shiftClockMinutes) ~= nil then
		local clock = tonumber(data.shiftClockMinutes) :: number
		if clock >= constants.SHIFT.startMinutes and clock < constants.SHIFT.endMinutes then
			session.shift.clockMinutes = clock
		end
	end
	if type(data.spareParts) == "table" then
		session.spareParts.hdd = math.max(0, math.floor(tonumber(data.spareParts.hdd) or 0))
	end

	-- Fase 2 cable inventory.
	if type(data.cableSpools) == "table" then
		for _, color in ipairs(constants.CABLES.colors) do
			local count = tonumber(data.cableSpools[color])
			if count ~= nil then
				session.cableSpools[color] = math.max(0, math.floor(count))
			end
		end
	end
	if type(data.selectedCableColor) == "string" then
		for _, color in ipairs(constants.CABLES.colors) do
			if color == data.selectedCableColor then
				session.selectedCableColor = color
			end
		end
	end

	-- saved device / rack id -> live id (starters keep their fixed ids)
	local restoredIds: { [string]: string } = {
		[ISP_ID] = ISP_ID,
		["isp_router_1"] = "isp_router_1",
		["sw_main_1"] = "sw_main_1",
		["bm_starter_1"] = "bm_starter_1",
		["rack_main_1"] = "rack_main_1",
		[BENCH_ID] = BENCH_ID,
	}
	local starterSet: { [string]: boolean } = {
		["bm_starter_1"] = true,
		["sw_main_1"] = true,
		["isp_router_1"] = true,
	}

	local savedDevices: { any } = if type(data.devices) == "table" then data.devices else {}

	-- 0) Freeform racks must exist before their mounted devices are restored.
	if type(data.racks) == "table" and placement ~= nil then
		for _, entry in ipairs(data.racks) do
			if type(entry) ~= "table" or type(entry.rackId) ~= "string" or type(entry.itemId) ~= "string" then
				continue
			end
			if entry.rackId == "rack_main_1" then
				continue
			end
			local posX = tonumber(entry.posX) or 0
			local posZ = tonumber(entry.posZ) or 0
			local rotY = tonumber(entry.rotY) or 0
			local ok, newRackId = pcall(function()
				return placement.RestoreRack(session, entry.itemId :: string, posX, posZ, rotY, entry.pduPowered == true)
			end)
			if ok and type(newRackId) == "string" and newRackId ~= "" then
				restoredIds[entry.rackId] = newRackId
			else
				warn("[DataPersistenceManager] could not restore rack '" .. entry.rackId .. "'")
			end
		end
	end

	-- 1) Starter device config + freeform / rack-mounted device re-placement.
	for _, entry in ipairs(savedDevices) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" then
			continue
		end
		local savedId = entry.id
		if savedId == BENCH_ID then
			continue -- node comes from workbench.ApplyState; ports link later
		end

		if starterSet[savedId] then
			local node = session.devices[savedId]
			if node ~= nil then
				restoredIds[savedId] = savedId
				if entry.ip ~= nil then
					node.ip = entry.ip
				end
				if entry.gateway ~= nil then
					node.gateway = entry.gateway
				end
				if entry.subnetMask ~= nil then
					node.subnetMask = entry.subnetMask
				end
				node.osInstalled = entry.osInstalled
				if entry.isPowered ~= nil then
					node.isPowered = entry.isPowered == true
				end
				node.vms = {}
				restoreVMs(session, node, savedId, entry.vms)
			end
		elseif entry.freeform == true and type(entry.itemId) == "string" and placement ~= nil then
			local posX = tonumber(entry.posX) or 0
			local posZ = tonumber(entry.posZ) or 0
			local rotY = tonumber(entry.rotY) or 0
			local floorY = constants.ROOM.floorTopY

			local vms: { any } = {}
			local maxOctet = 1
			if type(entry.vms) == "table" then
				for _, v in ipairs(entry.vms) do
					if type(v) == "table" and type(v.name) == "string" and #v.name > 0 then
						table.insert(vms, {
							name = v.name,
							cpu = tonumber(v.cpu) or 1,
							ram = tonumber(v.ram) or 1,
							disk = tonumber(v.disk) or 5,
							assignedIp = (type(v.assignedIp) == "string") and v.assignedIp or nil,
							cpuThrottlePercent = tonumber(v.cpuThrottlePercent) or 0,
							currentLoadPercent = tonumber(v.currentLoadPercent) or 0,
							status = if v.status == "throttled" or v.status == "stopped" then v.status else "running",
						})
						if type(v.assignedIp) == "string" then
							local octet = tonumber(string.match(v.assignedIp, "^10%.0%.0%.(%d+)$"))
							if octet ~= nil and octet > maxOctet then
								maxOctet = octet
							end
						end
					end
				end
			end

			local ok, newId = pcall(function()
				return placement.PlaceDevice(session, entry.itemId :: string,
					CFrame.new(Vector3.new(posX, floorY, posZ)), rotY, {
						ip = entry.ip,
						gateway = entry.gateway,
						subnetMask = entry.subnetMask,
						osInstalled = entry.osInstalled,
						isPowered = if entry.isPowered ~= nil then entry.isPowered == true else nil,
						vms = vms,
					})
			end)
			if ok and type(newId) == "string" then
				restoredIds[savedId] = newId
				session.vmIpCounter[newId] = maxOctet + 1
			else
				warn("[DataPersistenceManager] could not restore device '" .. savedId .. "' (" .. tostring(entry.itemId) .. ")")
			end
		elseif type(entry.rackId) == "string" and entry.uSlot ~= nil and type(entry.itemId) == "string" and placement ~= nil then
			-- Fase 2: rack-mounted devices (colocation servers, purchased units)
			local rackId = restoredIds[entry.rackId] or entry.rackId
			if session.racks[rackId] == nil then
				warn("[DataPersistenceManager] missing rack '" .. tostring(entry.rackId) .. "' for device '" .. savedId .. "'")
				continue
			end
			local ok, mounted, result = pcall(placement.MountDevice, session, entry.itemId, rackId, entry.uSlot, {
				name = entry.name,
				deviceType = entry.deviceType,
				ip = entry.ip,
				gateway = entry.gateway,
				subnetMask = entry.subnetMask,
				osInstalled = entry.osInstalled,
				isPowered = if entry.isPowered ~= nil then entry.isPowered == true else nil,
				contractId = entry.contractId,
				noAutoCable = true,
			})
			if ok and mounted == true then
				restoredIds[savedId] = result
				local node = session.devices[result]
				if node ~= nil then
					restoreVMs(session, node, result, entry.vms)
				end
			else
				warn("[DataPersistenceManager] could not restore rack device '" .. savedId .. "': " .. tostring(result))
			end
		else
			warn("[DataPersistenceManager] skipping non-restorable device '" .. savedId .. "'")
		end
	end

	-- 2) Workbench state BEFORE the link pass so bench_1 exists for bench cables.
	if workbench ~= nil and type(workbench.ApplyState) == "function" and type(data.workbench) == "table" then
		local ok, err = pcall(workbench.ApplyState, session, data.workbench)
		if not ok then
			warn("[DataPersistenceManager] workbench.ApplyState failed: " .. tostring(err))
		end
	end

	-- 3) Link pass: restore every recorded cable, deduped by sorted pair key.
	local linked: { [string]: boolean } = {}
	for _, entry in ipairs(savedDevices) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.ports) ~= "table" then
			continue
		end
		local devA = restoredIds[entry.id]
		if devA == nil then
			continue
		end
		for portA, conn in pairs(entry.ports :: { [string]: any }) do
			if type(conn) ~= "table" or type(conn.peer) ~= "string" or type(conn.peerPort) ~= "string" or type(portA) ~= "string" then
				continue
			end
			local devB = restoredIds[conn.peer]
			if devB == nil then
				continue
			end
			local key = pairKey(devA, portA, devB, conn.peerPort)
			if not linked[key] then
				linked[key] = true
				local color = if type(conn.color) == "string" then conn.color else "LAN_Blue"
				local ok, err = graph.ConnectPorts(session, devA, portA, devB, conn.peerPort, color)
				if not ok then
					-- Mostly benign: pre-wired starter links (wan1<->isp_uplink)
					-- already exist from BuildFacility and are rejected here.
					_ = err
				end
			end
		end
	end

	-- 3b) VLAN restore: applies to connected and unconnected ports alike.
	for _, entry in ipairs(savedDevices) do
		if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.ports) ~= "table" then
			continue
		end
		local devA = restoredIds[entry.id]
		if devA == nil then
			continue
		end
		for portA, conn in pairs(entry.ports :: { [string]: any }) do
			if type(conn) == "table" and type(portA) == "string" then
				if tonumber(conn.vlan) ~= nil then
					local okVlan = graph.SetPortVlan(session, devA, portA, tonumber(conn.vlan) :: number)
					_ = okVlan
				end
				if conn.trunk == true then
					local okTrunk = graph.SetPortTrunk(session, devA, portA, true)
					_ = okTrunk
				end
			end
		end
	end

	-- 4) Tickets restore: Available stays Available, Active stays Active.
	if type(data.tickets) == "table" then
		for _, t in ipairs(data.tickets) do
			if type(t) == "table" and type(t.id) == "string" and type(t.title) == "string" then
				table.insert(session.tickets, {
					id = t.id,
					category = if t.category == "CustomBuild" then "CustomBuild" else "CloudVPS",
					clientName = if type(t.clientName) == "string" then t.clientName else "Klien",
					title = t.title,
					description = if type(t.description) == "string" then t.description else "",
					requirements = if type(t.requirements) == "table" then t.requirements else {},
					rewardPayout = tonumber(t.rewardPayout) or 120,
					status = if t.status == "Active" then "Active" else "Available",
					requirementsText = if type(t.requirementsText) == "string" then t.requirementsText else "",
				})
			end
		end
	end

	-- 5) Restore done: re-enable normal placement behavior and refresh visuals.
	session.loadedFromSave = false
	if graph ~= nil and type(graph.UpdateDeviceLED) == "function" then
		for deviceId in pairs(session.devices) do
			pcall(graph.UpdateDeviceLED, session, deviceId)
		end
	end

	-- 6) Push the restored state to the client immediately.
	if Economy ~= nil and type(Economy.ForceSync) == "function" then
		pcall(Economy.ForceSync, session)
	end
end

--[[ Remove a player's save (Reset flow; MainServer then rebuilds the session). ]]
function DataPersistenceManager.WipeSave(player: Player)
	if not storeOk then
		warnStoreUnavailableOnce()
		return
	end
	local ok, err = pcall(function()
		store:RemoveAsync(KEY_PREFIX .. tostring(player.UserId))
	end)
	if not ok then
		warn("[DataPersistenceManager] RemoveAsync failed for userId " .. tostring(player.UserId) .. ": " .. tostring(err))
	end
end

--[[ Save every live session (autosave / shutdown). ]]
function DataPersistenceManager.SaveAll()
	if sessions == nil then
		return
	end
	for _, session in pairs(sessions.GetAllSessions()) do
		local ok, err = pcall(DataPersistenceManager.Save, session)
		if not ok then
			warn("[DataPersistenceManager] SaveAll error: " .. tostring(err))
		end
	end
end

--[[ Autosave loop (PlayerRemoving save is handled by MainServer -> Save). ]]
function DataPersistenceManager.Start()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			DataPersistenceManager.SaveAll()
		end
	end)
end

return DataPersistenceManager
