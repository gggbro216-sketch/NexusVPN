class_name SubscriptionParser
extends RefCounted
## Detects the format of subscription / import content and converts it into
## profiles. Supported: plain share-link lists, base64-encoded link lists,
## sing-box JSON, WireGuard .conf. Clash YAML, Xray JSON and HTML pages are
## detected and reported with a clear error instead of being misparsed.

const MAX_BYTES := 8 * 1024 * 1024
const MAX_LINES := 20000

enum Format { UNKNOWN, LINKS, BASE64_LINKS, SINGBOX_JSON, WIREGUARD, CLASH_YAML, XRAY_JSON, HTML, EMPTY }
const FORMAT_NAMES := ["unknown", "links", "base64", "sing-box JSON", "WireGuard", "Clash YAML", "Xray JSON", "HTML", "empty"]


## Returns {ok, error, format: Format, profiles: Array[ProfileModel],
##          errors: PackedStringArray (per-entry, masked), warnings, skipped: int, duplicates: int}.
static func parse(raw: String) -> Dictionary:
	var res := {"ok": false, "error": "", "format": Format.UNKNOWN, "profiles": [],
		"errors": PackedStringArray(), "warnings": PackedStringArray(), "skipped": 0, "duplicates": 0,
		"is_full_config": false, "config": {}}
	if raw.length() > MAX_BYTES:
		res.error = "content is too large"
		return res
	var text := strip_bom(raw).strip_edges()
	if text.is_empty():
		res.format = Format.EMPTY
		res.error = "the response is empty"
		return res
	var fmt := detect(text)
	res.format = fmt
	match fmt:
		Format.HTML:
			res.error = "the server returned an HTML page, not a subscription (check the URL or authorization)"
			return res
		Format.CLASH_YAML:
			res.error = "Clash/Mihomo YAML subscriptions are not supported yet; request the link in base64 or sing-box format"
			return res
		Format.XRAY_JSON:
			res.error = "Xray JSON configurations are not supported; use share links or sing-box JSON"
			return res
		Format.SINGBOX_JSON:
			var j := SingBoxJsonParser.parse(text)
			if not j.ok:
				res.error = j.error
				return res
			res.profiles = j.profiles
			res.warnings = j.warnings
			res.is_full_config = j.is_full_config
			res.config = j.config
		Format.WIREGUARD:
			var w := WireGuardParser.parse_conf(text)
			if not w.ok:
				res.error = w.error
				return res
			res.profiles = [w.profile]
			res.warnings = w.warnings
		Format.LINKS:
			_parse_lines(text, res)
		Format.BASE64_LINKS:
			var dec := UriUtil.base64_to_text(text)
			if not dec.ok:
				res.error = "invalid base64 content: " + dec.error
				return res
			var inner := strip_bom(dec.text).strip_edges()
			if not _has_links(inner):
				res.error = "decoded base64 content contains no share links"
				return res
			_parse_lines(inner, res)
		_:
			res.error = "unrecognised content format"
			return res
	_dedupe(res)
	if res.profiles.is_empty() and not res.is_full_config:
		if res.error.is_empty():
			res.error = "no valid servers found" + ("" if res.errors.is_empty() else " (%s)" % res.errors[0])
		return res
	res.ok = true
	return res


static func strip_bom(s: String) -> String:
	return s.replace(char(0xFEFF), "")


static func detect(text: String) -> Format:
	var head := text.substr(0, 512).to_lower()
	if head.begins_with("<!doctype") or head.begins_with("<html") or (head.begins_with("<") and head.contains("<html")):
		return Format.HTML
	if text.begins_with("{") or text.begins_with("["):
		var j := JsonUtil.parse(text)
		if j.ok:
			if _is_xray(j.data):
				return Format.XRAY_JSON
			return Format.SINGBOX_JSON
		return Format.UNKNOWN
	if WireGuardParser.looks_like_conf(text):
		return Format.WIREGUARD
	if _has_links(text):
		return Format.LINKS
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("proxies:") or l.begins_with("proxy-groups:") or l.begins_with("mixed-port:"):
			return Format.CLASH_YAML
	if UriUtil.base64_decode_lenient(text).ok:
		return Format.BASE64_LINKS
	return Format.UNKNOWN


static func _has_links(text: String) -> bool:
	var n := 0
	for line in text.split("\n", false):
		n += 1
		if n > 50:
			break
		if LinkParser.is_share_link(line.strip_edges()):
			return true
	return false


static func _is_xray(data: Variant) -> bool:
	var obs: Variant = []
	if typeof(data) == TYPE_DICTIONARY:
		obs = data.get("outbounds", [])
	elif typeof(data) == TYPE_ARRAY and data.size() > 0 and typeof(data[0]) == TYPE_DICTIONARY:
		obs = data[0].get("outbounds", data)
	if typeof(obs) != TYPE_ARRAY:
		return false
	for o in obs:
		if typeof(o) == TYPE_DICTIONARY and o.has("protocol") and not o.has("type"):
			return true
	return false


static func _parse_lines(text: String, res: Dictionary) -> void:
	var lines := text.split("\n", false)
	if lines.size() > MAX_LINES:
		res.warnings.append("only the first %d lines were processed" % MAX_LINES)
		lines = lines.slice(0, MAX_LINES)
	var n := 0
	for raw in lines:
		n += 1
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("//"):
			continue
		if not line.contains("://"):
			res.skipped += 1
			continue
		var r := LinkParser.parse(line)
		if r.ok:
			r.profile.source = ProfileModel.SOURCE_SUBSCRIPTION
			res.profiles.append(r.profile)
			for w in r.warnings:
				res.warnings.append("%s: %s" % [r.profile.name, w])
		else:
			res.errors.append("line %d (%s): %s" % [n, LinkParser.scheme_of(line), r.error])


static func _dedupe(res: Dictionary) -> void:
	var seen := {}
	var unique := []
	for p in res.profiles:
		var fp: String = p.fingerprint()
		if seen.has(fp):
			res.duplicates += 1
			continue
		seen[fp] = true
		unique.append(p)
	res.profiles = unique
