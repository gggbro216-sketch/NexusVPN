extends TestCase
## Generated sing-box configurations: structure checks in GDScript and, when
## NEXUS_SINGBOX_BIN points to a sing-box 1.14 binary, validation with the
## real core ("sing-box check"). Without the binary those checks are SKIPPED.

const UUID := "b831381d-6324-4d53-ad4f-8cda48b30811"
const PBK := "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"
const OUT_DIR := "user://config_check"

var _bin := ""


func setup(_runner: Node) -> void:
	_bin = OS.get_environment("NEXUS_SINGBOX_BIN")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)


static func links() -> Array:
	var ss2022 := Marshalls.raw_to_base64(PackedByteArray(range(32)))
	return [
		"vless://%s@r.example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=6ba85179&flow=xtls-rprx-vision#reality" % [UUID, PBK],
		"vless://%s@t.example.com:443?security=tls&alpn=h2,http/1.1&fp=firefox#tls" % UUID,
		"vless://%s@w.example.com:443?type=ws&security=tls&path=%%2Fws%%3Fed%%3D2048&host=cdn.example.com#ws" % UUID,
		"vless://%s@g.example.com:443?type=grpc&serviceName=svc&security=tls#grpc" % UUID,
		"vless://%s@h.example.com:80?type=httpupgrade&path=/up&host=h.example.com#hu" % UUID,
		"vless://%s@q.example.com:443?type=quic&security=tls#quic" % UUID,
		"vless://%s@h2.example.com:443?type=http&security=tls&path=/h2&host=h2.example.com#h2" % UUID,
		"vmess://" + Marshalls.utf8_to_base64(JSON.stringify({"add": "v.example.com", "port": 443, "id": UUID, "net": "ws", "path": "/v", "tls": "tls", "scy": "auto"})),
		"trojan://pw@tr.example.com:443?sni=tr.example.com#trojan",
		"ss://%s@s.example.com:8388#ss" % Marshalls.utf8_to_base64("chacha20-ietf-poly1305:pw"),
		"ss://2022-blake3-aes-256-gcm:%s@s2.example.com:443#ss2022" % UriUtil.percent_encode(ss2022),
		"ss://%s@s3.example.com:443/?plugin=obfs-local%%3Bobfs%%3Dhttp%%3Bobfs-host%%3Dexample.com#ssobfs" % Marshalls.utf8_to_base64("aes-128-gcm:pw"),
		"hysteria2://pw@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=x&mport=20000-30000#hy2",
		"tuic://%s:pw@tu.example.com:443?congestion_control=bbr&alpn=h3#tuic" % UUID,
		"anytls://pw@any.example.com:443?sni=any.example.com#anytls",
		"socks5://u:p@1.2.3.4:1080#socks",
	]


static func wireguard() -> ProfileModel:
	var conf := "[Interface]\nPrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\nAddress = 10.7.0.2/32\n[Peer]\nPublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\nEndpoint = wg.example.com:51820\nAllowedIPs = 0.0.0.0/0\n"
	return WireGuardParser.parse_conf(conf, "wg").profile


func _profiles() -> Array:
	var out := []
	for l in links():
		var r := LinkParser.parse(l)
		check(r.ok, "parse %s: %s" % [l.substr(0, 20), r.get("error", "")])
		if r.ok:
			out.append(r.profile)
	out.append(wireguard())
	return out


func _settings(overrides: Dictionary = {}) -> Dictionary:
	var s := Settings.DEFAULTS.duplicate(true)
	s.merge(overrides, true)
	return s


