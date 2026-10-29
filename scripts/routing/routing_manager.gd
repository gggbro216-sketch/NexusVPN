class_name RoutingManager
extends RefCounted
## Turns the routing mode + user rules from settings into sing-box route and
## DNS rule lists. Each mode changes the generated configuration:
##   global   - everything through the proxy (private networks optionally direct)
##   split    - traffic to the selected country (geoip + ccTLD) goes direct
##   selected - only matching "proxy" rules use the proxy, the rest goes direct
##   direct   - nothing is proxied (tunnel stays up; useful for diagnostics)
##   custom   - only the user rules decide; unmatched traffic uses custom_final

const MODE_LABELS := {
	"global": "Весь трафик через прокси",
	"split": "Раздельная маршрутизация (страна напрямую)",
	"selected": "Только выбранные направления через прокси",
	"direct": "Прямое подключение (без прокси)",
	"custom": "Пользовательские правила",
}

## Extra ccTLDs (punycode) for countries whose national IDN TLD is common.
const IDN_TLDS := {"ru": ["xn--p1ai"], "by": ["xn--90ais"], "ua": ["xn--j1amh"], "kz": ["xn--80ao21a"], "cn": ["xn--fiqs8s"]}


## Returns {route_rules, dns_rules, rule_sets, final, dns_final, warnings, errors}.
static func build(settings: Dictionary) -> Dictionary:
	var mode := str(settings.get("routing_mode", "global"))
	var res := {"route_rules": [], "dns_rules": [], "rule_sets": [], "final": "proxy", "dns_final": "remote",
		"warnings": PackedStringArray(), "errors": PackedStringArray()}
	if not MODE_LABELS.has(mode):
		res.errors.append("неизвестный режим маршрутизации \"%s\"" % mode)
		return res
	var user_rules: Array = settings.get("custom_rules", [])
	var conv := RulesManager.convert(user_rules)
	res.warnings.append_array(conv.warnings)
	res.errors.append_array(conv.errors)
	var rule_sets := {}
	for rs in conv.rule_sets:
		rule_sets[rs.tag] = rs
	var pre_rules := []
	var pre_dns := []
	if settings.get("block_ads", false):
		var tag := "geosite-category-ads-all"
		rule_sets[tag] = RulesManager.remote_rule_set(tag, RulesManager.GEOSITE_URL % "category-ads-all")
		pre_rules.append({"rule_set": [tag], "action": "reject"})
		pre_dns.append({"rule_set": [tag], "action": "reject"})
	var post_rules := []
	var post_dns := []
	match mode:
		"global":
			res.final = "proxy"
			res.dns_final = "remote"
		"split":
			var cc := str(settings.get("split_country", "")).strip_edges().to_lower()
			if cc.is_empty() or not RegEx.create_from_string("^[a-z]{2}$").search(cc):
				res.errors.append("для раздельной маршрутизации укажите код страны (например, ru)")
			else:
				var tag := "geoip-" + cc
				rule_sets[tag] = RulesManager.remote_rule_set(tag, RulesManager.GEOIP_URL % cc)
				var tlds := [cc]
				tlds.append_array(IDN_TLDS.get(cc, []))
				post_rules.append({"domain_suffix": tlds, "outbound": "direct"})
				post_rules.append({"rule_set": [tag], "outbound": "direct"})
				post_dns.append({"domain_suffix": tlds, "server": "local"})
			res.final = "proxy"
			res.dns_final = "remote"
		"selected":
			var has_proxy_rule := false
			for r in user_rules:
				if r.get("enabled", true) and r.get("action", "") == "proxy":
					has_proxy_rule = true
			if not has_proxy_rule:
				res.warnings.append("в режиме «только выбранные» нет ни одного правила «через прокси» — весь трафик пойдёт напрямую")
			res.final = "direct"
			res.dns_final = "local"
		"direct":
			res.final = "direct"
			res.dns_final = "local"
			# Proxy rules make no sense in direct mode; keep block/direct rules only.
			var filtered := []
			for rr in conv.route_rules:
				if rr.get("outbound", "") != "proxy":
					filtered.append(rr)
			conv.route_rules = filtered
			var fdns := []
			for dr in conv.dns_rules:
				if dr.get("server", "") != "remote":
					fdns.append(dr)
			conv.dns_rules = fdns
		"custom":
			res.final = str(settings.get("custom_final", "proxy"))
			if not (res.final in ["proxy", "direct"]):
				res.final = "proxy"
			res.dns_final = "remote" if res.final == "proxy" else "local"
	if settings.get("bypass_private", true):
		pre_rules.append({"ip_is_private": true, "outbound": "direct"})
	res.route_rules = pre_rules + conv.route_rules + post_rules
	res.dns_rules = pre_dns + conv.dns_rules + post_dns
	res.rule_sets = rule_sets.values()
	return res
