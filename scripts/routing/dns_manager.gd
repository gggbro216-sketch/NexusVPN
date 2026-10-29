class_name DnsManager
extends RefCounted
## Converts DNS server addresses entered by the user into sing-box 1.14 DNS
## server objects (new typed format; legacy "address" strings were removed in 1.14).
##
## Accepted forms:
##   local                      system resolver (type "local")
##   1.1.1.1 / udp://1.1.1.1    plain DNS over UDP
##   tcp://1.1.1.1              DNS over TCP
##   tls://dns.google           DNS over TLS (853)
##   https://1.1.1.1/dns-query  DNS over HTTPS
##   h3://dns.google/dns-query  DNS over HTTP/3
##   quic://dns.adguard.com     DNS over QUIC

const SCHEMES := {"udp": "udp", "tcp": "tcp", "tls": "tls", "https": "https", "h3": "h3", "quic": "quic"}

const PRESETS := [
	{"name": "Cloudflare DoH", "value": "https://1.1.1.1/dns-query"},
	{"name": "Google DoH", "value": "https://8.8.8.8/dns-query"},
	{"name": "Quad9 DoH", "value": "https://9.9.9.9/dns-query"},
	{"name": "AdGuard DoH", "value": "https://94.140.14.14/dns-query"},
	{"name": "Cloudflare DoT", "value": "tls://1.1.1.1"},
	{"name": "Cloudflare UDP", "value": "1.1.1.1"},
]


## Returns {ok, error, server: Dictionary}. [param detour] is an outbound tag or "".
static func build_server(address: String, tag: String, detour: String = "") -> Dictionary:
	var a := address.strip_edges()
	if a.is_empty():
		return {"ok": false, "error": "DNS-адрес не задан", "server": {}}
	if a.to_lower() == "local":
		return {"ok": true, "error": "", "server": {"type": "local", "tag": tag}}
	var type := "udp"
	var rest := a
	var se := a.find("://")
	if se > 0:
		var scheme := a.substr(0, se).to_lower()
		if not SCHEMES.has(scheme):
			return {"ok": false, "error": "неподдерживаемая схема DNS \"%s\"" % scheme, "server": {}}
		type = SCHEMES[scheme]
		rest = a.substr(se + 3)
	var path := ""
	var slash := rest.find("/")
	if slash >= 0:
		path = rest.substr(slash)
		rest = rest.substr(0, slash)
	var hp := UriUtil.split_host_port(rest)
	if not hp.ok:
		return {"ok": false, "error": "DNS: " + hp.error, "server": {}}
	if not UriUtil.is_valid_host(hp.host):
		return {"ok": false, "error": "DNS: некорректный адрес \"%s\"" % hp.host, "server": {}}
	if hp.port != -1 and not UriUtil.is_valid_port(hp.port):
		return {"ok": false, "error": "DNS: некорректный порт", "server": {}}
	var s := {"type": type, "tag": tag, "server": hp.host}
	if hp.port != -1:
		s["server_port"] = hp.port
	if type in ["https", "h3"] and not path.is_empty() and path != "/dns-query":
		s["path"] = path
	if not detour.is_empty():
		s["detour"] = detour
	if not hp.host.is_valid_ip_address():
		# Resolving the DNS server's own name must not depend on itself.
		s["domain_resolver"] = "local" if tag != "local" else ""
		if s.domain_resolver == "":
			return {"ok": false, "error": "прямой DNS должен быть IP-адресом или \"local\"", "server": {}}
	return {"ok": true, "error": "", "server": s}
