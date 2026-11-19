--!strict
--[[
	WorkbenchBuilderSystem (ModuleScript, ServerScriptService/Physical)
	Custom server assembly on the AssemblyWorkbench, single clean path:
	- Install order: Chassis -> Mobo -> CPU* -> RAM* -> Storage* -> PSU
	  (hints + "error" SFX on every violation)
	- Chassis install builds the bench device model ("bench_1") on the bench
	  top; the device id is reserved but the node is NOT registered until the
	  build is complete (mobo + psu present) and powered on
	- Every other component gets a visual model snapped to the bench top
	  (Snap_1..6 attachments, used cyclically), parented to facility.devices
	- Bench power switch toggles session.workbench.powered, syncs the bench
	  node LED and registers the node when the build is complete
	- Ship: payout = floor(totalSpent * 0.3) + 100, crate spawns at the dock
	- ApplyState / Serialize: persistence hooks (no Instance values serialized)
	Note: CommandExecutor sets node.osInstalled directly on install-os; Ship
	and Serialize sync workbench.osInstalled from the bench node so a finished
	build ships and persists correctly.
]]

local WorkbenchBuilderSystem = {}

local Sessions: any = nil -- SessionManager module
local Graph: any = nil -- NetworkGraph module
local Catalog: any = nil -- HardwareCatalog module
local Constants: any = nil -- PlotConstants module (reserved: bench layout constants)
local ModelFactory: any = nil -- ModelFactory module
local Cabling: any = nil -- RackAndCablingSystem module
local Remotes: any = nil -- Remotes folder

local BENCH_DEVICE_ID = "bench_1" -- reserved device id of the workbench build
local INSTALL_RANGE = 16 -- studs between player and workbench pivot
local PAYOUT_MARGIN = 0.3 -- fraction of totalSpent paid out on shipping
local PAYOUT_BONUS = 100 -- flat bonus per shipped build
local CRATE_DESPAWN = 20 -- seconds before the shipping crate disappears

local LED_GREEN = Color3.fromRGB(85, 255, 120)
local LED_OFF = Color3.fromRGB(70, 70, 70)

---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------

function WorkbenchBuilderSystem.Init(deps: { [string]: any })
	Sessions = deps.sessions
	Graph = deps.graph
	Catalog = deps.catalog
	Constants = deps.constants
	ModelFactory = deps.modelFactory
	Cabling = deps.cabling
	Remotes = deps.remotesFolder

	-- Client fallback: {action="register"} forces the bench node registration
	-- (used when the client believes the build is complete but power state
	-- desynced, e.g. after a reconnect).
	local remote = Remotes:FindFirstChild("WorkbenchRemote")
	if remote ~= nil then
		(remote :: any).OnServerEvent:Connect(function(player, action)
			WorkbenchBuilderSystem.onWorkbenchAction(player, action)
		end)
	end
end

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------

local function playSFX(player: Player, name: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("PlaySFXRemote") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, name)
	end
end

local function hint(player: Player, message: string)
	local remote = if Remotes ~= nil then Remotes:FindFirstChild("OpenTerminalEvent") else nil
	if remote ~= nil then
		(remote :: any):FireClient(player, { action = "hint", message = message })
	end
end

-- Places a component visual relative to the workbench pivot, snapped to the
-- Snap_<index> attachment position when available (bench top row).
local function placeVisual(session: any, visual: Model, snapIndex: number)
	local facility = session.facility
	local bench = facility.workbenchModel
	if bench == nil then
		return
	end
	local pivot = bench:GetPivot()
	local offset = CFrame.new(0, 2.72, 1.0) -- fallback: on the human-scale bench top
	local snaps = facility.benchSnaps
	local snap = if type(snaps) == "table" then snaps[snapIndex] else nil
	if snap ~= nil and snap:IsA("Attachment") then
		offset = CFrame.new(snap.WorldPosition - pivot.Position)
	end
	visual:PivotTo(pivot * offset)
	visual.Parent = facility.devices
end

