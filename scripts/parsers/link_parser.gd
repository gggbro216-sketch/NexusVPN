class_name LinkParser
extends RefCounted
## Dispatches a single share link to the protocol-specific parser.

const SCHEMES := {
	"vless": "vless", "vmess": "vmess", "trojan": "trojan", "ss": "shadowsocks",
	"hysteria2": "hysteria2", "hy2": "hysteria2", "tuic": "tuic", "anytls": "anytls",
	"socks": "socks", "socks5": "socks", "socks5h": "socks", "socks4": "socks", "socks4a": "socks",
}
## Schemes we recognise but cannot convert, with the reason.
const UNSUPPORTED := {
	"ssr": "ShadowsocksR is not supported by sing-box",
	"hysteria": "Hysteria v1 links are not supported; use Hysteria2 or import sing-box JSON",
	"wireguard": "import WireGuard as a .conf file or sing-box JSON",
	"wg": "import WireGuard as a .conf file or sing-box JSON",
	"naive+https": "NaiveProxy is not included in this build",
	"naive+quic": "NaiveProxy is not included in this build",
	"juicity": "Juicity is not supported by sing-box",
	"brook": "Brook is not supported by sing-box",
	"mieru": "Mieru is not supported by sing-box",
}


static func scheme_of(link: String) -> String:
	var i := link.find("://")
	if i <= 0:
		return ""
	return link.substr(0, i).strip_edges().to_lower()


static func is_share_link(text: String) -> bool:
	var s := scheme_of(text.strip_edges())
	return SCHEMES.has(s) or UNSUPPORTED.has(s)


## Returns {ok, error, profile, warnings}.
static func parse(link: String) -> Dictionary:
	var s := link.strip_edges()
	if s.length() > UriUtil.MAX_LINK_LENGTH:
		return ParserCommon.fail("link is too long")
	var scheme := scheme_of(s)
	if scheme.is_empty():
		return ParserCommon.fail("not a share link (missing scheme://)")
	if UNSUPPORTED.has(scheme):
		return ParserCommon.fail(UNSUPPORTED[scheme])
	match SCHEMES.get(scheme, ""):
		"vless":
			return VlessParser.parse(s)
		"vmess":
			return VmessParser.parse(s)
		"trojan":
			return TrojanParser.parse(s)
		"shadowsocks":
			return ShadowsocksParser.parse(s)
		"hysteria2":
			return QuicParsers.parse_hysteria2(s)
		"tuic":
			return QuicParsers.parse_tuic(s)
		"anytls":
			return QuicParsers.parse_anytls(s)
		"socks":
			return QuicParsers.parse_socks(s)
	if scheme in ["http", "https"]:
		return ParserCommon.fail("this is a web address; add it as a subscription instead")
	return ParserCommon.fail("unsupported link type \"%s://\"" % scheme)
