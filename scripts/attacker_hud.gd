extends Control
## HUD Штурмовика: статус в верхней полосе, выбор юнитов — в нижней.
## Центр экрана остаётся свободен для дороги, башен и тактического поля.

const WAVE_DISPLAY_SCRIPT := preload("res://scripts/wave_display.gd")
const BAR_HEIGHT := 64.0
const DOCK_HEIGHT := 154.0
const DOCK_MAX_WIDTH := 1450.0
const CYAN := Color(0.22, 0.90, 1.0)
const AMBER := Color(1.0, 0.76, 0.34)
const RED := Color(1.0, 0.38, 0.42)
const TEXT := Color(0.91, 0.96, 1.0)
const MUTED := Color(0.58, 0.69, 0.79)
const PANEL_BG := Color(0.012, 0.028, 0.048, 0.94)

var _unit_spawner: UnitSpawner
var _wave_display: WaveDisplay
var _gold_label: Label
var _hp_label: Label
var _hp_bar: ProgressBar
var _unit_dock: PanelContainer
var _unit_cards: HBoxContainer
var _last_gold := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UISkin.theme()
	_unit_spawner = get_node_or_null("%UnitSpawner") as UnitSpawner
	_build_status_bar()
	_build_unit_dock()
	resized.connect(_fit_unit_dock)
	call_deferred("_fit_unit_dock")
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.base_hp_changed.connect(_on_base_hp_changed)
	_refresh_status()
	rebuild_from_deck()


func _build_status_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "AttackerStatusBar"
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 0.0
	bar.anchor_bottom = 0.0
	bar.offset_left = 0.0
	bar.offset_top = 0.0
	bar.offset_right = 0.0
	bar.offset_bottom = BAR_HEIGHT
	bar.add_theme_stylebox_override("panel", _panel_style(PANEL_BG, Color(CYAN, 0.32), 10))
	add_child(bar)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	bar.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 15)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	var brand := VBoxContainer.new()
	brand.custom_minimum_size.x = 174.0
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brand.add_theme_constant_override("separation", -2)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(brand)
	brand.add_child(_label("TOWER DUEL", 18, CYAN, 3))
	brand.add_child(_label("ATTACKER // ASSAULT", 9, MUTED, 1))
	row.add_child(_vertical_line(30.0))

	_wave_display = WAVE_DISPLAY_SCRIPT.new() as WaveDisplay
	_wave_display.custom_minimum_size = Vector2(270.0, 42.0)
	_wave_display.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_wave_display)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var gold_panel := PanelContainer.new()
	gold_panel.custom_minimum_size = Vector2(150.0, 34.0)
	gold_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gold_panel.add_theme_stylebox_override(
		"panel", _panel_style(Color(0.07, 0.05, 0.02, 0.78), Color(AMBER, 0.34), 7)
	)
	row.add_child(gold_panel)
	var gold_margin := MarginContainer.new()
	gold_margin.add_theme_constant_override("margin_left", 10)
	gold_margin.add_theme_constant_override("margin_right", 10)
	gold_panel.add_child(gold_margin)
	_gold_label = _label("КРЕДИТЫ  ·  0", 14, AMBER, 2)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gold_margin.add_child(_gold_label)

	row.add_child(_vertical_line(30.0))
	var base_box := VBoxContainer.new()
	base_box.custom_minimum_size.x = 210.0
	base_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	base_box.add_theme_constant_override("separation", 3)
	base_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(base_box)
	_hp_label = _label("ВРАЖЕСКАЯ БАЗА  ·  20 / 20", 10, TEXT, 1)
	base_box.add_child(_hp_label)
	_hp_bar = ProgressBar.new()
	_hp_bar.custom_minimum_size = Vector2(0.0, 7.0)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_bar.show_percentage = false
	_hp_bar.max_value = GameState.BASE_MAX_HP
	_hp_bar.value = GameState.base_hp
	_hp_bar.add_theme_stylebox_override("background", _meter_style(Color(0.045, 0.06, 0.08)))
	_hp_bar.add_theme_stylebox_override("fill", _meter_style(RED))
	base_box.add_child(_hp_bar)


