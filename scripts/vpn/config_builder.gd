class_name ConfigBuilder
extends RefCounted
## Generates sing-box 1.14 configurations from a profile and app settings.
##
## VPN config layout:
##   inbounds:  tun "tun-in" (Android VpnService provides the fd via libbox)
##   outbounds: selector "proxy" -> ["server"], the server itself, "direct"
##   endpoints: the server when it is WireGuard
##   dns:       "remote" (through proxy), "local" (system/direct)
##   route:     sniff, hijack-dns, mode rules, final
## Loop prevention: libbox protects every socket it opens through
## VpnService.protect() (auto_detect_interface), and server names are resolved
## with the "local" resolver, so proxy traffic never re-enters the tunnel.

const PROXY_TAG := "proxy"
const SERVER_TAG := "server"
const DIRECT_TAG := "direct"
const TEST_GROUP_TAG := "nexus-test"
const TUN_TAG := "tun-in"
const TUN_INET4 := "172.19.0.1/30"
const TUN_INET6 := "fdfe:dcba:9876::1/126"


## Returns {ok, error, config: Dictionary, warnings: PackedStringArray,
##          xray_config: Dictionary (empty unless the profile runs on Xray)}.
## [param settings] is Settings.export_data() (passed in to keep this testable).
static func build_vpn_config(profile: ProfileModel, settings: Dictionary) -> Dictionary:
	var res := {"ok": false, "error": "", "config": {}, "warnings": PackedStringArray(), "xray_config": {}}
	if profile == null:
		res.error = "профиль не выбран"
		return res
	if profile.protocol == "config":
		return _use_full_config(profile, settings)
	var ob_check := validate_outbound(profile)
	if ob_check != "":
		res.error = ob_check
		return res

	var routing := RoutingManager.build(settings)
	if routing.errors.size() > 0:
		res.error = "ошибка правил маршрутизации: " + routing.errors[0]
		return res
	res.warnings.append_array(routing.warnings)

	var ipv6 := bool(settings.get("ipv6_enabled", true))
	var strategy := str(settings.get("dns_strategy", "prefer_ipv4"))
	if not ipv6:
		strategy = "ipv4_only"
	elif not (strategy in ["prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"]):
		strategy = "prefer_ipv4"

	var remote := DnsManager.build_server(str(settings.get("remote_dns", "https://1.1.1.1/dns-query")), "remote", PROXY_TAG)
	if not remote.ok:
		res.error = "удалённый DNS: " + remote.error
		return res
	var local := DnsManager.build_server(str(settings.get("direct_dns", "local")), "local")
	if not local.ok:
		res.error = "прямой DNS: " + local.error
		return res

	var addresses := [TUN_INET4]
	if ipv6:
		addresses.append(TUN_INET6)
	var stack := str(settings.get("tun_stack", "mixed"))
	if not (stack in ["mixed", "system", "gvisor"]):
		stack = "mixed"
	var tun := {
		"type": "tun",
		"tag": TUN_TAG,
		"address": addresses,
		"mtu": clampi(int(settings.get("mtu", 9000)), 1280, 65535),
		"auto_route": true,
		"strict_route": bool(settings.get("strict_route", true)),
		"stack": stack,
	}
	var per_app := str(settings.get("per_app_mode", "off"))
	var packages: Array = settings.get("per_app_packages", [])
	if per_app == "include":
		if packages.is_empty():
			res.error = "режим «только выбранные приложения» включён, но приложения не выбраны"
			return res
		tun["include_package"] = packages.duplicate()
	elif per_app == "exclude" and not packages.is_empty():
		tun["exclude_package"] = packages.duplicate()

	var server: Dictionary
	var xray_session := {}
	if profile.engine == "xray":
		# XHTTP / VLESS encryption: sing-box forwards to a local Xray process.
		xray_session = XrayBridge.new_session(1)
		server = XrayBridge.singbox_outbound(xray_session, 0, SERVER_TAG)
		res.xray_config = XrayBridge.xray_config(xray_session, [profile.outbound], _xray_log_level(settings))
	else:
		server = profile.outbound.duplicate(true)
		server["tag"] = SERVER_TAG
		server["type"] = profile.protocol
		apply_tls_fragment(server, str(settings.get("tls_fragment", "off")))
	var outbounds := [
		{"type": "selector", "tag": PROXY_TAG, "outbounds": [SERVER_TAG], "default": SERVER_TAG},
		{"type": "direct", "tag": DIRECT_TAG},
	]
	var endpoints := []
	if profile.is_endpoint:
		endpoints.append(server)
	else:
		outbounds.insert(1, server)

	var config := {
		"log": {"level": _core_log_level(settings), "timestamp": true},
		"dns": {
			"servers": [remote.server, local.server],
			"rules": routing.dns_rules,
			"final": routing.dns_final,
			"strategy": strategy,
		},
		"inbounds": [tun],
		"outbounds": outbounds,
		"route": {
			"rules": [
				{"action": "sniff"},
				{"protocol": "dns", "action": "hijack-dns"},
			] + routing.route_rules,
			"final": routing.final,
			"auto_detect_interface": true,
			"default_domain_resolver": {"server": "local"},
		},
		"experimental": {"cache_file": {"enabled": true}},
	}
	if endpoints.size() > 0:
		config["endpoints"] = endpoints
	if not xray_session.is_empty():
		config.inbounds.append(XrayBridge.singbox_dial_inbound(xray_session))
		config.route.rules.insert(0, XrayBridge.singbox_dial_rule())
	if routing.rule_sets.size() > 0:
		config.route["rule_set"] = routing.rule_sets
	if config.dns.rules.is_empty():
		config.dns.erase("rules")
	res.config = config
	res.ok = true
	return res


