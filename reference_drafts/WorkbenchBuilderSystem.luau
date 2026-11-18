--!strict
--[[
	WorkbenchBuilderSystem (ModuleScript, ServerScriptService/Physical)
	Rakit server custom di AssemblyWorkbench: urutan Chassis -> Mobo -> CPU* ->
	RAM* -> Storage* -> PSU. Build lengkap + powered = node BareMetal nyata di
	jaringan (bisa di-SSH, install OS, VM). Stress test + shipping crate.
]]

local WorkbenchBuilderSystem = {}

local sessions = nil
local graph = nil
local catalog = nil
local constants = nil
local modelFactory = nil
local cabling = nil
local remotesFolder = nil

local BENCH_DEVICE_ID = "bench_1"

function WorkbenchBuilderSystem.Init(deps: { [string]: any })
	sessions = deps.sessions
	graph = deps.graph
	catalog = deps.catalog
	constants = deps.constants
	modelFactory = deps.modelFactory
	cabling = deps.cabling
	remotesFolder = deps.remotesFolder

	local remote = remotesFolder:FindFirstChild("WorkbenchRemote")
	if remote then
		remote.OnServerEvent:Connect(function(player, action)
			WorkbenchBuilderSystem.OnWorkbenchAction(player, action)
		end)
	end
end

local function playSFX(player: Player, name: string)
	local remote = remotesFolder:FindFirstChild("PlaySFXRemote")
	if remote then
		remote:FireClient(player, name)
	end
end

local function hint(player: Player, message: string)
	local openRemote = remotesFolder:FindFirstChild("OpenTerminalEvent")
	if openRemote then
		openRemote:FireClient(player, { action = "hint", message = message })
	end
end

function WorkbenchBuilderSystem.HookBenchSwitch(session: any)
	local facility = session.facility
	local switchPart = facility.benchSwitch
	local benchLed = facility.benchLed
	if switchPart == nil then
		return
	end
	local click = switchPart:FindFirstChild("BenchPowerClick")
	if click and click:IsA("ClickDetector") and not click:GetAttribute("Hooked") then
		click:SetAttribute("Hooked", true)
		click.MouseClick:Connect(function(clicker)
			if clicker ~= session.player then
				return
			end
			local wb = session.workbench
			wb.powered = not wb.powered
			if benchLed and benchLed:IsA("BasePart") then
				benchLed.Color = if wb.powered then Color3.fromRGB(85, 255, 120) else Color3.fromRGB(70, 70, 70)
			end
			if wb.powered then
				WorkbenchBuilderSystem.EnsureBenchNode(session)
			end
			local node = session.devices[BENCH_DEVICE_ID]
			if node then
				node.isPowered = wb.powered
				graph.UpdateDeviceLED(session, BENCH_DEVICE_ID)
			end
			playSFX(session.player, if wb.powered then "plug" else "key")
		end)
	end
end

function WorkbenchBuilderSystem.EnsureBenchNode(session: any)
	local wb = session.workbench
	if wb.deviceId ~= nil then
		return
	end
	if wb.chassis == nil or wb.mobo == nil or wb.psu == nil then
		return
	end
	local facility = session.facility
	local benchModel, _ports, _console, _led, _smoke = modelFactory.BuildDeviceModel(wb.chassis :: string, BENCH_DEVICE_ID)
	local benchBase = facility.workbenchModel:GetPivot() * CFrame.new(0, 3.5, 0)
	benchModel:PivotTo(benchBase)
	benchModel.Parent = facility.devices

	local defChassis = catalog.Get(wb.chassis :: string)
	local uSize = if defChassis then (defChassis :: any).uSize else 2
	local node = graph.DefaultNode(BENCH_DEVICE_ID, "Custom Server (" .. wb.chassis .. ")", wb.chassis :: string)
	node.uSize = uSize
	node.isPowered = wb.powered
	local psuDef = catalog.Get(wb.psu :: string)
	node.specs.powerWatts = if psuDef then (psuDef :: any).specs.powerWatts else 450
	node.specs.cpu = wb.cpuCount * (if wb.cpuSockets > 0 then 0 else 0) + wb.cpuCores
	node.specs.ram = wb.ramGb
	node.specs.disk = wb.storageGb
	wb.deviceId = BENCH_DEVICE_ID

	local prompt = benchModel:FindFirstChild("ConsolePort", true)
	if prompt and prompt:IsA("BasePart") then
		local pr = prompt:FindFirstChildOfClass("ProximityPrompt")
		if pr then
			pr.ObjectText = "Custom Server (Workbench)"
		end
	end

	graph.RegisterDevice(session, node, benchModel)
	cabling.HookDevice(session, BENCH_DEVICE_ID)
	if wb.powered then
		graph.AutoCable(session, BENCH_DEVICE_ID)
	end
