class_name JsonUtil
extends RefCounted
## JSON helpers. Godot parses every JSON number as float; sing-box rejects
## "443.0" for integer fields, so loaded data is normalised back to ints.


## Recursively converts floats without a fractional part into ints.
static func normalize_numbers(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			if is_finite(v) and v == floorf(v) and absf(v) < 9.0e15:
				return int(v)
			return v
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in v:
				d[k] = normalize_numbers(v[k])
			return d
		TYPE_ARRAY:
			var a: Array = []
			for x in v:
				a.append(normalize_numbers(x))
			return a
	return v


## Parses JSON text; returns {ok, data, error}. Numbers are normalised.
static func parse(text: String) -> Dictionary:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return {"ok": false, "data": null, "error": "JSON error at line %d: %s" % [json.get_error_line(), json.get_error_message()]}
	return {"ok": true, "data": normalize_numbers(json.data), "error": ""}


static func stringify(v: Variant, indent: String = "") -> String:
	return JSON.stringify(normalize_numbers(v), indent, false)


## Deep-copies [param v] (dictionaries/arrays).
static func clone(v: Variant) -> Variant:
	if typeof(v) in [TYPE_DICTIONARY, TYPE_ARRAY]:
		return v.duplicate(true)
	return v
