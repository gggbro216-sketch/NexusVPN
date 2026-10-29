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


## Returns {ok, error, config: Dictionary, warnings: PackedStringArray}.
## [param settings] is Settings.export_data() (passed in to keep this testable).
static func build_vpn_config(profile: ProfileModel, settings: Dictionary) -> Dictionary:
	var res := {"ok": false, "error": "", "config": {}, "warnings": PackedStringArray()}
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

	var server := profile.outbound.duplicate(true)
	server["tag"] = SERVER_TAG
	server["type"] = profile.protocol
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
	var res := {"ok": false, "error": "", "config": {}, "tags": {}, "skipped": {}}
	var outbounds := []
	var endpoints := []
	var tags := []
	var i := 0
	for p in profiles:
		var prof: ProfileModel = p
		if prof.protocol == "config":
			res.skipped[prof.id] = "полная конфигурация не тестируется"
			continue
		var err := validate_outbound(prof)
		if err != "":
			res.skipped[prof.id] = err
			continue
		var ob := prof.outbound.duplicate(true)
		var tag := "test-%d" % i
		i += 1
		ob["tag"] = tag
		ob["type"] = prof.protocol
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
	res.config = config
	res.ok = true
	return res


## Basic structural checks before handing the outbound to the core.
static func validate_outbound(profile: ProfileModel) -> String:
	var o := profile.outbound
	if typeof(o) != TYPE_DICTIONARY or o.is_empty():
		return "у профиля нет параметров подключения"
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


static func _core_log_level(settings: Dictionary) -> String:
	var l := str(settings.get("core_log_level", "warn"))
	return l if l in ["trace", "debug", "info", "warn", "error"] else "warn"
