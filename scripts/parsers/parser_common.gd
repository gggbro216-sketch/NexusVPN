class_name ParserCommon
extends RefCounted
## Shared helpers for share-link parsers: result objects, TLS/REALITY and
## V2Ray transport conversion to sing-box 1.14 option objects.

## uTLS fingerprints accepted by sing-box 1.14 (option/tls.go enum).
const UTLS_FINGERPRINTS := ["chrome", "chrome_psk", "chrome_psk_shuffle", "chrome_padding_psk_shuffle",
	"chrome_pq", "chrome_pq_psk", "firefox", "edge", "safari", "360", "qq", "ios", "android",
	"random", "randomized"]

## V2Ray transport types implemented by sing-box 1.14 (constant/v2ray.go).
const SUPPORTED_TRANSPORTS := ["tcp", "raw", "ws", "grpc", "httpupgrade", "http", "h2", "quic"]
## Transports known from Xray links that sing-box 1.14 does NOT implement.
const UNSUPPORTED_TRANSPORTS := {
	"xhttp": "XHTTP is not implemented by sing-box 1.14",
	"splithttp": "SplitHTTP/XHTTP is not implemented by sing-box 1.14",
	"kcp": "mKCP is not implemented by sing-box",
	"mkcp": "mKCP is not implemented by sing-box",
	"hysteria": "Xray hysteria transport is not supported",
}

## Query parameters understood by the V2Ray-style parsers (others produce warnings).
const COMMON_PARAMS := ["type", "security", "sni", "peer", "alpn", "fp", "pbk", "sid", "spx",
	"allowInsecure", "allow_insecure", "insecure", "host", "path", "serviceName", "service_name",
	"mode", "headerType", "encryption", "flow", "authority", "quicSecurity", "key", "ed",
	"eh", "packetEncoding", "remarks", "pqv", "ech"]


static func ok(profile: ProfileModel, warnings: PackedStringArray = PackedStringArray()) -> Dictionary:
	return {"ok": true, "error": "", "profile": profile, "warnings": warnings}


static func fail(error: String) -> Dictionary:
	return {"ok": false, "error": error, "profile": null, "warnings": PackedStringArray()}


static func is_true(v: Variant) -> bool:
	var s := str(v).strip_edges().to_lower()
	return s in ["1", "true", "yes", "on"]


static func split_list(v: String) -> Array:
	var out := []
	for item in v.split(",", false):
		var t := item.strip_edges()
		if not t.is_empty():
			out.append(t)
	return out


## Builds the sing-box "tls" object.
## [param security]: "tls" | "reality" | "none" | "".
## Returns {ok, error, tls: Dictionary (empty if none), warnings, label}.
static func build_tls(q: Dictionary, security: String, server: String, default_tls: bool = false) -> Dictionary:
	var res := {"ok": true, "error": "", "tls": {}, "warnings": PackedStringArray(), "label": ""}
	var sec := security.to_lower()
	if sec == "" and default_tls:
		sec = "tls"
	if sec in ["", "none"]:
		return res
	if sec == "xtls":
		res.ok = false
		res.error = "security=xtls is obsolete (removed from Xray); use flow=xtls-rprx-vision with tls/reality"
		return res
	if not (sec in ["tls", "reality"]):
		res.ok = false
		res.error = "unsupported security \"%s\"" % security
		return res
	var tls := {"enabled": true}
	var sni := str(q.get("sni", q.get("peer", ""))).strip_edges()
	if sni.is_empty() and not server.is_valid_ip_address():
		sni = server
	if not sni.is_empty():
		tls["server_name"] = sni
	var alpn := split_list(str(q.get("alpn", "")))
	if alpn.size() > 0:
		tls["alpn"] = alpn
	if is_true(q.get("allowInsecure", q.get("allow_insecure", q.get("insecure", "0")))):
		tls["insecure"] = true
		res.warnings.append("the link disables TLS certificate verification (allowInsecure); the connection is vulnerable to MITM")
	var fp := str(q.get("fp", "")).strip_edges().to_lower()
	if not fp.is_empty() and fp != "none":
		if fp in UTLS_FINGERPRINTS:
			tls["utls"] = {"enabled": true, "fingerprint": fp}
		else:
			res.warnings.append("uTLS fingerprint \"%s\" is unknown to sing-box, using \"chrome\"" % fp)
			tls["utls"] = {"enabled": true, "fingerprint": "chrome"}
	if str(q.get("ech", "")) != "":
		res.warnings.append("ECH parameter in link is not applied")
	if sec == "reality":
		var pbk := str(q.get("pbk", "")).strip_edges()
		if pbk.is_empty():
			res.ok = false
			res.error = "REALITY requires a public key (pbk)"
			return res
		if not _is_base64url_key(pbk):
			res.ok = false
			res.error = "REALITY public key (pbk) is malformed"
			return res
		var reality := {"enabled": true, "public_key": pbk}
		var sid := str(q.get("sid", "")).strip_edges()
		if not sid.is_empty():
			if sid.length() > 16 or not sid.is_valid_hex_number(false):
				res.ok = false
				res.error = "REALITY short ID (sid) must be up to 16 hex characters"
				return res
			reality["short_id"] = sid
		tls["reality"] = reality
		if not tls.has("utls"):
			# sing-box requires uTLS for REALITY clients.
			tls["utls"] = {"enabled": true, "fingerprint": "chrome"}
		if str(q.get("spx", "")) != "":
			res.warnings.append("REALITY spiderX (spx) is an Xray-only option and is ignored")
		if str(q.get("pqv", "")) != "":
			res.warnings.append("REALITY ML-DSA verification (pqv) is not supported by sing-box and is ignored")
		if not tls.has("server_name"):
			res.ok = false
			res.error = "REALITY requires a server name (sni)"
			return res
		res.label = "Reality"
	else:
		res.label = "TLS"
	res.tls = tls
	return res


