extends Node
## Autoload "Style": colour palettes, fonts and the runtime-built Godot Theme.
## Dark theme by default, light theme optional (setting "theme").

signal theme_changed

const DARK := {
	"bg": Color("#0E1016"), "surface": Color("#171A22"), "surface2": Color("#1E222D"),
	"surface3": Color("#262B38"), "border": Color("#2C3240"), "text": Color("#ECEEF4"),
	"text2": Color("#9CA3B4"), "text3": Color("#6B7285"), "accent": Color("#4D8DFF"),
	"accent2": Color("#2BD4C4"), "on_accent": Color("#FFFFFF"), "success": Color("#2FD08A"),
	"warning": Color("#F6B445"), "danger": Color("#FF5D6C"), "overlay": Color(0, 0, 0, 0.55),
}
const LIGHT := {
	"bg": Color("#F3F5F9"), "surface": Color("#FFFFFF"), "surface2": Color("#ECEFF5"),
	"surface3": Color("#E1E5EE"), "border": Color("#D9DEE8"), "text": Color("#131722"),
	"text2": Color("#5B6375"), "text3": Color("#8A91A3"), "accent": Color("#2F6FEB"),
	"accent2": Color("#0FA79A"), "on_accent": Color("#FFFFFF"), "success": Color("#13A86A"),
	"warning": Color("#C98712"), "danger": Color("#E23D4F"), "overlay": Color(0, 0, 0, 0.4),
}

const RADIUS := 16
const RADIUS_SMALL := 10
const FONT_SIZE := 15

var palette: Dictionary = DARK
var theme: Theme
var font: Font
var font_bold: Font


func _ready() -> void:
	_build_fonts()
	apply(str(Settings.get_value("theme")))
	Settings.changed.connect(func(k: String, v: Variant) -> void:
		if k == "theme":
			apply(str(v)))


func c(name: String) -> Color:
	return palette.get(name, Color.MAGENTA)


func is_dark() -> bool:
	return palette == DARK


func ui_scale_for_icons() -> float:
	return 3.0


func apply(mode: String) -> void:
	palette = LIGHT if mode == "light" else DARK
	theme = _build_theme()
	if is_inside_tree():
		get_tree().root.theme = theme
		RenderingServer.set_default_clear_color(c("bg"))
	theme_changed.emit()


func _build_fonts() -> void:
	# System fonts give full Unicode coverage on Android (Cyrillic, emoji flags).
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray(["Roboto", "Google Sans", "Noto Sans", "sans-serif"])
	sys.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	sys.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	font = sys
	var bold := SystemFont.new()
	bold.font_names = sys.font_names
	bold.font_weight = 650
	bold.antialiasing = sys.antialiasing
	font_bold = bold


