class_name ProfileValidator
extends RefCounted
## Validation of user-edited profiles before they are stored.

const MAX_NAME := 120


## Returns "" if the profile can be saved, otherwise an error message.
static func validate(p: ProfileModel) -> String:
	if p.name.strip_edges().is_empty():
		return "название не может быть пустым"
	if p.name.length() > MAX_NAME:
		return "название длиннее %d символов" % MAX_NAME
	if p.protocol == "config":
		var cfg := p.outbound
		if not cfg.has("outbounds") and not cfg.has("endpoints"):
			return "конфигурация не содержит outbounds"
		return ""
	return ConfigBuilder.validate_outbound(p)


## Parses edited outbound JSON (from the editor screen). Returns {ok, error, outbound}.
static func parse_outbound_json(text: String, protocol: String) -> Dictionary:
	var j := JsonUtil.parse(text)
	if not j.ok:
		return {"ok": false, "error": j.error, "outbound": {}}
	if typeof(j.data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "ожидается JSON-объект", "outbound": {}}
	var o: Dictionary = j.data
	o.erase("tag")
	if str(o.get("type", protocol)) != protocol:
		return {"ok": false, "error": "тип «%s» не совпадает с протоколом профиля «%s»" % [o.get("type"), protocol], "outbound": {}}
	o["type"] = protocol
	return {"ok": true, "error": "", "outbound": o}
