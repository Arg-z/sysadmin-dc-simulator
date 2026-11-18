--!strict
--[[
	HardwareCatalog (ModuleScript, ReplicatedStorage/Shared)
	Katalog hardware: harga, ukuran U, specs, warna visual, deskripsi.
]]

export type ItemCategory = "Rack" | "Network" | "Server" | "Component" | "Cable"

export type ItemDef = {
	id: string,
	name: string,
	category: ItemCategory,
	price: number,
	uSize: number,
	description: string,
	specs: { [string]: number },
	visualColor: Color3,
}

local Catalog = {}

local ITEMS: { [string]: ItemDef } = {}

local function addItem(def: ItemDef)
	ITEMS[def.id] = def
end

-- ===== Racks =====
addItem({
	id = "rack_12u",
	name = "Server Rack 12U",
	category = "Rack",
	price = 400,
	uSize = 12,
	description = "Rack 12U dengan PDU 3000W. Tempat mount device rackable.",
	specs = { maxU = 12, maxPowerWatts = 3000, idleWatts = 40 },
	visualColor = Color3.fromRGB(52, 56, 62),
})
addItem({
	id = "rack_24u",
	name = "Server Rack 24U",
	category = "Rack",
	price = 950,
	uSize = 24,
	description = "Rack 24U dengan PDU 6000W. Kapasitas dobel.",
	specs = { maxU = 24, maxPowerWatts = 6000, idleWatts = 60 },
	visualColor = Color3.fromRGB(52, 56, 62),
})

-- ===== Network =====
addItem({
	id = "switch_8p",
	name = "Gigabit Switch 8-Port",
	category = "Network",
	price = 250,
	uSize = 1,
	description = "8x RJ45. Distribusi LAN dasar.",
	specs = { ports = 8, sfpPorts = 0, wanPorts = 0, powerWatts = 30 },
	visualColor = Color3.fromRGB(55, 58, 66),
})
addItem({
	id = "switch_24p",
	name = "Gigabit Switch 24-Port",
	category = "Network",
	price = 650,
	uSize = 1,
	description = "24x RJ45 + 2x SFP. Untuk kolokasi skala besar.",
	specs = { ports = 24, sfpPorts = 2, wanPorts = 0, powerWatts = 60 },
	visualColor = Color3.fromRGB(55, 58, 66),
})
addItem({
	id = "router_edge",
	name = "Edge Router",
	category = "Network",
	price = 500,
	uSize = 1,
	description = "2x WAN + 4x RJ45. Gateway antar subnet/VLAN.",
	specs = { ports = 4, sfpPorts = 0, wanPorts = 2, powerWatts = 40 },
	visualColor = Color3.fromRGB(60, 62, 70),
})

-- ===== Bare-Metal =====
addItem({
	id = "bm_starter",
	name = "Bare-Metal Starter",
	category = "Server",
	price = 800,
	uSize = 2,
	description = "8 vCPU / 16GB RAM / 500GB Disk / 450W.",
	specs = { cpu = 8, ram = 16, disk = 500, powerWatts = 450, ports = 1, sfpPorts = 0, wanPorts = 0 },
	visualColor = Color3.fromRGB(64, 68, 76),
})
addItem({
	id = "bm_enterprise",
	name = "Bare-Metal Enterprise",
	category = "Server",
	price = 2200,
	uSize = 2,
	description = "32 vCPU / 128GB RAM / 2TB Disk / 750W.",
	specs = { cpu = 32, ram = 128, disk = 2000, powerWatts = 750, ports = 2, sfpPorts = 0, wanPorts = 0 },
	visualColor = Color3.fromRGB(40, 42, 48),
})

