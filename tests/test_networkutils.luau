--!strict
--[[
	Unit tests for NetworkUtils (pure module, no Roblox API).
	Run: tools/luau tests/test_networkutils.luau  (from /data/workspace/netsim)
	Exits non-zero when any assertion fails.
]]

local Utils = require("./NetworkUtils")

local passCount = 0
local failCount = 0

local function check(name: string, actual: any, expected: any)
	if actual == expected then
		passCount += 1
		print(string.format("PASS  %s", name))
	else
		failCount += 1
		print(string.format("FAIL  %s  expected=%s actual=%s", name, tostring(expected), tostring(actual)))
	end
end

print("== NetworkUtils.IsValidIPv4 ==")
check("valid simple", Utils.IsValidIPv4("192.168.1.1"), true)
check("valid zeros", Utils.IsValidIPv4("0.0.0.0"), true)
check("valid max", Utils.IsValidIPv4("255.255.255.255"), true)
check("valid mixed", Utils.IsValidIPv4("203.0.113.254"), true)
check("leading zero octet", Utils.IsValidIPv4("01.2.3.4"), false)
check("leading zero octet long", Utils.IsValidIPv4("192.168.001.1"), false)
check("out of range 256", Utils.IsValidIPv4("256.1.1.1"), false)
check("out of range 999", Utils.IsValidIPv4("1.2.3.999"), false)
check("out of range 300", Utils.IsValidIPv4("300.0.0.1"), false)
check("non-numeric letters", Utils.IsValidIPv4("a.b.c.d"), false)
check("non-numeric mixed", Utils.IsValidIPv4("1.2.3.4x"), false)
check("non-numeric hex", Utils.IsValidIPv4("0x1.2.3.4"), false)
check("negative octet", Utils.IsValidIPv4("-1.2.3.4"), false)
check("wrong octet count 3", Utils.IsValidIPv4("1.2.3"), false)
check("wrong octet count 5", Utils.IsValidIPv4("1.2.3.4.5"), false)
check("empty string", Utils.IsValidIPv4(""), false)
check("empty octet", Utils.IsValidIPv4("1..2.3"), false)
check("leading space", Utils.IsValidIPv4(" 1.2.3.4"), false)
check("trailing space", Utils.IsValidIPv4("1.2.3.4 "), false)
check("inner space", Utils.IsValidIPv4("1. 2.3.4"), false)
check("nil input", Utils.IsValidIPv4(nil), false)
check("too long (>15 chars)", Utils.IsValidIPv4("1234.1234.1.1"), false)
check("length exactly 15", Utils.IsValidIPv4("123.123.123.123"), true)

print("== IPToNumber / NumberToIP roundtrip ==")
check("IPToNumber 0.0.0.0", Utils.IPToNumber("0.0.0.0"), 0)
check("IPToNumber 255.255.255.255", Utils.IPToNumber("255.255.255.255"), 4294967295)
check("IPToNumber 192.168.1.1", Utils.IPToNumber("192.168.1.1"), 3232235777)
check("IPToNumber 10.0.0.2", Utils.IPToNumber("10.0.0.2"), 167772162)
check("NumberToIP 0", Utils.NumberToIP(0), "0.0.0.0")
check("NumberToIP max", Utils.NumberToIP(4294967295), "255.255.255.255")
check("NumberToIP 3232235777", Utils.NumberToIP(3232235777), "192.168.1.1")
check("roundtrip 8.8.8.8", Utils.NumberToIP(Utils.IPToNumber("8.8.8.8")), "8.8.8.8")
check("roundtrip 172.16.5.200", Utils.NumberToIP(Utils.IPToNumber("172.16.5.200")), "172.16.5.200")
check("roundtrip 203.0.113.99", Utils.NumberToIP(Utils.IPToNumber("203.0.113.99")), "203.0.113.99")

print("== MaskToPrefix ==")
check("/8", Utils.MaskToPrefix("255.0.0.0"), 8)
check("/16", Utils.MaskToPrefix("255.255.0.0"), 16)
check("/24", Utils.MaskToPrefix("255.255.255.0"), 24)
check("/32", Utils.MaskToPrefix("255.255.255.255"), 32)
check("/0", Utils.MaskToPrefix("0.0.0.0"), 0)
check("/25", Utils.MaskToPrefix("255.255.255.128"), 25)
check("discontiguous mask stops at first zero", Utils.MaskToPrefix("255.0.255.0"), 8)

print("== IsSameSubnet ==")
check("same /24 true", Utils.IsSameSubnet("192.168.1.5", "192.168.1.99", "255.255.255.0"), true)
check("different /24 false", Utils.IsSameSubnet("192.168.1.5", "192.168.2.5", "255.255.255.0"), false)
check("different host /16 true", Utils.IsSameSubnet("192.168.1.5", "192.168.2.5", "255.255.0.0"), true)
check("gateway same subnet", Utils.IsSameSubnet("192.168.1.10", "192.168.1.1", "255.255.255.0"), true)
check("cross class /8", Utils.IsSameSubnet("10.1.2.3", "10.200.201.202", "255.0.0.0"), true)
check("identical ips any mask", Utils.IsSameSubnet("10.0.0.1", "10.0.0.1", "255.255.255.0"), true)
check("invalid ip arg -> false", Utils.IsSameSubnet("999.1.1.1", "192.168.1.5", "255.255.255.0"), false)
check("invalid mask arg -> false", Utils.IsSameSubnet("192.168.1.5", "192.168.1.9", "255.255"), false)
-- Locked documented behavior: a discontiguous but IPv4-valid mask is accepted (pure bitwise compare, per contract).
check("discontiguous valid mask -> bitwise semantics", Utils.IsSameSubnet("192.168.1.5", "192.168.1.9", "255.255.2.0"), true)