func _core_check(name: String, config: Dictionary) -> String:
	var path := OUT_DIR.path_join(name + ".json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JsonUtil.stringify(config, "  "))
	f.close()
	var out := []
	var code := OS.execute(_bin, ["check", "-c", ProjectSettings.globalize_path(path)], out, true)
	return "" if code == 0 else "exit %d: %s" % [code, SecretMasker.mask("".join(out)).strip_edges()]


func _assert_structure(cfg: Dictionary, label: String) -> void:
	var text := JSON.stringify(cfg)
	check(not RegEx.create_from_string("\\d\\.0[,}\\]]").search(text), "%s: float numbers leaked into JSON" % label)
	var tun: Dictionary = cfg.inbounds[0]
	eq(tun.type, "tun", label)
	eq(tun.auto_route, true, label)
	var rules: Array = cfg.route.rules
	eq(rules[0].action, "sniff", label)
	eq(rules[1].action, "hijack-dns", label)
	eq(cfg.route.default_domain_resolver.server, "local", label + " (server names resolved directly: no loop)")
	eq(cfg.route.auto_detect_interface, true, label)


func test_all_protocols_global_mode() -> void:
	var n := 0
	for p in _profiles():
		var b := ConfigBuilder.build_vpn_config(p, _settings())
		if not check(b.ok, "%s: %s" % [p.name, b.error]):
			continue
		_assert_structure(b.config, p.name)
		if _bin != "":
			var err := _core_check("proto_%s" % p.name, b.config)
			check(err == "", "sing-box rejected %s (%s): %s" % [p.name, p.protocol, err])
		n += 1
	eq(n, links().size() + 1, "all protocol configs built")
	if _bin == "":
		skip("NEXUS_SINGBOX_BIN not set: core validation skipped (structure checked)")


func test_routing_modes_and_options() -> void:
	var p: ProfileModel = LinkParser.parse("vless://%s@t.example.com:443?security=tls#t" % UUID).profile
	var rules := [
		RulesManager.make_rule("domain_suffix", "example.org", "proxy"),
		RulesManager.make_rule("domain", "direct.example.net", "direct"),
		RulesManager.make_rule("domain_keyword", "ads", "block"),
		RulesManager.make_rule("ip_cidr", "203.0.113.0/24", "direct"),
		RulesManager.make_rule("port", "6881:6889", "block"),
		RulesManager.make_rule("geosite", "google", "proxy"),
		RulesManager.make_rule("geoip", "ru", "direct"),
	]
	var cases := {
		"global": {},
		"split": {"routing_mode": "split", "split_country": "ru"},
		"selected": {"routing_mode": "selected", "custom_rules": rules},
		"direct": {"routing_mode": "direct", "custom_rules": rules},
		"custom_direct": {"routing_mode": "custom", "custom_final": "direct", "custom_rules": rules},
		"ads": {"block_ads": true},
		"ipv4_only": {"ipv6_enabled": false},
		"apps_include": {"per_app_mode": "include", "per_app_packages": ["org.mozilla.firefox"]},
		"apps_exclude": {"per_app_mode": "exclude", "per_app_packages": ["com.bank.app"]},
		"dns_tls": {"remote_dns": "tls://dns.google", "direct_dns": "8.8.8.8", "dns_strategy": "ipv4_only"},
		"dns_h3": {"remote_dns": "h3://dns.google/dns-query"},
		"stack_gvisor": {"tun_stack": "gvisor", "mtu": 1500, "strict_route": false},
	}
	for name in cases:
		var b := ConfigBuilder.build_vpn_config(p, _settings(cases[name]))
		if not check(b.ok, "%s: %s" % [name, b.error]):
			continue
		_assert_structure(b.config, name)
		if _bin != "":
			var err := _core_check("mode_" + name, b.config)
			check(err == "", "sing-box rejected mode %s: %s" % [name, err])
	# Mode semantics
	eq(ConfigBuilder.build_vpn_config(p, _settings(cases.selected)).config.route.final, "direct")
	eq(ConfigBuilder.build_vpn_config(p, _settings(cases.global)).config.route.final, "proxy")
	var ipv4: Dictionary = ConfigBuilder.build_vpn_config(p, _settings(cases.ipv4_only)).config
	eq(ipv4.inbounds[0].address.size(), 1, "no IPv6 address when IPv6 disabled")
	eq(ipv4.dns.strategy, "ipv4_only")
	var direct: Dictionary = ConfigBuilder.build_vpn_config(p, _settings(cases.direct)).config
	for r in direct.route.rules:
		check(r.get("outbound", "") != "proxy", "direct mode must not route to proxy")
	eq(ConfigBuilder.build_vpn_config(p, _settings(cases.apps_include)).config.inbounds[0].include_package, ["org.mozilla.firefox"])
	if _bin == "":
		skip("NEXUS_SINGBOX_BIN not set: core validation skipped (structure checked)")


func test_invalid_settings_are_rejected() -> void:
	var p: ProfileModel = LinkParser.parse("vless://%s@t.example.com:443#t" % UUID).profile
	check(not ConfigBuilder.build_vpn_config(p, _settings({"routing_mode": "split", "split_country": ""})).ok, "split without country")
	check(not ConfigBuilder.build_vpn_config(p, _settings({"remote_dns": "ftp://x"})).ok, "bad dns scheme")
	check(not ConfigBuilder.build_vpn_config(p, _settings({"per_app_mode": "include", "per_app_packages": []})).ok, "include without apps")
	check(not ConfigBuilder.build_vpn_config(p, _settings({"custom_rules": [{"type": "ip_cidr", "value": "999.1.1.1", "action": "direct"}]})).ok, "invalid rule")
	check(not ConfigBuilder.build_vpn_config(null, _settings()).ok, "no profile")
	var bad := ProfileModel.create("vless", {"type": "vless", "server": "", "server_port": 443, "uuid": UUID})
	check(not ConfigBuilder.build_vpn_config(bad, _settings()).ok, "empty server")


func test_core_rejects_broken_config() -> void:
	if _bin == "":
		skip("NEXUS_SINGBOX_BIN not set")
		return
	var p := ProfileModel.create("vless", {"type": "vless", "server": "a.example.com", "server_port": 443, "uuid": UUID,
		"flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": "a.example.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": "not-a-key"}}})
	var b := ConfigBuilder.build_vpn_config(p, _settings())
	if check(b.ok, b.error):
		check(_core_check("broken", b.config) != "", "core must reject an invalid REALITY key")


