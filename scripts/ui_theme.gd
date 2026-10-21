class_name UISkin
extends RefCounted
## Shared high-contrast midnight/neon theme for front-end, settings and attacker HUD.

const INK := Color(0.018, 0.035, 0.060, 0.96)
const PANEL := Color(0.025, 0.055, 0.085, 0.94)
const PANEL_HOVER := Color(0.045, 0.090, 0.130, 0.98)
const CYAN := Color(0.22, 0.90, 1.0)
const AMBER := Color(1.0, 0.76, 0.34)
const TEXT := Color(0.91, 0.96, 1.0)
const MUTED := Color(0.58, 0.69, 0.79)

static var _cached_theme: Theme


static func theme() -> Theme:
	if _cached_theme != null:
		return _cached_theme
	var result := Theme.new()
	result.default_font_size = 15
	result.set_color("font_color", "Label", TEXT)
	result.set_color("font_color", "Button", TEXT)
	result.set_color("font_hover_color", "Button", CYAN)
	result.set_color("font_pressed_color", "Button", AMBER)
	result.set_color("font_disabled_color", "Button", Color(0.56, 0.64, 0.70, 0.52))
	result.set_color("font_color", "LineEdit", TEXT)
	result.set_color("font_placeholder_color", "LineEdit", MUTED)
	result.set_color("font_color", "OptionButton", TEXT)
	result.set_stylebox("normal", "Button", _button_style(PANEL, Color(CYAN, 0.25), 8))
	result.set_stylebox("hover", "Button", _button_style(PANEL_HOVER, Color(CYAN, 0.88), 8))
	result.set_stylebox("pressed", "Button",
			_button_style(Color(0.07, 0.11, 0.15), Color(AMBER, 0.92), 8))
	result.set_stylebox("focus", "Button", _button_style(PANEL_HOVER, CYAN, 8))
	result.set_stylebox("disabled", "Button",
			_button_style(Color(0.025, 0.04, 0.055, 0.7), Color(1, 1, 1, 0.08), 8))
	result.set_stylebox("panel", "PanelContainer", _panel_style())
	result.set_stylebox("normal", "LineEdit", _button_style(INK, Color(CYAN, 0.32), 6))
	result.set_stylebox("focus", "LineEdit", _button_style(INK, CYAN, 6))
	result.set_stylebox("background", "ProgressBar", _button_style(INK, Color(CYAN, 0.25), 5))
	result.set_stylebox("fill", "ProgressBar", _button_style(CYAN, Color.TRANSPARENT, 5))
	result.set_constant("separation", "HBoxContainer", 10)
	result.set_constant("v_separation", "VBoxContainer", 8)
	_cached_theme = result
	return _cached_theme


static func panel_style() -> StyleBoxFlat:
	return _panel_style()


static func _button_style(fill: Color, outline: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = outline
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style


static func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = Color(CYAN, 0.28)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(0, 0, 0, 0.32)
	style.shadow_size = 10
	return style
