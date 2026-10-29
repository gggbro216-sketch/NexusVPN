class_name SubscriptionUpdater
extends Node
## Downloads subscription content safely (non-blocking, threaded HTTPRequest).
##
## Protections: HTTPS only (HTTP only if explicitly allowed), TLS verification
## always on, private/loopback/link-local targets refused (checked on every
## redirect hop after DNS resolution), redirects followed manually (max 5),
## response size limit, overall timeout.

const MAX_BODY := 8 * 1024 * 1024
const MAX_REDIRECTS := 5
const TIMEOUT_S := 25.0
const RESOLVE_TIMEOUT_MS := 8000


## Returns "" if the URL may be fetched, else the reason.
static func validate_url(url: String, allow_http: bool) -> String:
	var u := url.strip_edges()
	if u.length() > 4096:
		return "адрес слишком длинный"
	var lower := u.to_lower()
	if lower.begins_with("http://"):
		if not allow_http:
			return "незащищённый HTTP запрещён (включите в настройках подписок, если уверены)"
	elif not lower.begins_with("https://"):
		return "адрес подписки должен начинаться с https://"
	var p := UriUtil.parse(u)
	if not p.ok:
		return "некорректный адрес: " + p.error
	if p.host.is_empty():
		return "в адресе нет хоста"
	if not str(p.userinfo).is_empty():
		return "адреса с логином в URL не поддерживаются"
	var h := str(p.host).to_lower()
	if h == "localhost" or h.ends_with(".localhost") or h.ends_with(".local") or h.ends_with(".internal") or h.ends_with(".lan"):
		return "обращение к локальным адресам запрещено"
	if h.is_valid_ip_address() and is_private_ip(h):
		return "обращение к локальным/внутренним адресам запрещено"
	return ""


static func is_private_ip(ip: String) -> bool:
	if ip.contains(":"):
		var l := ip.to_lower()
		if l == "::1" or l == "::" or l.begins_with("fe8") or l.begins_with("fe9") or l.begins_with("fea") or l.begins_with("feb"):
			return true
		if l.begins_with("fc") or l.begins_with("fd"):
			return true
		if l.begins_with("::ffff:"):
			return is_private_ip(l.substr(7))
		return false
	var o := ip.split(".")
	if o.size() != 4:
		return true
	var a := int(o[0])
	var b := int(o[1])
	return a == 0 or a == 10 or a == 127 or (a == 169 and b == 254) or (a == 172 and b >= 16 and b <= 31) \
		or (a == 192 and b == 168) or (a == 100 and b >= 64 and b <= 127) or a >= 224


## Fetches [param url]. Returns (await) {ok, error, status, body: String, headers: Dictionary, final_url}.
func fetch(url: String, user_agent: String, allow_http: bool) -> Dictionary:
	var current := url.strip_edges()
	var started := Time.get_ticks_msec()
	for hop in MAX_REDIRECTS + 1:
		var verr := validate_url(current, allow_http)
		if verr != "":
			return _fail(verr)
		var host := str(UriUtil.parse(current).host)
		if not host.is_valid_ip_address():
			var rerr := await _check_resolved(host)
			if rerr != "":
				return _fail(rerr)
		var remaining := TIMEOUT_S - (Time.get_ticks_msec() - started) / 1000.0
		if remaining <= 1.0:
			return _fail("превышено время ожидания")
		var r := await _request(current, user_agent, remaining)
		if not r.ok:
			return r
		if r.status in [301, 302, 303, 307, 308]:
			var loc := str(r.headers.get("location", ""))
			if loc.is_empty():
				return _fail("перенаправление без адреса")
			current = _resolve_location(current, loc)
			continue
		if r.status < 200 or r.status >= 300:
			return _fail("сервер ответил HTTP %d" % r.status, r.status)
		r.final_url = current
		return r
	return _fail("слишком много перенаправлений")


