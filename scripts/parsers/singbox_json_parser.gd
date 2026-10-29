class_name SingBoxJsonParser
extends RefCounted
## Imports sing-box JSON: a full configuration, an array of outbounds, or a
## single outbound/endpoint object. Each supported outbound becomes a profile;
## its options are stored verbatim (unknown fields are preserved).

## Proxy outbound types this build of sing-box (libbox tags: with_quic,
## with_wireguard, with_utls, with_gvisor, with_clash_api) can run.
const PROXY_TYPES := ["vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria", "tuic",
	"anytls", "socks", "http", "ssh", "snell"]
const ENDPOINT_TYPES := ["wireguard"]
## Types that are not servers (silently skipped).
const NON_PROXY := ["direct", "block", "dns", "selector", "urltest", "bridge"]
## Types that exist in sing-box but are not compiled into this build.
const NOT_BUILT := {
	"naive": "NaiveProxy outbound requires the cronet build of libbox (not included)",
	"tor": "Tor outbound requires embedded Tor (not included)",
	"tailscale": "Tailscale endpoint is not included in this build",
	"openvpn-client": "OpenVPN endpoint is not included in this build",
	"openconnect": "OpenConnect endpoint is not included in this build",
	"shadowtls": "ShadowTLS needs a detour chain; import it as a full configuration",
}

const MAX_ITEMS := 5000


## Returns {ok, error, profiles: Array[ProfileModel], warnings, is_full_config: bool, config: Dictionary}.
static func parse(text: String) -> Dictionary:
	var res := {"ok": false, "error": "", "profiles": [], "warnings": PackedStringArray(),
		"is_full_config": false, "config": {}}
	var j := JsonUtil.parse(text)
	if not j.ok:
		res.error = j.error
		return res
	var data: Variant = j.data
	var items := []
	var kind := ""
	if typeof(data) == TYPE_DICTIONARY:
		if data.has("outbounds") or data.has("endpoints") or data.has("inbounds") or data.has("route"):
			kind = "config"
			res.is_full_config = true
			res.config = data
			if typeof(data.get("outbounds", [])) != TYPE_ARRAY or typeof(data.get("endpoints", [])) != TYPE_ARRAY:
				res.error = "\"outbounds\"/\"endpoints\" must be arrays"
				return res
			items.append_array(data.get("outbounds", []))
			items.append_array(data.get("endpoints", []))
		elif data.has("type"):
			kind = "single"
			items.append(data)
		else:
			res.error = "JSON is not a sing-box configuration or outbound object"
			return res
	elif typeof(data) == TYPE_ARRAY:
		kind = "array"
		items = data
	else:
		res.error = "JSON is not a sing-box configuration"
		return res
	if items.size() > MAX_ITEMS:
		res.error = "too many entries (%d > %d)" % [items.size(), MAX_ITEMS]
		return res
	var tags := {}
	for it in items:
		if typeof(it) == TYPE_DICTIONARY and it.has("tag"):
			tags[str(it.tag)] = it
	for it in items:
		if typeof(it) != TYPE_DICTIONARY:
			res.warnings.append("skipped a non-object entry")
			continue
		var r := parse_outbound(it)
		if r.skip:
			continue
		if not r.ok:
			res.warnings.append("%s: %s" % [str(it.get("tag", it.get("type", "?"))), r.error])
			continue
		res.profiles.append(r.profile)
		res.warnings.append_array(r.warnings)
	if res.profiles.is_empty() and not res.is_full_config:
		res.error = "no supported servers found" + ("" if res.warnings.is_empty() else ": " + res.warnings[0])
		return res
	res.ok = true
	return res


## Returns {ok, skip, error, profile, warnings}.
static func parse_outbound(o: Dictionary) -> Dictionary:
	var r := {"ok": false, "skip": false, "error": "", "profile": null, "warnings": PackedStringArray()}
	var t := str(o.get("type", ""))
	if t in NON_PROXY or t.is_empty():
		r.skip = true
		return r
	if NOT_BUILT.has(t):
		r.error = NOT_BUILT[t]
		return r
	if not (t in PROXY_TYPES) and not (t in ENDPOINT_TYPES):
		r.error = "unknown outbound type \"%s\"" % t
		return r
	if str(o.get("detour", "")) != "":
		r.error = "outbounds chained through \"detour\" are not supported as standalone servers"
		return r
	var ob := o.duplicate(true)
	var name := str(ob.get("tag", ""))
	ob.erase("tag")
	if t in ENDPOINT_TYPES:
		var peers: Variant = ob.get("peers", [])
		if typeof(peers) != TYPE_ARRAY or peers.is_empty() or str(peers[0].get("address", "")).is_empty():
			r.error = "WireGuard endpoint has no peer address"
			return r
		if not ob.has("private_key") or not ob.has("address"):
			r.error = "WireGuard endpoint requires private_key and address"
			return r
	else:
		var host := str(ob.get("server", ""))
		var port := int(ob.get("server_port", 0))
		var serr := ParserCommon.validate_server(host, port if port != 0 else (443 if ob.has("server_ports") else -1))
		if serr != "":
			r.error = serr
			return r
		var verr := _validate_credentials(t, ob)
		if verr != "":
			r.error = verr
			return r
		var tr: Variant = ob.get("transport", {})
		if typeof(tr) == TYPE_DICTIONARY and str(tr.get("type", "")) not in ["", "ws", "grpc", "http", "httpupgrade", "quic"]:
			r.error = "transport \"%s\" is not supported by sing-box 1.14" % str(tr.get("type"))
			return r
	var p := ProfileModel.create(t, ob, name)
	p.source = ProfileModel.SOURCE_SINGBOX_JSON
	p.transport_label = _label(ob)
	r.ok = true
	r.profile = p
	return r


static func _validate_credentials(t: String, ob: Dictionary) -> String:
	match t:
		"vless", "vmess":
			return ParserCommon.validate_user_id(str(ob.get("uuid", "")))
		"trojan", "anytls":
			return "" if str(ob.get("password", "")) != "" else "password is missing"
		"shadowsocks":
			var m := str(ob.get("method", ""))
			if not (m in ShadowsocksParser.METHODS):
				return "unsupported Shadowsocks method \"%s\"" % m
			return ShadowsocksParser.validate_password(m, str(ob.get("password", "")))
		"tuic":
			return "" if ParserCommon.is_canonical_uuid(str(ob.get("uuid", ""))) else "TUIC requires a valid UUID"
		"ssh":
			if str(ob.get("password", "")) == "" and ob.get("private_key", null) == null and str(ob.get("private_key_path", "")) == "":
				return "SSH requires a password or private key"
			if str(ob.get("private_key_path", "")) != "":
				return "SSH private_key_path refers to a local file; embed the key with private_key instead"
	return ""


static func _label(ob: Dictionary) -> String:
	var parts := PackedStringArray()
	var tr: Variant = ob.get("transport", {})
	if typeof(tr) == TYPE_DICTIONARY and tr.has("type"):
		parts.append({"ws": "WS", "grpc": "gRPC", "http": "HTTP/2", "httpupgrade": "HTTPUpgrade", "quic": "QUIC"}.get(tr.type, str(tr.type)))
	var tls: Variant = ob.get("tls", {})
	if typeof(tls) == TYPE_DICTIONARY and tls.get("enabled", false):
		if typeof(tls.get("reality", {})) == TYPE_DICTIONARY and tls.get("reality", {}).get("enabled", false):
			parts.append("Reality")
		elif not (str(ob.get("type")) in ["hysteria2", "tuic", "hysteria", "anytls"]):
			parts.append("TLS")
	return "+".join(parts)
