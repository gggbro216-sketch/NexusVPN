class_name UriUtil
extends RefCounted
## Strict URI helpers for share links (RFC 3986 subset).

const MAX_LINK_LENGTH := 16384


## Strict percent-decoding. Returns {ok, value, error}.
## Rejects malformed escapes ("%G1", "%4") and invalid UTF-8 sequences.
static func percent_decode(s: String, plus_as_space: bool = false) -> Dictionary:
	if not s.contains("%") and not (plus_as_space and s.contains("+")):
		return {"ok": true, "value": s, "error": ""}
	var src := s.to_utf8_buffer()
	var out := PackedByteArray()
	var i := 0
	while i < src.size():
		var c := src[i]
		if c == 0x25: # '%'
			if i + 2 >= src.size():
				return {"ok": false, "value": "", "error": "truncated percent-escape"}
			var h := _hex(src[i + 1])
			var l := _hex(src[i + 2])
			if h < 0 or l < 0:
				return {"ok": false, "value": "", "error": "invalid percent-escape \"%s\"" % s.substr(_char_index(s, i), 3)}
			out.append(h * 16 + l)
			i += 3
		elif c == 0x2B and plus_as_space:
			out.append(0x20)
			i += 1
		else:
			out.append(c)
			i += 1
	var decoded := out.get_string_from_utf8()
	# get_string_from_utf8 replaces invalid sequences; detect by round-tripping.
	if decoded.to_utf8_buffer() != out:
		return {"ok": false, "value": "", "error": "percent-decoded value is not valid UTF-8"}
	return {"ok": true, "value": decoded, "error": ""}


static func _char_index(s: String, byte_index: int) -> int:
	# Escapes are ASCII so byte index == char index for well-formed prefixes in practice.
	return mini(byte_index, s.length() - 1)


static func _hex(b: int) -> int:
	if b >= 0x30 and b <= 0x39:
		return b - 0x30
	if b >= 0x41 and b <= 0x46:
		return b - 0x41 + 10
	if b >= 0x61 and b <= 0x66:
		return b - 0x61 + 10
	return -1


## Splits a URI into components without decoding the userinfo.
## Returns {ok, error, scheme, userinfo, host, port (int, -1 if absent), path,
##          query: Dictionary (decoded, last value wins), query_keys: Array (in order),
##          fragment (decoded)}.
static func parse(uri: String) -> Dictionary:
	var r := {"ok": false, "error": "", "scheme": "", "userinfo": "", "host": "", "port": -1,
		"path": "", "query": {}, "query_keys": [], "fragment": "", "raw_query": ""}
	var s := uri.strip_edges()
	if s.length() > MAX_LINK_LENGTH:
		r.error = "link is too long"
		return r
	var se := s.find("://")
	if se <= 0:
		r.error = "missing scheme"
		return r
	r.scheme = s.substr(0, se).to_lower()
	var rest := s.substr(se + 3)
	var hash_i := rest.find("#")
	if hash_i >= 0:
		var frag := percent_decode(rest.substr(hash_i + 1))
		if not frag.ok:
			# Fragments are display names; be lenient, fall back to the raw text.
			r.fragment = rest.substr(hash_i + 1)
		else:
			r.fragment = frag.value
		rest = rest.substr(0, hash_i)
	var q_i := rest.find("?")
	if q_i >= 0:
		r.raw_query = rest.substr(q_i + 1)
		var q := parse_query(r.raw_query)
		if not q.ok:
			r.error = q.error
			return r
		r.query = q.values
		r.query_keys = q.keys
		rest = rest.substr(0, q_i)
	var slash := rest.find("/")
	var authority := rest
	if slash >= 0:
		authority = rest.substr(0, slash)
		r.path = rest.substr(slash)
	var at := authority.rfind("@")
	if at >= 0:
		r.userinfo = authority.substr(0, at)
		authority = authority.substr(at + 1)
	var hp := split_host_port(authority)
	if not hp.ok:
		r.error = hp.error
		return r
	r.host = hp.host
	r.port = hp.port
	r.ok = true
	return r


