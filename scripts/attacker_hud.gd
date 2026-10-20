extends VBoxContainer
## HUD Штурмовика: золото, HP базы противника, кнопки отправки юнитов/волн.
## Кнопки генерируются из GameDB (с описанием способностей). Отправка —
## RPC строго серверу (rpc_id(1)).

@onready var gold_label: Label = $GoldLabel
@onready var hp_label: Label = $HPLabel
@onready var unit_buttons: VBoxContainer = $UnitButtons
@onready var unit_spawner: UnitSpawner = %UnitSpawner

var _hp_bar: ProgressBar


func _ready() -> void:
	theme = UISkin.theme()
	add_theme_constant_override("separation", 7)
	_build_panel_backdrop()
	gold_label.add_theme_font_size_override("font_size", 20)
	gold_label.add_theme_color_override("font_color", UISkin.AMBER)
	hp_label.add_theme_font_size_override("font_size", 14)
	hp_label.add_theme_color_override("font_color", Color(1.0, 0.46, 0.50))
	$HintLabel.add_theme_font_size_override("font_size", 11)
	$HintLabel.add_theme_color_override("font_color", UISkin.MUTED)
	var header := Label.new()
	header.text = "RAIDER COMMAND  //  ATTACKER"
	header.add_theme_font_size_override("font_size", 10)
	header.add_theme_color_override("font_color", UISkin.CYAN)
	add_child(header)
	move_child(header, 0)
	_hp_bar = ProgressBar.new()
	_hp_bar.custom_minimum_size = Vector2(0, 8)
	_hp_bar.show_percentage = false
	_hp_bar.max_value = GameState.BASE_MAX_HP
	_hp_bar.value = GameState.base_hp
	_hp_bar.add_theme_stylebox_override("background", _meter_style(Color(0.045, 0.06, 0.08)))
	_hp_bar.add_theme_stylebox_override("fill", _meter_style(Color(1.0, 0.30, 0.42)))
	add_child(_hp_bar)
	move_child(_hp_bar, hp_label.get_index() + 1)
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.base_hp_changed.connect(_on_base_hp_changed)


func _build_panel_backdrop() -> void:
	var panel := Panel.new()
	panel.name = "AttackerPanelBackdrop"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = offset_left - 10.0
	panel.offset_top = offset_top - 8.0
	panel.offset_right = offset_right + 8.0
	panel.offset_bottom = offset_bottom + 8.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := UISkin.panel_style()
	style.bg_color = Color(0.012, 0.028, 0.048, 0.94)
	style.border_color = Color(UISkin.CYAN, 0.38)
	panel.add_theme_stylebox_override("panel", style)
	get_parent().add_child.call_deferred(panel)
	await get_tree().process_frame
	if is_instance_valid(panel):
		get_parent().move_child(panel, get_index())


func _meter_style(fill: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(4)
	return style


## Кнопки юнитов строятся ИЗ ДЕКА Штурмовика этого матча (вызывает game.gd
## ПОСЛЕ GameState.setup_match — деки приходят из лобби-RPC).
func rebuild_from_deck() -> void:
	for child in unit_buttons.get_children():
		child.queue_free()
	for unit_id in GameState.attacker_units:
		var stats: Dictionary = GameDB.UNITS[unit_id]
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(0, 58)
		var card_style := StyleBoxFlat.new()
		card_style.bg_color = Color(0.035, 0.070, 0.098, 0.92)
		card_style.border_color = Color(0.28, 0.60, 0.72, 0.26)
		card_style.set_border_width_all(1)
		card_style.set_corner_radius_all(7)
		card.add_theme_stylebox_override("panel", card_style)
		unit_buttons.add_child(card)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 7)
		margin.add_theme_constant_override("margin_right", 7)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		card.add_child(margin)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		margin.add_child(row)
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(42, 42)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var icon_path := "res://assets/img/%s.png" % unit_id
		if ResourceLoader.exists(icon_path):
			icon.texture = load(icon_path)
		row.add_child(icon)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 0)
		row.add_child(info)
		var title := Label.new()
		title.text = "%s  ·  %d ЗОЛ." % [String(stats["name"]).to_upper(), stats["cost"]]
		title.add_theme_font_size_override("font_size", 12)
		title.add_theme_color_override("font_color", UISkin.TEXT)
		info.add_child(title)
		var details := Label.new()
		details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		details.text = "HP %d  ·  базе −%d%s" % [stats["hp"], stats["damage"], _trait_tags(stats)]
		details.add_theme_font_size_override("font_size", 10)
		details.add_theme_color_override("font_color", UISkin.MUTED)
		info.add_child(details)
		var send_btn := Button.new()
		send_btn.text = "ОДИН"
		send_btn.custom_minimum_size = Vector2(70, 40)
		send_btn.pressed.connect(_on_send_one.bind(unit_id))
		row.add_child(send_btn)
		var wave_btn := Button.new()
		wave_btn.text = "ВОЛНА ×%d" % unit_spawner.wave_size
		wave_btn.custom_minimum_size = Vector2(94, 40)
		wave_btn.pressed.connect(_on_send_wave.bind(unit_id))
		row.add_child(wave_btn)


## Строка способностей юнита: «летает, иммун к замедлению», «аура защиты»…
func _trait_tags(stats: Dictionary) -> String:
	var tags: Array[String] = []
	if stats["flying"]:
		tags.append("летает")
	if stats.get("ignores_slow", false):
		tags.append("иммун к замедлению")
	if stats.has("aura_radius"):
		tags.append("аура: -%d%% урона союзникам рядом"
				% int(round(float(stats["aura_reduction"]) * 100.0)))
	if tags.is_empty():
		return ""
	return " | " + ", ".join(tags)


func _on_send_one(unit_id: String) -> void:
	AudioManager.play_sfx("click", -7.0, 1.2)
	# 1 — peer_id хоста: только он валидирует и спавнит.
	unit_spawner.request_unit.rpc_id(1, unit_id)


func _on_send_wave(unit_id: String) -> void:
	AudioManager.play_sfx("click", -4.0, 0.82)
	unit_spawner.request_wave.rpc_id(1, unit_id)


var _last_gold := -1   # для определения дохода/траты при анимации


func _on_gold_changed(peer_id: int, amount: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		return
	var delta := 0 if _last_gold < 0 else amount - _last_gold
	_last_gold = amount
	gold_label.text = "КРЕДИТЫ  ·  %d" % amount
	if delta > 0:
		_punch(gold_label, Color(0.55, 1.0, 0.55), "+%d" % delta)
	elif delta < 0:
		_punch(gold_label, Color(1.0, 0.5, 0.4), "%d" % delta)


func _on_base_hp_changed(hp: int, max_hp: int) -> void:
	hp_label.text = "ВРАЖЕСКОЕ ЯДРО  ·  %d / %d" % [hp, max_hp]
	if _hp_bar != null:
		_hp_bar.max_value = max_hp
		_hp_bar.value = hp
	_punch(hp_label, Color(1.0, 0.62, 0.62))


## Мини-анимация «удара»: короткий рост масштаба + вспышка цвета + дельта.
## suffix («+100», «-50») показывается поверх суммы на время вспышки.
func _punch(label: Label, flash: Color = Color(1.0, 0.9, 0.4), suffix := "") -> void:
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.3, 1.3)
	label.modulate = flash
	var base_text := label.text
	if suffix != "":
		label.text = "%s  (%s)" % [base_text, suffix]
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate", Color.WHITE, 0.35)
	if suffix != "":
		tween.chain().tween_callback(label.set_text.bind(base_text))
