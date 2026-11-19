--!strict
--[[
	PlotConstants (ModuleScript, ReplicatedStorage/Shared)
	Layout lab per pemain, bounds placement, snap grid, konstanta ekonomi, warna.
	Dipakai server DAN client: geometry & aturan validasi harus konsisten di dua-duanya.
]]

export type RoomSpec = {
	halfX: number,
	halfZ: number,
	height: number,
	doorWidth: number,
	doorHeight: number,
	floorTopY: number,
	wallThickness: number,
}

export type ZoneSpec = {
	name: string,
	position: Vector3,
	radius: number,
}

local PlotConstants = {}

PlotConstants.PLOT_COUNT = 4
PlotConstants.PLOT_POSITIONS = {
	Vector3.new(-210, 0, 0),
	Vector3.new(-70, 0, 0),
	Vector3.new(70, 0, 0),
	Vector3.new(210, 0, 0),
}

PlotConstants.ROOM = {
	halfX = 32,
	halfZ = 32,
	height = 18,
	doorWidth = 14,
	doorHeight = 10,
	floorTopY = 0.5,
	wallThickness = 1,
} :: RoomSpec

-- Area bebas placement device (relatif pusat plot, di lantai dalam ruangan)
PlotConstants.PLACEMENT_BOUNDS = { minX = -26, maxX = 26, minZ = -26, maxZ = 26 }
PlotConstants.SNAP_GRID = 2

-- Zona furniture: device tidak boleh placement menabrak area ini
PlotConstants.FURNITURE_ZONES = {
	{ name = "Rack", position = Vector3.new(-22, 0, -20), radius = 7 },
	{ name = "Workbench", position = Vector3.new(18, 0, -12), radius = 8 },
	{ name = "NOCDesk", position = Vector3.new(18, 0, 16), radius = 8 },
	{ name = "Dock", position = Vector3.new(0, 0, -24), radius = 8 },
	{ name = "ISP", position = Vector3.new(-16, 0, 30.2), radius = 6 },
} :: { ZoneSpec }

PlotConstants.RACK_POS = Vector3.new(-22, 0, -20)
PlotConstants.RACK_ROT_Y = 0
PlotConstants.WORKBENCH_POS = Vector3.new(18, 0, -12)
PlotConstants.NOCDESK_POS = Vector3.new(18, 0, 16)
PlotConstants.DOCK_POS = Vector3.new(0, 0, -24)
-- ISP uplink di dinding depan (+Z, dekat pintu masuk), box menghadap ke dalam ruangan.
PlotConstants.ISP_POS = Vector3.new(-16, 0, 30.2)
PlotConstants.BEACON_OFFSET = Vector3.new(0, 15.6, -6)
PlotConstants.AC_OFFSET = Vector3.new(29.8, 7, -10)

PlotConstants.STARTER = {
	isp = { id = "isp_uplink", name = "ISP_Uplink" },
	router = {
		id = "isp_router_1",
		name = "ISP_Gateway_Router",
		itemId = "router_edge",
		uSlot = 12,
		ip = "192.168.1.1",
		gateway = "203.0.113.1",
		subnetMask = "255.255.255.0",
	},
	switch = { id = "sw_main_1", name = "Switch_8P", itemId = "switch_8p", uSlot = 10 },
	baremetal = { id = "bm_starter_1", name = "BareMetal_Starter", itemId = "bm_starter", uSlot = 8 },
}

PlotConstants.LAPTOP_BRIDGE_IP = "192.168.1.254"

PlotConstants.ECONOMY = {
	startBalance = 2500,
	startReputation = 10,
	tickSeconds = 5,
	payoutInterval = 15,
	electricityPerWattPerTick = 0.00015,
	vpsCpuRatePerPayout = 0.15,
	vpsRamRatePerPayout = 0.02,
	vpsDiskRatePerPayout = 0.003,
}

-- ===== Fase 2: manual cabling & colour-coded spools =====
-- One store purchase fills a spool with spoolYield patch cables.
PlotConstants.CABLES = {
	spoolYield = 5,
	starter = {
		LAN_Blue = 8,
		WAN_Yellow = 2,
		Mgmt_Red = 2,
	},
	colors = { "LAN_Blue", "WAN_Yellow", "Mgmt_Red" },
	labels = {
		LAN_Blue = "LAN Biru",
		WAN_Yellow = "WAN Kuning",
		Mgmt_Red = "Mgmt Merah",
	},
	itemByColor = {
		LAN_Blue = "cable_lan_blue",
		WAN_Yellow = "cable_wan_yellow",
		Mgmt_Red = "cable_mgmt_red",
	},
}

-- ===== Fase 2: colocation contracts =====
PlotConstants.COLOCATION = {
	vlanChoices = { 20, 30, 40 },
	uSize = 2,
	slaSeconds = 240, -- time to mount, cable, VLAN and power the client server
	runtimeSeconds = 60, -- paid service window after validation
	payoutIntervalSeconds = 10, -- one payout tick inside the service window
	deliveryDelaySeconds = 3, -- crate appears at the dock after accepting
	cleanupDelaySeconds = 15, -- client collects the server after completion
}

-- ===== Fase 3: shift clock + daily settlement =====
-- One shift is 08:00 -> 18:00. With 30 real seconds per in-game hour the
-- shift lasts 300s (5 minutes); peak hours 11:00-17:00 last 180s.
PlotConstants.SHIFT = {
	startMinutes = 8 * 60,
	endMinutes = 18 * 60,
	peakStartMinutes = 11 * 60,
	peakEndMinutes = 17 * 60,
	secondsPerGameHour = 30,
	settlementBaseBonus = 100,
	settlementUptimeBonusPerPercent = 2,
	settlementPerfectBonus = 150,
	incidentFailurePenalty = 75,
}

-- ===== Fase 3: incident engine =====
-- Four incident types; only the 11:00-17:00 peak produces new incidents.
PlotConstants.INCIDENTS = {
	spawnCooldownSeconds = 30,
	maxActive = 2,
	slaSeconds = 100,
	noisyThrottleLimit = 40,
	types = { "CableFault", "DDoSFlood", "NoisyNeighbor", "DriveFailure", "ServiceCrash" },
	labels = {
		CableFault = "Cable Fault",
		DDoSFlood = "DDoS Flood",
		NoisyNeighbor = "Noisy Neighbor",
		DriveFailure = "Drive Failure",
		ServiceCrash = "Service Crash",
	},
	rewards = {
		CableFault = 140,
		DDoSFlood = 180,
		NoisyNeighbor = 160,
		DriveFailure = 200,
		ServiceCrash = 170,
	},
}

PlotConstants.COLORS = {
	floor = Color3.fromRGB(118, 124, 132),
	floorGrid = Color3.fromRGB(92, 98, 106),
	wall = Color3.fromRGB(162, 168, 178),
	wallLower = Color3.fromRGB(64, 72, 84),
	trim = Color3.fromRGB(142, 150, 160),
	frame = Color3.fromRGB(48, 54, 64),
	glass = Color3.fromRGB(188, 212, 226),
	accentCyan = Color3.fromRGB(44, 156, 208),
	accentAmber = Color3.fromRGB(222, 178, 40),
	lightPanel = Color3.fromRGB(248, 252, 255),
	ledGreen = Color3.fromRGB(60, 245, 115),
	ledYellow = Color3.fromRGB(255, 215, 70),
	ledRed = Color3.fromRGB(255, 82, 82),
	ledOff = Color3.fromRGB(95, 102, 112),
	consoleBlue = Color3.fromRGB(64, 172, 255),
}

return PlotConstants
