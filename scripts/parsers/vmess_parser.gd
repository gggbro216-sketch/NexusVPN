class_name VmessParser
extends RefCounted
## Parses vmess:// links: the common v2rayN base64-JSON format and the
## URI form (vmess://uuid@host:port?...). Produces a sing-box "vmess" outbound.

const CIPHERS := ["auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-ctr"]
const JSON_KEYS := ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path",
	"tls", "sni", "alpn", "fp", "allowInsecure", "insecure", "security", "skip-cert-verify", "remark", "pbk", "sid"]


static func parse(link: String) -> Dictionary:
	var s := link.strip_edges()
	if not s.to_lower().begins_with("vmess://"):
		return ParserCommon.fail("not a VMess link")
	var body := s.substr(8)
	if body.contains("@"):
		return _parse_uri(s)
	var name_hint := ""
	var hash_i := body.find("#")
	if hash_i >= 0:
		var fd := UriUtil.percent_decode(body.substr(hash_i + 1))
		name_hint = fd.value if fd.ok else ""
		body = body.substr(0, hash_i)
	var dec := UriUtil.base64_to_text(body)
	if not dec.ok:
		return ParserCommon.fail("VMess link is not valid base64: " + dec.error)
	var j := JsonUtil.parse(dec.text)
	if not j.ok or typeof(j.data) != TYPE_DICTIONARY:
		return ParserCommon.fail("VMess link does not contain a JSON object")
	return _from_json(j.data, s, name_hint)


static func _from_json(d: Dictionary, link: String, name_hint: String) -> Dictionary:
	var warnings := PackedStringArray()
	var host := str(d.get("add", "")).strip_edges()
	var port_v: Variant = d.get("port", -1)
	var port := -1
	if typeof(port_v) in [TYPE_INT, TYPE_FLOAT]:
		port = int(port_v)
	elif str(port_v).strip_edges().is_valid_int():
		port = int(str(port_v))
	elif str(port_v) != "":
		return ParserCommon.fail("invalid port \"%s\"" % str(port_v))
	var serr := ParserCommon.validate_server(host, port)
	if serr != "":
		return ParserCommon.fail(serr)
	var uuid := str(d.get("id", "")).strip_edges()
	var uerr := ParserCommon.validate_user_id(uuid)
	if uerr != "":
		return ParserCommon.fail(uerr)
	var aid := int(str(d.get("aid", "0"))) if str(d.get("aid", "0")).is_valid_int() else 0
	var cipher := str(d.get("scy", "auto")).strip_edges().to_lower()
	if cipher.is_empty():
		cipher = "auto"
	if not (cipher in CIPHERS):
		return ParserCommon.fail("unsupported VMess cipher \"%s\"" % cipher)
	# Map JSON fields to the V2Ray query-parameter vocabulary.
	var net := str(d.get("net", "tcp")).to_lower()
	var q := {
		"type": net,
		"headerType": str(d.get("type", "none")),
		"host": str(d.get("host", "")),
		"path": str(d.get("path", "")),
		"sni": str(d.get("sni", "")),
		"alpn": str(d.get("alpn", "")),
		"fp": str(d.get("fp", "")),
		"allowInsecure": str(d.get("allowInsecure", d.get("insecure", d.get("skip-cert-verify", "0")))),
		"pbk": str(d.get("pbk", "")),
		"sid": str(d.get("sid", "")),
	}
	if net == "grpc":
		q["serviceName"] = str(d.get("path", ""))
		q.erase("path")
	if net in ["tcp", "raw"] and str(d.get("type", "none")).to_lower() not in ["", "none"]:
		return ParserCommon.fail("VMess TCP header type \"%s\" is not supported by sing-box" % str(d.get("type")))
	if net in ["kcp", "mkcp", "quic"] and str(d.get("type", "none")).to_lower() not in ["", "none"]:
		return ParserCommon.fail("VMess %s with header obfuscation is not supported by sing-box" % net)
	q["headerType"] = "none"
	var tr := ParserCommon.build_transport(q)
	if not tr.ok:
		return ParserCommon.fail(tr.error)
	warnings.append_array(tr.warnings)
	var tls_v := str(d.get("tls", "")).to_lower()
	var tls := ParserCommon.build_tls(q, tls_v, host)
	if not tls.ok:
		return ParserCommon.fail(tls.error)
	warnings.append_array(tls.warnings)
	for k in d:
		if not (k in JSON_KEYS):
			warnings.append("ignored unknown field \"%s\"" % k)
	var ob := {"type": "vmess", "server": host, "server_port": port, "uuid": uuid, "security": cipher, "alter_id": aid}
	if not tls.tls.is_empty():
		ob["tls"] = tls.tls
	if not tr.transport.is_empty():
		ob["transport"] = tr.transport
	var name := str(d.get("ps", d.get("remark", ""))).strip_edges()
	if name.is_empty():
		name = name_hint
	var p := ProfileModel.create("vmess", ob, name)
	p.uri = link
	p.transport_label = VlessParser._label(tr.label, tls.label)
	return ParserCommon.ok(p, warnings)


static func _parse_uri(link: String) -> Dictionary:
	var u := UriUtil.parse(link)
	if not u.ok:
		return ParserCommon.fail("malformed VMess link: " + u.error)
	var uid := UriUtil.percent_decode(u.userinfo)
	if not uid.ok:
		return ParserCommon.fail("UUID: " + uid.error)
	var d := {
		"add": u.host, "port": u.port, "id": uid.value, "aid": str(u.query.get("aid", "0")),
		"scy": str(u.query.get("encryption", "auto")), "net": str(u.query.get("type", "tcp")),
		"type": str(u.query.get("headerType", "none")), "host": str(u.query.get("host", "")),
		"path": str(u.query.get("path", u.query.get("serviceName", ""))),
		"tls": str(u.query.get("security", "")), "sni": str(u.query.get("sni", "")),
		"alpn": str(u.query.get("alpn", "")), "fp": str(u.query.get("fp", "")),
		"allowInsecure": str(u.query.get("allowInsecure", "0")),
		"pbk": str(u.query.get("pbk", "")), "sid": str(u.query.get("sid", "")),
		"ps": u.fragment,
	}
	return _from_json(d, link, u.fragment)