## Config for measuring real proxy latency of several profiles without a TUN.
## Returns {ok, error, config, tags: Dictionary(tag -> profile_id), skipped: Dictionary(profile_id -> reason)}.
static func build_test_config(profiles: Array, settings: Dictionary) -> Dictionary:
	var res := {"ok": false, "error": "", "config": {}, "tags": {}, "skipped": {}, "xray_config": {}}
	var outbounds := []
	var endpoints := []
	var tags := []
	var i := 0
	var xray_profiles: Array[ProfileModel] = []
	for p in profiles:
		if (p as ProfileModel).engine == "xray" and validate_outbound(p) == "":
			xray_profiles.append(p)
	var xray_session := XrayBridge.new_session(xray_profiles.size()) if xray_profiles.size() > 0 else {}
	var xray_outbounds := []
	for p in profiles:
		var prof: ProfileModel = p
		if prof.protocol == "config":
			res.skipped[prof.id] = "полная конфигурация не тестируется"
			continue
		var err := validate_outbound(prof)
		if err != "":
			res.skipped[prof.id] = err
			continue
		var tag := "test-%d" % i
		i += 1
		var ob: Dictionary
		if prof.engine == "xray":
			ob = XrayBridge.singbox_outbound(xray_session, xray_outbounds.size(), tag)
			xray_outbounds.append(prof.outbound)
		else:
			ob = prof.outbound.duplicate(true)
			ob["type"] = prof.protocol
			apply_tls_fragment(ob, str(settings.get("tls_fragment", "off")))
			ob["tag"] = tag
		if prof.is_endpoint:
			endpoints.append(ob)
		else:
			outbounds.append(ob)
		tags.append(tag)
		res.tags[tag] = prof.id
	if tags.is_empty():
		res.error = "нет профилей, пригодных для проверки"
		return res
	outbounds.append({"type": "selector", "tag": TEST_GROUP_TAG, "outbounds": tags})
	outbounds.append({"type": "direct", "tag": DIRECT_TAG})
	var local := DnsManager.build_server(str(settings.get("direct_dns", "local")), "local")
	if not local.ok:
		local = DnsManager.build_server("local", "local")
	var config := {
		"log": {"level": "warn", "timestamp": true},
		"dns": {"servers": [local.server], "final": "local"},
		"outbounds": outbounds,
		"route": {"final": DIRECT_TAG, "auto_detect_interface": true, "default_domain_resolver": {"server": "local"}},
	}
	if endpoints.size() > 0:
		config["endpoints"] = endpoints
	if xray_outbounds.size() > 0:
		config["inbounds"] = [XrayBridge.singbox_dial_inbound(xray_session)]
		config.route["rules"] = [XrayBridge.singbox_dial_rule()]
		res.xray_config = XrayBridge.xray_config(xray_session, xray_outbounds)
	res.config = config
	res.ok = true
	return res