func box(bg: Color, radius: int = RADIUS, border: Color = Color.TRANSPARENT, border_w: int = 0, pad: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.anti_aliasing = true
	s.anti_aliasing_size = 0.8
	if pad > 0:
		s.set_content_margin_all(pad)
	return s


func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = FONT_SIZE
	var text := c("text")
	var text2 := c("text2")
	var accent := c("accent")

	# Labels
	t.set_color("font_color", "Label", text)
	t.set_constant("line_spacing", "Label", 2)

	# Buttons
	for kind in ["Button", "MenuButton", "OptionButton", "CheckButton", "CheckBox"]:
		t.set_color("font_color", kind, text)
		t.set_color("font_hover_color", kind, text)
		t.set_color("font_pressed_color", kind, text)
		t.set_color("font_focus_color", kind, text)
		t.set_color("font_disabled_color", kind, c("text3"))
		t.set_color("icon_normal_color", kind, text)
		t.set_color("icon_hover_color", kind, text)
		t.set_color("icon_pressed_color", kind, text)
		t.set_color("icon_focus_color", kind, text)
		t.set_color("icon_disabled_color", kind, c("text3"))
		t.set_constant("h_separation", kind, 10)
		t.set_constant("icon_max_width", kind, 22)
	var btn := box(c("surface2"), RADIUS_SMALL, c("border"), 1, 12)
	btn.content_margin_top = 11
	btn.content_margin_bottom = 11
	var btn_hover := btn.duplicate()
	btn_hover.bg_color = c("surface3")
	var btn_pressed := btn.duplicate()
	btn_pressed.bg_color = c("surface3").darkened(0.08)
	var btn_disabled := btn.duplicate()
	btn_disabled.bg_color = c("surface2").darkened(0.1) if is_dark() else c("surface2")
	for kind in ["Button", "MenuButton", "OptionButton"]:
		t.set_stylebox("normal", kind, btn)
		t.set_stylebox("hover", kind, btn_hover)
		t.set_stylebox("pressed", kind, btn_pressed)
		t.set_stylebox("hover_pressed", kind, btn_pressed)
		t.set_stylebox("disabled", kind, btn_disabled)
		t.set_stylebox("focus", kind, StyleBoxEmpty.new())
	# Variations
	t.add_type("AccentButton")
	t.set_type_variation("AccentButton", "Button")
	var acc := box(accent, RADIUS_SMALL, Color.TRANSPARENT, 0, 12)
	acc.content_margin_top = 12
	acc.content_margin_bottom = 12
	t.set_stylebox("normal", "AccentButton", acc)
	var acc_h := acc.duplicate()
	acc_h.bg_color = accent.lightened(0.08)
	t.set_stylebox("hover", "AccentButton", acc_h)
	var acc_p := acc.duplicate()
	acc_p.bg_color = accent.darkened(0.12)
	t.set_stylebox("pressed", "AccentButton", acc_p)
	t.set_stylebox("hover_pressed", "AccentButton", acc_p)
	var acc_d := acc.duplicate()
	acc_d.bg_color = accent.darkened(0.45)
	t.set_stylebox("disabled", "AccentButton", acc_d)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		t.set_color(k, "AccentButton", c("on_accent"))
	t.set_font("font", "AccentButton", font_bold)

	t.add_type("FlatButton")
	t.set_type_variation("FlatButton", "Button")
	var flat := StyleBoxFlat.new()
	flat.bg_color = Color(0, 0, 0, 0)
	flat.set_corner_radius_all(RADIUS_SMALL)
	flat.set_content_margin_all(8)
	t.set_stylebox("normal", "FlatButton", flat)
	t.set_stylebox("disabled", "FlatButton", flat)
	var flat_h := flat.duplicate()
	flat_h.bg_color = Color(c("text"), 0.06)
	t.set_stylebox("hover", "FlatButton", flat_h)
	var flat_p := flat.duplicate()
	flat_p.bg_color = Color(c("text"), 0.12)
	t.set_stylebox("pressed", "FlatButton", flat_p)
	t.set_stylebox("hover_pressed", "FlatButton", flat_p)

	t.add_type("DangerButton")
	t.set_type_variation("DangerButton", "Button")
	var dng := box(Color(c("danger"), 0.14), RADIUS_SMALL, Color(c("danger"), 0.35), 1, 12)
	t.set_stylebox("normal", "DangerButton", dng)
	t.set_stylebox("hover", "DangerButton", dng)
	t.set_stylebox("pressed", "DangerButton", dng)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "icon_normal_color"]:
		t.set_color(k, "DangerButton", c("danger"))

	# Chip (toggle) buttons
	t.add_type("ChipButton")
	t.set_type_variation("ChipButton", "Button")
	var chip := box(c("surface2"), 999, c("border"), 1, 0)
	chip.content_margin_left = 14
	chip.content_margin_right = 14
	chip.content_margin_top = 7
	chip.content_margin_bottom = 7
	t.set_stylebox("normal", "ChipButton", chip)
	t.set_stylebox("hover", "ChipButton", chip)
	var chip_on := chip.duplicate()
	chip_on.bg_color = Color(accent, 0.18)
	chip_on.border_color = accent
	t.set_stylebox("pressed", "ChipButton", chip_on)
	t.set_stylebox("hover_pressed", "ChipButton", chip_on)
	t.set_color("font_pressed_color", "ChipButton", accent)
	t.set_color("font_hover_pressed_color", "ChipButton", accent)
	t.set_font_size("font_size", "ChipButton", 13)

	# Inputs
	var le := box(c("surface2"), RADIUS_SMALL, c("border"), 1, 12)
	var le_focus := le.duplicate()
	le_focus.border_color = accent
	for kind in ["LineEdit", "TextEdit", "SpinBox"]:
		t.set_stylebox("normal", kind, le)
		t.set_stylebox("focus", kind, le_focus)
		t.set_stylebox("read_only", kind, le)
		t.set_color("font_color", kind, text)
		t.set_color("font_placeholder_color", kind, c("text3"))
		t.set_color("caret_color", kind, accent)
		t.set_color("selection_color", kind, Color(accent, 0.35))
	t.set_color("font_readonly_color", "TextEdit", text2)
	t.set_color("background_color", "TextEdit", Color.TRANSPARENT)

	# CheckButton (switch) — drawn icons
	t.set_icon("checked", "CheckButton", _switch_icon(true))
	t.set_icon("unchecked", "CheckButton", _switch_icon(false))
	t.set_icon("checked_disabled", "CheckButton", _switch_icon(true, true))
	t.set_icon("unchecked_disabled", "CheckButton", _switch_icon(false, true))
	t.set_stylebox("normal", "CheckButton", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckButton", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckButton", StyleBoxEmpty.new())
	t.set_stylebox("hover_pressed", "CheckButton", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckButton", StyleBoxEmpty.new())
	t.set_stylebox("disabled", "CheckButton", StyleBoxEmpty.new())

	# Panels
	t.set_stylebox("panel", "PanelContainer", box(c("surface"), RADIUS, c("border"), 1, 16))
	t.add_type("Card")
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", box(c("surface"), RADIUS, c("border"), 1, 16))
	t.add_type("FlatPanel")
	t.set_type_variation("FlatPanel", "PanelContainer")
	t.set_stylebox("panel", "FlatPanel", StyleBoxEmpty.new())
	t.set_stylebox("panel", "Panel", box(c("surface"), RADIUS))
	t.set_stylebox("panel", "PopupPanel", box(c("surface"), RADIUS, c("border"), 1, 8))
	t.set_stylebox("panel", "PopupMenu", box(c("surface2"), RADIUS_SMALL, c("border"), 1, 6))
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", text)
	t.set_stylebox("hover", "PopupMenu", box(c("surface3"), 8))
	t.set_constant("v_separation", "PopupMenu", 14)
	t.set_font_size("font_size", "PopupMenu", 15)

	# Scrollbars: slim
	var grab := box(Color(c("text"), 0.18), 4)
	var grab_h := box(Color(c("text"), 0.3), 4)
	for kind in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", kind, StyleBoxEmpty.new())
		t.set_stylebox("grabber", kind, grab)
		t.set_stylebox("grabber_highlight", kind, grab_h)
		t.set_stylebox("grabber_pressed", kind, grab_h)
	t.set_constant("separation", "HSeparator", 1)
	var sep := StyleBoxLine.new()
	sep.color = c("border")
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)

	# Label variations
	for v in [["TitleLabel", 22, true, "text"], ["HeaderLabel", 17, true, "text"], ["MutedLabel", 13, false, "text2"],
			["CaptionLabel", 12, false, "text3"], ["ValueLabel", 20, true, "text"], ["SectionLabel", 12, true, "text3"]]:
		t.add_type(v[0])
		t.set_type_variation(v[0], "Label")
		t.set_font_size("font_size", v[0], v[1])
		t.set_color("font_color", v[0], c(v[3]))
		if v[2]:
			t.set_font("font", v[0], font_bold)

	t.set_stylebox("panel", "TooltipPanel", box(c("surface3"), 8, Color.TRANSPARENT, 0, 8))
	t.set_color("font_color", "TooltipLabel", text)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_color("default_color", "RichTextLabel", text)
	t.set_stylebox("background", "ProgressBar", box(c("surface3"), 4))
	t.set_stylebox("fill", "ProgressBar", box(accent, 4))
	return t


func _switch_icon(on: bool, disabled: bool = false) -> Texture2D:
	var s := 3
	var w := 46 * s
	var h := 28 * s
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var track: Color = c("accent") if on else c("surface3")
	var knob := Color.WHITE
	if disabled:
		track = track.darkened(0.3)
		knob = knob.darkened(0.3)
	var r := h / 2.0
	for y in h:
		for x in w:
			var cx := clampf(float(x), r, w - r)
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(cx, r))
			var a := clampf(r - d + 0.5, 0.0, 1.0)
			if a > 0:
				img.set_pixel(x, y, Color(track, track.a * a))
	var kr := r - 3 * s
	var kx := (w - r) if on else r
	for y in h:
		for x in w:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(kx, r))
			var a := clampf(kr - d + 0.5, 0.0, 1.0)
			if a > 0:
				img.set_pixel(x, y, img.get_pixel(x, y).blend(Color(knob, a)))
	var tex := ImageTexture.create_from_image(img)
	tex.set_size_override(Vector2i(46, 28))
	return tex
