extends Control
## HUD Штурмовика: статус в верхней полосе, выбор юнитов — в нижней.
## Центр экрана остаётся свободен для дороги, башен и тактического поля.
##
## ЭТАП 7: вместо кнопки «ВОЛНА ×5» — большая кнопка «ДЕРЖАТЬ»: одно нажатие
## покупает юнита, удержание покупает их подряд, пока хватает кредитов.
## Рядом — кнопка уровня типа юнита (1..10).
##
## ЭТАП 8: зазор между покупками — ровно 0,2 с и для удержания, и для
## «залипания» мышью. Один общий шлюз (_spawn_gate) не даёт обойти лимит ни
## повтором клика, ни быстрым тапом: чаще 5 юнитов в секунду не купить.

const PHASE_DISPLAY_SCRIPT := preload("res://scripts/phase_display.gd")
## Минимальный зазор между двумя покупками юнита, сек.
const SPAWN_GAP := 0.20
const BAR_HEIGHT := 64.0
const DOCK_HEIGHT := 150.0
const DOCK_MAX_WIDTH := 820.0
const CYAN := Color(0.22, 0.90, 1.0)
const AMBER := Color(1.0, 0.76, 0.34)
const RED := Color(1.0, 0.38, 0.42)
const TEXT := Color(0.91, 0.96, 1.0)
const MUTED := Color(0.58, 0.69, 0.79)
const PANEL_BG := Color(0.012, 0.028, 0.048, 0.94)

var _unit_spawner: UnitSpawner
var _phase_display: PhaseDisplay
var _queue_label: Label
var _break_button: Button
var _cards_by_unit: Dictionary = {}
var _gold_label: Label
var _hp_label: Label
var _hp_bar: ProgressBar
var _unit_dock: PanelContainer
var _unit_cards: HBoxContainer
var _last_gold := -1
## Тип юнита, кнопку которого сейчас держат ("" — не держат).
var _hold_unit := ""
## Момент (мс, Time.get_ticks_msec), раньше которого следующая покупка
## невозможна. Общий и для удержания, и для кликов.
var _spawn_gate := 0


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
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.unit_level_changed.connect(_on_unit_level_changed)
	_refresh_card_states()


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
	bar.add_theme_stylebox_override("panel", HudKit.panel_style(PANEL_BG, Color(CYAN, 0.32), 1, 10))
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
	row.add_child(HudKit.vertical_line(30.0))

	_phase_display = PHASE_DISPLAY_SCRIPT.new() as PhaseDisplay
	_phase_display.custom_minimum_size = Vector2(250.0, 42.0)
	_phase_display.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_phase_display)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var gold_panel := PanelContainer.new()
	gold_panel.custom_minimum_size = Vector2(150.0, 34.0)
	gold_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gold_panel.add_theme_stylebox_override(
		"panel", HudKit.panel_style(Color(0.07, 0.05, 0.02, 0.78),
				Color(AMBER, 0.34), 1, 7)
	)
	row.add_child(gold_panel)
	var gold_margin := MarginContainer.new()
	gold_margin.add_theme_constant_override("margin_left", 10)
	gold_margin.add_theme_constant_override("margin_right", 10)
	gold_panel.add_child(gold_margin)
	_gold_label = _label("КРЕДИТЫ  ·  0", 14, AMBER, 2)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gold_margin.add_child(_gold_label)

	row.add_child(HudKit.vertical_line(30.0))
	var base_box := VBoxContainer.new()
	base_box.custom_minimum_size.x = 210.0
	base_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	base_box.add_theme_constant_override("separation", 3)
	base_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(base_box)
	_hp_label = _label(
		"ВРАЖЕСКАЯ БАЗА  ·  %d / %d" % [GameState.base_hp, GameState.ROUND_BASE_HP], 10, TEXT, 1
	)
	base_box.add_child(_hp_label)
	_hp_bar = ProgressBar.new()
	_hp_bar.custom_minimum_size = Vector2(0.0, 7.0)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_bar.show_percentage = false
	_hp_bar.max_value = GameState.ROUND_BASE_HP
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
	_unit_dock.offset_left = -410.0
	_unit_dock.offset_right = 410.0
	_unit_dock.offset_top = -DOCK_HEIGHT - 10.0
	_unit_dock.offset_bottom = -10.0
	_unit_dock.add_theme_stylebox_override("panel",
			HudKit.panel_style(PANEL_BG, Color(CYAN, 0.28), 1, 10))
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
	_queue_label = _label("ОЧЕРЕДЬ 0 / %d" % UnitSpawner.MAX_QUEUE, 9, MUTED, 1)
	header.add_child(_queue_label)

	# «ПРОРЫВ» — разовый залп всей очередью (способность Штурмовика).
	_break_button = Button.new()
	_break_button.text = "ПРОРЫВ"
	_break_button.tooltip_text = ("Мгновенно выпустить всю очередь. "
			+ "Один раз за раунд — лучший способ пробить плотную оборону.")
	_break_button.focus_mode = Control.FOCUS_NONE
	_break_button.custom_minimum_size = Vector2(84.0, 22.0)
	_break_button.add_theme_font_size_override("font_size", 10)
	_break_button.add_theme_color_override("font_color", RED)
	_break_button.pressed.connect(_on_breakthrough_pressed)
	header.add_child(_break_button)

	var rule := ColorRect.new()
	rule.custom_minimum_size.y = 1.0
	rule.color = Color(CYAN, 0.18)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	_unit_cards = HBoxContainer.new()
	_unit_cards.add_theme_constant_override("separation", 8)
	_unit_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	_unit_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_unit_cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_unit_cards)


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
	_cards_by_unit.clear()
	if _unit_spawner == null:
		_unit_spawner = get_node_or_null("%UnitSpawner") as UnitSpawner

	for unit_id in GameState.attacker_units:
		if not GameDB.UNITS.has(unit_id):
			continue
		var card := _create_unit_card(String(unit_id), GameState.unit_stats(unit_id))
		_unit_cards.add_child(card)
		_cards_by_unit[String(unit_id)] = card