-- Builds (or rebuilds) the bench device model on the bench top. Called when
-- the chassis is installed or when ApplyState restores a chassis. The model
-- is NOT registered as a node here - RegisterBenchNode does that later.
local function ensureBenchModel(session: any)
	local wb = session.workbench
	local facility = session.facility
	if wb.chassis == nil or wb.benchModel ~= nil or facility.workbenchModel == nil then
		return
	end
	local chassisId = wb.chassis :: string
	local model, _ports, _consoleAttach, _led, _smoke = ModelFactory.BuildDeviceModel(chassisId, BENCH_DEVICE_ID)
	model:PivotTo(facility.workbenchModel:GetPivot() * CFrame.new(0, 2.72, 0))
	model.Parent = facility.devices

	-- The bench console prompt should read as the custom build.
	local consolePart = model:FindFirstChild("ConsolePort", true)
	if consolePart ~= nil and consolePart:IsA("BasePart") then
		local prompt = consolePart:FindFirstChildOfClass("ProximityPrompt")
		if prompt ~= nil then
			prompt.ObjectText = "Custom Server (Workbench)"
		end
	end

	wb.benchModel = model
	wb.deviceId = BENCH_DEVICE_ID
end

---------------------------------------------------------------------
-- Bench switch
---------------------------------------------------------------------

--[[
	HookBenchSwitch(session): wires the bench power switch ClickDetector
	(guard attribute "Hooked"). Toggling flips session.workbench.powered,
	recolors the bench LED, syncs the registered bench node power state and
	(registering when the build is complete and powering on).
]]
function WorkbenchBuilderSystem.HookBenchSwitch(session: any)
	local facility = session.facility
	if type(facility) ~= "table" or facility.benchSwitch == nil then
		return
	end
	local switchPart = facility.benchSwitch :: BasePart
	local click = switchPart:FindFirstChild("BenchPowerClick")
	if click == nil or not click:IsA("ClickDetector") or click:GetAttribute("Hooked") then
		return
	end
	click:SetAttribute("Hooked", true)
	local benchLed = facility.benchLed
	local player = session.player

	click.MouseClick:Connect(function(clicker)
		if clicker ~= player then
			return
		end
		local wb = session.workbench
		wb.powered = not wb.powered
		if benchLed ~= nil and benchLed:IsA("BasePart") then
			benchLed.Color = if wb.powered then LED_GREEN else LED_OFF
		end
		if wb.powered then
			WorkbenchBuilderSystem.RegisterBenchNode(session)
		end
		local node = session.devices[BENCH_DEVICE_ID]
		if node ~= nil then
			node.isPowered = wb.powered
			Graph.UpdateDeviceLED(session, BENCH_DEVICE_ID)
		end
		playSFX(player, if wb.powered then "plug" else "key")
	end)
end

---------------------------------------------------------------------
-- Component installation
---------------------------------------------------------------------