## Parses "host", "host:port", "[v6]:port". Returns {ok, error, host, port}.
static func split_host_port(authority: String) -> Dictionary:
	var res := {"ok": false, "error": "", "host": "", "port": -1}
	var host := authority
	var port_s := ""
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			res.error = "unterminated IPv6 address"
			return res
		host = authority.substr(1, close - 1)
		var after := authority.substr(close + 1)
		if after.begins_with(":"):
			port_s = after.substr(1)
		elif not after.is_empty():
			res.error = "unexpected characters after IPv6 address"
			return res
		if not host.is_valid_ip_address():
			res.error = "invalid IPv6 address"
			return res
	else:
		var colon := authority.rfind(":")
		if colon >= 0:
			if authority.count(":") > 1:
				res.error = "IPv6 addresses must be enclosed in []"
				return res
			host = authority.substr(0, colon)
			port_s = authority.substr(colon + 1)
	var hd := percent_decode(host)
	if not hd.ok:
		res.error = "host: " + hd.error
		return res
	host = hd.value
	if port_s != "":
		if not port_s.is_valid_int():
			res.error = "invalid port \"%s\"" % port_s
			return res
		res.port = int(port_s)
	res.host = host
	res.ok = true
	return res


## Returns {ok, error, values: Dictionary, keys: Array}.
static func parse_query(q: String) -> Dictionary:
	var values := {}
	var keys := []
	for pair in q.split("&", false):
		var eq := pair.find("=")
		var k := pair if eq < 0 else pair.substr(0, eq)
		var v := "" if eq < 0 else pair.substr(eq + 1)
		var kd := percent_decode(k, true)
		var vd := percent_decode(v, true)
		if not kd.ok:
			return {"ok": false, "error": "query key: " + kd.error, "values": {}, "keys": []}
		if not vd.ok:
			return {"ok": false, "error": "parameter \"%s\": %s" % [kd.value, vd.error], "values": {}, "keys": []}
		values[kd.value] = vd.value
		keys.append(kd.value)
	return {"ok": true, "error": "", "values": values, "keys": keys}


static func is_valid_port(p: int) -> bool:
	return p >= 1 and p <= 65535


## Accepts IPv4/IPv6 literals and RFC 1123 host names (incl. IDN in Unicode form).
static func is_valid_host(h: String) -> bool:
	if h.is_empty() or h.length() > 253:
		return false
	if h.is_valid_ip_address():
		return true
	for label in h.split("."):
		if label.is_empty() or label.length() > 63:
			return false
		if label.begins_with("-") or label.ends_with("-"):
			return false
		for ch in label:
			var c := ch.unicode_at(0)
			var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95 or c > 127
			if not ok:
				return false
	return true


## Decodes standard or URL-safe base64, with or without padding/whitespace.
## Returns {ok, bytes, error}.
static func base64_decode_lenient(s: String) -> Dictionary:
	var t := s.strip_edges().replace("\r", "").replace("\n", "").replace(" ", "").replace("\t", "")
	t = t.replace("-", "+").replace("_", "/")
	if t.is_empty():
		return {"ok": false, "bytes": PackedByteArray(), "error": "empty"}
	for ch in t:
		if not (ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="):
			return {"ok": false, "bytes": PackedByteArray(), "error": "not base64"}
	t = t.rstrip("=")
	if t.length() % 4 == 1:
		return {"ok": false, "bytes": PackedByteArray(), "error": "invalid base64 length"}
	while t.length() % 4 != 0:
		t += "="
	var bytes := Marshalls.base64_to_raw(t)
	if bytes.is_empty():
		return {"ok": false, "bytes": bytes, "error": "base64 decode failed"}
	return {"ok": true, "bytes": bytes, "error": ""}


## Decodes base64 into UTF-8 text, rejecting binary/invalid UTF-8.
static func base64_to_text(s: String) -> Dictionary:
	var b := base64_decode_lenient(s)
	if not b.ok:
		return {"ok": false, "text": "", "error": b.error}
	var text: String = b.bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != b.bytes:
		return {"ok": false, "text": "", "error": "decoded data is not valid UTF-8"}
	return {"ok": true, "text": text, "error": ""}


## Encodes a component for share links (RFC 3986 unreserved kept).
static func percent_encode(s: String) -> String:
	var out := ""
	for b in s.to_utf8_buffer():
		var ch := char(b)
		if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or ch in "-._~":
			out += ch
		else:
			out += "%%%02X" % b
	return out