func _build_unit_dock() -> void:
	_unit_dock = PanelContainer.new()
	_unit_dock.name = "UnitSelectionDock"
	_unit_dock.mouse_filter = Control.MOUSE_FILTER_STOP
	_unit_dock.anchor_left = 0.5
	_unit_dock.anchor_right = 0.5
	_unit_dock.anchor_top = 1.0
	_unit_dock.anchor_bottom = 1.0
	_unit_dock.offset_left = -560.0
	_unit_dock.offset_right = 560.0
	_unit_dock.offset_top = -DOCK_HEIGHT - 10.0
	_unit_dock.offset_bottom = -10.0
	_unit_dock.add_theme_stylebox_override("panel", _panel_style(PANEL_BG, Color(CYAN, 0.28), 10))
	add_child(_unit_dock)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_unit_dock.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(header)
	header.add_child(_label("UNIT SELECTION", 11, TEXT, 2))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	header.add_child(_label("ОДИН ЮНИТ  /  ВОЛНА ×5", 9, MUTED, 1))

	var rule := ColorRect.new()
	rule.custom_minimum_size.y = 1.0
	rule.color = Color(CYAN, 0.18)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	var scroll := ScrollContainer.new()
	scroll.name = "UnitScroll"
	scroll.custom_minimum_size.y = 99.0
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	column.add_child(scroll)

	_unit_cards = HBoxContainer.new()
	_unit_cards.add_theme_constant_override("separation", 8)
	_unit_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_unit_cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(_unit_cards)


func _fit_unit_dock() -> void:
	if _unit_dock == null or not is_inside_tree():
		return
	var width := minf(DOCK_MAX_WIDTH, get_viewport_rect().size.x - 32.0)
	_unit_dock.offset_left = -width * 0.5
	_unit_dock.offset_right = width * 0.5


## Карточки строятся из текущей деки Штурмовика после настройки матча.
func rebuild_from_deck() -> void:
	if _unit_cards == null:
		return
	for child in _unit_cards.get_children():
		_unit_cards.remove_child(child)
		child.queue_free()
	if _unit_spawner == null:
		_unit_spawner = get_node_or_null("%UnitSpawner") as UnitSpawner

	for unit_id in GameState.attacker_units:
		if not GameDB.UNITS.has(unit_id):
			continue
		_unit_cards.add_child(_create_unit_card(String(unit_id), GameDB.UNITS[unit_id]))


