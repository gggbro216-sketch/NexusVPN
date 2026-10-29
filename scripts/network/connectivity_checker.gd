class_name ConnectivityChecker
extends Node
## Determines the public exit IP while the VPN is up by requesting a
## Cloudflare-style "trace" endpoint (key=value lines incl. ip= and loc=).
## The request goes through the system network, i.e. through the tunnel.
## Disabled via the "ip_check_enabled" setting.

const TIMEOUT_S := 10.0


## Returns (await) {ok, error, ip, country}.
func check(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = TIMEOUT_S
	http.body_size_limit = 16 * 1024
	http.max_redirects = 2
	add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: NexusVPN"]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": error_string(err), "ip": "", "country": ""}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return {"ok": false, "error": "result %d, HTTP %d" % [res[0], res[1]], "ip": "", "country": ""}
	return parse_trace((res[3] as PackedByteArray).get_string_from_utf8())


static func parse_trace(body: String) -> Dictionary:
	var ip := ""
	var loc := ""
	for line in body.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("ip="):
			ip = l.substr(3)
		elif l.begins_with("loc="):
			loc = l.substr(4).to_upper()
	if ip.is_valid_ip_address():
		return {"ok": true, "error": "", "ip": ip, "country": loc if loc.length() == 2 else ""}
	# Plain-text "what is my IP" services return only the address.
	var t := body.strip_edges()
	if t.is_valid_ip_address():
		return {"ok": true, "error": "", "ip": t, "country": ""}
	return {"ok": false, "error": "неожиданный ответ сервиса проверки IP", "ip": "", "country": ""}
