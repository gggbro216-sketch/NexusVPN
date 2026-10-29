extends Control
## One settings section. Every control is bound to a real setting consumed by
## the config builder / managers; unavailable features are labelled as such.

const TITLES := {
	"connection": "Подключение", "network": "Сеть", "dns": "DNS", "routing": "Маршрутизация",
	"apps": "Приложения", "subscriptions": "Подписки", "interface": "Интерфейс",
	"notifications": "Уведомления", "privacy": "Конфиденциальность", "about": "О приложении",
}

var _section := ""
var _body: VBoxContainer


func setup(params: Dictionary) -> void:
	_section = str(params.get("section", ""))


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(Nav.header(TITLES.get(_section, "Настройки")))
	var page := UI.page(12)
	_body = UI.body(page)
	col.add_child(UI.scroll(page))
	_rebuild()


func on_shown() -> void:
	if _section in ["routing", "apps"]:
		_rebuild()


func _rebuild() -> void:
	for c in _body.get_children():
		c.queue_free()
	match _section:
		"connection": _connection()
		"network": _network()
		"dns": _dns()
		"routing": _routing()
		"apps": _apps()
		"subscriptions": _subscriptions()
		"interface": _interface()
		"notifications": _notifications()
		"privacy": _privacy()
		"about": _about()


func _card(children: Array) -> void:
	var c := UI.card(10)
	for ch in children:
		UI.body(c).add_child(ch)
	_body.add_child(c)


func _note(text: String) -> Label:
	return UI.label(text, "CaptionLabel", true)


func _reconnect_hint() -> Label:
	return _note("Изменения применяются при следующем подключении.")


# --- sections ---------------------------------------------------------------------

func _connection() -> void:
	_card([
		UI.toggle_row("Подключаться при запуске", "Запускать VPN при открытии приложения (последний сервер)", "auto_connect_on_start"),
		UI.toggle_row("Подключаться к самому быстрому", "Использовать сервер с наименьшей задержкой среди успешно проверенных", "connect_best_server"),
		UI.toggle_row("Проверять соединение", "Считать подключение установленным только после успешного запроса через сервер", "verify_connection"),
		UI.number_row("Тайм-аут проверки", "", "url_test_timeout_s", 3, 30, 1, " с"),
	])
	_card([
		UI.toggle_row("Автоматическое переподключение", "При обрыве соединения ядра", "auto_reconnect"),
		UI.number_row("Максимум попыток", "", "reconnect_max_attempts", 1, 10, 1),
		UI.number_row("Начальная задержка", "Удваивается с каждой попыткой (не более 60 с)", "reconnect_base_delay_s", 1, 30, 1, " с"),
		UI.toggle_row("Реагировать на смену сети", "Сбрасывать соединения при переходе Wi-Fi ↔ мобильная сеть", "reconnect_on_network_change"),
	])
	var ks := UI.card(8)
	var b := UI.body(ks)
	b.add_child(UI.label("Блокировка трафика без VPN (Kill Switch)", "HeaderLabel"))
	b.add_child(_note("Приложение не может само запретить трафик вне VPN. На Android это делает система: включите «Постоянная VPN» и «Блокировать соединения без VPN» для %s в системных настройках VPN. Без этого при обрыве VPN трафик пойдёт напрямую." % App.app_name()))
	var btn := UI.button("Открыть системные настройки VPN", "settings", "", func() -> void:
		if not Platform.has_vpn_backend() or not Platform.bridge.openVpnSettings():
			Nav.toast("Недоступно на этой платформе", "warning"))
	btn.disabled = not Platform.has_vpn_backend()
	b.add_child(btn)
	_body.add_child(ks)


