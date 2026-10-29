extends TestCase
## VMess, Trojan, Shadowsocks, Hysteria2, TUIC, AnyTLS, SOCKS, WireGuard and
## sing-box JSON parsers.

const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"
const WG_PRIV := "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
const WG_PUB := "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="


func _vmess(d: Dictionary) -> String:
	return "vmess://" + Marshalls.utf8_to_base64(JSON.stringify(d))


func test_vmess_json_ws_tls() -> void:
	var r := VmessParser.parse(_vmess({"v": "2", "ps": "Тест VMess", "add": "v.example.com", "port": "443", "id": UUID,
		"aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": "cdn.example.com", "path": "/ray", "tls": "tls", "sni": "v.example.com"}))
	if not ok_result(r):
		return
	var o: Dictionary = r.profile.outbound
	eq(o.type, "vmess")
	eq(o.server_port, 443)
	eq(o.security, "auto")
	eq(o.transport, {"type": "ws", "path": "/ray", "headers": {"Host": "cdn.example.com"}})
	eq(o.tls.server_name, "v.example.com")
	eq(r.profile.name, "Тест VMess")


func test_vmess_grpc_and_errors() -> void:
	var r := VmessParser.parse(_vmess({"add": "g.example.com", "port": 443, "id": UUID, "net": "grpc", "path": "svc", "tls": "tls"}))
	if ok_result(r):
		eq(r.profile.outbound.transport, {"type": "grpc", "service_name": "svc"})
	err_result(VmessParser.parse("vmess://%%%notbase64"), "base64")
	err_result(VmessParser.parse("vmess://" + Marshalls.utf8_to_base64("not json")), "json")
	err_result(VmessParser.parse(_vmess({"add": "a.com", "port": "x", "id": UUID})), "port")
	err_result(VmessParser.parse(_vmess({"add": "a.com", "port": 443, "id": UUID, "scy": "rc4"})), "cipher")
	err_result(VmessParser.parse(_vmess({"add": "a.com", "port": 443, "id": UUID, "net": "tcp", "type": "http"})), "header")
	err_result(VmessParser.parse(_vmess({"add": "a.com", "port": 443, "id": UUID, "net": "xhttp"})), "xhttp")


func test_trojan() -> void:
	var r := TrojanParser.parse("trojan://p%40ss%3Aword@t.example.com:443?sni=front.example.com&type=grpc&serviceName=gun#Trojan")
	if not ok_result(r):
		return
	var o: Dictionary = r.profile.outbound
	eq(o.password, "p@ss:word")
	eq(o.tls.server_name, "front.example.com")
	eq(o.transport.type, "grpc")
	err_result(TrojanParser.parse("trojan://@t.example.com:443"), "password")


func test_shadowsocks_sip002_and_legacy() -> void:
	var userinfo := Marshalls.utf8_to_base64("chacha20-ietf-poly1305:secret").replace("=", "").replace("+", "-").replace("/", "_")
	var r := ShadowsocksParser.parse("ss://%s@s.example.com:8388#SS%%20Test" % userinfo)
	if ok_result(r):
		eq(r.profile.outbound.method, "chacha20-ietf-poly1305")
		eq(r.profile.outbound.password, "secret")
		eq(r.profile.name, "SS Test")
	var legacy := "ss://" + Marshalls.utf8_to_base64("aes-256-gcm:pw@1.2.3.4:443") + "#Legacy"
	var l := ShadowsocksParser.parse(legacy)
	if ok_result(l):
		eq(l.profile.server, "1.2.3.4")
		eq(l.profile.outbound.method, "aes-256-gcm")


func test_shadowsocks_2022() -> void:
	var key := Marshalls.raw_to_base64(PackedByteArray(range(32)))
	var r := ShadowsocksParser.parse("ss://2022-blake3-aes-256-gcm:%s@s.example.com:443#2022" % UriUtil.percent_encode(key))
	if ok_result(r):
		eq(r.profile.outbound.password, key)
		eq(r.profile.transport_label, "SS2022")
	err_result(ShadowsocksParser.parse("ss://2022-blake3-aes-256-gcm:c2hvcnQ%3D@s.example.com:443"), "32 bytes")


func test_shadowsocks_plugin() -> void:
	var userinfo := Marshalls.utf8_to_base64("aes-128-gcm:pw")
	var r := ShadowsocksParser.parse("ss://%s@s.example.com:443/?plugin=obfs-local%%3Bobfs%%3Dhttp%%3Bobfs-host%%3Dexample.com#P" % userinfo)
	if ok_result(r):
		eq(r.profile.outbound.plugin, "obfs-local")
		eq(r.profile.outbound.plugin_opts, "obfs=http;obfs-host=example.com")
	err_result(ShadowsocksParser.parse("ss://%s@s.example.com:443/?plugin=kcptun" % userinfo), "plugin")
	err_result(ShadowsocksParser.parse("ss://" + Marshalls.utf8_to_base64("rc5-fake:pw") + "@s.example.com:443"), "method")


func test_hysteria2() -> void:
	var r := QuicParsers.parse_hysteria2("hy2://pass%2Fword@h.example.com:8443/?sni=h.example.com&obfs=salamander&obfs-password=ob&mport=20000-30000#Hy2")
	if not ok_result(r):
		return
	var o: Dictionary = r.profile.outbound
	eq(o.type, "hysteria2")
	eq(o.password, "pass/word")
	eq(o.obfs, {"type": "salamander", "password": "ob"})
	eq(o.server_ports, ["20000:30000"])
	eq(o.tls.server_name, "h.example.com")
	err_result(QuicParsers.parse_hysteria2("hysteria2://p@h.example.com:443?obfs=salamander"), "obfs-password")
	ok_result(QuicParsers.parse_hysteria2("hysteria2://p@h.example.com"), "default port 443")