end

--[[
	TryInstall: beli komponen -> pasang ke build sesuai urutan.
]]
function WorkbenchBuilderSystem.TryInstall(player: Player, session: any, itemId: string)
	local def = catalog.Get(itemId)
	if def == nil then
		return
	end
	local defv = def :: any
	if defv.category ~= "Component" then
		return
	end
	if itemId == "replacement_hdd" then
		hint(player, "Replacement HDD dipakai untuk Remote Hands (Fase 2).")
		return
	end

	local wb = session.workbench
	local facility = session.facility

	-- harus dekat workbench
	local char = player.Character
	local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
	if hrp == nil or facility.workbenchModel == nil then
		hint(player, "Dekati AssemblyWorkbench untuk memasang komponen.")
		return
	end
	if (hrp.Position - facility.workbenchModel:GetPivot().Position).Magnitude > 16 then
		hint(player, "Dekati AssemblyWorkbench untuk memasang komponen.")
		return
	end

	local isChassis = string.sub(itemId, 1, 8) == "chassis_"
	local isMobo = string.sub(itemId, 1, 5) == "mobo_"
	local isCpu = string.sub(itemId, 1, 4) == "cpu_"
	local isRam = string.sub(itemId, 1, 4) == "ram_"
	local isStorage = itemId == "nvme_1tb"
	local isPsu = itemId == "psu_redundant"

	local orderErr: string? = nil
	if isChassis then
		if wb.chassis ~= nil then
			orderErr = "Chassis sudah terpasang"
		end
	elseif isMobo then
		if wb.chassis == nil then
			orderErr = "Pasang chassis dulu"
		elseif wb.mobo ~= nil then
			orderErr = "Motherboard sudah terpasang"
		end
	elseif isCpu then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu"
		elseif wb.cpuCount >= wb.cpuSockets then
			orderErr = "Socket CPU penuh"
		end
	elseif isRam then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu"
		elseif wb.ramSlotsUsed >= wb.ramSlots then
			orderErr = "Slot RAM penuh"
		end
	elseif isStorage then
		if wb.mobo == nil then
			orderErr = "Pasang motherboard dulu"
		elseif wb.storageBaysUsed >= wb.storageBays then
			orderErr = "Bay storage penuh"
		end
	elseif isPsu then
		if wb.chassis == nil or wb.mobo == nil then
			orderErr = "Pasang chassis + motherboard dulu"
		elseif wb.psu ~= nil then
			orderErr = "PSU sudah terpasang"
		end
	else
		orderErr = "Komponen tidak dikenal"
	end

	if orderErr ~= nil then
		hint(player, orderErr)
		playSFX(player, "error")
		return
	end

	if session.balance < defv.price then
		hint(player, "Uang belum cukup untuk " .. defv.name)
		playSFX(player, "error")
		return
	end

	session.balance -= defv.price
	wb.totalSpent += defv.price

	local specs = defv.specs
	local visualOffset = CFrame.new(0, 3.5, 0)
	if isChassis then
		wb.chassis = itemId
		wb.snapIndex = 1
		-- chassis = device model nyata di atas bench (port RJ45 + console + LED)
		WorkbenchBuilderSystem.EnsureBenchNodeVisualOnly(session, itemId)
	elseif isMobo then
		wb.mobo = itemId
		wb.cpuSockets = specs.sockets or 1
		wb.ramSlots = specs.ramSlots or 2
		wb.storageBays = specs.storageBays or 2
		visualOffset = CFrame.new(0, 3.5 + 0.35, 0.4)
	elseif isCpu then
		wb.cpuCount += 1
		wb.cpuCores += specs.cores or 8
		visualOffset = CFrame.new(-0.5 + wb.cpuCount * 0.6, 3.5 + 0.55, 0.4)
	elseif isRam then
		wb.ramSlotsUsed += 1
		wb.ramGb += specs.ramGb or 0
		visualOffset = CFrame.new(-1.4 + wb.ramSlotsUsed * 0.35, 3.5 + 0.62, 0.4)
	elseif isStorage then
		wb.storageBaysUsed += 1
		wb.storageGb += specs.storageGb or 0
		visualOffset = CFrame.new(1.0 + wb.storageBaysUsed * 0.5, 3.5 + 0.2, 0.4)
	elseif isPsu then
		wb.psu = itemId
		visualOffset = CFrame.new(0, 3.5 + 0.5, -0.7)
	end

	-- visual komponen nempel di bench (kecuali chassis, karena chassis = model device)
	if not isChassis then
		local visual = modelFactory.BuildBenchComponentVisual(itemId)
		visual:PivotTo(facility.workbenchModel:GetPivot() * visualOffset)
		visual.Parent = facility.devices
		wb.snapIndex = (wb.snapIndex or 0) + 1
	end

	-- node bench sudah ada? update specs
	local node = session.devices[BENCH_DEVICE_ID]
	if node then
		node.specs.cpu = wb.cpuCores
		node.specs.ram = wb.ramGb
		node.specs.disk = wb.storageGb
	end

	playSFX(player, "plug")
	if isPsu and wb.powered then
		WorkbenchBuilderSystem.EnsureBenchNode(session)
	end