func _network() -> void:
	_card([
		UI.toggle_row("IPv6", "Адрес IPv6 в туннеле и маршрутизация IPv6. Если выключено — DNS только IPv4", "ipv6_enabled"),
		UI.toggle_row("Строгая маршрутизация (strict_route)", "Не допускать обход туннеля системными маршрутами", "strict_route"),
		UI.option_row("Сетевой стек TUN", "mixed — рекомендуется; system/gvisor — для совместимости", "tun_stack",
			[["mixed", "mixed"], ["system", "system"], ["gvisor", "gvisor"]]),
		UI.number_row("MTU", "", "mtu", 1280, 9000, 1),
		_reconnect_hint(),
	])
	_card([
		UI.option_row("Фрагментация TLS (обход DPI)",
			"Разбивает TLS ClientHello, чтобы простые фильтры не распознали имя сервера. Сначала пробуйте «записи TLS»: TCP-фрагментация медленнее.",
			"tls_fragment", [["off", "Выключена"], ["record", "Записи TLS (record_fragment)"], ["tcp", "TCP-сегменты (fragment)"], ["both", "Оба способа"]]),
		_note("Действует только для TLS поверх TCP (VLESS/VMess/Trojan/AnyTLS с TLS). Не влияет на REALITY (ядро не применяет фрагментацию к REALITY), Hysteria2, TUIC и QUIC. Против полноценной цензуры не гарантирует результат."),
		_reconnect_hint(),
	])
	_card([
		UI.toggle_row("Определять внешний IP", "После подключения запросить адрес у сервиса ниже (через VPN)", "ip_check_enabled"),
		UI.text_row("Сервис проверки IP", "Формат ответа Cloudflare trace (ip=…, loc=…) или просто IP", "ip_check_url", "https://…",
			func(v: String) -> String: return "" if v.begins_with("https://") else "нужен адрес https://"),
	])


func _dns() -> void:
	var validate_remote := func(v: String) -> String:
		var r := DnsManager.build_server(v, "remote", "proxy")
		return "" if r.ok else r.error
	var validate_direct := func(v: String) -> String:
		var r := DnsManager.build_server(v, "local")
		return "" if r.ok else r.error
	var presets := UI.hbox(6)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	for p in DnsManager.PRESETS:
		var val: String = p.value
		flow.add_child(UI.chip(p.name, Settings.get_value("remote_dns") == val, func() -> void:
			Settings.set_value("remote_dns", val)
			_rebuild()))
	presets.add_child(flow)
	_card([
		UI.text_row("DNS через прокси", "Запросы идут через сервер VPN. Формат: https://…, tls://…, quic://…, h3://…, IP", "remote_dns", "https://1.1.1.1/dns-query", validate_remote),
		presets,
		UI.text_row("Прямой DNS", "Для прямых направлений и адресов серверов. «local» — системный DNS", "direct_dns", "local", validate_direct),
		UI.option_row("Стратегия", "", "dns_strategy", [["prefer_ipv4", "Предпочитать IPv4"], ["prefer_ipv6", "Предпочитать IPv6"], ["ipv4_only", "Только IPv4"], ["ipv6_only", "Только IPv6"]]),
		_note("DNS-запросы приложений перехватываются в туннеле (hijack-dns), поэтому не уходят мимо VPN. Адреса серверов VPN разрешаются прямым DNS, чтобы избежать петли."),
		_reconnect_hint(),
	])


