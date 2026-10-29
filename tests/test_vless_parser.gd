extends TestCase
## VLESS share-link parser tests.

const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"
const PBK := "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"


func test_basic_tcp() -> void:
	var r := VlessParser.parse("vless://%s@example.com:443?encryption=none&type=tcp#Basic" % UUID)
	if not ok_result(r):
		return
	var p: ProfileModel = r.profile
	eq(p.protocol, "vless")
	eq(p.server, "example.com")
	eq(p.port, 443)
	eq(p.name, "Basic")
	eq(p.outbound.uuid, UUID)
	check(not p.outbound.has("tls"), "no tls expected")
	check(not p.outbound.has("transport"), "raw tcp has no transport object")


func test_reality() -> void:
	var link := "vless://%s@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=6ba85179e30d4fc2&spx=%%2F&type=tcp&headerType=none#Reality%%20NL" % [UUID, PBK]
	var r := VlessParser.parse(link)
	if not ok_result(r):
		return
	var o: Dictionary = r.profile.outbound
	eq(o.flow, "xtls-rprx-vision")
	eq(o.tls.server_name, "www.microsoft.com")
	eq(o.tls.reality.public_key, PBK)
	eq(o.tls.reality.short_id, "6ba85179e30d4fc2")
	eq(o.tls.utls.fingerprint, "chrome")
	eq(r.profile.name, "Reality NL")
	eq(r.profile.transport_label, "Reality")


func test_reality_requires_pbk() -> void:
	err_result(VlessParser.parse("vless://%s@h.com:443?security=reality&sni=a.com" % UUID), "public key")


func test_tls_alpn_sni_defaults() -> void:
	var r := VlessParser.parse("vless://%s@srv.example.org:8443?security=tls&alpn=h2,http/1.1&fp=firefox" % UUID)
	if not ok_result(r):
		return
	var tls: Dictionary = r.profile.outbound.tls
	eq(tls.server_name, "srv.example.org", "sni defaults to host")
	eq(tls.alpn, ["h2", "http/1.1"])
	eq(tls.utls.fingerprint, "firefox")
	check(not tls.has("insecure"), "insecure must not be set by default")


func test_websocket_with_early_data() -> void:
	var r := VlessParser.parse("vless://%s@cdn.example.com:443?type=ws&security=tls&path=%%2Fws%%3Fed%%3D2048&host=front.example.com#WS" % UUID)
	if not ok_result(r):
		return
	var t: Dictionary = r.profile.outbound.transport
	eq(t.type, "ws")
	eq(t.path, "/ws")
	eq(t.max_early_data, 2048)
	eq(t.early_data_header_name, "Sec-WebSocket-Protocol")
	eq(t.headers.Host, "front.example.com")
	eq(r.profile.transport_label, "WS+TLS")


func test_grpc() -> void:
	var r := VlessParser.parse("vless://%s@g.example.com:443?type=grpc&serviceName=my%%2Fsvc&security=tls&mode=multi" % UUID)
	if not ok_result(r):
		return
	eq(r.profile.outbound.transport, {"type": "grpc", "service_name": "my/svc"})
	check(r.warnings.size() > 0, "multi mode should produce a warning")


func test_httpupgrade() -> void:
	var r := VlessParser.parse("vless://%s@h.example.com:80?type=httpupgrade&path=/up&host=x.com" % UUID)
	if ok_result(r):
		eq(r.profile.outbound.transport, {"type": "httpupgrade", "path": "/up", "host": "x.com"})


