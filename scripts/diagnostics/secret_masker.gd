class_name SecretMasker
extends RefCounted
## Removes credentials from text before it is shown in logs or exported.
##
## Masking is applied to every log line on ingestion (not only on export), so
## secrets never reach the in-memory ring buffer or the log file.

const MASK := "***"

## Keys whose values are always secret, both in JSON and in URL query strings.
const SECRET_KEYS: PackedStringArray = [
	"uuid", "password", "passwd", "pass", "private_key", "privatekey", "pre_shared_key",
	"presharedkey", "psk", "public_key", "pbk", "publickey", "short_id", "sid", "shortid",
	"token", "auth", "auth_str", "authorization", "secret", "key", "obfs-password",
	"obfs_password", "username", "user",
]

static var _uuid_re: RegEx
static var _link_re: RegEx
static var _kv_json_re: RegEx
static var _kv_query_re: RegEx
static var _pem_re: RegEx
static var _b64_long_re: RegEx


static func _ensure() -> void:
	if _uuid_re != null:
		return
	_uuid_re = RegEx.create_from_string("(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b")
	# Userinfo part of proxy links: scheme://SECRET@host
	_link_re = RegEx.create_from_string("(?i)\\b(vless|vmess|trojan|ss|ssr|hysteria2|hy2|hysteria|tuic|anytls|socks5?|https?|wireguard|wg|ssh)://([^@\\s/]+)@")
	var keys := "|".join(SECRET_KEYS).replace("-", "\\-")
	_kv_json_re = RegEx.create_from_string("(?i)\"(" + keys + ")\"\\s*:\\s*\"[^\"]*\"")
	_kv_query_re = RegEx.create_from_string("(?i)([?&;])(" + keys + ")=([^&#\\s]*)")
	_pem_re = RegEx.create_from_string("-----BEGIN [A-Z ]+-----[\\s\\S]*?-----END [A-Z ]+-----")
	# Bare vmess:// links are a base64 JSON blob containing the UUID.
	_b64_long_re = RegEx.create_from_string("(?i)\\b(vmess|ssr)://[A-Za-z0-9+/=_-]{16,}")


## Returns [param text] with all recognised secrets replaced by [constant MASK].
static func mask(text: String) -> String:
	if text.is_empty():
		return text
	_ensure()
	var out := text
	out = _pem_re.sub(out, "-----PEM " + MASK + "-----", true)
	out = _b64_long_re.sub(out, "$1://" + MASK, true)
	out = _link_re.sub(out, "$1://" + MASK + "@", true)
	out = _kv_json_re.sub(out, "\"$1\": \"" + MASK + "\"", true)
	out = _kv_query_re.sub(out, "$1$2=" + MASK, true)
	out = _uuid_re.sub(out, MASK, true)
	return out


## Masks secret values inside a JSON-like structure (returns a deep copy).
static func mask_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in value:
				var lk := str(k).to_lower()
				if lk in SECRET_KEYS and typeof(value[k]) in [TYPE_STRING, TYPE_STRING_NAME]:
					d[k] = MASK
				else:
					d[k] = mask_value(value[k])
			return d
		TYPE_ARRAY:
			var a: Array = []
			for v in value:
				a.append(mask_value(v))
			return a
		TYPE_STRING:
			return mask(value)
	return value
