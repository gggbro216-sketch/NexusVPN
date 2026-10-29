class_name RulesManager
extends RefCounted
## Validation and conversion of user routing rules into sing-box route/DNS
## rules, including conflict detection.
##
## Rule record: {type, value, action, enabled}
##   type:   domain | domain_suffix | domain_keyword | ip_cidr | geosite | geoip | port
##   action: proxy | direct | block

const TYPES := ["domain", "domain_suffix", "domain_keyword", "ip_cidr", "geosite", "geoip", "port"]
const ACTIONS := ["proxy", "direct", "block"]
const TYPE_LABELS := {
	"domain": "Домен (точно)", "domain_suffix": "Домен и поддомены", "domain_keyword": "Ключевое слово",
	"ip_cidr": "IP / подсеть", "geosite": "Набор доменов (geosite)", "geoip": "Страна по IP (geoip)", "port": "Порт",
}
const ACTION_LABELS := {"proxy": "Через прокси", "direct": "Напрямую", "block": "Блокировать"}

const GEOSITE_URL := "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-%s.srs"
const GEOIP_URL := "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-%s.srs"


static func make_rule(type: String, value: String, action: String) -> Dictionary:
	return {"type": type, "value": value.strip_edges(), "action": action, "enabled": true}


## Returns "" when valid, otherwise a human-readable error.
static func validate(rule: Dictionary) -> String:
	var t := str(rule.get("type", ""))
	var v := str(rule.get("value", "")).strip_edges()
	var a := str(rule.get("action", ""))
	if not (t in TYPES):
		return "неизвестный тип правила \"%s\"" % t
	if not (a in ACTIONS):
		return "неизвестное действие \"%s\"" % a
	if v.is_empty():
		return "пустое значение"
	match t:
		"domain", "domain_suffix":
			var d := v.trim_prefix(".") if t == "domain_suffix" else v
			if not UriUtil.is_valid_host(d) or d.is_valid_ip_address():
				return "некорректный домен \"%s\"" % v
		"domain_keyword":
			if v.contains(" "):
				return "ключевое слово не должно содержать пробелов"
		"ip_cidr":
			if not is_valid_cidr(v):
				return "некорректный IP или подсеть \"%s\"" % v
		"geosite", "geoip":
			if not RegEx.create_from_string("^[a-z0-9][a-z0-9!@_-]*$").search(v.to_lower()):
				return "некорректный код набора \"%s\"" % v
		"port":
			var parts := v.split(":")
			if parts.size() > 2:
				return "порт: используйте 443 или 1000:2000"
			for p in parts:
				if not p.is_valid_int() or not UriUtil.is_valid_port(int(p)):
					return "некорректный порт \"%s\"" % v
			if parts.size() == 2 and int(parts[0]) > int(parts[1]):
				return "начало диапазона больше конца"
	return ""


static func is_valid_cidr(v: String) -> bool:
	var ip := v
	var bits := -1
	var slash := v.find("/")
	if slash >= 0:
		ip = v.substr(0, slash)
		var b := v.substr(slash + 1)
		if not b.is_valid_int():
			return false
		bits = int(b)
	if not ip.is_valid_ip_address():
		return false
	var maxb := 128 if ip.contains(":") else 32
	return bits == -1 or (bits >= 0 and bits <= maxb)


static func normalize_cidr(v: String) -> String:
	if v.contains("/"):
		return v
	return v + ("/128" if v.contains(":") else "/32")


## Finds rules with the same matcher but different actions, and exact duplicates.
## Returns Array of human-readable warnings.
static func find_conflicts(rules: Array) -> PackedStringArray:
	var seen := {}
	var out := PackedStringArray()
	for r in rules:
		if not r.get("enabled", true):
			continue
		var key := "%s:%s" % [r.type, str(r.value).strip_edges().to_lower()]
		if seen.has(key):
			if seen[key] != r.action:
				out.append("правило %s «%s» задано с разными действиями (%s и %s); действует первое" %
					[TYPE_LABELS.get(r.type, r.type), r.value, ACTION_LABELS.get(seen[key], seen[key]), ACTION_LABELS.get(r.action, r.action)])
			else:
				out.append("дубликат правила %s «%s»" % [TYPE_LABELS.get(r.type, r.type), r.value])
		else:
			seen[key] = r.action
	return out


## Converts enabled, valid rules into grouped sing-box route rules (preserving
## first-match order per action group) plus the rule-sets they need.
## Returns {route_rules: Array, dns_rules: Array, rule_sets: Array, warnings, errors}.
## [param proxy_tag]/[param direct_tag] are outbound tags.
static func convert(rules: Array, proxy_tag: String = "proxy", direct_tag: String = "direct") -> Dictionary:
	var res := {"route_rules": [], "dns_rules": [], "rule_sets": [], "warnings": find_conflicts(rules), "errors": PackedStringArray()}
	var seen := {}
	var rule_sets := {}
	for r in rules:
		if not r.get("enabled", true):
			continue
		var err := validate(r)
		if err != "":
			res.errors.append("%s «%s»: %s" % [r.get("type", "?"), r.get("value", ""), err])
			continue
		var key := "%s:%s" % [r.type, str(r.value).strip_edges().to_lower()]
		if seen.has(key):
			continue # first rule wins
		seen[key] = true
		var matcher := _matcher(r, rule_sets)
		var route_rule := matcher.duplicate(true)
		match str(r.action):
			"proxy":
				route_rule["outbound"] = proxy_tag
			"direct":
				route_rule["outbound"] = direct_tag
			"block":
				route_rule["action"] = "reject"
		res.route_rules.append(route_rule)
		# DNS: domains that go direct resolve with the local resolver; blocked ones are refused.
		if r.type in ["domain", "domain_suffix", "domain_keyword", "geosite"]:
			var dns_rule := matcher.duplicate(true)
			match str(r.action):
				"direct":
					dns_rule["server"] = "local"
					res.dns_rules.append(dns_rule)
				"proxy":
					dns_rule["server"] = "remote"
					res.dns_rules.append(dns_rule)
				"block":
					dns_rule["action"] = "reject"
					res.dns_rules.append(dns_rule)
	res.rule_sets = rule_sets.values()
	return res


static func _matcher(r: Dictionary, rule_sets: Dictionary) -> Dictionary:
	var v := str(r.value).strip_edges()
	match str(r.type):
		"domain":
			return {"domain": [v.to_lower()]}
		"domain_suffix":
			return {"domain_suffix": [v.to_lower().trim_prefix(".")]}
		"domain_keyword":
			return {"domain_keyword": [v.to_lower()]}
		"ip_cidr":
			return {"ip_cidr": [normalize_cidr(v)]}
		"port":
			if v.contains(":"):
				return {"port_range": [v]}
			return {"port": [int(v)]}
		"geosite":
			var tag := "geosite-" + v.to_lower()
			rule_sets[tag] = remote_rule_set(tag, GEOSITE_URL % v.to_lower())
			return {"rule_set": [tag]}
		"geoip":
			var tag := "geoip-" + v.to_lower()
			rule_sets[tag] = remote_rule_set(tag, GEOIP_URL % v.to_lower())
			return {"rule_set": [tag]}
	return {}


## Remote binary rule-set downloaded through the proxy and cached by sing-box.
static func remote_rule_set(tag: String, url: String) -> Dictionary:
	return {"type": "remote", "tag": tag, "format": "binary", "url": url,
		"http_client": {"detour": "proxy"}, "update_interval": "72h"}
