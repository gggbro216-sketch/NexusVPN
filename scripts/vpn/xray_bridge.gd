class_name XrayBridge
extends RefCounted
## Chains sing-box (TUN, DNS, routing, statistics) with Xray-core for profiles
## sing-box cannot run (XHTTP, VLESS encryption).
##
##   app traffic → TUN → sing-box ── socks (auth) ──▶ Xray inbound 127.0.0.1:A
##   Xray outbound (VLESS/XHTTP…) dials its server through
##   sockopt.dialerProxy ── socks (auth) ──▶ sing-box inbound "xray-dial"
##   127.0.0.1:B ──▶ "direct" (socket protected by VpnService.protect)
##
## So every connection Xray makes leaves through sing-box's protected direct
## outbound: no routing loop, and server names are resolved by sing-box's
## "local" DNS (Android system resolver), not by Xray inside the tunnel.
## Both loopback hops require random per-session credentials so other apps on
## the device cannot use the local proxies.

const DIAL_INBOUND_TAG := "xray-dial"
const DIAL_OUTBOUND_TAG := "nexus-dial"
const PORT_MIN := 20000
const PORT_MAX := 59999


## Random per-session ports and credentials.
static func new_session(xray_inbounds: int) -> Dictionary:
	var crypto := Crypto.new()
	var ports := []
	var used := {}
	while ports.size() < xray_inbounds + 1:
		var p := randi_range(PORT_MIN, PORT_MAX)
		if not used.has(p):
			used[p] = true
			ports.append(p)
	return {
		"dial_port": ports[0],
		"dial_user": crypto.generate_random_bytes(8).hex_encode(),
		"dial_pass": crypto.generate_random_bytes(16).hex_encode(),
		"socks_ports": ports.slice(1),
		"socks_user": crypto.generate_random_bytes(8).hex_encode(),
		"socks_pass": crypto.generate_random_bytes(16).hex_encode(),
	}


## sing-box outbound that forwards to Xray inbound #[param index].
static func singbox_outbound(session: Dictionary, index: int, tag: String) -> Dictionary:
	return {"type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": session.socks_ports[index],
		"version": "5", "username": session.socks_user, "password": session.socks_pass}


## sing-box inbound Xray dials through.
static func singbox_dial_inbound(session: Dictionary) -> Dictionary:
	return {"type": "mixed", "tag": DIAL_INBOUND_TAG, "listen": "127.0.0.1", "listen_port": session.dial_port,
		"users": [{"username": session.dial_user, "password": session.dial_pass}]}


## Route rule (must be first): Xray's server connections go out directly.
static func singbox_dial_rule() -> Dictionary:
	return {"inbound": [DIAL_INBOUND_TAG], "outbound": "direct"}


## Xray config: one authenticated SOCKS inbound per outbound, all outbounds
## dialing through sing-box. [param outbounds] are profile Xray outbounds.
static func xray_config(session: Dictionary, outbounds: Array, log_level: String = "warning") -> Dictionary:
	var inbounds := []
	var obs := []
	var rules := []
	for i in outbounds.size():
		var in_tag := "in-%d" % i
		var out_tag := "out-%d" % i
		inbounds.append({"tag": in_tag, "listen": "127.0.0.1", "port": session.socks_ports[i], "protocol": "socks",
			"settings": {"auth": "password", "accounts": [{"user": session.socks_user, "pass": session.socks_pass}], "udp": true}})
		var ob: Dictionary = (outbounds[i] as Dictionary).duplicate(true)
		ob["tag"] = out_tag
		var stream: Dictionary = ob.get("streamSettings", {})
		var sockopt: Dictionary = stream.get("sockopt", {})
		sockopt["dialerProxy"] = DIAL_OUTBOUND_TAG
		stream["sockopt"] = sockopt
		ob["streamSettings"] = stream
		obs.append(ob)
		rules.append({"type": "field", "inboundTag": [in_tag], "outboundTag": out_tag})
	obs.append({"tag": DIAL_OUTBOUND_TAG, "protocol": "socks",
		"settings": {"servers": [{"address": "127.0.0.1", "port": session.dial_port,
			"users": [{"user": session.dial_user, "pass": session.dial_pass}]}]}})
	return {
		"log": {"loglevel": log_level},
		"inbounds": inbounds,
		"outbounds": obs,
		"routing": {"domainStrategy": "AsIs", "rules": rules},
	}