func test_latency_test_config() -> void:
	var profiles := _profiles()
	var b := ConfigBuilder.build_test_config(profiles, _settings())
	if not ok_result(b):
		return
	eq(b.tags.size(), profiles.size())
	check(not b.config.has("inbounds"), "no TUN in latency session")
	if _bin != "":
		var err := _core_check("latency", b.config)
		check(err == "", "sing-box rejected latency config: " + err)
	else:
		skip("NEXUS_SINGBOX_BIN not set: core validation skipped")


func test_rule_conflicts() -> void:
	var rules := [RulesManager.make_rule("domain", "a.com", "proxy"), RulesManager.make_rule("domain", "A.com", "direct"),
		RulesManager.make_rule("domain", "b.com", "block"), RulesManager.make_rule("domain", "b.com", "block")]
	var c := RulesManager.find_conflicts(rules)
	eq(c.size(), 2, "one conflict + one duplicate")
	var conv := RulesManager.convert(rules)
	eq(conv.route_rules.size(), 2, "first rule wins, duplicates dropped")
	eq(RulesManager.validate(RulesManager.make_rule("port", "2000:1000", "block")) != "", true)
	eq(RulesManager.validate(RulesManager.make_rule("ip_cidr", "2001:db8::/32", "direct")), "")


func test_dns_parsing() -> void:
	eq(DnsManager.build_server("https://1.1.1.1/dns-query", "remote", "proxy").server, {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"})
	eq(DnsManager.build_server("local", "local").server, {"type": "local", "tag": "local"})
	eq(DnsManager.build_server("8.8.8.8:5353", "x").server, {"type": "udp", "tag": "x", "server": "8.8.8.8", "server_port": 5353})
	var named := DnsManager.build_server("tls://dns.google", "remote", "proxy")
	eq(named.server.domain_resolver, "local")
	check(not DnsManager.build_server("dns.google", "local").ok, "direct DNS by name would need itself")
	check(not DnsManager.build_server("gopher://x", "r").ok, "bad scheme")