func _create_unit_card(unit_id: String, stats: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.name = "Unit_%s" % unit_id
	card.custom_minimum_size = Vector2(194.0, 94.0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override(
		"panel", _panel_style(Color(0.035, 0.070, 0.098, 0.96), Color(CYAN, 0.23), 7)
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	card.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(content)

	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 6)
	info_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(info_row)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(38.0, 38.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon_path := "res://assets/img/%s.png" % unit_id
	if ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path) as Texture2D
	info_row.add_child(icon)

	var labels := VBoxContainer.new()
	labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	labels.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	labels.add_theme_constant_override("separation", 0)
	labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_row.add_child(labels)
	var title := _label(
		"%s  ·  %d зол." % [String(stats["name"]).to_upper(), int(stats["cost"])], 11, TEXT, 1
	)
	title.clip_text = true
	labels.add_child(title)
	var details := _label(
		"HP %d  ·  БАЗЕ −%d%s" % [int(stats["hp"]), int(stats["damage"]), _trait_short(stats)],
		9,
		MUTED,
		1
	)
	details.clip_text = true
	labels.add_child(details)
	card.tooltip_text = (
		"%s — %d золота\nHP: %d · Урон базе: %d%s"
		% [
			String(stats["name"]),
			int(stats["cost"]),
			int(stats["hp"]),
			int(stats["damage"]),
			_trait_long(stats)
		]
	)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 5)
	content.add_child(buttons)
	var send_one := Button.new()
	send_one.text = "ОДИН"
	send_one.custom_minimum_size = Vector2(0.0, 30.0)
	send_one.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_one.pressed.connect(_on_send_one.bind(unit_id))
	buttons.add_child(send_one)
	var send_wave := Button.new()
	var wave_size := _unit_spawner.wave_size if _unit_spawner != null else 5
	send_wave.text = "ВОЛНА ×%d" % wave_size
	send_wave.custom_minimum_size = Vector2(0.0, 30.0)
	send_wave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_wave.pressed.connect(_on_send_wave.bind(unit_id))
	buttons.add_child(send_wave)
	return card


func _trait_short(stats: Dictionary) -> String:
	if stats.has("aura_radius"):
		return " · АУРА −%d%%" % int(round(float(stats["aura_reduction"]) * 100.0))
	if bool(stats.get("flying", false)):
		return " · ЛЕТИТ"
	return ""


func _trait_long(stats: Dictionary) -> String:
	var tags: Array[String] = []
	if bool(stats.get("flying", false)):
		tags.append("летает")
	if bool(stats.get("ignores_slow", false)):
		tags.append("иммунитет к замедлению")
	if stats.has("aura_radius"):
		tags.append(
			"аура защиты союзников −%d%%" % int(round(float(stats["aura_reduction"]) * 100.0))
		)
	return "" if tags.is_empty() else "\n" + ", ".join(tags)


func _label(text: String, font_size: int, color: Color, outline_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.008, 0.016, 0.028, 0.9))
	label.add_theme_constant_override("outline_size", outline_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _vertical_line(height: float) -> ColorRect:
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(1.0, height)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.color = Color(1.0, 1.0, 1.0, 0.12)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _panel_style(fill: Color, outline: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = outline
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.28)
	style.shadow_size = 8
	return style


func _meter_style(fill: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(4)
	return style


func _on_send_one(unit_id: String) -> void:
	if _unit_spawner == null:
		return
	AudioManager.play_sfx("click", -7.0, 1.2)
	_unit_spawner.request_unit.rpc_id(1, unit_id)


func _on_send_wave(unit_id: String) -> void:
	if _unit_spawner == null:
		return
	AudioManager.play_sfx("click", -4.0, 0.82)
	_unit_spawner.request_wave.rpc_id(1, unit_id)


func _refresh_status() -> void:
	var peer_id := multiplayer.get_unique_id()
	var amount := int(GameState.gold.get(peer_id, 0))
	_last_gold = amount
	if _gold_label != null:
		_gold_label.text = "КРЕДИТЫ  ·  %d" % amount
	if _hp_label != null:
		_on_base_hp_changed(GameState.base_hp, GameState.BASE_MAX_HP)


func _on_gold_changed(peer_id: int, amount: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		return
	var delta := 0 if _last_gold < 0 else amount - _last_gold
	_last_gold = amount
	_gold_label.text = "КРЕДИТЫ  ·  %d" % amount
	if delta != 0:
		_punch(
			_gold_label,
			Color(0.55, 1.0, 0.55) if delta > 0 else RED,
			"+%d" % delta if delta > 0 else "%d" % delta
		)


func _on_base_hp_changed(hp: int, max_hp: int) -> void:
	if _hp_label != null:
		_hp_label.text = "ВРАЖЕСКАЯ БАЗА  ·  %d / %d" % [hp, max_hp]
	if _hp_bar != null:
		_hp_bar.max_value = max_hp
		_hp_bar.value = hp


func _punch(label: Label, flash: Color, suffix := "") -> void:
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.12, 1.12)
	label.modulate = flash
	var base_text := label.text
	if suffix != "":
		label.text = "%s  (%s)" % [base_text, suffix]
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	tween.tween_property(label, "modulate", Color.WHITE, 0.28)
	if suffix != "":
		tween.chain().tween_callback(label.set_text.bind(base_text))
