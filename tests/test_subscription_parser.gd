extends TestCase
## Subscription content detection and parsing.

const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"


func _links() -> String:
	return "vless://%s@a.example.com:443?security=tls#A\ntrojan://pw@b.example.com:443#B\nss://%s@c.example.com:8388#C" % [
		UUID, Marshalls.utf8_to_base64("aes-128-gcm:pw")]


func test_plain_links() -> void:
	var r := SubscriptionParser.parse(_links())
	if ok_result(r):
		eq(r.profiles.size(), 3)
		eq(r.format, SubscriptionParser.Format.LINKS)


func test_base64_links_with_crlf_and_bom() -> void:
	var body := Marshalls.utf8_to_base64(_links().replace("\n", "\r\n"))
	var r := SubscriptionParser.parse(char(0xFEFF) + body + "\r\n")
	if ok_result(r):
		eq(r.profiles.size(), 3)
		eq(r.format, SubscriptionParser.Format.BASE64_LINKS)
	var urlsafe := body.replace("+", "-").replace("/", "_").replace("=", "")
	ok_result(SubscriptionParser.parse(urlsafe), "url-safe base64 without padding")


func test_empty_response() -> void:
	err_result(SubscriptionParser.parse(""), "empty")
	err_result(SubscriptionParser.parse("  \n" + char(0xFEFF) + " "), "empty")


func test_invalid_base64() -> void:
	err_result(SubscriptionParser.parse("!!!!not*base64***"))


func test_invalid_utf8() -> void:
	var raw := PackedByteArray([0xff, 0xfe, 0xfd, 0x80, 0x81, 0x41, 0x42])
	var r := SubscriptionParser.parse(Marshalls.raw_to_base64(raw))
	err_result(r, "utf-8")


func test_html_instead_of_subscription() -> void:
	err_result(SubscriptionParser.parse("<!DOCTYPE html><html><body>Login</body></html>"), "html")
	err_result(SubscriptionParser.parse("<html><head></head></html>"), "html")


func test_clash_and_xray_are_reported() -> void:
	err_result(SubscriptionParser.parse("mixed-port: 7890\nproxies:\n  - name: a\n    type: vless"), "clash")
	err_result(SubscriptionParser.parse(JSON.stringify({"outbounds": [{"protocol": "vless", "settings": {}}]})), "xray")


func test_mixed_valid_and_broken_entries() -> void:
	var text := _links() + "\nvless://broken\n# comment line\nnot a link\nssr://abc\n"
	var r := SubscriptionParser.parse(text)
	if ok_result(r):
		eq(r.profiles.size(), 3)
		eq(r.errors.size(), 2, "broken vless + ssr reported")
		eq(r.skipped, 1)
		for e in r.errors:
			check(not e.contains(UUID), "errors must not leak secrets")


func test_duplicates_are_removed() -> void:
	var r := SubscriptionParser.parse(_links() + "\n" + _links())
	if ok_result(r):
		eq(r.profiles.size(), 3)
		eq(r.duplicates, 3)


func test_only_garbage() -> void:
	err_result(SubscriptionParser.parse("hello world\nfoo bar"))
	err_result(SubscriptionParser.parse("vless://broken\nvless://also-broken"), "no valid servers")


func test_user_info_and_title_headers() -> void:
	eq(SubscriptionUpdater.parse_user_info("upload=100; download=200; total=1000; expire=1700000000"),
		{"upload": 100, "download": 200, "total": 1000, "expire": 1700000000})
	eq(SubscriptionUpdater.parse_title("base64:" + Marshalls.utf8_to_base64("Мой VPN")), "Мой VPN")


func test_url_validation() -> void:
	eq(SubscriptionUpdater.validate_url("https://sub.example.com/x?token=1", false), "")
	check(SubscriptionUpdater.validate_url("http://sub.example.com/x", false) != "", "http rejected by default")
	eq(SubscriptionUpdater.validate_url("http://sub.example.com/x", true), "")
	for bad in ["https://127.0.0.1/x", "https://localhost/x", "https://192.168.1.1/", "https://10.0.0.5/",
			"https://[::1]/x", "https://169.254.169.254/latest", "file:///etc/passwd", "https://user:pw@sub.example.com/",
			"https://router.local/x", "ftp://example.com"]:
		check(SubscriptionUpdater.validate_url(bad, true) != "", "must reject " + bad)
	check(SubscriptionUpdater.is_private_ip("100.64.1.1"), "CGNAT")
	check(SubscriptionUpdater.is_private_ip("::ffff:127.0.0.1"), "mapped loopback")
	check(not SubscriptionUpdater.is_private_ip("8.8.8.8"), "public")
