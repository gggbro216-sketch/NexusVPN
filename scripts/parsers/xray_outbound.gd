class_name XrayOutbound
extends RefCounted
## Converts VLESS share-link parameters into an Xray-core outbound (JSON as in
## Xray's infra/conf, v26.10). Used only for features sing-box 1.14 lacks:
## XHTTP/SplitHTTP transport and VLESS encryption (ML-KEM).

const FINGERPRINTS := ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized", "randomizednoalpn", "unsafe"]


## True when the link needs Xray instead of sing-box.
static func needed(q: Dictionary) -> bool:
	var t := str(q.get("type", "tcp")).to_lower()
	var enc := str(q.get("encryption", "none")).strip_edges().to_lower()
	return t in ["xhttp", "splithttp"] or not (enc in ["", "none"])


## Returns {ok, error, outbound, label, warnings}.
static func build_vless(host: String, port: int, uuid: String, q: Dictionary) -> Dictionary:
	var res := {"ok": false, "error": "", "outbound": {}, "label": "", "warnings": PackedStringArray()}
	var user := {"id": uuid, "encryption": str(q.get("encryption", "none")).strip_edges()}
	if user.encryption == "":
		user.encryption = "none"
	var flow := str(q.get("flow", "")).strip_edges()
	if flow != "":
		if not (flow in ["xtls-rprx-vision", "xtls-rprx-vision-udp443"]):
			res.error = "unsupported VLESS flow \"%s\"" % flow
			return res
		user["flow"] = flow
	var stream := {}
	var t := str(q.get("type", "tcp")).to_lower()
	var labels := PackedStringArray()
	match t:
		"xhttp", "splithttp":
			stream["network"] = "xhttp"
			var xs := {"path": str(q.get("path", "/"))}
			if str(q.get("host", "")) != "":
				xs["host"] = str(q.host)
			var mode := str(q.get("mode", "auto"))
			if not (mode in ["auto", "packet-up", "stream-up", "stream-one"]):
				res.error = "unknown XHTTP mode \"%s\"" % mode
				return res
			xs["mode"] = mode
			if str(q.get("extra", "")) != "":
				var j := JsonUtil.parse(str(q.extra))
				if not j.ok or typeof(j.data) != TYPE_DICTIONARY:
					res.error = "XHTTP \"extra\" parameter is not a JSON object"
					return res
				xs["extra"] = j.data
			stream["xhttpSettings"] = xs
			labels.append("XHTTP")
		"tcp", "raw", "":
			if str(q.get("headerType", "none")) not in ["", "none"]:
				res.error = "TCP header obfuscation with VLESS encryption is not supported"
				return res
			stream["network"] = "raw"
		"ws":
			stream["network"] = "ws"
			var ws := {"path": str(q.get("path", "/"))}
			if str(q.get("host", "")) != "":
				ws["host"] = str(q.host)
			stream["wsSettings"] = ws
			labels.append("WS")
		"grpc":
			stream["network"] = "grpc"
			stream["grpcSettings"] = {"serviceName": str(q.get("serviceName", q.get("service_name", ""))),
				"multiMode": str(q.get("mode", "gun")) == "multi"}
			labels.append("gRPC")
		"httpupgrade":
			stream["network"] = "httpupgrade"
			var hu := {"path": str(q.get("path", "/"))}
			if str(q.get("host", "")) != "":
				hu["host"] = str(q.host)
			stream["httpupgradeSettings"] = hu
			labels.append("HTTPUpgrade")
		_:
			res.error = "transport \"%s\" is not supported" % t
			return res
	var sec := str(q.get("security", "none")).to_lower()
	var sni := str(q.get("sni", q.get("peer", ""))).strip_edges()
	if sni == "" and not host.is_valid_ip_address():
		sni = host
	var fp := str(q.get("fp", "")).to_lower()
	if fp != "" and not (fp in FINGERPRINTS):
		res.warnings.append("fingerprint \"%s\" unknown, using chrome" % fp)
		fp = "chrome"
	match sec:
		"", "none":
			stream["security"] = "none"
		"tls":
			stream["security"] = "tls"
			var tls := {"serverName": sni}
			var alpn := ParserCommon.split_list(str(q.get("alpn", "")))
			if alpn.size() > 0:
				tls["alpn"] = alpn
			if fp != "":
				tls["fingerprint"] = fp
			var pcs := str(q.get("pcs", "")).strip_edges()
			if pcs != "":
				for h in pcs.split(","):
					var hex := h.strip_edges().replace(":", "")
					if hex.length() != 64 or not hex.is_valid_hex_number(false):
						res.error = "certificate pin (pcs) must be SHA-256 hex"
						return res
				tls["pinnedPeerCertSha256"] = pcs
			if str(q.get("vcn", "")).strip_edges() != "":
				tls["verifyPeerCertByName"] = str(q.vcn).strip_edges()
			if ParserCommon.is_true(q.get("allowInsecure", q.get("insecure", "0"))) and pcs == "":
				# Xray 26 removed allowInsecure; verification stays on.
				res.warnings.append("allowInsecure is not supported by Xray 26 (replaced by certificate pinning, pcs); the server certificate will be verified")
			stream["tlsSettings"] = tls
			labels.append("TLS")
		"reality":
			var pbk := str(q.get("pbk", "")).strip_edges()
			if pbk == "":
				res.error = "REALITY requires a public key (pbk)"
				return res
			if sni == "":
				res.error = "REALITY requires a server name (sni)"
				return res
			var rs := {"serverName": sni, "fingerprint": fp if fp != "" else "chrome", "publicKey": pbk}
			if str(q.get("sid", "")) != "":
				rs["shortId"] = str(q.sid)
			if str(q.get("spx", "")) != "":
				rs["spiderX"] = str(q.spx)
			if str(q.get("pqv", "")) != "":
				rs["mldsa65Verify"] = str(q.pqv)
			stream["security"] = "reality"
			stream["realitySettings"] = rs
			labels.append("Reality")
		_:
			res.error = "unsupported security \"%s\"" % sec
			return res
	if user.encryption != "none":
		labels.append("ML-KEM")
	res.outbound = {
		"protocol": "vless",
		"settings": {"vnext": [{"address": host, "port": port, "users": [user]}]},
		"streamSettings": stream,
	}
	res.label = "+".join(labels)
	res.ok = true
	return res
