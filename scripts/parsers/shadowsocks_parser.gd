class_name ShadowsocksParser
extends RefCounted
## Parses ss:// links: SIP002 (base64url userinfo or percent-encoded
## "method:password" for 2022 ciphers) and the legacy all-base64 form.

## Methods accepted by sing-box 1.14 shadowsocks outbound (option/shadowsocks.go).
const METHODS := ["none", "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
	"xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
	"2022-blake3-chacha20-poly1305", "aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb",
	"aes-192-cfb", "aes-256-cfb", "rc4-md5", "chacha20-ietf", "xchacha20"]
const LEGACY_STREAM := ["aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb",
	"aes-256-cfb", "rc4-md5", "chacha20-ietf", "xchacha20"]
## SIP003 plugins implemented by sing-box.
const PLUGINS := ["obfs-local", "v2ray-plugin"]
const ALIASES := {"chacha20-poly1305": "chacha20-ietf-poly1305", "xchacha20-poly1305": "xchacha20-ietf-poly1305"}


static func parse(link: String) -> Dictionary:
	var s := link.strip_edges()
	if not s.to_lower().begins_with("ss://"):
		return ParserCommon.fail("not a Shadowsocks link")
	var body := s.substr(5)
	var name := ""
	var hash_i := body.find("#")
	if hash_i >= 0:
		var fd := UriUtil.percent_decode(body.substr(hash_i + 1))
		name = fd.value if fd.ok else body.substr(hash_i + 1)
		body = body.substr(0, hash_i)
	var method := ""
	var password := ""
	var host := ""
	var port := -1
	var query := {}
	var query_keys := []
	if body.contains("@"):
		# SIP002
		var u := UriUtil.parse("ss://" + body)
		if not u.ok:
			return ParserCommon.fail("malformed Shadowsocks link: " + u.error)
		host = u.host
		port = u.port
		query = u.query
		query_keys = u.query_keys
		var cred := _decode_userinfo(u.userinfo)
		if not cred.ok:
			return ParserCommon.fail(cred.error)
		method = cred.method
		password = cred.password
	else:
		# Legacy: ss://base64(method:password@host:port)
		var q_i := body.find("?")
		if q_i >= 0:
			var pq := UriUtil.parse_query(body.substr(q_i + 1))
			if pq.ok:
				query = pq.values
				query_keys = pq.keys
			body = body.substr(0, q_i)
		var dec := UriUtil.base64_to_text(body.trim_suffix("/"))
		if not dec.ok:
			return ParserCommon.fail("Shadowsocks link is not valid base64: " + dec.error)
		var at := str(dec.text).rfind("@")
		if at < 0:
			return ParserCommon.fail("malformed legacy Shadowsocks link")
		var mp := str(dec.text).substr(0, at)
		var colon := mp.find(":")
		if colon < 0:
			return ParserCommon.fail("Shadowsocks credentials must be method:password")
		method = mp.substr(0, colon)
		password = mp.substr(colon + 1)
		var hp := UriUtil.split_host_port(str(dec.text).substr(at + 1))
		if not hp.ok:
			return ParserCommon.fail(hp.error)
		host = hp.host
		port = hp.port
	method = method.strip_edges().to_lower()
	method = ALIASES.get(method, method)
	var serr := ParserCommon.validate_server(host, port)
	if serr != "":
		return ParserCommon.fail(serr)
	if not (method in METHODS):
		return ParserCommon.fail("unsupported Shadowsocks method \"%s\"" % method)
	var verr := validate_password(method, password)
	if verr != "":
		return ParserCommon.fail(verr)
	var warnings := PackedStringArray()
	if method in LEGACY_STREAM:
		warnings.append("legacy stream cipher %s is insecure" % method)
	if method == "none":
		warnings.append("Shadowsocks method \"none\" provides no encryption")
	var ob := {"type": "shadowsocks", "server": host, "server_port": port, "method": method, "password": password}
	var label := ""
	var plugin := str(query.get("plugin", "")).strip_edges()
	if not plugin.is_empty():
		var semi := plugin.find(";")
		var pname := plugin if semi < 0 else plugin.substr(0, semi)
		var popts := "" if semi < 0 else plugin.substr(semi + 1)
		if pname in ["simple-obfs", "obfs"]:
			pname = "obfs-local"
		if not (pname in PLUGINS):
			return ParserCommon.fail("Shadowsocks plugin \"%s\" is not supported by sing-box (supported: obfs-local, v2ray-plugin)" % pname)
		ob["plugin"] = pname
		if not popts.is_empty():
			ob["plugin_opts"] = popts
		label = pname
	if str(query.get("uot", "")) != "" and ParserCommon.is_true(query.get("uot")):
		ob["udp_over_tcp"] = {"enabled": true}
	warnings.append_array(ParserCommon.unknown_param_warnings(query_keys, ["plugin", "uot", "group"]))
	var p := ProfileModel.create("shadowsocks", ob, name.strip_edges())
	p.uri = s
	p.transport_label = "SS2022" if method.begins_with("2022-") else label
	return ParserCommon.ok(p, warnings)


static func _decode_userinfo(userinfo: String) -> Dictionary:
	var pd := UriUtil.percent_decode(userinfo)
	if not pd.ok:
		return {"ok": false, "error": "credentials: " + pd.error}
	var plain: String = pd.value
	# SIP002 2022 ciphers: plain "method:password" (password is base64 and may contain ':')
	if plain.contains(":"):
		var c := plain.find(":")
		var m := plain.substr(0, c).to_lower()
		if m in METHODS or ALIASES.has(m):
			return {"ok": true, "method": m, "password": plain.substr(c + 1), "error": ""}
	var dec := UriUtil.base64_to_text(userinfo)
	if not dec.ok:
		return {"ok": false, "error": "credentials are neither base64 nor method:password"}
	var t: String = dec.text
	var c2 := t.find(":")
	if c2 < 0:
		return {"ok": false, "error": "Shadowsocks credentials must be method:password"}
	return {"ok": true, "method": t.substr(0, c2), "password": t.substr(c2 + 1), "error": ""}


## Shadowsocks 2022 requires base64 PSKs of the exact cipher key length
## (multi-user form "iPSK:uPSK" is allowed).
static func validate_password(method: String, password: String) -> String:
	if method == "none":
		return ""
	if password.is_empty():
		return "Shadowsocks password is missing"
	if method.begins_with("2022-"):
		var need := 16 if method == "2022-blake3-aes-128-gcm" else 32
		for part in password.split(":"):
			var b := UriUtil.base64_decode_lenient(part)
			if not b.ok or b.bytes.size() != need:
				return "Shadowsocks 2022 key must be base64 of %d bytes" % need
	return ""