end

--[[
	Chassis terpasang -> langsung buat model device bench (belum register node
	sampai mobo+psu+power lengkap).
]]
function WorkbenchBuilderSystem.EnsureBenchNodeVisualOnly(session: any, chassisItemId: string)
	local facility = session.facility
	if session.workbench.deviceId ~= nil then
		return
	end
	local benchModel, _ports, _console, _led, _smoke = modelFactory.BuildDeviceModel(chassisItemId, BENCH_DEVICE_ID)
	benchModel:PivotTo(facility.workbenchModel:GetPivot() * CFrame.new(0, 3.5, 0))
	benchModel.Parent = facility.devices
	local prompt = benchModel:FindFirstChild("ConsolePort", true)
	if prompt and prompt:IsA("BasePart") then
		local pr = prompt:FindFirstChildOfClass("ProximityPrompt")
		if pr then
			pr.ObjectText = "Custom Server (Workbench)"
		end
	end
	session.workbench.deviceId = BENCH_DEVICE_ID
	session.workbench.benchModel = benchModel
	-- belum register node: menunggu mobo + psu + power
end

function WorkbenchBuilderSystem.RegisterBenchNode(session: any)
	local wb = session.workbench
	if wb.deviceId == nil or session.devices[BENCH_DEVICE_ID] ~= nil then
		return
	end
	if wb.chassis == nil or wb.mobo == nil or wb.psu == nil then
		return
	end
	local node = graph.DefaultNode(BENCH_DEVICE_ID, "Custom Server (" .. wb.chassis .. ")", wb.chassis :: string)
	local defChassis = catalog.Get(wb.chassis :: string)
	node.uSize = if defChassis then (defChassis :: any).uSize else 2
	node.isPowered = wb.powered
	local psuDef = catalog.Get(wb.psu :: string)
	node.specs.powerWatts = if psuDef then (psuDef :: any).specs.powerWatts else 450
	node.specs.cpu = wb.cpuCores
	node.specs.ram = wb.ramGb
	node.specs.disk = wb.storageGb
	node.osInstalled = wb.osInstalled
	local benchModel = wb.benchModel
	if benchModel then
		graph.RegisterDevice(session, node, benchModel :: Model)
		cabling.HookDevice(session, BENCH_DEVICE_ID)
		if wb.powered then
			graph.AutoCable(session, BENCH_DEVICE_ID)
		end
	end