--[[
	TryInstall(player, session, itemId): buys + installs one component.
	Enforces proximity (16 studs of the workbench pivot), install order,
	capacity (sockets / RAM slots / storage bays) and balance; deducts the
	price into session.workbench.totalSpent; attaches a bench visual; updates
	the registered node specs; registers the node when PSU lands on a powered
	bench. Every path gives a hint + appropriate SFX.
]]
function WorkbenchBuilderSystem.TryInstall(player: Player, session: any, itemId: string)
	local def = Catalog.Get(itemId)
	if def == nil then
		return
	end
	if def.category ~= "Component" then
		return -- only components install at the workbench
	end
	if itemId == "replacement_hdd" then
		hint(player, "Replacement HDD dipakai untuk Remote Hands (Fase 2).")
		return
	end

	local wb = session.workbench
	local facility = session.facility

	-- Must stand at the workbench.
	local char = player.Character
	local hrp = if char ~= nil then char:FindFirstChild("HumanoidRootPart") else nil
	if hrp == nil or facility.workbenchModel == nil then
		hint(player, "Dekati AssemblyWorkbench untuk memasang komponen.")
		return
	end
	if (hrp.Position - facility.workbenchModel:GetPivot().Position).Magnitude > INSTALL_RANGE then
		hint(player, "Dekati AssemblyWorkbench untuk memasang komponen.")
		return
	end

	-- Component classification.
	local isChassis = string.sub(itemId, 1, 8) == "chassis_"
	local isMobo = string.sub(itemId, 1, 5) == "mobo_"
	local isCpu = string.sub(itemId, 1, 4) == "cpu_"
	local isRam = string.sub(itemId, 1, 4) == "ram_"
	local isStorage = itemId == "nvme_1tb"
	local isPsu = itemId == "psu_redundant"

	-- Install order + capacity enforcement.
	local orderErr: string? = nil
	if isChassis then
		if wb.chassis ~= nil then
			orderErr = "Chassis sudah terpasang di workbench."
		end
	elseif isMobo then
		if wb.chassis == nil then
			orderErr = "Pasang chassis dulu."
		elseif wb.mobo ~= nil then
			orderErr = "Motherboard sudah terpasang."
		end
	elseif isCpu then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu."
		elseif wb.cpuCount >= wb.cpuSockets then
			orderErr = "Socket CPU penuh."
		end
	elseif isRam then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu."
		elseif wb.ramSlotsUsed >= wb.ramSlots then
			orderErr = "Slot RAM penuh."
		end
	elseif isStorage then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu."
		elseif wb.storageBaysUsed >= wb.storageBays then
			orderErr = "Bay storage penuh."
		end
	elseif isPsu then
		if wb.chassis == nil or wb.mobo == nil then
			orderErr = "Pasang chassis + motherboard dulu."
		elseif wb.psu ~= nil then
			orderErr = "PSU sudah terpasang."
		end
	else
		orderErr = "Komponen tidak dikenal."
	end
	if orderErr ~= nil then
		hint(player, orderErr :: string)
		playSFX(player, "error")
		return
	end

	-- Balance.
	if session.balance < def.price then
		hint(player, "Uang belum cukup untuk " .. def.name .. " ($" .. tostring(def.price) .. ")")
		playSFX(player, "error")
		return
	end

	session.balance -= def.price
	wb.totalSpent += def.price

	local specs = def.specs
	if isChassis then
		wb.chassis = itemId
		wb.snapIndex = 0 -- no component visuals yet
		ensureBenchModel(session) -- device id reserved, node NOT registered yet
	elseif isMobo then
		wb.mobo = itemId
		wb.cpuSockets = specs.sockets or 1
		wb.ramSlots = specs.ramSlots or 2
		wb.storageBays = specs.storageBays or 2
	elseif isCpu then
		wb.cpuCount += 1
		wb.cpuCores += specs.cores or 8
		wb.lastCpuId = itemId
	elseif isRam then
		wb.ramSlotsUsed += 1
		wb.ramGb += specs.ramGb or 0
		wb.lastRamId = itemId
	elseif isStorage then
		wb.storageBaysUsed += 1
		wb.storageGb += specs.storageGb or 0
	elseif isPsu then
		wb.psu = itemId
	end

	-- Visual: every non-chassis component snaps onto the bench top
	-- (Snap_1..6 used cyclically). The chassis IS the bench device model.
	if not isChassis then
		local visual = ModelFactory.BuildBenchComponentVisual(itemId)
		local nextSnap = ((wb.snapIndex or 0) % 6) + 1
		placeVisual(session, visual, nextSnap)
		wb.snapIndex = nextSnap
	end

	-- Registered bench node? Keep its specs in sync.
	local node = session.devices[BENCH_DEVICE_ID]
	if node ~= nil then
		node.specs.cpu = wb.cpuCores
		node.specs.ram = wb.ramGb
		node.specs.disk = wb.storageGb
	end

	playSFX(player, "plug")
	if isPsu and wb.powered then
		WorkbenchBuilderSystem.RegisterBenchNode(session)
	end
end

---------------------------------------------------------------------
-- Bench node registration
---------------------------------------------------------------------

--[[
	RegisterBenchNode(session): when the build is complete (chassis + mobo +
	psu) and not registered yet, creates the BareMetal node "bench_1" with
	specs from the installed components, registers it with the bench device
	model, hooks its interactions and auto-cables it when powered (skipped
	when session.loadedFromSave - the persistence layer re-links cables
	explicitly). EnsureBenchNode is an alias for the same behavior.
]]
function WorkbenchBuilderSystem.RegisterBenchNode(session: any)
	local wb = session.workbench
	if session.devices[BENCH_DEVICE_ID] ~= nil then
		return -- already registered
	end
	if wb.chassis == nil or wb.mobo == nil or wb.psu == nil then
		return -- build incomplete
	end

	ensureBenchModel(session) -- covers restored chassis state without a model
	local benchModel = wb.benchModel
	if benchModel == nil then
		return
	end

	local chassisId = wb.chassis :: string
	local node = Graph.DefaultNode(BENCH_DEVICE_ID, "Custom Server (" .. chassisId .. ")", chassisId)
	local chassisDef = Catalog.Get(chassisId)
	node.uSize = if chassisDef ~= nil then chassisDef.uSize else 1
	local psuDef = Catalog.Get(wb.psu :: string)
	node.specs.powerWatts = if psuDef ~= nil then (psuDef.specs.powerWatts or 450) else 450
	node.specs.cpu = wb.cpuCores
	node.specs.ram = wb.ramGb
	node.specs.disk = wb.storageGb
	node.osInstalled = wb.osInstalled
	node.isPowered = wb.powered
	wb.deviceId = BENCH_DEVICE_ID

	Graph.RegisterDevice(session, node, benchModel :: Model)
	Cabling.HookDevice(session, BENCH_DEVICE_ID)
	if wb.powered and not session.loadedFromSave then
		Graph.AutoCable(session, BENCH_DEVICE_ID)
	end