func _routing() -> void:
	var modes := []
	for k in RoutingManager.MODE_LABELS:
		modes.append([k, RoutingManager.MODE_LABELS[k]])
	var mode := str(Settings.get_value("routing_mode"))
	_card([
		UI.option_row("Режим", "", "routing_mode", modes, func(_v: Variant) -> void: _rebuild()),
		_note(_mode_help(mode)),
	])
	var extra := []
	if mode == "split":
		extra.append(UI.text_row("Страна для прямого подключения", "Двухбуквенный код (ru, by, kz, cn, ir…). Используются набор geoip и доменная зона страны", "split_country", "ru",
			func(v: String) -> String: return "" if RegEx.create_from_string("^[a-zA-Z]{2}$").search(v) else "нужен двухбуквенный код страны"))
	if mode == "custom":
		extra.append(UI.option_row("Для остального трафика", "", "custom_final", [["proxy", "Через прокси"], ["direct", "Напрямую"]]))
	extra.append(UI.toggle_row("Локальные сети напрямую", "10.0.0.0/8, 192.168.0.0/16 и др. не идут через прокси", "bypass_private"))
	extra.append(UI.toggle_row("Блокировать рекламу", "Набор geosite-category-ads-all (загружается через прокси при подключении)", "block_ads"))
	_card(extra)
	var rules: Array = Settings.get_value("custom_rules")
	var conflicts := RulesManager.find_conflicts(rules)
	var rc := []
	rc.append(UI.row("Правила маршрутизации", "Правил: %d" % rules.size(), "tune", null, func() -> void: Nav.push("rules")))
	for c in conflicts:
		var l := _note("⚠ " + c)
		l.add_theme_color_override("font_color", Style.c("warning"))
		rc.append(l)
	rc.append(_note("Наборы geoip/geosite скачиваются ядром с GitHub (SagerNet/sing-geoip, sing-geosite) через прокси и кэшируются. Без доступа к ним подключение с такими правилами не запустится."))
	rc.append(_reconnect_hint())
	_card(rc)


func _mode_help(mode: String) -> String:
	match mode:
		"global":
			return "Весь трафик идёт через сервер (кроме правил «напрямую»)."
		"split":
			return "Трафик к выбранной стране (по IP-диапазонам и доменной зоне) идёт напрямую, остальное — через сервер."
		"selected":
			return "Через сервер идут только направления из правил с действием «через прокси», остальное — напрямую."
		"direct":
			return "Туннель активен, но трафик идёт напрямую (правила блокировки действуют). Полезно для диагностики."
		"custom":
			return "Решают только ваши правила; для остального трафика выберите действие ниже."
	return ""


func _apps() -> void:
	var avail := SingBoxManager.backend.supports_per_app() if SingBoxManager.backend else false
	var mode_row := UI.option_row("Режим", "", "per_app_mode", [["off", "Все приложения через VPN"], ["include", "Только выбранные через VPN"], ["exclude", "Выбранные в обход VPN"]], func(_v: Variant) -> void: _rebuild())
	var pk: Array = Settings.get_value("per_app_packages")
	var children := [mode_row]
	if not avail:
		children.append(_note("Недоступно на этой платформе: требуется Android VpnService."))
	children.append(UI.row("Выбрать приложения", "Выбрано: %d" % pk.size(), "apps", null, func() -> void: Nav.push("apps")))
	children.append(_note("Используются addAllowedApplication / addDisallowedApplication системного VpnService. Одновременно включение и исключение невозможно — действует выбранный режим. В режиме «только выбранные» трафик остальных приложений, включая браузер, идёт мимо VPN."))
	children.append(_reconnect_hint())
	_card(children)


func _subscriptions() -> void:
	_card([
		UI.toggle_row("Автообновление", "Обновлять подписки по их расписанию, пока приложение открыто", "sub_auto_update"),
		UI.toggle_row("Обновлять при запуске", "Если подошёл срок обновления", "sub_update_on_start"),
		UI.number_row("Период по умолчанию", "Для новых подписок (может переопределяться заголовком сервера)", "sub_default_interval_h", 1, 168, 1, " ч"),
		UI.text_row("User-Agent", "Некоторые провайдеры выбирают формат по User-Agent", "sub_user_agent", "", func(v: String) -> String: return "" if v.length() > 0 and v.length() < 200 else "1–200 символов"),
		UI.toggle_row("Разрешить HTTP без шифрования", "Не рекомендуется: адрес и содержимое подписки видны в сети", "sub_allow_http"),
		_note("Подписки загружаются только по HTTPS с проверкой сертификата; обращения к локальным/внутренним адресам блокируются; размер ответа ограничен 8 МБ. При ошибке загрузки существующие серверы не удаляются."),
	])