-- ===== Components (Custom Build) =====
addItem({
	id = "chassis_1u",
	name = "Chassis 1U",
	category = "Component",
	price = 150,
	uSize = 1,
	description = "Casing rack 1U untuk custom build (1x RJ45 terpasang).",
	specs = { uSize = 1, width = 4.2, ports = 1, sfpPorts = 0, wanPorts = 0 },
	visualColor = Color3.fromRGB(70, 72, 78),
})
addItem({
	id = "chassis_2u",
	name = "Chassis 2U",
	category = "Component",
	price = 220,
	uSize = 2,
	description = "Casing rack 2U, lebih lega (1x RJ45 terpasang).",
	specs = { uSize = 2, width = 4.6, ports = 1, sfpPorts = 0, wanPorts = 0 },
	visualColor = Color3.fromRGB(70, 72, 78),
})
addItem({
	id = "mobo_single",
	name = "Motherboard Single-Socket",
	category = "Component",
	price = 200,
	uSize = 0,
	description = "1 socket CPU, 2 slot RAM, 2 bay storage.",
	specs = { sockets = 1, ramSlots = 2, storageBays = 2 },
	visualColor = Color3.fromRGB(40, 90, 55),
})
addItem({
	id = "mobo_dual",
	name = "Motherboard Dual-Socket",
	category = "Component",
	price = 450,
	uSize = 0,
	description = "2 socket CPU, 4 slot RAM, 3 bay storage.",
	specs = { sockets = 2, ramSlots = 4, storageBays = 3 },
	visualColor = Color3.fromRGB(40, 90, 55),
})
addItem({
	id = "cpu_xeon8",
	name = "CPU Xeon 8-Core",
	category = "Component",
	price = 300,
	uSize = 0,
	description = "8 vCPU untuk host bare-metal.",
	specs = { cores = 8 },
	visualColor = Color3.fromRGB(150, 150, 155),
})
addItem({
	id = "cpu_epyc32",
	name = "CPU EPYC 32-Core",
	category = "Component",
	price = 850,
	uSize = 0,
	description = "32 vCPU untuk host bare-metal.",
	specs = { cores = 32 },
	visualColor = Color3.fromRGB(150, 150, 155),
})
addItem({
	id = "ram_32g",
	name = "RAM 32GB ECC",
	category = "Component",
	price = 120,
	uSize = 0,
	description = "32GB memory per module.",
	specs = { ramGb = 32 },
	visualColor = Color3.fromRGB(50, 200, 130),
})
addItem({
	id = "ram_128g",
	name = "RAM 128GB ECC",
	category = "Component",
	price = 420,
	uSize = 0,
	description = "128GB memory per module.",
	specs = { ramGb = 128 },
	visualColor = Color3.fromRGB(50, 200, 130),
})
addItem({
	id = "nvme_1tb",
	name = "NVMe 1TB",
	category = "Component",
	price = 140,
	uSize = 0,
	description = "Storage 1000GB per drive.",
	specs = { storageGb = 1000 },
	visualColor = Color3.fromRGB(35, 35, 40),
})
addItem({
	id = "psu_redundant",
	name = "PSU Redundant 750W",
	category = "Component",
	price = 180,
	uSize = 0,
	description = "Power supply 750W untuk menyalakan build.",
	specs = { powerWatts = 750 },
	visualColor = Color3.fromRGB(45, 45, 50),
})
addItem({
	id = "replacement_hdd",
	name = "Replacement HDD",
	category = "Component",
	price = 90,
	uSize = 0,
	description = "Drive pengganti untuk Remote Hands (Fase 2).",
	specs = { storageGb = 500 },
	visualColor = Color3.fromRGB(35, 35, 40),
})

-- ===== Cables (aktif penuh di Fase 2) =====
addItem({
	id = "cable_lan_blue",
	name = "Cable Spool LAN Blue",
	category = "Cable",
	price = 15,
	uSize = 0,
	description = "Kabel patch LAN biru (Fase 2: manual cabling).",
	specs = {},
	visualColor = Color3.fromRGB(70, 130, 255),
})
addItem({
	id = "cable_wan_yellow",
	name = "Cable Spool WAN Yellow",
	category = "Cable",
	price = 15,
	uSize = 0,
	description = "Kabel WAN kuning (Fase 2: manual cabling).",
	specs = {},
	visualColor = Color3.fromRGB(240, 210, 70),
})
addItem({
	id = "cable_mgmt_red",
	name = "Cable Spool Mgmt Red",
	category = "Cable",
	price = 15,
	uSize = 0,
	description = "Kabel management merah (Fase 2: manual cabling).",
	specs = {},
	visualColor = Color3.fromRGB(230, 80, 80),
})

Catalog.Items = ITEMS

function Catalog.Get(itemId: string): ItemDef?
	return ITEMS[itemId]
end

function Catalog.IsPlaceable(itemId: string): boolean
	local def = ITEMS[itemId]
	if def == nil then
		return false
	end
	return def.category == "Rack" or def.category == "Network" or def.category == "Server"
end

Catalog.StoreCategories = { "Rack", "Network", "Server", "Component" }

function Catalog.ListByCategory(category: ItemCategory): { ItemDef }
	local out: { ItemDef } = {}
	for _, def in pairs(ITEMS) do
		if def.category == category then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.price < b.price
	end)
	return out
end

return Catalog