func _request(url: String, ua: String, timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.max_redirects = 0
	http.body_size_limit = MAX_BODY
	http.timeout = timeout_s
	http.accept_gzip = true
	add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: " + ua, "Accept: */*"]))
	if err != OK:
		http.queue_free()
		return _fail("не удалось начать запрос: %s" % error_string(err))
	var res: Array = await http.request_completed
	http.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	var headers := _parse_headers(res[2])
	var body: PackedByteArray = res[3]
	match result:
		HTTPRequest.RESULT_SUCCESS:
			pass
		HTTPRequest.RESULT_TIMEOUT:
			return _fail("превышено время ожидания ответа")
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return _fail("ответ слишком большой (более %d МБ)" % (MAX_BODY / 1048576))
		HTTPRequest.RESULT_CANT_RESOLVE:
			return _fail("не удалось разрешить имя сервера")
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR:
			return _fail("не удалось подключиться к серверу")
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return _fail("ошибка TLS (сертификат не прошёл проверку)")
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			pass
		_:
			return _fail("ошибка сети (код %d)" % result)
	var text := body.get_string_from_utf8()
	if text.to_utf8_buffer() != body and code >= 200 and code < 300:
		return _fail("ответ не является текстом в кодировке UTF-8")
	return {"ok": true, "error": "", "status": code, "body": text, "headers": headers, "final_url": url}


func _check_resolved(host: String) -> String:
	var id := IP.resolve_hostname_queue_item(host, IP.TYPE_ANY)
	if id == IP.RESOLVER_INVALID_ID:
		return "не удалось разрешить имя сервера"
	var t0 := Time.get_ticks_msec()
	while IP.get_resolve_item_status(id) == IP.RESOLVER_STATUS_WAITING:
		if Time.get_ticks_msec() - t0 > RESOLVE_TIMEOUT_MS:
			IP.erase_resolve_item(id)
			return "превышено время разрешения имени"
		await get_tree().create_timer(0.05).timeout
	var addrs := IP.get_resolve_item_addresses(id)
	IP.erase_resolve_item(id)
	if addrs.is_empty():
		return "не удалось разрешить имя сервера"
	for a in addrs:
		if is_private_ip(a):
			return "имя сервера указывает на локальный адрес (%s) — запрос заблокирован" % a
	return ""


static func _parse_headers(raw: PackedStringArray) -> Dictionary:
	var h := {}
	for line in raw:
		var c := line.find(":")
		if c > 0:
			h[line.substr(0, c).strip_edges().to_lower()] = line.substr(c + 1).strip_edges()
	return h


static func _resolve_location(base: String, loc: String) -> String:
	if loc.contains("://"):
		return loc
	var p := UriUtil.parse(base)
	var origin := "%s://%s" % [p.scheme, base.split("://")[1].split("/")[0]]
	if loc.begins_with("//"):
		return p.scheme + ":" + loc
	if loc.begins_with("/"):
		return origin + loc
	var path := str(p.path)
	var dir := path.substr(0, path.rfind("/") + 1) if path.contains("/") else "/"
	return origin + dir + loc


static func _fail(msg: String, status: int = 0) -> Dictionary:
	return {"ok": false, "error": msg, "status": status, "body": "", "headers": {}, "final_url": ""}


## Parses "upload=1; download=2; total=3; expire=4".
static func parse_user_info(v: String) -> Dictionary:
	var out := {}
	for part in v.split(";", false):
		var kv := part.strip_edges().split("=")
		if kv.size() == 2 and kv[1].strip_edges().is_valid_int():
			out[kv[0].strip_edges().to_lower()] = int(kv[1].strip_edges())
	return out


## Decodes "profile-title" header (plain or "base64:...").
static func parse_title(v: String) -> String:
	var t := v.strip_edges()
	if t.to_lower().begins_with("base64:"):
		var d := UriUtil.base64_to_text(t.substr(7))
		return d.text if d.ok else ""
	return t.substr(0, 80)