## Protocols whose TLS runs over QUIC: no TCP handshake to fragment.
const QUIC_PROTOCOLS := ["hysteria2", "hysteria", "tuic"]


## Returns true when TLS ClientHello fragmentation can apply to [param ob]:
## TCP-based TLS only. REALITY builds its own uTLS connection and does not use
## sing-box's fragmenter (common/tls/reality_client.go), QUIC has no TCP stream.
static func tls_fragment_applicable(ob: Dictionary) -> bool:
	var tls: Variant = ob.get("tls", {})
	if typeof(tls) != TYPE_DICTIONARY or not tls.get("enabled", false):
		return false
	if typeof(tls.get("reality", {})) == TYPE_DICTIONARY and tls.get("reality", {}).get("enabled", false):
		return false
	if str(ob.get("type", "")) in QUIC_PROTOCOLS:
		return false
	var tr: Variant = ob.get("transport", {})
	if typeof(tr) == TYPE_DICTIONARY and str(tr.get("type", "")) == "quic":
		return false
	return true


## Sets sing-box tls.fragment / tls.record_fragment according to [param mode].
static func apply_tls_fragment(ob: Dictionary, mode: String) -> void:
	if mode == "off" or not tls_fragment_applicable(ob):
		return
	var tls: Dictionary = ob.tls
	if mode in ["record", "both"]:
		tls["record_fragment"] = true
	if mode in ["tcp", "both"]:
		tls["fragment"] = true


## Basic structural checks before handing the outbound to the core.
static func validate_outbound(profile: ProfileModel) -> String:
	var o := profile.outbound
	if typeof(o) != TYPE_DICTIONARY or o.is_empty():
		return "у профиля нет параметров подключения"
	if profile.engine == "xray":
		var vn: Variant = o.get("settings", {}).get("vnext", [])
		if str(o.get("protocol", "")) != "vless" or typeof(vn) != TYPE_ARRAY or vn.is_empty():
			return "некорректный outbound Xray"
		if typeof(o.get("streamSettings")) != TYPE_DICTIONARY:
			return "outbound Xray без streamSettings"
		return ""
	var t := profile.protocol
	if not (t in SingBoxJsonParser.PROXY_TYPES) and not (t in SingBoxJsonParser.ENDPOINT_TYPES):
		return "протокол «%s» не поддерживается ядром этой сборки" % t
	if profile.is_endpoint:
		if (o.get("peers", []) as Array).is_empty():
			return "WireGuard: нет пиров"
		return ""
	var host := str(o.get("server", ""))
	if host.is_empty() or not UriUtil.is_valid_host(host):
		return "некорректный адрес сервера"
	if not o.has("server_ports") and not UriUtil.is_valid_port(int(o.get("server_port", 0))):
		return "некорректный порт сервера"
	if str(o.get("detour", "")) != "":
		return "цепочки (detour) не поддерживаются"
	return ""


static func _use_full_config(profile: ProfileModel, _settings: Dictionary) -> Dictionary:
	var res := {"ok": false, "error": "", "config": {}, "warnings": PackedStringArray()}
	var cfg := profile.outbound.duplicate(true)
	var has_tun := false
	for ib in cfg.get("inbounds", []):
		if typeof(ib) == TYPE_DICTIONARY and ib.get("type", "") == "tun":
			has_tun = true
	if not has_tun:
		res.error = "импортированная конфигурация не содержит TUN-входа и не может работать как VPN"
		return res
	res.warnings.append("используется полная импортированная конфигурация: настройки DNS/маршрутизации приложения не применяются")
	res.config = cfg
	res.ok = true
	return res


static func _xray_log_level(settings: Dictionary) -> String:
	return {"trace": "debug", "debug": "debug", "info": "info", "warn": "warning", "error": "error"}.get(str(settings.get("core_log_level", "warn")), "warning")


static func _core_log_level(settings: Dictionary) -> String:
	var l := str(settings.get("core_log_level", "warn"))
	return l if l in ["trace", "debug", "info", "warn", "error"] else "warn"
