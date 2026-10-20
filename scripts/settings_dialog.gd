extends Control
## Runtime-built options modal shared by the front end and in-match pause menu.

const BG := Color(0.018, 0.035, 0.060, 0.97)
const ACCENT := Color(0.22, 0.88, 1.0)

var _controls: Dictionary = {}
var _closed := false


func _ready() -> void:
	theme = UISkin.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.18)


func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.005, 0.012, 0.025, 0.78)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = BG
	style.border_color = Color(ACCENT, 0.65)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)
	var title := Label.new()
	title.text = "НАСТРОЙКИ"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT)
	box.add_child(title)
	_add_slider(box, "Общая громкость", "master_volume", SettingsManager.master_volume)
	_add_slider(box, "Музыка", "music_volume", SettingsManager.music_volume)
	_add_slider(box, "Эффекты", "sfx_volume", SettingsManager.sfx_volume)
	_add_option(box, "Качество 2D сглаживания", "quality", SettingsManager.QUALITY_LABELS, SettingsManager.quality)
	_add_option(box, "Частота кадров", "target_fps", ["30 FPS", "60 FPS", "120 FPS", "240 FPS"], _fps_index(SettingsManager.target_fps))
	_add_check(box, "Полноэкранный режим", "fullscreen", SettingsManager.fullscreen)
	_add_check(box, "Вертикальная синхронизация", "vsync", SettingsManager.vsync)
	var hint := Label.new()
	hint.text = "Параметры сохраняются автоматически"
	hint.modulate = Color(0.72, 0.82, 0.9, 0.72)
	box.add_child(hint)
	var close := Button.new()
	close.text = "ГОТОВО"
	close.custom_minimum_size.y = 42
	close.pressed.connect(close_dialog)
	box.add_child(close)
	close.grab_focus()


func _add_slider(parent: VBoxContainer, caption: String, key: String, initial: float) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	parent.add_child(row)
	var label := Label.new()
	label.text = "%s  ·  %d%%" % [caption, roundi(initial * 100.0)]
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.value_changed.connect(func(value: float) -> void:
		label.text = "%s  ·  %d%%" % [caption, roundi(value * 100.0)]
		SettingsManager.update_option(key, value))
	row.add_child(slider)


func _add_option(parent: VBoxContainer, caption: String, key: String, items: Array, selected: int) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	option.selected = selected
	option.item_selected.connect(func(index: int) -> void:
		if key == "target_fps":
			SettingsManager.update_option(key, [30, 60, 120, 240][index])
		else:
			SettingsManager.update_option(key, index))
	row.add_child(option)


func _add_check(parent: VBoxContainer, caption: String, key: String, initial: bool) -> void:
	var check := CheckButton.new()
	check.text = caption
	check.button_pressed = initial
	check.toggled.connect(func(value: bool) -> void: SettingsManager.update_option(key, value))
	parent.add_child(check)


func _fps_index(fps: int) -> int:
	return [30, 60, 120, 240].find(fps) if [30, 60, 120, 240].has(fps) else 2


func close_dialog() -> void:
	if _closed:
		return
	_closed = true
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.14)
	tween.tween_callback(queue_free)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_menu"):
		close_dialog()
		get_viewport().set_input_as_handled()
