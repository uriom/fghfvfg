extends CanvasLayer
## Local pause/options overlay for a networked match.
## It intentionally does NOT pause SceneTree: this is a live PvP match and a
## unilateral client pause must not freeze the server/opponent simulation.

const SETTINGS_DIALOG := preload("res://scripts/settings_dialog.gd")

var _root: Control
var _open := false
var _settings_open := false


func _ready() -> void:
	layer = 30
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = UISkin.theme()
	_root.visible = false
	add_child(_root)
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_menu") and not GameState.game_over:
		if _settings_open:
			return
		set_open(not _open)
		get_viewport().set_input_as_handled()


func set_open(value: bool) -> void:
	_open = value
	_root.visible = value
	if value:
		var continue_button := _root.find_child("ContinueButton", true, false) as Button
		if continue_button != null:
			continue_button.grab_focus()
		_root.modulate.a = 0.0
		_root.create_tween().tween_property(_root, "modulate:a", 1.0, 0.16)


func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.005, 0.012, 0.025, 0.76)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.035, 0.060, 0.98)
	style.border_color = Color(0.22, 0.88, 1.0, 0.65)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)
	var title := Label.new()
	title.text = "ПАУЗА"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(0.22, 0.88, 1.0))
	box.add_child(title)
	var note := Label.new()
	note.text = "Матч продолжается для соперника"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(0.76, 0.84, 0.92, 0.8)
	box.add_child(note)
	_add_button(box, "ПРОДОЛЖИТЬ", func() -> void: set_open(false))
	_add_button(box, "НАСТРОЙКИ", _open_settings)
	_add_button(box, "ВЫЙТИ В ГЛАВНОЕ МЕНЮ", _leave_match)
	var tip := Label.new()
	tip.text = "Esc / B — закрыть"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.modulate = Color(0.72, 0.82, 0.9, 0.6)
	box.add_child(tip)


func _add_button(parent: VBoxContainer, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.name = "ContinueButton" if caption == "ПРОДОЛЖИТЬ" else "ActionButton"
	button.custom_minimum_size.y = 44
	button.pressed.connect(callback)
	button.mouse_entered.connect(func() -> void:
		button.scale = Vector2(1.025, 1.025)
		AudioManager.play_sfx("click", -8.0, 1.4))
	button.mouse_exited.connect(func() -> void: button.scale = Vector2.ONE)
	parent.add_child(button)


func _open_settings() -> void:
	_settings_open = true
	var dialog := SETTINGS_DIALOG.new()
	add_child(dialog)
	dialog.tree_exited.connect(func() -> void: _settings_open = false)


func _leave_match() -> void:
	NetworkManager.end_session()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
