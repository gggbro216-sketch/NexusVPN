class_name QuicParsers
extends RefCounted
## Parsers for QUIC-based protocols and other simple share links:
## hysteria2:// (hy2://), tuic://, anytls://, socks5:// (socks://).


## hysteria2://[auth@]host[:port][/]?sni=..&insecure=1&obfs=salamander&obfs-password=..&mport=..#name
static func parse_hysteria2(link: String) -> Dictionary:
	var s := link.strip_edges()
	var lower := s.to_lower()
	if lower.begins_with("hy2://"):
		s = "hysteria2://" + s.substr(6)
	var u := UriUtil.parse(s)
	if not u.ok:
		return ParserCommon.fail("malformed Hysteria2 link: " + u.error)
	if u.scheme != "hysteria2":
		return ParserCommon.fail("not a Hysteria2 link")
	var q: Dictionary = u.query
	var warnings := PackedStringArray()
	var port: int = u.port if u.port != -1 else 443
	# Port hopping: host:443,1000-2000 is not representable in the authority; use mport.
	var serr := ParserCommon.validate_server(u.host, port)
	if serr != "":
		return ParserCommon.fail(serr)
	var auth := UriUtil.percent_decode(u.userinfo)
	if not auth.ok:
		return ParserCommon.fail("auth: " + auth.error)
	var ob := {"type": "hysteria2", "server": u.host, "server_port": port}
	if not str(auth.value).is_empty():
		ob["password"] = auth.value
	var obfs := str(q.get("obfs", "")).to_lower()
	if not obfs.is_empty() and obfs != "none":
		if obfs != "salamander":
			return ParserCommon.fail("Hysteria2 obfs \"%s\" is not supported" % obfs)
		var op := str(q.get("obfs-password", ""))
		if op.is_empty():
			return ParserCommon.fail("Hysteria2 salamander obfs requires obfs-password")
		ob["obfs"] = {"type": "salamander", "password": op}
	var mport := str(q.get("mport", "")).strip_edges()
	if not mport.is_empty():
		var ranges := []
		for part in mport.split(",", false):
			var r := part.strip_edges().replace("-", ":")
			var ends := r.split(":")
			var valid := ends.size() in [1, 2]
			for e in ends:
				valid = valid and e.is_valid_int() and UriUtil.is_valid_port(int(e))
			if not valid:
				return ParserCommon.fail("invalid Hysteria2 port hopping range \"%s\"" % part)
			ranges.append(r if ends.size() == 2 else "%s:%s" % [ends[0], ends[0]])
		ob["server_ports"] = ranges
	var tls := {"enabled": true}
	var sni := str(q.get("sni", q.get("peer", ""))).strip_edges()
	if sni.is_empty() and not u.host.is_valid_ip_address():
		sni = u.host
	if not sni.is_empty():
		tls["server_name"] = sni
	if ParserCommon.is_true(q.get("insecure", q.get("allowInsecure", "0"))):
		tls["insecure"] = true
		warnings.append("the link disables TLS certificate verification (insecure=1)")
	if str(q.get("pinSHA256", "")) != "":
		warnings.append("pinSHA256 is not applied (use certificate_public_key_sha256 in JSON editor)")
	var alpn := ParserCommon.split_list(str(q.get("alpn", "")))
	if alpn.size() > 0:
		tls["alpn"] = alpn
	ob["tls"] = tls
	for k in ["upmbps", "up"]:
		if str(q.get(k, "")).is_valid_int():
			ob["up_mbps"] = int(q[k])
	for k in ["downmbps", "down"]:
		if str(q.get(k, "")).is_valid_int():
			ob["down_mbps"] = int(q[k])
	warnings.append_array(ParserCommon.unknown_param_warnings(u.query_keys,
		["sni", "peer", "insecure", "allowInsecure", "obfs", "obfs-password", "mport", "alpn", "pinSHA256", "upmbps", "downmbps", "up", "down"]))
	var p := ProfileModel.create("hysteria2", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	p.transport_label = "Salamander" if ob.has("obfs") else ""
	return ParserCommon.ok(p, warnings)


## tuic://uuid:password@host:port?congestion_control=bbr&alpn=h3&sni=..&udp_relay_mode=native#name
static func parse_tuic(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed TUIC link: " + u.error)
	if u.scheme != "tuic":
		return ParserCommon.fail("not a TUIC link")
	var serr := ParserCommon.validate_server(u.host, u.port)
	if serr != "":
		return ParserCommon.fail(serr)
	var colon := str(u.userinfo).find(":")
	if colon < 0:
		return ParserCommon.fail("TUIC link must contain uuid:password")
	var id_d := UriUtil.percent_decode(str(u.userinfo).substr(0, colon))
	var pw_d := UriUtil.percent_decode(str(u.userinfo).substr(colon + 1))
	if not id_d.ok or not pw_d.ok:
		return ParserCommon.fail("TUIC credentials contain invalid percent-encoding")
	if not ParserCommon.is_canonical_uuid(id_d.value):
		return ParserCommon.fail("TUIC requires a valid UUID")
	var q: Dictionary = u.query
	var warnings := PackedStringArray()
	var ob := {"type": "tuic", "server": u.host, "server_port": u.port, "uuid": id_d.value, "password": pw_d.value}
	var cc := str(q.get("congestion_control", q.get("congestion", ""))).to_lower()
	if not cc.is_empty():
		if not (cc in ["cubic", "new_reno", "bbr"]):
			return ParserCommon.fail("unsupported TUIC congestion control \"%s\"" % cc)
		ob["congestion_control"] = cc
	var relay := str(q.get("udp_relay_mode", "")).to_lower()
	if not relay.is_empty():
		if not (relay in ["native", "quic"]):
			return ParserCommon.fail("unsupported TUIC udp_relay_mode \"%s\"" % relay)
		ob["udp_relay_mode"] = relay
	var tls := {"enabled": true}
	var sni := str(q.get("sni", "")).strip_edges()
	if sni.is_empty() and not u.host.is_valid_ip_address():
		sni = u.host
	if not sni.is_empty():
		tls["server_name"] = sni
	var alpn := ParserCommon.split_list(str(q.get("alpn", "h3")))
	tls["alpn"] = alpn
	if ParserCommon.is_true(q.get("allow_insecure", q.get("insecure", q.get("allowInsecure", "0")))):
		tls["insecure"] = true
		warnings.append("the link disables TLS certificate verification")
	if ParserCommon.is_true(q.get("disable_sni", "0")):
		tls["disable_sni"] = true
	ob["tls"] = tls
	warnings.append_array(ParserCommon.unknown_param_warnings(u.query_keys,
		["congestion_control", "congestion", "udp_relay_mode", "sni", "alpn", "allow_insecure", "insecure", "allowInsecure", "disable_sni"]))
	var p := ProfileModel.create("tuic", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	return ParserCommon.ok(p, warnings)


## anytls://password@host:port?sni=..&insecure=1&fp=..#name
static func parse_anytls(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed AnyTLS link: " + u.error)
	if u.scheme != "anytls":
		return ParserCommon.fail("not an AnyTLS link")
	var port: int = u.port if u.port != -1 else 443
	var serr := ParserCommon.validate_server(u.host, port)
	if serr != "":
		return ParserCommon.fail(serr)
	var pw := UriUtil.percent_decode(u.userinfo)
	if not pw.ok or str(pw.value).is_empty():
		return ParserCommon.fail("AnyTLS password is missing or malformed")
	var tls := ParserCommon.build_tls(u.query, "tls", u.host)
	if not tls.ok:
		return ParserCommon.fail(tls.error)
	var ob := {"type": "anytls", "server": u.host, "server_port": port, "password": pw.value, "tls": tls.tls}
	var warnings: PackedStringArray = tls.warnings
	warnings.append_array(ParserCommon.unknown_param_warnings(u.query_keys, ["sni", "peer", "insecure", "allowInsecure", "fp", "alpn"]))
	var p := ProfileModel.create("anytls", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	return ParserCommon.ok(p, warnings)


## socks5://[user:pass@]host:port#name  (also socks:// and socks4://)
static func parse_socks(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed SOCKS link: " + u.error)
	if not (u.scheme in ["socks", "socks5", "socks5h", "socks4", "socks4a"]):
		return ParserCommon.fail("not a SOCKS link")
	var serr := ParserCommon.validate_server(u.host, u.port)
	if serr != "":
		return ParserCommon.fail(serr)
	var ob := {"type": "socks", "server": u.host, "server_port": u.port}
	match str(u.scheme):
		"socks4":
			ob["version"] = "4"
		"socks4a":
			ob["version"] = "4a"
		_:
			ob["version"] = "5"
	var warnings := PackedStringArray(["SOCKS is not encrypted; use only over trusted networks"])
	if not str(u.userinfo).is_empty():
		var ui: String = u.userinfo
		# Some generators base64-encode "user:pass".
		if not ui.contains(":"):
			var b := UriUtil.base64_to_text(ui)
			if b.ok and str(b.text).contains(":"):
				ui = b.text
		var c := ui.find(":")
		var user := UriUtil.percent_decode(ui if c < 0 else ui.substr(0, c))
		var pw := UriUtil.percent_decode("" if c < 0 else ui.substr(c + 1))
		if not user.ok or not pw.ok:
			return ParserCommon.fail("SOCKS credentials contain invalid percent-encoding")
		ob["username"] = user.value
		if not str(pw.value).is_empty():
			ob["password"] = pw.value
	var p := ProfileModel.create("socks", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	return ParserCommon.ok(p, warnings)
