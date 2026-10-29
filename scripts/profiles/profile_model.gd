class_name ProfileModel
extends RefCounted
## A single server profile.
##
## [member outbound] holds the sing-box outbound (or endpoint, for WireGuard)
## object WITHOUT the "tag" field. It is the canonical connection config; the
## original share link is kept only for re-export.

const SOURCE_MANUAL := "manual"
const SOURCE_CLIPBOARD := "clipboard"
const SOURCE_FILE := "file"
const SOURCE_QR := "qr"
const SOURCE_SUBSCRIPTION := "subscription"
const SOURCE_SINGBOX_JSON := "singbox_json"

## Latency status values.
const LAT_UNTESTED := "untested"
const LAT_OK := "ok"
const LAT_SLOW := "slow"
const LAT_FAILED := "failed"
const LAT_TESTING := "testing"
const SLOW_THRESHOLD_MS := 800

var id: String = ""
var name: String = ""
var protocol: String = ""          ## sing-box type: vless, vmess, trojan, shadowsocks, ...
var server: String = ""
var port: int = 0
var source: String = SOURCE_MANUAL
var created_at: int = 0
var updated_at: int = 0
var subscription_id: String = ""
var uri: String = ""                ## original share link (secret!)
var outbound: Dictionary = {}       ## sing-box outbound/endpoint options without "tag"
var is_endpoint: bool = false       ## true for WireGuard (sing-box "endpoints" section)
var favorite: bool = false
var order: int = 0
var user_renamed: bool = false
var notes: String = ""
var transport_label: String = ""    ## e.g. "Reality", "WS+TLS", "gRPC"
## Last latency measurement: {ms:int, status:String, method:"proxy"|"tcp", checked_at:int, error:String}
var latency: Dictionary = {}
## Exit country code learned from IP check while connected through this profile.
var exit_country: String = ""
var exit_ip_checked_at: int = 0
## Unknown/extra fields of the stored record, preserved across saves.
var extra: Dictionary = {}

const _FIELDS := ["id", "name", "protocol", "server", "port", "source", "created_at", "updated_at",
	"subscription_id", "uri", "outbound", "is_endpoint", "favorite", "order", "user_renamed",
	"notes", "transport_label", "latency", "exit_country", "exit_ip_checked_at"]


static func create(p_protocol: String, p_outbound: Dictionary, p_name: String = "") -> ProfileModel:
	var p := ProfileModel.new()
	p.id = new_id()
	p.protocol = p_protocol
	p.outbound = p_outbound
	p.server = str(p_outbound.get("server", ""))
	p.port = int(p_outbound.get("server_port", 0))
	if p_protocol == "wireguard":
		p.is_endpoint = true
		var peers: Array = p_outbound.get("peers", [])
		if peers.size() > 0:
			p.server = str(peers[0].get("address", ""))
			p.port = int(peers[0].get("port", 0))
	p.name = p_name if not p_name.strip_edges().is_empty() else default_name(p.protocol, p.server, p.port)
	p.created_at = int(Time.get_unix_time_from_system())
	p.updated_at = p.created_at
	return p


static func new_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(8)
	return bytes.hex_encode()


static func default_name(proto: String, host: String, prt: int) -> String:
	return "%s %s:%d" % [proto.to_upper(), host, prt]


static func from_dict(d: Dictionary) -> ProfileModel:
	var p := ProfileModel.new()
	for f in _FIELDS:
		if d.has(f):
			var v: Variant = d[f]
			match typeof(p.get(f)):
				TYPE_INT:
					p.set(f, int(v))
				TYPE_BOOL:
					p.set(f, bool(v))
				TYPE_STRING:
					p.set(f, str(v))
				TYPE_DICTIONARY:
					if typeof(v) == TYPE_DICTIONARY:
						p.set(f, v)
	for k in d:
		if not (k in _FIELDS):
			p.extra[k] = d[k]
	return p


func to_dict() -> Dictionary:
	var d := extra.duplicate(true)
	for f in _FIELDS:
		var v: Variant = get(f)
		d[f] = v.duplicate(true) if typeof(v) == TYPE_DICTIONARY else v
	return d


func duplicate_profile() -> ProfileModel:
	var p := ProfileModel.from_dict(to_dict())
	p.id = new_id()
	p.name = name + " (копия)"
	p.subscription_id = ""
	p.source = SOURCE_MANUAL
	p.user_renamed = true
	p.latency = {}
	p.created_at = int(Time.get_unix_time_from_system())
	p.updated_at = p.created_at
	return p


## Identity used for duplicate detection and for matching profiles across
## subscription updates: protocol + endpoint + credential + transport.
func fingerprint() -> String:
	var o := outbound.duplicate(true)
	var parts := PackedStringArray([protocol, server.to_lower(), str(port)])
	for k in ["uuid", "password", "method", "private_key", "username", "flow"]:
		if o.has(k):
			parts.append(str(o[k]))
	if o.has("transport"):
		parts.append(JsonUtil.stringify(o.transport))
	if o.has("tls") and typeof(o.tls) == TYPE_DICTIONARY:
		parts.append(str(o.tls.get("server_name", "")).to_lower())
	if protocol == "wireguard":
		parts.append(JsonUtil.stringify(o.get("peers", [])))
	return "|".join(parts).sha256_text()


## Coarse identity (server endpoint only) used as a fallback when matching
## subscription entries whose credentials were rotated.
func endpoint_key() -> String:
	return "%s|%s|%d" % [protocol, server.to_lower(), port]


func display_address() -> String:
	if server.contains(":") and not server.begins_with("["):
		return "[%s]:%d" % [server, port]
	return "%s:%d" % [server, port]


func protocol_label() -> String:
	var names := {
		"vless": "VLESS", "vmess": "VMess", "trojan": "Trojan", "shadowsocks": "Shadowsocks",
		"hysteria2": "Hysteria2", "tuic": "TUIC", "wireguard": "WireGuard", "ssh": "SSH",
		"socks": "SOCKS5", "http": "HTTP", "anytls": "AnyTLS", "shadowtls": "ShadowTLS",
		"hysteria": "Hysteria", "naive": "Naive",
	}
	var base: String = names.get(protocol, protocol.to_upper())
	if not transport_label.is_empty():
		return "%s · %s" % [base, transport_label]
	return base


func latency_status() -> String:
	return str(latency.get("status", LAT_UNTESTED))