func _interface() -> void:
	_card([
		UI.option_row("Тема", "", "theme", [["dark", "Тёмная"], ["light", "Светлая"]]),
		UI.toggle_row("Компактный список серверов", "", "compact_list"),
		_note("Язык интерфейса: русский (другие языки пока не реализованы)."),
	])


func _notifications() -> void:
	var granted := Platform.has_vpn_backend() and bool(Platform.bridge.hasNotificationPermission())
	var perm := UI.button("Разрешить уведомления" if not granted else "Уведомления разрешены", "bell", "", func() -> void:
		if Platform.has_vpn_backend():
			Platform.bridge.requestNotificationPermission())
	perm.disabled = granted or not Platform.has_vpn_backend()
	_card([
		_note("Пока VPN работает, Android показывает постоянное уведомление с кнопкой «Отключить» — это требование системы для фоновой работы."),
		perm,
		UI.toggle_row("Сообщать об обрыве соединения", "Всплывающее сообщение в приложении при ошибке или разрыве", "notify_on_disconnect"),
	])


func _privacy() -> void:
	var level := SecureStorage.protection_level()
	var level_text: String = {"android_keystore": "Профили и подписки зашифрованы (AES-256); ключ защищён Android Keystore.",
		"plain": "Профили зашифрованы (AES-256), но на этой платформе ключ хранится рядом с данными — это защита от случайного просмотра, а не от злоумышленника."}.get(level, "Хранилище не инициализировано.")
	_card([
		UI.label("Хранение данных", "HeaderLabel"),
		_note(level_text),
		_note("Приложение не собирает телеметрию и не отправляет профили третьим лицам. Сетевые запросы: подписки (только по вашим адресам), проверка IP (если включена), наборы правил geoip/geosite (если используются), запросы проверки задержки."),
		UI.toggle_row("Проверять буфер обмена при возврате", "Предлагать импорт, если скопирована ссылка. Анализ только на устройстве", "clipboard_detect_on_resume"),
	])
	_card([
		UI.label("Резервная копия", "HeaderLabel"),
		_note("Файл содержит все серверы и подписки с секретами в открытом виде. Храните его в надёжном месте."),
		UI.button("Экспортировать резервную копию", "share", "", _export_backup),
		UI.button("Импортировать резервную копию", "file", "", _import_backup),
		UI.button("Экспортировать все ссылки серверов", "link", "", _export_links),
	])
	_card([
		UI.label("Сброс", "HeaderLabel"),
		UI.button("Сбросить настройки", "refresh", "", func() -> void:
			if await Nav.confirm("Сбросить настройки?", "Серверы и подписки сохранятся.", "Сбросить", true):
				Settings.reset_to_defaults()
				Nav.toast("Настройки сброшены", "success")),
		UI.button("Удалить все серверы и подписки", "delete", "DangerButton", func() -> void:
			if SingBoxManager.is_active():
				Nav.toast("Сначала отключите VPN", "warning")
				return
			if await Nav.confirm("Удалить все данные?", "Все серверы, подписки и ключ шифрования будут удалены без возможности восстановления.", "Удалить", true):
				Profiles.reset_storage()
				Nav.toast("Данные удалены", "success")),
	])


func _export_backup() -> void:
	if not await Nav.confirm("Экспорт резервной копии", "Файл будет содержать все секреты (UUID, пароли, ключи) в открытом виде.", "Продолжить"):
		return
	var text := Profiles.export_backup()
	var name := "nexusvpn-backup-%s.json" % Time.get_date_string_from_system()
	FileExport.save(name, "application/json", text)


func _import_backup() -> void:
	FileExport.pick("backup", func(content: String) -> void:
		var restore := await Nav.confirm("Импорт резервной копии", "Восстановить также настройки приложения?", "Да, с настройками")
		var r := Profiles.import_backup(content, restore)
		if r.ok:
			Nav.toast("Восстановлено: серверов %d, подписок %d, настроек %d" % [r.profiles, r.subscriptions, r.settings], "success")
		else:
			Nav.toast(r.error, "error"))


