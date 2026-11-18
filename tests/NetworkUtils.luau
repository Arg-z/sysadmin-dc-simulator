--!strict
--[[
	NetworkUtils (ModuleScript, ReplicatedStorage/Shared)
	Utilitas jaringan murni & deterministik: validasi IPv4, subnet bitwise,
	generator IP, formatter currency/watt/uptime, escape RichText.
	Tidak menyentuh API Roblox -> bisa di-unit-test dengan luau CLI.
]]

local NetworkUtils = {}

function NetworkUtils.IsValidIPv4(ip: string): boolean
	if type(ip) ~= "string" or #ip == 0 or #ip > 15 then
		return false
	end
	local parts = string.split(ip, ".")
	if #parts ~= 4 then
		return false
	end
	for _, p in ipairs(parts) do
		if #p == 0 or #p > 3 then
			return false
		end
		for i = 1, #p do
			local ch = string.sub(p, i, i)
			if ch < "0" or ch > "9" then
				return false
			end
		end
		local n = tonumber(p)
		if n == nil then
			return false
		end
		if n < 0 or n > 255 then
			return false
		end
		if #p > 1 and string.sub(p, 1, 1) == "0" then
			return false
		end
	end
	return true
end

function NetworkUtils.IPToNumber(ip: string): number
	local parts = string.split(ip, ".")
	local n = 0
	for _, p in ipairs(parts) do
		n = bit32.bor(bit32.lshift(n, 8), tonumber(p) or 0)
	end
	return n
end

function NetworkUtils.NumberToIP(n: number): string
	local a = bit32.band(bit32.rshift(n, 24), 255)
	local b = bit32.band(bit32.rshift(n, 16), 255)
	local c = bit32.band(bit32.rshift(n, 8), 255)
	local d = bit32.band(n, 255)
	return string.format("%d.%d.%d.%d", a, b, c, d)
end

function NetworkUtils.MaskToPrefix(mask: string): number
	local n = NetworkUtils.IPToNumber(mask)
	local prefix = 0
	for i = 31, 0, -1 do
		if bit32.band(bit32.rshift(n, i), 1) == 1 then
			prefix += 1
		else
			break
		end
	end
	return prefix
end

function NetworkUtils.IsSameSubnet(ipA: string, ipB: string, mask: string): boolean
	if not NetworkUtils.IsValidIPv4(ipA) or not NetworkUtils.IsValidIPv4(ipB) or not NetworkUtils.IsValidIPv4(mask) then
		return false
	end
	local m = NetworkUtils.IPToNumber(mask)
	return bit32.band(NetworkUtils.IPToNumber(ipA), m) == bit32.band(NetworkUtils.IPToNumber(ipB), m)
end

function NetworkUtils.IsPrivateIP(ip: string): boolean
	if not NetworkUtils.IsValidIPv4(ip) then
		return false
	end
	local parts = string.split(ip, ".")
	local a = tonumber(parts[1]) or 0
	local b = tonumber(parts[2]) or 0
	if a == 10 or a == 127 then
		return true
	end
	if a == 172 and b >= 16 and b <= 31 then
		return true
	end
	if a == 192 and b == 168 then
		return true
	end
	return false
end

function NetworkUtils.GenerateRandomPublicIP(): string
	return string.format("203.0.113.%d", math.random(2, 254))
end

function NetworkUtils.GenerateInternalIP(index: number): string
	local last = math.clamp(index, 2, 254)
	return string.format("10.0.0.%d", last)
end

function NetworkUtils.FormatCurrency(amount: number): string
	local negative = amount < 0
	local n = math.floor(math.abs(amount) + 0.5)
	local s = tostring(n)
	local formatted = s
	while true do
		local k
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then
			break
		end
	end
	local prefix = if negative then "-$" else "$"
	return prefix .. formatted
end

function NetworkUtils.FormatWatts(watts: number): string
	return string.format("%d W", math.floor(watts + 0.5))
end

function NetworkUtils.FormatUptime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local days = math.floor(s / 86400)
	local hours = math.floor((s % 86400) / 3600)
	local minutes = math.floor((s % 3600) / 60)
	if days > 0 then
		return string.format("%dd %dh %02dm", days, hours, minutes)
	end
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%dm", minutes)
end

function NetworkUtils.EscapeRich(text: string): string
	local out = text
	out = string.gsub(out, "&", "&amp;")
	out = string.gsub(out, "<", "&lt;")
	out = string.gsub(out, ">", "&gt;")
	return out
end

return NetworkUtils
