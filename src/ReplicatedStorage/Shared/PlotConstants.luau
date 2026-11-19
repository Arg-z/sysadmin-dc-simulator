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
	{ name = "ISP", position = Vector3.new(-20, 0, -28), radius = 6 },
} :: { ZoneSpec }

PlotConstants.RACK_POS = Vector3.new(-22, 0, -20)
PlotConstants.RACK_ROT_Y = 0
PlotConstants.WORKBENCH_POS = Vector3.new(18, 0, -12)
PlotConstants.NOCDESK_POS = Vector3.new(18, 0, 16)
PlotConstants.DOCK_POS = Vector3.new(0, 0, -24)
PlotConstants.ISP_POS = Vector3.new(-20, 0, -28)
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

PlotConstants.COLORS = {
	floor = Color3.fromRGB(214, 220, 228),
	floorGrid = Color3.fromRGB(186, 195, 208),
	wall = Color3.fromRGB(228, 233, 240),
	wallLower = Color3.fromRGB(108, 122, 142),
	trim = Color3.fromRGB(188, 198, 210),
	frame = Color3.fromRGB(68, 78, 94),
	glass = Color3.fromRGB(165, 215, 245),
	accentCyan = Color3.fromRGB(56, 189, 248),
	accentAmber = Color3.fromRGB(245, 196, 48),
	lightPanel = Color3.fromRGB(248, 252, 255),
	ledGreen = Color3.fromRGB(60, 245, 115),
	ledYellow = Color3.fromRGB(255, 215, 70),
	ledRed = Color3.fromRGB(255, 82, 82),
	ledOff = Color3.fromRGB(95, 102, 112),
	consoleBlue = Color3.fromRGB(64, 172, 255),
}

return PlotConstants
