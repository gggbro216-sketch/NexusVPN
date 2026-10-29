extends Control
## Settings index. Each section opens a page built by settings_page.gd.

const SECTIONS := [
	["connection", "Подключение", "Автоподключение, переподключение, проверка", "power"],
	["network", "Сеть", "IPv6, стек TUN, MTU, проверка IP", "wifi"],
	["dns", "DNS", "DNS через прокси, прямой DNS, стратегия", "dns"],
	["routing", "Маршрутизация", "Режимы и правила", "route"],
	["apps", "Приложения", "Раздельное туннелирование по приложениям", "apps"],
	["subscriptions", "Подписки", "Автообновление, User-Agent", "cloud"],
	["interface", "Интерфейс", "Тема, вид списка", "palette"],
	["notifications", "Уведомления", "Разрешение и оповещения", "bell"],
	["privacy", "Конфиденциальность", "Хранение данных, резервные копии", "lock"],
	["diagnostics", "Диагностика", "Журналы, отчёт без секретов", "bug"],
	["about", "О приложении", "Версии, лицензии", "info"],
]


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", 16)
	hm.add_theme_constant_override("margin_right", 16)
	hm.add_child(Nav.header("Настройки", [], false))
	col.add_child(hm)
	var page := UI.page(8)
	var body := UI.body(page)
	col.add_child(UI.scroll(page))
	var card := UI.card(2)
	for s in SECTIONS:
		var id: String = s[0]
		UI.body(card).add_child(UI.row(s[1], s[2], s[3], null, func() -> void:
			if id == "diagnostics":
				Nav.push("diagnostics")
			else:
				Nav.push("settings_page", {"section": id})))
	body.add_child(card)