func test_xhttp_goes_to_xray() -> void:
	var r := VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&security=tls&sni=h.example.com&path=%%2Fx&mode=packet-up&extra=%%7B%%22xPaddingBytes%%22%%3A%%22100-1000%%22%%7D#XH" % UUID)
	if not ok_result(r):
		return
	var p: ProfileModel = r.profile
	eq(p.engine, "xray")
	eq(p.server, "h.example.com")
	var ss: Dictionary = p.outbound.streamSettings
	eq(ss.network, "xhttp")
	eq(ss.xhttpSettings.path, "/x")
	eq(ss.xhttpSettings.mode, "packet-up")
	eq(ss.xhttpSettings.extra, {"xPaddingBytes": "100-1000"})
	eq(ss.tlsSettings.serverName, "h.example.com")
	eq(p.outbound.settings.vnext[0].users[0].id, UUID)
	check(p.protocol_label().contains("Xray"), "label shows the engine")
	ok_result(VlessParser.parse("vless://%s@h.example.com:443?type=splithttp&path=/s" % UUID), "splithttp alias")
	err_result(VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&mode=weird" % UUID), "mode")
	err_result(VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&extra=notjson" % UUID), "extra")
	err_result(VlessParser.parse("vless://%s@h.example.com:443?type=kcp" % UUID), "kcp")


func test_vless_encryption_goes_to_xray() -> void:
	var r := VlessParser.parse("vless://%s@e.example.com:443?type=tcp&security=reality&sni=a.com&pbk=%s&sid=ab&pqv=XYZ&encryption=mlkem768x25519plus.native.0rtt.KEY#E" % [UUID, PBK])
	if not ok_result(r):
		return
	eq(r.profile.engine, "xray")
	eq(r.profile.outbound.settings.vnext[0].users[0].encryption, "mlkem768x25519plus.native.0rtt.KEY")
	eq(r.profile.outbound.streamSettings.realitySettings.mldsa65Verify, "XYZ", "pqv honoured by Xray")


func test_xray_certificate_pinning() -> void:
	var pin := "AB:CD:".repeat(16).trim_suffix(":")
	var r := VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&security=tls&pcs=%s&allowInsecure=1#P" % [UUID, pin])
	if ok_result(r):
		eq(r.profile.outbound.streamSettings.tlsSettings.pinnedPeerCertSha256, pin)
		check(not r.profile.outbound.streamSettings.tlsSettings.has("allowInsecure"), "allowInsecure never emitted for Xray")
	err_result(VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&security=tls&pcs=1234" % UUID), "pcs")
	var w := VlessParser.parse("vless://%s@h.example.com:443?type=xhttp&security=tls&allowInsecure=1#W" % UUID)
	if ok_result(w):
		check(str(w.warnings).contains("verified"), "user is told the certificate will be verified")
		check(not w.profile.is_insecure_tls(), "not marked insecure: Xray verifies")


func test_missing_port() -> void:
	err_result(VlessParser.parse("vless://%s@example.com?type=tcp" % UUID), "port")


func test_missing_host() -> void:
	err_result(VlessParser.parse("vless://%s@:443" % UUID), "server address")


func test_invalid_uuid() -> void:
	err_result(VlessParser.parse("vless://b831381d-6324-4d53-ad4f-8cda48b3081@e.com:443"), "uuid")
	err_result(VlessParser.parse("vless://@e.com:443"), "uuid")


func test_custom_id_mapped_to_uuidv5() -> void:
	# Xray/sing-box accept short non-UUID ids (mapped to UUIDv5).
	ok_result(VlessParser.parse("vless://myuser@e.com:443"))


func test_invalid_port() -> void:
	err_result(VlessParser.parse("vless://%s@e.com:70000" % UUID), "port")
	err_result(VlessParser.parse("vless://%s@e.com:0" % UUID), "port")
	err_result(VlessParser.parse("vless://%s@e.com:44a3" % UUID), "port")


func test_bad_percent_encoding() -> void:
	err_result(VlessParser.parse("vless://%s@e.com:443?path=%%2G&type=ws" % UUID), "percent")
	err_result(VlessParser.parse("vless://%s@e.com:443?sni=a%%2" % UUID), "percent")


func test_special_characters_and_cyrillic_name() -> void:
	var r := VlessParser.parse("vless://%s@e.com:443?type=ws&path=%%2Fp%%20a%%2Bb%%26c#%%D0%%A1%%D0%%B5%%D1%%80%%D0%%B2%%D0%%B5%%D1%%80%%20%%F0%%9F%%87%%B3%%F0%%9F%%87%%B1%%20%%231" % UUID)
	if not ok_result(r):
		return
	eq(r.profile.name, "Сервер 🇳🇱 #1")
	eq(r.profile.outbound.transport.path, "/p a+b&c")


func test_raw_cyrillic_fragment() -> void:
	var r := VlessParser.parse("vless://%s@e.com:443#Москва-1" % UUID)
	if ok_result(r):
		eq(r.profile.name, "Москва-1")


func test_ipv6_host() -> void:
	var r := VlessParser.parse("vless://%s@[2001:db8::1]:443" % UUID)
	if ok_result(r):
		eq(r.profile.server, "2001:db8::1")
		eq(r.profile.display_address(), "[2001:db8::1]:443")


func test_unknown_params_are_warnings() -> void:
	var r := VlessParser.parse("vless://%s@e.com:443?foo=1&bar=2" % UUID)
	if ok_result(r):
		check(str(r.warnings).contains("foo"), "unknown params should be reported")


func test_unsupported_critical_params() -> void:
	err_result(VlessParser.parse("vless://%s@e.com:443?flow=xtls-rprx-direct&security=tls" % UUID), "flow")
	err_result(VlessParser.parse("vless://%s@e.com:443?security=xtls" % UUID), "xtls")
	err_result(VlessParser.parse("vless://%s@e.com:443?type=tcp&headerType=http" % UUID), "header")
	err_result(VlessParser.parse("vless://%s@e.com:443?type=kcp" % UUID), "kcp")
	err_result(VlessParser.parse("vless://%s@e.com:443?flow=xtls-rprx-vision" % UUID), "requires tls")


func test_corrupted_links() -> void:
	err_result(VlessParser.parse("vless:/broken"))
	err_result(VlessParser.parse("vless://"))
	err_result(VlessParser.parse("vless://%s@[2001:db8::1:443" % UUID), "ipv6")
	err_result(VlessParser.parse("vless://%s@e.com:443:22" % UUID))
	err_result(LinkParser.parse("not a link at all"))
	err_result(LinkParser.parse("vless://%s@e.com:443?%s" % [UUID, "a".repeat(20000)]), "too long")


func test_allow_insecure_warns() -> void:
	var r := VlessParser.parse("vless://%s@e.com:443?security=tls&allowInsecure=1" % UUID)
	if ok_result(r):
		eq(r.profile.outbound.tls.insecure, true)
		check(str(r.warnings).contains("MITM"), "insecure must be warned about")


func test_dispatcher_and_fingerprint() -> void:
	var a := LinkParser.parse("vless://%s@e.com:443?security=tls#A" % UUID)
	var b := LinkParser.parse("vless://%s@E.com:443?security=tls#B" % UUID)
	if ok_result(a) and ok_result(b):
		eq(a.profile.fingerprint(), b.profile.fingerprint(), "same server, different names => duplicate")
	err_result(LinkParser.parse("ssr://abc"), "shadowsocksr")
	err_result(LinkParser.parse("https://example.com/sub"), "subscription")
