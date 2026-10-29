class_name VlessParser
extends RefCounted
## Parses vless:// share links (XTLS share-link format) into a sing-box
## "vless" outbound.
##
## vless://<uuid>@<host>:<port>?type=..&security=..&sni=..#<name>

const SUPPORTED_FLOWS := ["xtls-rprx-vision"]


static func parse(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed VLESS link: " + u.error)
	if u.scheme != "vless":
		return ParserCommon.fail("not a VLESS link")
	var uid_d := UriUtil.percent_decode(u.userinfo)
	if not uid_d.ok:
		return ParserCommon.fail("UUID: " + uid_d.error)
	var uuid: String = uid_d.value.strip_edges()
	var uerr := ParserCommon.validate_user_id(uuid)
	if uerr != "":
		return ParserCommon.fail(uerr)
	var serr := ParserCommon.validate_server(u.host, u.port)
	if serr != "":
		return ParserCommon.fail(serr)
	var q: Dictionary = u.query
	var warnings := PackedStringArray()

	if XrayOutbound.needed(q):
		# XHTTP / VLESS encryption are not in sing-box 1.14: run via Xray-core.
		var x := XrayOutbound.build_vless(u.host, u.port, uuid, q)
		if not x.ok:
			return ParserCommon.fail(x.error)
		var xp := ProfileModel.create("vless", x.outbound, u.fragment.strip_edges())
		xp.server = u.host
		xp.port = u.port
		xp.engine = "xray"
		xp.uri = link.strip_edges()
		xp.transport_label = x.label
		warnings.append_array(x.warnings)
		return ParserCommon.ok(xp, warnings)

	var enc := str(q.get("encryption", "none")).strip_edges().to_lower()
	if enc not in ["", "none"]:
		return ParserCommon.fail("VLESS encryption \"%s\" is not supported by sing-box (only \"none\")" % enc)

	var flow := str(q.get("flow", "")).strip_edges()
	if not flow.is_empty() and not (flow in SUPPORTED_FLOWS):
		return ParserCommon.fail("unsupported VLESS flow \"%s\" (sing-box supports xtls-rprx-vision)" % flow)

	var tr := ParserCommon.build_transport(q)
	if not tr.ok:
		return ParserCommon.fail(tr.error)
	warnings.append_array(tr.warnings)

	var sec := str(q.get("security", "none"))
	var tls := ParserCommon.build_tls(q, sec, u.host)
	if not tls.ok:
		return ParserCommon.fail(tls.error)
	warnings.append_array(tls.warnings)

	if not flow.is_empty():
		if tls.tls.is_empty():
			return ParserCommon.fail("flow %s requires TLS or REALITY" % flow)
		if not tr.transport.is_empty():
			return ParserCommon.fail("flow %s works only with raw TCP transport" % flow)

	var ob := {
		"type": "vless",
		"server": u.host,
		"server_port": u.port,
		"uuid": uuid,
	}
	if not flow.is_empty():
		ob["flow"] = flow
	if not tls.tls.is_empty():
		ob["tls"] = tls.tls
	if not tr.transport.is_empty():
		ob["transport"] = tr.transport
	var pe := str(q.get("packetEncoding", "")).to_lower()
	if pe in ["xudp", "packetaddr"]:
		ob["packet_encoding"] = pe
	elif pe == "none":
		ob["packet_encoding"] = ""

	warnings.append_array(ParserCommon.unknown_param_warnings(u.query_keys, ParserCommon.COMMON_PARAMS))
	var p := ProfileModel.create("vless", ob, u.fragment.strip_edges())
	p.uri = link.strip_edges()
	p.transport_label = _label(tr.label, tls.label)
	return ParserCommon.ok(p, warnings)


static func _label(transport: String, security: String) -> String:
	var parts := PackedStringArray()
	if not transport.is_empty():
		parts.append(transport)
	if not security.is_empty():
		parts.append(security)
	return "+".join(parts)