print("== IsPrivateIP ==")
check("10.x true", Utils.IsPrivateIP("10.0.0.5"), true)
check("10.255.x true", Utils.IsPrivateIP("10.255.255.255"), true)
check("127.x true", Utils.IsPrivateIP("127.0.0.1"), true)
check("172.16 true", Utils.IsPrivateIP("172.16.0.1"), true)
check("172.31 true", Utils.IsPrivateIP("172.31.255.255"), true)
check("192.168 true", Utils.IsPrivateIP("192.168.1.1"), true)
check("172.32 false", Utils.IsPrivateIP("172.32.0.1"), false)
check("172.15 false", Utils.IsPrivateIP("172.15.255.1"), false)
check("192.169 false", Utils.IsPrivateIP("192.169.0.1"), false)
check("8.8.8.8 false", Utils.IsPrivateIP("8.8.8.8"), false)
check("public 203.0.113.x false", Utils.IsPrivateIP("203.0.113.7"), false)
check("invalid string false", Utils.IsPrivateIP("not-an-ip"), false)

print("== GenerateInternalIP ==")
check("normal index", Utils.GenerateInternalIP(3), "10.0.0.3")
check("clamp below 2 (0)", Utils.GenerateInternalIP(0), "10.0.0.2")
check("clamp below 2 (1)", Utils.GenerateInternalIP(1), "10.0.0.2")
check("clamp at 2", Utils.GenerateInternalIP(2), "10.0.0.2")
check("clamp at 254", Utils.GenerateInternalIP(254), "10.0.0.254")
check("clamp above 254 (255)", Utils.GenerateInternalIP(255), "10.0.0.254")
check("clamp far above (1000)", Utils.GenerateInternalIP(1000), "10.0.0.254")

print("== GenerateRandomPublicIP (range sanity) ==")
local publicOk = true
for _ = 1, 200 do
	local ip = Utils.GenerateRandomPublicIP()
	local p = string.split(ip, ".")
	if p[1] ~= "203" or p[2] ~= "0" or p[3] ~= "113" then
		publicOk = false
	else
		local last = tonumber(p[4]) or -1
		if last < 2 or last > 254 then
			publicOk = false
		end
	end
end
check("200 samples all 203.0.113.[2..254]", publicOk, true)

print("== FormatCurrency ==")
check("0", Utils.FormatCurrency(0), "$0")
check("999", Utils.FormatCurrency(999), "$999")
check("1000", Utils.FormatCurrency(1000), "$1,000")
check("1234567", Utils.FormatCurrency(1234567), "$1,234,567")
check("-250", Utils.FormatCurrency(-250), "-$250")
check("-0 -> $0", Utils.FormatCurrency(0 - 0), "$0")
check("rounds 250.6 -> $251", Utils.FormatCurrency(250.6), "$251")
check("negative thousand", Utils.FormatCurrency(-1234567), "-$1,234,567")

print("== FormatWatts ==")
check("0 W", Utils.FormatWatts(0), "0 W")
check("450 W", Utils.FormatWatts(450), "450 W")
check("rounds 299.5 -> 300 W", Utils.FormatWatts(299.5), "300 W")

print("== FormatUptime ==")
check("59s -> 0m", Utils.FormatUptime(59), "0m")
check("60s -> 1m", Utils.FormatUptime(60), "1m")
check("3600s -> 1h 00m", Utils.FormatUptime(3600), "1h 00m")
check("3661s -> 1h 01m", Utils.FormatUptime(3661), "1h 01m")
check("90000s -> 1d 1h 00m", Utils.FormatUptime(90000), "1d 1h 00m")
check("86400s -> 1d 0h 00m", Utils.FormatUptime(86400), "1d 0h 00m")
check("negative clamps to 0m", Utils.FormatUptime(-5), "0m")

print("== EscapeRich ==")
check("amp only", Utils.EscapeRich("a&b"), "a&amp;b")
check("lt only", Utils.EscapeRich("<b>"), "&lt;b&gt;")
check("combined", Utils.EscapeRich("a&b<c>d"), "a&amp;b&lt;c&gt;d")
check("already-escaped entity stays literal-safe", Utils.EscapeRich("&lt;"), "&amp;lt;")
check("plain text unchanged", Utils.EscapeRich("ping 192.168.1.1"), "ping 192.168.1.1")
check("empty string", Utils.EscapeRich(""), "")

print("")
print(string.format("SUMMARY: %d passed, %d failed, %d total", passCount, failCount, passCount + failCount))
if failCount > 0 then
	error(string.format("TESTS FAILED: %d of %d assertions failed", failCount, passCount + failCount))
end
print("ALL TESTS PASSED")