func test_tuic() -> void:
	var r := QuicParsers.parse_tuic("tuic://%s:pw@t.example.com:443?congestion_control=bbr&alpn=h3&udp_relay_mode=native#TUIC" % UUID)
	if ok_result(r):
		eq(r.profile.outbound.congestion_control, "bbr")
		eq(r.profile.outbound.tls.alpn, ["h3"])
	err_result(QuicParsers.parse_tuic("tuic://notuuid:pw@t.example.com:443"), "uuid")
	err_result(QuicParsers.parse_tuic("tuic://%s:pw@t.example.com:443?congestion_control=hybla" % UUID), "congestion")


func test_anytls_and_socks() -> void:
	var a := QuicParsers.parse_anytls("anytls://secret@a.example.com:443?sni=a.example.com#A")
	if ok_result(a):
		eq(a.profile.outbound.password, "secret")
		eq(a.profile.outbound.tls.enabled, true)
	var s := QuicParsers.parse_socks("socks5://user:p%40ss@10.0.0.1:1080#S")
	if ok_result(s):
		eq(s.profile.outbound.username, "user")
		eq(s.profile.outbound.password, "p@ss")
		eq(s.profile.outbound.version, "5")


func test_wireguard_conf() -> void:
	var conf := "[Interface]\nPrivateKey = %s\nAddress = 10.7.0.2/32, fd00::2/128\nDNS = 1.1.1.1\nMTU = 1420\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = wg.example.com:51820\nPersistentKeepalive = 25\n" % [WG_PRIV, WG_PUB]
	var r := WireGuardParser.parse_conf(conf, "WG")
	if not ok_result(r):
		return
	var p: ProfileModel = r.profile
	eq(p.is_endpoint, true)
	eq(p.server, "wg.example.com")
	eq(p.port, 51820)
	eq(p.outbound.address, ["10.7.0.2/32", "fd00::2/128"])
	eq(p.outbound.peers[0].persistent_keepalive_interval, 25)
	eq(p.outbound.mtu, 1420)
	err_result(WireGuardParser.parse_conf(conf.replace(WG_PRIV, "short"), ""), "privatekey")
	err_result(WireGuardParser.parse_conf(conf + "Jc = 4\n".replace("Jc", "[Interface]\nJc"), ""))


func test_singbox_json_import_preserves_unknown_fields() -> void:
	var cfg := {"outbounds": [
		{"type": "vless", "tag": "my-vless", "server": "x.example.com", "server_port": 443, "uuid": UUID,
			"tls": {"enabled": true, "server_name": "x.example.com"}, "future_field": {"a": 1}},
		{"type": "direct", "tag": "direct"},
		{"type": "naive", "tag": "nv", "server": "n.example.com", "server_port": 443},
		{"type": "vless", "tag": "chained", "server": "y.example.com", "server_port": 443, "uuid": UUID, "detour": "my-vless"},
	], "endpoints": [{"type": "wireguard", "tag": "wg", "address": ["10.0.0.2/32"], "private_key": WG_PRIV,
		"peers": [{"address": "1.2.3.4", "port": 51820, "public_key": WG_PUB, "allowed_ips": ["0.0.0.0/0"]}]}]}
	var r := SingBoxJsonParser.parse(JSON.stringify(cfg))
	if not ok_result(r):
		return
	eq(r.profiles.size(), 2, "vless + wireguard")
	var v: ProfileModel = r.profiles[0]
	eq(v.name, "my-vless")
	eq(v.outbound.future_field, {"a": 1}, "unknown fields preserved")
	check(not v.outbound.has("tag"), "tag stripped")
	check(str(r.warnings).contains("Naive"), "naive reported as not built")
	check(str(r.warnings).contains("detour"), "chained outbound reported")
	eq(r.is_full_config, true)


func test_singbox_json_rejects_garbage() -> void:
	err_result(SingBoxJsonParser.parse("{\"hello\": 1}"))
	err_result(SingBoxJsonParser.parse("[1,2,3]"), "no supported")
	err_result(SingBoxJsonParser.parse("{bad json"))
	err_result(SingBoxJsonParser.parse(JSON.stringify({"outbounds": [{"type": "vless", "server": "a.com", "server_port": 443, "uuid": UUID,
		"transport": {"type": "xhttp"}}]})))


func test_secret_masking() -> void:
	var text := "vless://%s@host.com:443?pbk=KEY123&sid=abcd#x password=hunter2 {\"password\": \"p\", \"uuid\": \"u\"}" % UUID
	var m := SecretMasker.mask(text)
	check(not m.contains(UUID), "uuid masked: " + m)
	check(not m.contains("KEY123"), "pbk masked")
	check(not m.contains("\"p\""), "json password masked")
	var mv: Dictionary = SecretMasker.mask_value({"uuid": UUID, "server": "a.com", "tls": {"reality": {"public_key": "k"}}})
	eq(mv.uuid, SecretMasker.MASK)
	eq(mv.server, "a.com")
	eq(mv.tls.reality.public_key, SecretMasker.MASK)