end

function WorkbenchBuilderSystem.OnWorkbenchAction(player: Player, action: any)
	local session = sessions.GetSession(player)
	if session == nil then
		return
	end
	if action == "register" then
		WorkbenchBuilderSystem.RegisterBenchNode(session)
	end
end

--[[
	Ship: crate ke LoadingDock + payout margin 30% dari total biaya build.
]]
function WorkbenchBuilderSystem.Ship(session: any): (boolean, string)
	local wb = session.workbench
	if wb.chassis == nil or wb.psu == nil then
		return false, "Build belum lengkap"
	end
	if wb.osInstalled == nil then
		return false, "Install OS dulu di server bench"
	end
	if not wb.tested then
		return false, "Jalankan stress-test dulu"
	end
	if wb.shipped then
		return false, "Build ini sudah dikirim"
	end
	wb.shipped = true
	local payout = math.floor(wb.totalSpent * 0.3) + 100
	session.balance += payout

	local crate = modelFactory.BuildCrate("CUSTOM SERVER\n+" .. string.format("$%d", payout))
	crate:PivotTo(CFrame.new(session.facility.dockCF))
	crate.Parent = session.facility.crates
	local crateModel = crate
	task.delay(20, function()
		if crateModel and crateModel.Parent then
			crateModel:Destroy()
		end
	end)
	return true, ""
end

--[[
	ApplyState: restore state workbench dari save (dipanggil Persistence).
]]
function WorkbenchBuilderSystem.ApplyState(session: any, data: any)
	local wb = session.workbench
	wb.chassis = data.chassis
	wb.mobo = data.mobo
	wb.cpuCount = data.cpuCount or 0
	wb.cpuSockets = data.cpuSockets or 0
	wb.cpuCores = data.cpuCores or 0
	wb.ramSlotsUsed = data.ramSlotsUsed or 0
	wb.ramSlots = data.ramSlots or 0
	wb.ramGb = data.ramGb or 0
	wb.storageBaysUsed = data.storageBaysUsed or 0
	wb.storageBays = data.storageBays or 0
	wb.storageGb = data.storageGb or 0
	wb.psu = data.psu
	wb.powered = data.powered or false
	wb.osInstalled = data.osInstalled
	wb.tested = data.tested or false
	wb.shipped = data.shipped or false
	wb.totalSpent = data.totalSpent or 0

	if wb.chassis ~= nil then
		WorkbenchBuilderSystem.EnsureBenchNodeVisualOnly(session, wb.chassis :: string)
		-- visual ulang komponen
		local facility = session.facility
		if data.visuals then
			for _, compId in ipairs(data.visuals) do
				local visual = modelFactory.BuildBenchComponentVisual(compId)
				visual:PivotTo(facility.workbenchModel:GetPivot() * CFrame.new(0, 3.5 + 0.4, 0.3))
				visual.Parent = facility.devices
			end
		end
		if wb.powered and wb.psu ~= nil and wb.mobo ~= nil then
			WorkbenchBuilderSystem.RegisterBenchNode(session)
		end
	end
	local benchLed = session.facility.benchLed
	if benchLed and benchLed:IsA("BasePart") then
		benchLed.Color = if wb.powered then Color3.fromRGB(85, 255, 120) else Color3.fromRGB(70, 70, 70)
	end
end

function WorkbenchBuilderSystem.Serialize(session: any): { [string]: any }
	local wb = session.workbench
	local visuals: { string } = {}
	if wb.mobo then
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
	if wb.psu then
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
		powered = wb.powered,
		osInstalled = wb.osInstalled,
		tested = wb.tested,
		shipped = wb.shipped,
		totalSpent = wb.totalSpent,
		visuals = visuals,
	}
end

return WorkbenchBuilderSystem