end

-- Alias: same single registration path (CONTRACT lists both entry points).
function WorkbenchBuilderSystem.EnsureBenchNode(session: any)
	WorkbenchBuilderSystem.RegisterBenchNode(session)
end

---------------------------------------------------------------------
-- Remote responder
---------------------------------------------------------------------

function WorkbenchBuilderSystem.onWorkbenchAction(player: Player, action: any)
	if Sessions == nil then
		return
	end
	local session = Sessions.GetSession(player)
	if session == nil then
		return
	end
	if action == "register" then
		WorkbenchBuilderSystem.RegisterBenchNode(session)
	end
end

---------------------------------------------------------------------
-- Shipping
---------------------------------------------------------------------

--[[
	Ship(session) -> (ok, msg): packs the finished build into a crate that
	spawns on the loading dock (despawns after 20 s) and pays out
	floor(totalSpent * 0.3) + 100. Requires chassis + psu + OS + stress-test
	pass and not already shipped.
]]
function WorkbenchBuilderSystem.Ship(session: any): (boolean, string)
	local wb = session.workbench
	if wb.chassis == nil then
		return false, "Belum ada build di workbench (pasang chassis dulu)."
	end
	if wb.psu == nil then
		return false, "Build belum lengkap (PSU belum terpasang)."
	end
	-- Sync OS state from the bench node (install-os writes the node directly).
	local node = session.devices[BENCH_DEVICE_ID]
	if wb.osInstalled == nil and node ~= nil then
		wb.osInstalled = node.osInstalled
	end
	if wb.osInstalled == nil then
		return false, "Install OS dulu di server bench (install-os)."
	end
	if not wb.tested then
		return false, "Jalankan stress-test dulu di server bench."
	end
	if wb.shipped then
		return false, "Build ini sudah dikirim."
	end

	wb.shipped = true
	local payout = math.floor(wb.totalSpent * PAYOUT_MARGIN) + PAYOUT_BONUS
	session.balance += payout

	local facility = session.facility
	if type(facility) == "table" and facility.dockCF ~= nil then
		local crate = ModelFactory.BuildCrate("CUSTOM SERVER\n+$" .. tostring(payout))
		crate:PivotTo(facility.dockCF :: CFrame)
		crate.Parent = facility.crates
		task.delay(CRATE_DESPAWN, function()
			if crate.Parent ~= nil then
				crate:Destroy()
			end
		end)
	end

	playSFX(session.player, "cash")
	return true, ""
end

---------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------

