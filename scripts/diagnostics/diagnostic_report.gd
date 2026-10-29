class_name DiagnosticReport
extends RefCounted
## Builds a plain-text diagnostic report without secrets: versions, platform,
## settings, profile/subscription summary (no credentials, hosts masked),
## VPN state, generated config of the active profile (masked) and recent logs.


static func build(max_log_lines: int = 600) -> String:
	var out := PackedStringArray()
	out.append("=== %s diagnostic report ===" % App.app_name())
	out.append("Generated: %s UTC" % Time.get_datetime_string_from_system(true))
	out.append("App: %s %s" % [App.app_name(), App.app_version()])
	out.append("Godot: %s" % Engine.get_version_info().string)
	out.append("OS: %s %s, model: %s, locale: %s" % [OS.get_name(), OS.get_version(), OS.get_model_name(), OS.get_locale()])
	out.append("Core: %s" % ("sing-box " + SingBoxManager.core_version() if SingBoxManager.is_available() else "unavailable: " + SingBoxManager.unavailable_reason()))
	out.append("Secure storage: %s" % SecureStorage.protection_level())
	out.append("")
	out.append("--- VPN state ---")
	var st := SingBoxManager.get_status()
	for k in ["label", "message", "profile_name", "connected_since", "exit_country", "network_available", "last_error"]:
		out.append("%s: %s" % [k, str(st.get(k, ""))])
	out.append("stats: %s" % JSON.stringify(SingBoxManager.get_statistics()))
	out.append("")
	out.append("--- Settings ---")
	var s := Settings.export_data()
	s.erase("per_app_packages")
	s["per_app_packages_count"] = (Settings.get_value("per_app_packages") as Array).size()
	out.append(JsonUtil.stringify(s, "  "))
	out.append("")
	out.append("--- Profiles (%d) ---" % Profiles.count())
	var by_proto := {}
	for p in Profiles.get_all():
		var key := p.protocol_label()
		by_proto[key] = int(by_proto.get(key, 0)) + 1
	for k in by_proto:
		out.append("%s: %d" % [k, by_proto[k]])
	var active := Profiles.get_active()
	if active:
		out.append("active: %s, %s, host=%s, latency=%s" % [active.protocol_label(), active.source, _mask_host(active.server), JSON.stringify(active.latency)])
	out.append("")
	out.append("--- Subscriptions (%d) ---" % Subscriptions.list().size())
	for sub in Subscriptions.list():
		out.append("%s host=%s count=%d last_success=%d error=%s" % [str(sub.name), _mask_host(str(UriUtil.parse(str(sub.url)).host)),
			int(sub.get("count", 0)), int(sub.get("last_success", 0)), SecretMasker.mask(str(sub.get("last_error", "")))])
	out.append("")
	if active:
		out.append("--- Generated config (masked) ---")
		var built := ConfigBuilder.build_vpn_config(active, Settings.export_data())
		if built.ok:
			var masked: Variant = SecretMasker.mask_value(built.config)
			_mask_servers(masked)
			out.append(JsonUtil.stringify(masked, "  "))
		else:
			out.append("ERROR: " + built.error)
		out.append("")
	out.append("--- Log (last %d lines) ---" % max_log_lines)
	var lines := Log.export_text().split("\n")
	if lines.size() > max_log_lines:
		lines = lines.slice(lines.size() - max_log_lines)
	out.append("\n".join(lines))
	return SecretMasker.mask("\n".join(out))


## Keeps the TLD only: "vpn.example.com" -> "***.com", IPs -> "x.x.x.***".
static func _mask_host(h: String) -> String:
	if h.is_empty():
		return ""
	if h.is_valid_ip_address():
		if h.contains(":"):
			return h.split(":")[0] + ":***"
		var o := h.split(".")
		return "%s.%s.***" % [o[0], o[1]] if o.size() == 4 else "***"
	var parts := h.split(".")
	return "***." + parts[parts.size() - 1]


static func _mask_servers(v: Variant) -> void:
	if typeof(v) == TYPE_DICTIONARY:
		for k in v:
			if k in ["server", "address"] and typeof(v[k]) == TYPE_STRING:
				v[k] = _mask_host(v[k])
			elif k == "server_name" and typeof(v[k]) == TYPE_STRING:
				v[k] = _mask_host(v[k])
			else:
				_mask_servers(v[k])
	elif typeof(v) == TYPE_ARRAY:
		for x in v:
			_mask_servers(x)
