class_name TrojanParser
extends RefCounted
## Parses trojan://password@host:port?sni=..&type=..#name into a sing-box
## "trojan" outbound. TLS is on unless security=none is given explicitly.


static func parse(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed Trojan link: " + u.error)
	if u.scheme != "trojan":
		return ParserCommon.fail("not a Trojan link")
	var pw := UriUtil.percent_decode(u.userinfo)
	if not pw.ok:
		return ParserCommon.fail("password: " + pw.error)
	if str(pw.value).is_empty():
		return ParserCommon.fail("Trojan password is missing")
	var serr := ParserCommon.validate_server(u.host, u.port)
	if serr != "":
		return ParserCommon.fail(serr)
	var q: Dictionary = u.query
	var warnings := PackedStringArray()
	var tr := ParserCommon.build_transport(q)
	if not tr.ok:
		return ParserCommon.fail(tr.error)
	warnings.append_array(tr.warnings)
	var sec := str(q.get("security", "tls"))
	if sec.is_empty():
		sec = "tls"
	var tls := ParserCommon.build_tls(q, sec, u.host)
	if not tls.ok:
		return ParserCommon.fail(tls.error)
	warnings.append_array(tls.warnings)
	if tls.tls.is_empty():
		warnings.append("Trojan without TLS sends traffic unencrypted")
	if str(q.get("flow", "")) != "":
		return ParserCommon.fail("Trojan flow (XTLS) is not supported by sing-box")
	var ob := {"type": "trojan", "server": u.host, "server_port": u.port, "password": pw.value}
	if not tls.tls.is_empty():
		ob["tls"] = tls.tls
	if not tr.transport.is_empty():
		ob["transport"] = tr.transport
	warnings.append_array(ParserCommon.unknown_param_warnings(u.query_keys, ParserCommon.COMMON_PARAMS))
	var p := ProfileModel.create("trojan", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	p.transport_label = VlessParser._label(tr.label, tls.label)
	return ParserCommon.ok(p, warnings)
