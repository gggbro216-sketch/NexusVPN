class_name WireGuardParser
extends RefCounted
## Parses WireGuard configurations (wg-quick .conf format) into a sing-box
## "wireguard" endpoint. Only the first [Peer] with an Endpoint is used.


static func looks_like_conf(text: String) -> bool:
	return text.contains("[Interface]") and text.contains("PrivateKey")


static func parse_conf(text: String, name: String = "") -> Dictionary:
	var section := ""
	var iface := {}
	var peers: Array[Dictionary] = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		var hash_i := line.find("#")
		if hash_i >= 0:
			line = line.substr(0, hash_i).strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges().to_lower()
			if section == "peer":
				peers.append({})
			continue
		var eq := line.find("=")
		if eq < 0:
			return ParserCommon.fail("WireGuard config: malformed line \"%s\"" % SecretMasker.mask(line))
		var k := line.substr(0, eq).strip_edges().to_lower()
		var v := line.substr(eq + 1).strip_edges()
		if section == "interface":
			iface[k] = v
		elif section == "peer" and peers.size() > 0:
			peers[-1][k] = v
	if not iface.has("privatekey"):
		return ParserCommon.fail("WireGuard config has no [Interface] PrivateKey")
	if not _is_key(iface.privatekey):
		return ParserCommon.fail("WireGuard PrivateKey is not a valid 32-byte base64 key")
	var addresses := []
	for a in ParserCommon.split_list(str(iface.get("address", ""))):
		var addr: String = a
		if not addr.contains("/"):
			addr += "/128" if addr.contains(":") else "/32"
		if not _is_prefix(addr):
			return ParserCommon.fail("WireGuard Address \"%s\" is invalid" % a)
		addresses.append(addr)
	if addresses.is_empty():
		return ParserCommon.fail("WireGuard config has no Address")
	var peer: Dictionary = {}
	for p in peers:
		if p.has("endpoint"):
			peer = p
			break
	if peer.is_empty():
		return ParserCommon.fail("WireGuard config has no [Peer] with an Endpoint")
	if not _is_key(str(peer.get("publickey", ""))):
		return ParserCommon.fail("WireGuard peer PublicKey is missing or invalid")
	var hp := UriUtil.split_host_port(str(peer.endpoint))
	if not hp.ok:
		return ParserCommon.fail("WireGuard Endpoint: " + hp.error)
	var serr := ParserCommon.validate_server(hp.host, hp.port)
	if serr != "":
		return ParserCommon.fail("WireGuard Endpoint: " + serr)
	var allowed := []
	for a in ParserCommon.split_list(str(peer.get("allowedips", "0.0.0.0/0, ::/0"))):
		if not _is_prefix(a):
			return ParserCommon.fail("WireGuard AllowedIPs entry \"%s\" is invalid" % a)
		allowed.append(a)
	var sb_peer := {"address": hp.host, "port": hp.port, "public_key": peer.publickey, "allowed_ips": allowed}
	if peer.has("presharedkey"):
		if not _is_key(peer.presharedkey):
			return ParserCommon.fail("WireGuard PresharedKey is invalid")
		sb_peer["pre_shared_key"] = peer.presharedkey
	if str(peer.get("persistentkeepalive", "")).is_valid_int():
		sb_peer["persistent_keepalive_interval"] = int(peer.persistentkeepalive)
	var ob := {"type": "wireguard", "address": addresses, "private_key": iface.privatekey, "peers": [sb_peer]}
	if str(iface.get("mtu", "")).is_valid_int():
		ob["mtu"] = int(iface.mtu)
	var warnings := PackedStringArray()
	if peers.size() > 1:
		warnings.append("only the first peer with an Endpoint is used")
	if iface.has("dns"):
		warnings.append("WireGuard DNS setting is ignored; DNS is configured in the app settings")
	for k in ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"]:
		if iface.has(k):
			return ParserCommon.fail("AmneziaWG parameters are not supported by sing-box")
	var p := ProfileModel.create("wireguard", ob, name)
	p.source = ProfileModel.SOURCE_FILE
	return ParserCommon.ok(p, warnings)


static func _is_key(k: String) -> bool:
	var b := UriUtil.base64_decode_lenient(k)
	return b.ok and b.bytes.size() == 32


static func _is_prefix(p: String) -> bool:
	var slash := p.find("/")
	if slash < 0:
		return false
	var ip := p.substr(0, slash)
	var bits := p.substr(slash + 1)
	if not ip.is_valid_ip_address() or not bits.is_valid_int():
		return false
	var maxb := 128 if ip.contains(":") else 32
	return int(bits) >= 0 and int(bits) <= maxb