func _create_unit_card(unit_id: String, stats: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.name = "Unit_%s" % unit_id
	card.custom_minimum_size = Vector2(220.0, 96.0)
	card.size_flags_horizontal = Control.SIZE_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override(
		"panel", HudKit.panel_style(Color(0.035, 0.070, 0.098, 0.96),
				Color(CYAN, 0.23), 1, 7)
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
	icon.custom_minimum_size = Vector2(44.0, 44.0)
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
	var level := GameState.unit_level(unit_id)
	var title := _label(
		"%s · УР %d · %d кр." % [String(stats["name"]).to_upper(), level,
				int(stats["cost"])], 11, TEXT, 1
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
		"%s — %d кр., уровень %d/%d\nHP: %d · Скорость: %d · Урон базе: %d%s"
		% [
			String(stats["name"]),
			int(stats["cost"]),
			level,
			GameDB.UNIT_MAX_LEVEL,
			int(stats["hp"]),
			int(stats["speed"]),
			int(stats["damage"]),
			_trait_long(stats)
		]
	)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 5)
	content.add_child(buttons)
	# Главная кнопка: клик — один юнит, удержание — поток юнитов.
	var send_hold := Button.new()
	send_hold.text = "ДЕРЖАТЬ"
	send_hold.tooltip_text = "Клик — один юнит. Зажми — поток, пока хватает кредитов."
	send_hold.add_theme_font_size_override("font_size", 12)
	send_hold.custom_minimum_size = Vector2(0.0, 28.0)
	send_hold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_hold.focus_mode = Control.FOCUS_NONE
	send_hold.button_down.connect(_on_hold_started.bind(unit_id))
	send_hold.button_up.connect(_on_hold_stopped)
	send_hold.pressed.connect(_on_hold_click.bind(unit_id))
	buttons.add_child(send_hold)
	# Уровень типа юнита: 1..10. Кнопка покупает следующий уровень.
	var upgrade := Button.new()
	upgrade.add_theme_font_size_override("font_size", 10)
	upgrade.custom_minimum_size = Vector2(74.0, 28.0)
	upgrade.focus_mode = Control.FOCUS_NONE
	upgrade.pressed.connect(_on_unit_upgrade.bind(unit_id))
	buttons.add_child(upgrade)
	card.set_meta("unit_id", unit_id)
	card.set_meta("send_hold", send_hold)
	card.set_meta("upgrade", upgrade)
	card.set_meta("title", title)
	card.set_meta("details", details)
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


func _meter_style(fill: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(4)
	return style


## Нажатие «ДЕРЖАТЬ»: один юнит сразу и запуск потока, пока кнопку держат.
## Автоповтор живёт в _process, чтобы темп не зависел от частоты нажатий мыши.
func _on_hold_started(unit_id: String) -> void:
	_hold_unit = unit_id
	_buy_one(unit_id, true)


func _on_hold_stopped() -> void:
	_hold_unit = ""


## Короткий клик тоже приходит как pressed (после button_up) — не покупаем
## второго юнита: кнопка уже купила одного на button_down.
func _on_hold_click(_unit_id: String) -> void:
	pass


## Покупка одного юнита: деньги списывает СЕРВЕР (в спавнере), HUD только
## не даёт клику уйти в пустоту.
func _buy_one(unit_id: String, audible: bool) -> void:
	if _unit_spawner == null:
		return
	# Зазор 0,2 с: и для удержания, и для спама кликами. Проверяем ДО денег,
	# чтобы «зажатие» не превращалось в пулемёт из серверных RPC.
	if Time.get_ticks_msec() < _spawn_gate:
		return
	if not _can_afford(unit_id, 1):
		if audible:
			_deny()
		return
	if audible:
		AudioManager.play_sfx("click", -7.0, 1.2)
	_spawn_gate = Time.get_ticks_msec() + int(round(SPAWN_GAP * 1000.0))
	_unit_spawner.enqueue_unit(unit_id, 1)


func _deny() -> void:
	AudioManager.play_sfx("deny", -6.0)


## Покупка следующего уровня типа юнита (переживает раунды).
func _on_unit_upgrade(unit_id: String) -> void:
	var level := GameState.unit_level(unit_id)
	if level >= GameDB.UNIT_MAX_LEVEL or GameState.game_over:
		_deny()
		return
	var cost := GameDB.unit_upgrade_cost(unit_id, level)
	if int(GameState.gold.get(multiplayer.get_unique_id(), 0)) < cost:
		_deny()
		return
	AudioManager.play_sfx("ability", -6.0, 1.1)
	if multiplayer.is_server():
		GameState.apply_unit_upgrade(multiplayer.get_unique_id(), unit_id)
	else:
		GameState.request_unit_upgrade.rpc_id(1, unit_id)


## Хватает ли кредитов на count юнитов и не переполнена ли очередь.
func _can_afford(unit_id: String, count: int) -> bool:
	if _unit_spawner == null or GameState.game_over:
		return false
	if _unit_spawner.queue_size() + count > UnitSpawner.MAX_QUEUE:
		return false
	var cost := int(GameDB.UNITS[unit_id]["cost"]) * count
	return int(GameState.gold.get(multiplayer.get_unique_id(), 0)) >= cost


## Пересчёт доступности карточек. Вызывается по изменению золота/очереди и
## раз в кадр — недорого (5 карточек), зато кнопки всегда честные.
func _refresh_card_states() -> void:
	if _cards_by_unit.is_empty():
		return
	var gold := int(GameState.gold.get(multiplayer.get_unique_id(), 0))
	var queue := _unit_spawner.queue_size() if _unit_spawner != null else 0
	for unit_id in _cards_by_unit:
		var card: PanelContainer = _cards_by_unit[unit_id]
		if not is_instance_valid(card):
			continue
		var cost := int(GameDB.UNITS[unit_id]["cost"])
		var one_ok := gold >= cost and queue < UnitSpawner.MAX_QUEUE \
				and GameState.can_buy_units()
		(card.get_meta("send_hold") as Button).disabled = not one_ok
		card.modulate = Color.WHITE if one_ok else Color(0.62, 0.66, 0.72)
		_refresh_upgrade_button(card, unit_id, gold)
	if _queue_label != null:
		_queue_label.text = "ОЧЕРЕДЬ %d / %d" % [queue, UnitSpawner.MAX_QUEUE]
		_queue_label.add_theme_color_override("font_color",
				Color(CYAN) if queue > 0 else MUTED)
	_refresh_breakthrough()


func _process(delta: float) -> void:
	_tick_hold(delta)
	_refresh_card_states()


## Автоповтор «зажатой» кнопки. Покупаем, как только истёк общий зазор
## 0,2 с; _buy_one сам проверит деньги и место в очереди. Сервер всё равно
## проверяет каждую покупку и держит свой лимит частоты.
func _tick_hold(_delta: float) -> void:
	if _hold_unit == "":
		return
	if not GameState.can_buy_units():
		_hold_unit = ""
		return
	if Time.get_ticks_msec() < _spawn_gate:
		return
	_buy_one(_hold_unit, false)


## Кнопка уровня: «УР 3 → 4 · 33 кр.» либо «УР 10 · МАКС».
func _refresh_upgrade_button(card: PanelContainer, unit_id: String, gold: int) -> void:
	var button := card.get_meta("upgrade") as Button
	if button == null:
		return
	var level := GameState.unit_level(unit_id)
	if level >= GameDB.UNIT_MAX_LEVEL:
		button.text = "УР %d · МАКС" % level
		button.disabled = true
		button.modulate = Color(0.75, 0.8, 0.86)
		return
	var cost := GameDB.unit_upgrade_cost(unit_id, level)
	button.text = "УР %d → %d" % [level, level + 1]
	button.tooltip_text = ("Улучшить весь тип «%s»: +HP и скорость, "
			+ "на 10-м — +1 урон базе. %d кр.") % [
		String(GameDB.UNITS[unit_id]["name"]), cost]
	button.disabled = gold < cost or GameState.game_over
	button.modulate = Color.WHITE if gold >= cost else Color(0.6, 0.65, 0.72)


func _on_phase_changed(_round_index: int, _phase: int, _duration: float) -> void:
	_refresh_card_states()


## Уровень куплен (сервер подтвердил) — перерисовываем карточки: в них
## записаны HP/урон/скорость именно этого уровня.
func _on_unit_level_changed(_unit_id: String, _level: int) -> void:
	_hold_unit = ""
	rebuild_from_deck()


## «ПРОРЫВ»: сервер проверит фазу и «один раз за раунд».
func _on_breakthrough_pressed() -> void:
	if GameState.game_over or not GameState.is_assault():
		_deny()
		return
	AudioManager.play_sfx("ability", -4.0, 0.85)
	if multiplayer.is_server():
		GameState.apply_ability(multiplayer.get_unique_id(), "breakthrough")
	else:
		GameState.request_ability.rpc_id(1, "breakthrough")


func _refresh_breakthrough() -> void:
	if _break_button == null:
		return
	var used: Array = GameState.abilities_used.get(multiplayer.get_unique_id(), [])
	var queue := _unit_spawner.queue_size() if _unit_spawner != null else 0
	var ready := not used.has("breakthrough") and GameState.is_assault() \
			and queue > 0 and not GameState.game_over
	_break_button.disabled = not ready
	_break_button.modulate = Color.WHITE if ready else Color(0.55, 0.6, 0.66)
	if ready:
		_break_button.text = "ПРОРЫВ ×%d" % queue
	else:
		_break_button.text = "ПРОРЫВ"


func _refresh_status() -> void:
	var peer_id := multiplayer.get_unique_id()
	var amount := int(GameState.gold.get(peer_id, 0))
	_last_gold = amount
	if _gold_label != null:
		_gold_label.text = "КРЕДИТЫ  ·  %d" % amount
	if _hp_label != null:
		_on_base_hp_changed(GameState.base_hp, GameState.ROUND_BASE_HP)


func _on_gold_changed(peer_id: int, amount: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		return
	var delta := 0 if _last_gold < 0 else amount - _last_gold
	_last_gold = amount
	_gold_label.text = "КРЕДИТЫ  ·  %d" % amount
	_refresh_card_states()
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
