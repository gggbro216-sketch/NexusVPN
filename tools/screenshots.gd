extends Node
## Renders the main UI and saves screenshots of each screen (used for visual
## checks on desktop: xvfb-run godot --path . res://tools/screenshots.tscn).
## Adds demo profiles only to a temporary data dir when NEXUS_DEMO=1.

const OUT := "user://screenshots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var main: Control = load("res://scenes/main/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().create_timer(0.6).timeout
	if OS.get_environment("NEXUS_DEMO") == "1" and Profiles.count() == 0:
		Profiles.import_text("vless://b831381d-6324-4d53-ad4f-8cda48b30811@nl1.example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=6ba85179&flow=xtls-rprx-vision#Нидерланды%20Reality\nvless://b831381d-6324-4d53-ad4f-8cda48b30811@de.example.com:443?type=ws&security=tls&path=%2Fws#Германия%20WS\ntrojan://pass@fi.example.com:443#Финляндия%20Trojan\nhysteria2://pw@jp.example.com:443?sni=jp.example.com#Япония%20Hy2", "manual")
		Profiles.set_active(Profiles.get_all()[0].id)
	for tab in ["dashboard", "servers", "subscriptions", "statistics", "settings"]:
		Nav.show_tab(tab)
		await get_tree().create_timer(0.5).timeout
		await _shot(tab)
	Nav.push("settings_page", {"section": "routing"})
	await get_tree().create_timer(0.5).timeout
	await _shot("settings_routing")
	Nav.pop()
	Nav.push("diagnostics")
	await get_tree().create_timer(0.5).timeout
	await _shot("diagnostics")
	Nav.pop()
	await get_tree().create_timer(0.3).timeout
	ImportSheet.open()
	await get_tree().create_timer(0.7).timeout
	await _shot("import_sheet")
	Nav.close_sheet()
	if OS.get_environment("NEXUS_LIGHT") == "1":
		Settings.set_value("theme", "light")
		Nav.show_tab("dashboard")
		await get_tree().create_timer(0.5).timeout
		await _shot("dashboard_light")
	get_tree().quit()


func _shot(name: String) -> void:
	# low_processor_mode skips idle frames; force one so the capture is current.
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT.path_join(name + ".png"))
	print("saved ", ProjectSettings.globalize_path(OUT.path_join(name + ".png")))