func _export_links() -> void:
	var ids := []
	for p in Profiles.get_all():
		ids.append(p.id)
	var text := Profiles.export_links(ids)
	if text == "":
		Nav.toast("Нет серверов с исходными ссылками", "warning")
		return
	if not await Nav.confirm("Экспорт ссылок", "Ссылки содержат секреты. Скопировать в буфер обмена?", "Скопировать"):
		return
	DisplayServer.clipboard_set(text)
	Nav.toast("Скопировано ссылок: %d" % text.split("\n").size(), "success")


func _about() -> void:
	var rows := [
		["Приложение", "%s %s" % [App.app_name(), App.app_version()]],
		["Ядро", ("sing-box " + SingBoxManager.core_version()) if SingBoxManager.is_available() else "недоступно на этой платформе"],
		["Второе ядро", ("Xray " + SingBoxManager.backend.xray_version()) if SingBoxManager.is_available() and SingBoxManager.backend.xray_version() != "" else "Xray (для XHTTP), недоступно на этой платформе"],
		["Движок", "Godot " + Engine.get_version_info().string],
		["Платформа", OS.get_name() + " " + OS.get_version()],
	]
	var c := UI.card(6)
	for r in rows:
		var h := UI.hbox(8)
		var k := UI.label(r[0], "MutedLabel")
		k.custom_minimum_size.x = 110
		h.add_child(k)
		h.add_child(UI.label(r[1], "", true))
		UI.body(c).add_child(h)
	_body.add_child(c)
	_card([
		UI.label("Лицензии", "HeaderLabel"),
		_note("%s распространяется под GPL-3.0-or-later." % App.app_name()),
		_note("sing-box (libbox) — © SagerNet, GPL-3.0-or-later. Исходный код: github.com/SagerNet/sing-box"),
		_note("Xray-core — © XTLS, Mozilla Public License 2.0. Исходный код: github.com/XTLS/Xray-core"),
		_note("Godot Engine — © Godot Engine contributors, MIT License."),
		_note("ZXing — Apache License 2.0. Google ML Kit code scanner — условия Google APIs."),
		_note("Иконки — Material Design Icons (Google), Apache License 2.0."),
		_note("Название и логотип не связаны с Happ, NekoBox, Hiddify и другими клиентами."),
	])


## Platform-aware save/open helpers.
class FileExport:
	static func save(name: String, mime: String, content: String) -> void:
		if Platform.has_vpn_backend():
			var bridge: Object = Platform.bridge
			bridge.connect("file_saved", func(ok: bool, info: String) -> void:
				if ok:
					Nav.toast("Сохранено: " + info, "success")
				elif info != "cancelled":
					Nav.toast("Не сохранено: " + info, "error"), Object.CONNECT_ONE_SHOT | Object.CONNECT_DEFERRED)
			bridge.saveFile(name, mime, content)
			return
		var path := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join(name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			Nav.toast("Не удалось сохранить файл", "error")
			return
		f.store_string(content)
		Nav.toast("Сохранено: " + path, "success")

	static func pick(tag: String, on_content: Callable) -> void:
		if Platform.has_vpn_backend():
			var bridge: Object = Platform.bridge
			bridge.connect("file_picked", func(t: String, _name: String, content: String, error: String) -> void:
				if t != tag:
					return
				if error != "":
					if error != "cancelled":
						Nav.toast(error, "error")
					return
				on_content.call(content), Object.CONNECT_ONE_SHOT | Object.CONNECT_DEFERRED)
			bridge.pickFile(tag)
			return
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.use_native_dialog = true
		fd.file_selected.connect(func(path: String) -> void:
			var f := FileAccess.open(path, FileAccess.READ)
			if f and f.get_length() < 8 * 1024 * 1024:
				on_content.call(f.get_as_text())
			fd.queue_free())
		fd.canceled.connect(fd.queue_free)
		Nav.get_tree().root.add_child(fd)
		fd.popup_centered_ratio(0.8)