static func _is_base64url_key(k: String) -> bool:
	if k.length() < 40 or k.length() > 48:
		return false
	for ch in k:
		if not (ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=+/"):
			return false
	return true


## Builds the sing-box "transport" object from V2Ray share-link parameters.
## Returns {ok, error, transport: Dictionary (empty for raw TCP), label, warnings}.
static func build_transport(q: Dictionary, default_type: String = "tcp") -> Dictionary:
	var res := {"ok": true, "error": "", "transport": {}, "label": "", "warnings": PackedStringArray()}
	var t := str(q.get("type", default_type)).strip_edges().to_lower()
	if t.is_empty():
		t = "tcp"
	if UNSUPPORTED_TRANSPORTS.has(t):
		res.ok = false
		res.error = "transport \"%s\": %s" % [t, UNSUPPORTED_TRANSPORTS[t]]
		return res
	if not (t in SUPPORTED_TRANSPORTS):
		res.ok = false
		res.error = "unknown transport type \"%s\"" % t
		return res
	var host := str(q.get("host", "")).strip_edges()
	var path := str(q.get("path", ""))
	match t:
		"tcp", "raw":
			var header := str(q.get("headerType", "none")).to_lower()
			if header == "http":
				res.ok = false
				res.error = "TCP with HTTP header obfuscation (headerType=http) is not supported by sing-box"
				return res
			if header not in ["", "none"]:
				res.ok = false
				res.error = "unsupported TCP headerType \"%s\"" % header
				return res
		"ws":
			var tr := {"type": "ws"}
			var p := path if not path.is_empty() else "/"
			# Xray early data: "/path?ed=2048"
			var qi := p.find("?")
			if qi >= 0:
				var pq := UriUtil.parse_query(p.substr(qi + 1))
				p = p.substr(0, qi)
				if pq.ok and str(pq.values.get("ed", "")).is_valid_int():
					tr["max_early_data"] = int(pq.values.ed)
					tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
			if str(q.get("ed", "")).is_valid_int():
				tr["max_early_data"] = int(q.ed)
				tr["early_data_header_name"] = str(q.get("eh", "Sec-WebSocket-Protocol"))
			tr["path"] = p if p.begins_with("/") else "/" + p
			if not host.is_empty():
				tr["headers"] = {"Host": host}
			res.transport = tr
			res.label = "WS"
		"grpc":
			var sn := str(q.get("serviceName", q.get("service_name", path.trim_prefix("/"))))
			var tr := {"type": "grpc"}
			if not sn.is_empty():
				tr["service_name"] = sn
			if str(q.get("mode", "gun")).to_lower() == "multi":
				res.warnings.append("gRPC multi mode is not supported by sing-box; using gun mode")
			if str(q.get("authority", "")) != "":
				res.warnings.append("gRPC authority parameter is ignored")
			res.transport = tr
			res.label = "gRPC"
		"httpupgrade":
			var tr := {"type": "httpupgrade", "path": path if not path.is_empty() else "/"}
			if not host.is_empty():
				tr["host"] = host
			res.transport = tr
			res.label = "HTTPUpgrade"
		"http", "h2":
			var tr := {"type": "http"}
			var hosts := split_list(host)
			if hosts.size() > 0:
				tr["host"] = hosts
			if not path.is_empty():
				tr["path"] = path
			res.transport = tr
			res.label = "HTTP/2"
		"quic":
			var qs := str(q.get("quicSecurity", "none")).to_lower()
			if qs not in ["", "none"]:
				res.ok = false
				res.error = "QUIC transport encryption (quicSecurity=%s) is not supported by sing-box" % qs
				return res
			res.transport = {"type": "quic"}
			res.label = "QUIC"
	return res


static func unknown_param_warnings(keys: Array, known: Array) -> PackedStringArray:
	var w := PackedStringArray()
	var unknown := []
	for k in keys:
		if not (k in known) and not (k in unknown):
			unknown.append(k)
	if unknown.size() > 0:
		w.append("ignored unknown parameters: " + ", ".join(PackedStringArray(unknown)))
	return w


static func validate_server(host: String, port: int) -> String:
	if host.is_empty():
		return "server address is missing"
	if not UriUtil.is_valid_host(host):
		return "invalid server address \"%s\"" % host
	if port == -1:
		return "port is missing"
	if not UriUtil.is_valid_port(port):
		return "invalid port %d (must be 1-65535)" % port
	return ""


static func is_canonical_uuid(s: String) -> bool:
	var re := RegEx.create_from_string("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	return re.search(s) != null


## VLESS/VMess user id: a canonical UUID, or (Xray/sing-box compatible) a
## 1-30 character string that is mapped to UUIDv5. Strings that look like a
## mistyped UUID are rejected. Returns "" if valid, else an error.
static func validate_user_id(s: String) -> String:
	if s.is_empty():
		return "UUID is missing"
	if is_canonical_uuid(s):
		return ""
	var looks_like_uuid := RegEx.create_from_string("^[0-9a-fA-F-]{16,}$").search(s) != null and s.contains("-")
	if looks_like_uuid:
		return "invalid UUID \"%s\"" % SecretMasker.MASK
	if s.length() > 30:
		return "invalid UUID (not a UUID and longer than 30 characters)"
	for ch in s:
		if ch.unicode_at(0) <= 32:
			return "invalid UUID (contains whitespace)"
	return ""