--[[
	Serialize(session) -> table: every persistent workbench field + the
	visuals list (component ids in install order). No Instance values - this
	payload goes straight into a DataStore.
]]
function WorkbenchBuilderSystem.Serialize(session: any): { [string]: any }
	local wb = session.workbench
	-- Sync OS from the bench node so a finished build keeps its OS on reload.
	local node = session.devices[BENCH_DEVICE_ID]
	if wb.osInstalled == nil and node ~= nil then
		wb.osInstalled = node.osInstalled
	end

	local visuals: { string } = {}
	if wb.mobo ~= nil then
		table.insert(visuals, wb.mobo :: string)
	end
	for _ = 1, wb.cpuCount do
		table.insert(visuals, wb.lastCpuId or "cpu_xeon8")
	end
	for _ = 1, wb.ramSlotsUsed do
		table.insert(visuals, wb.lastRamId or "ram_32g")
	end
	for _ = 1, wb.storageBaysUsed do
		table.insert(visuals, "nvme_1tb")
	end
	if wb.psu ~= nil then
		table.insert(visuals, wb.psu :: string)
	end

	return {
		chassis = wb.chassis,
		mobo = wb.mobo,
		cpuCount = wb.cpuCount,
		cpuSockets = wb.cpuSockets,
		cpuCores = wb.cpuCores,
		ramSlotsUsed = wb.ramSlotsUsed,
		ramSlots = wb.ramSlots,
		ramGb = wb.ramGb,
		storageBaysUsed = wb.storageBaysUsed,
		storageBays = wb.storageBays,
		storageGb = wb.storageGb,
		psu = wb.psu,
		powered = wb.powered == true,
		osInstalled = wb.osInstalled,
		tested = wb.tested == true,
		shipped = wb.shipped == true,
		totalSpent = wb.totalSpent,
		deviceId = wb.deviceId,
		snapIndex = wb.snapIndex,
		lastCpuId = wb.lastCpuId,
		lastRamId = wb.lastRamId,
		visuals = visuals,
	}
end

--[[
	ApplyState(session, data): restores the workbench from a save.
	- sets every wb field (incl. cpuCores / lastCpuId / lastRamId)
	- chassis present -> rebuilds the bench device model (same path as install)
	- data.visuals -> rebuilds the component visuals on the bench snaps
	- complete + powered -> registers the bench node (auto-cable suppressed by
	  loadedFromSave; cables are restored by the persistence link pass)
	- recolors the bench LED
]]
function WorkbenchBuilderSystem.ApplyState(session: any, data: any)
	if type(data) ~= "table" then
		return
	end
	local wb = session.workbench

	wb.chassis = if type(data.chassis) == "string" then data.chassis else nil
	wb.mobo = if type(data.mobo) == "string" then data.mobo else nil
	wb.cpuCount = tonumber(data.cpuCount) or 0
	wb.cpuSockets = tonumber(data.cpuSockets) or 0
	wb.cpuCores = tonumber(data.cpuCores) or 0
	wb.ramSlotsUsed = tonumber(data.ramSlotsUsed) or 0
	wb.ramSlots = tonumber(data.ramSlots) or 0
	wb.ramGb = tonumber(data.ramGb) or 0
	wb.storageBaysUsed = tonumber(data.storageBaysUsed) or 0
	wb.storageBays = tonumber(data.storageBays) or 0
	wb.storageGb = tonumber(data.storageGb) or 0
	wb.psu = if type(data.psu) == "string" then data.psu else nil
	wb.powered = data.powered == true
	wb.osInstalled = if type(data.osInstalled) == "string" then data.osInstalled else nil
	wb.installing = false
	wb.stressRunning = false
	wb.tested = data.tested == true
	wb.shipped = data.shipped == true
	wb.totalSpent = tonumber(data.totalSpent) or 0
	wb.snapIndex = tonumber(data.snapIndex) or 0
	wb.lastCpuId = if type(data.lastCpuId) == "string" then data.lastCpuId else nil
	wb.lastRamId = if type(data.lastRamId) == "string" then data.lastRamId else nil
	wb.deviceId = nil
	wb.benchModel = nil

	-- Rebuild the bench device model through the same path as a live install.
	if wb.chassis ~= nil then
		ensureBenchModel(session)

		-- Rebuild the component visuals (skip the chassis id if present).
		if type(data.visuals) == "table" then
			local snapIdx = 0
			for _, compId in ipairs(data.visuals :: { any }) do
				if type(compId) == "string" and compId ~= wb.chassis then
					local visual = ModelFactory.BuildBenchComponentVisual(compId)
					snapIdx = (snapIdx % 6) + 1
					placeVisual(session, visual, snapIdx)
				end
			end
			wb.snapIndex = snapIdx
		end

		-- Complete + powered -> the bench node comes alive right away.
		if wb.powered and wb.mobo ~= nil and wb.psu ~= nil then
			WorkbenchBuilderSystem.RegisterBenchNode(session)
		end
	end

	local benchLed = session.facility.benchLed
	if benchLed ~= nil and benchLed:IsA("BasePart") then
		benchLed.Color = if wb.powered then LED_GREEN else LED_OFF
	end
end

return WorkbenchBuilderSystem
