extends Control
## HUD Защитника — верхняя статус-панель + нижняя горизонтальная полоса
## снаряжения. Полностью собран из стандартных Control-нод:
## PanelContainer / StyleBoxFlat / Label / ProgressBar / TextureButton /
## TextureRect / ColorRect. Ни одного _draw.
##
## ЧТО ЗДЕСЬ ЕСТЬ:
##   * Верхняя панель: индикатор фазы раунда, КРЕДИТЫ, полоса HP базы.
##   * Карточки башен: горизонтальная дека-полоса в нижней зоне, иконка 2.5D,
##     статусы «ГОТОВО» / «ВЫБРАНО» / «МАЛО КРЕДИТОВ», затемнение при нехватке.
##   * Hover/selection поднимают тактический радиус на земле через GameMap.
##   * Панч-анимации золота/HP и всплывающая дельта («+100», «−50»).
##
## ИНТЕГРАЦИЯ: game.gd вызывает rebuild_from_deck() ПОСЛЕ setup_match(),
## поэтому состав карточек всегда совпадает с деком Защитника этого матча.

const PHASE_DISPLAY_SCRIPT := preload("res://scripts/phase_display.gd")

# --- Геометрия (базовый viewport 1152x648, HUD в экранных пикселях) ---------
const TOP_BAR_HEIGHT := 64.0
const SIDE_MARGIN := 16.0
const LOADOUT_WIDTH := 580.0
const CARD_SIZE := Vector2(172.0, 108.0)
const CARD_GAP := 9.0

# --- Палитра ----------------------------------------------------------------
const CYAN := Color(0.22, 0.95, 1.0)
const GREEN := Color(0.30, 1.0, 0.62)
const AMBER := Color(1.0, 0.78, 0.34)
const RED := Color(1.0, 0.30, 0.42)
const TEXT := Color(0.92, 0.97, 1.0)
const MUTED := Color(0.55, 0.72, 0.82, 0.75)
const PANEL_BG := Color(0.012, 0.030, 0.055, 0.90)
const CARD_BG := Color(0.025, 0.065, 0.100, 0.94)
const CARD_BG_LOCKED := Color(0.022, 0.040, 0.060, 0.90)

# Английские позывные для карточек (в GameDB имена локализованы по-русски).
const CALLSIGNS := {
	"sniper": "SNIPER",
	"splash": "MORTAR",
	"frost": "CRYO",
	"flamer": "FLAMER",
	"tesla": "TESLA",
}

# --- Ссылки на мир/HUD ------------------------------------------------------
var _map: GameMap
var _built := false
var _locked := false

var _top_bar: PanelContainer
var _phase_display: PhaseDisplay
var _gold_panel: PanelContainer
var _gold_label: Label
var _base_bar: ProgressBar
var _base_label: Label
var _base_fill: StyleBoxFlat

var _loadout_panel: PanelContainer
var _cards_box: HBoxContainer
var _slots_label: Label

# tower_id -> Dictionary с дочерними нодами и параметрами карточки.
var _card_data: Dictionary = {}
# ability_id -> Button (РЕМОНТ / ОВЕРКЛОК).
var _ability_buttons: Dictionary = {}
var _card_group: ButtonGroup
var _deck_snapshot: Array[String] = []
var _selected_tower_id := ""
var _hovered_tower_id := ""

# --- Состояние для панчей ---------------------------------------------------
var _last_gold := -1
var _last_base_hp := -1
var _gold_tween: Tween
var _base_tween: Tween
var _base_label_tween: Tween

# Кэшированные процедурные текстуры для «голограммы» карточек.


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map = get_node_or_null("%Map") as GameMap
	if _map == null and get_tree().current_scene != null:
		_map = get_tree().current_scene.get_node_or_null("Map") as GameMap

	_build_ui()

	GameState.gold_changed.connect(_on_gold_changed)
	GameState.base_hp_changed.connect(_on_base_hp_changed)
	GameState.game_ended.connect(_on_game_ended)
	visibility_changed.connect(_on_visibility_changed)
	resized.connect(_fit_loadout_panel)

	GameState.round_ended.connect(_on_round_ended)
	GameState.ability_used.connect(_on_ability_used)
	GameState.phase_changed.connect(_on_phase_changed)

	_refresh_from_state()
	# Нужно для самостоятельного запуска HUD-сцены; в матче game.gd вызовет
	# rebuild_from_deck() повторно, но снимок деки защитит от пересборки.
	rebuild_from_deck()


# ============================================================ ПОСТРОЕНИЕ =====

func _build_ui() -> void:
	if _built:
		return
	_built = true
	_build_top_bar()
	_build_loadout()


# ------------------------------------------------------------ Верхняя панель --

func _build_top_bar() -> void:
	_top_bar = PanelContainer.new()
	_top_bar.name = "StatusBar"
	_top_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_top_bar)
	_top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_bottom = TOP_BAR_HEIGHT

	var panel_style := HudKit.panel_style(PANEL_BG, Color(CYAN, 0.32), 0, 0,
			Color(CYAN, 0.10), 10)
	panel_style.border_width_bottom = 1
	_top_bar.add_theme_stylebox_override("panel", panel_style)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	_top_bar.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	# Бренд / роль.
	var brand := VBoxContainer.new()
	brand.custom_minimum_size.x = 190.0
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	brand.add_theme_constant_override("separation", -2)
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(brand)

	var title := _label("TOWER DUEL", 19, CYAN, 3)
	brand.add_child(title)
	var subtitle := _label("DEFENDER // DEFENSE PROTOCOL", 9, MUTED, 1)
	brand.add_child(subtitle)

	row.add_child(HudKit.vertical_line(30.0, Color(1, 1, 1, 0.12)))

	# LIVE-индикатор волны.
	_phase_display = PHASE_DISPLAY_SCRIPT.new() as PhaseDisplay
	_phase_display.custom_minimum_size = Vector2(250.0, 42.0)
	_phase_display.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_phase_display)

	# Пружина отжимает ресурсы вправо.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	_build_gold_capsule(row)
	_build_base_bar(row)


func _build_gold_capsule(parent: HBoxContainer) -> void:
	_gold_panel = PanelContainer.new()
	_gold_panel.custom_minimum_size = Vector2(154.0, 32.0)
	_gold_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gold_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_gold_panel.add_theme_stylebox_override("panel", HudKit.panel_style(
			Color(0.06, 0.045, 0.015, 0.72), Color(AMBER, 0.34), 1, 7))
	parent.add_child(_gold_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 11)
	margin.add_theme_constant_override("margin_right", 11)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	_gold_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	row.add_child(HudKit.diamond(AMBER, 9.0))
	_gold_label = _label("КРЕДИТЫ · 0", 15, TEXT, 2)
	row.add_child(_gold_label)


func _build_base_bar(parent: HBoxContainer) -> void:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(282.0, 32.0)
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	wrap.add_theme_stylebox_override("panel", HudKit.panel_style(
			Color(0.015, 0.045, 0.030, 0.74), Color(GREEN, 0.28), 1, 7))
	parent.add_child(wrap)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 2)
	margin.add_theme_constant_override("margin_right", 2)
	margin.add_theme_constant_override("margin_top", 2)
	margin.add_theme_constant_override("margin_bottom", 2)
	wrap.add_child(margin)

	_base_bar = ProgressBar.new()
	_base_bar.custom_minimum_size = Vector2(278.0, 26.0)
	_base_bar.show_percentage = false
	_base_bar.min_value = 0.0
	_base_bar.max_value = GameState.ROUND_BASE_HP
	_base_bar.value = GameState.ROUND_BASE_HP
	_base_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_bar.add_theme_stylebox_override("background", HudKit.panel_style(
			Color(0.01, 0.05, 0.03, 0.92), Color(GREEN, 0.16), 1, 5))
	_base_fill = HudKit.panel_style(GREEN, Color.TRANSPARENT, 0, 5)
	_base_fill.shadow_color = Color(GREEN, 0.50)
	_base_fill.shadow_size = 6
	_base_bar.add_theme_stylebox_override("fill", _base_fill)
	margin.add_child(_base_bar)

	_base_label = _label("БАЗА: %d / %d" % [GameState.ROUND_BASE_HP, GameState.ROUND_BASE_HP],
			13, Color(0.88, 1.0, 0.92), 2)
	_base_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_base_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_base_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_base_bar.add_child(_base_label)


# ---------------------------------------------------- Нижняя панель деки -----

func _build_loadout() -> void:
	_loadout_panel = PanelContainer.new()
	_loadout_panel.name = "EquipmentPanel"
	_loadout_panel.custom_minimum_size = Vector2(LOADOUT_WIDTH, 0.0)
	_loadout_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_loadout_panel.add_theme_stylebox_override("panel", HudKit.panel_style(
			PANEL_BG, Color(CYAN, 0.22), 1, 10, Color(0, 0, 0, 0.55), 14))
	add_child(_loadout_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_loadout_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(header)

	var header_title := _label("TOWER LOADOUT", 13, TEXT, 2)
	header.add_child(header_title)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(header_spacer)
	_slots_label = _label("03 SLOTS", 9, CYAN, 1)
	header.add_child(_slots_label)

	var rule := ColorRect.new()
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.color = Color(CYAN, 0.20)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	_cards_box = HBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", int(CARD_GAP))
	_cards_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_cards_box)

	# ПОДСКАЗКА ПО АПГРЕЙДУ (ЭТАП 7): лимитов на количество башен больше нет,
	# зато клик по своей башне покупает ей следующий уровень.
	var upgrade_hint := _label(
		"КЛИК ПО БАШНЕ — УЛУЧШИТЬ (до %d ур.)" % GameDB.TOWER_MAX_LEVEL,
		9, AMBER, 1)
	upgrade_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(upgrade_hint)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(footer)

	var hints := _label("LMB — ПОСТРОЙКА / АПГРЕЙД  ·  КОЛЬЦО РАДИУСА — HOVER", 8, MUTED, 1)
	hints.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(hints)

	_build_ability_buttons(footer)


## Две способности Защитника (SPEC-01). Каждая — один раз за раунд.
## Логика применения живёт на сервере в GameState, здесь только ввод/статус.
func _build_ability_buttons(parent: HBoxContainer) -> void:
	for spec in [
		{"id": "repair", "text": "РЕМОНТ +2", "color": GREEN, "hint": "Починить базу на 2 HP"},
		{"id": "overclock", "text": "ОВЕРКЛОК +40%", "color": CYAN, "hint": "Ускорить все башни на 4 с"},
	]:
		var button := Button.new()
		button.text = String(spec["text"])
		button.tooltip_text = String(spec["hint"])
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(112.0, 24.0)
		button.add_theme_font_size_override("font_size", 9)
		button.add_theme_color_override("font_color", spec["color"])
		button.pressed.connect(_on_ability_pressed.bind(String(spec["id"])))
		parent.add_child(button)
		_ability_buttons[String(spec["id"])] = button


# ============================================================== КАРТОЧКИ =====

## Вызывается из game.gd после GameState.setup_match(). Дека может измениться
## между лобби и матчем, поэтому снимок сравниваем и пересобираем только при
## реальном изменении состава.
func rebuild_from_deck() -> void:
	if not _built:
		_build_ui()
	var deck: Array[String] = GameState.defender_towers.duplicate()
	if _same_deck(deck):
		_refresh_card_states()
		return

	_deck_snapshot = deck
	_selected_tower_id = ""
	_hovered_tower_id = ""

	for child in _cards_box.get_children():
		_cards_box.remove_child(child)
		child.queue_free()
	_card_data.clear()
	_card_group = ButtonGroup.new()

	var order := 0
	for tower_id in deck:
		if not GameDB.TOWERS.has(tower_id):
			continue
		_card_data[tower_id] = _create_card(tower_id, order)
		order += 1

	_update_slots_label()

	if _card_data.is_empty():
		var empty := _label("NO TOWERS EQUIPPED", 11, RED, 2)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_cards_box.add_child(empty)
		if _map != null:
			_map.hide_range_preview()
	else:
		# Радио-кнопка: подсвечиваем и активируем первую башню деки.
		var first_id := String(deck[0])
		if not _card_data.has(first_id):
			first_id = String(_card_data.keys()[0])
		var first_button: TextureButton = _card_data[first_id]["button"]
		first_button.button_pressed = true
		_select_tower(first_id, false)

	_fit_loadout_panel()
	call_deferred("_fit_loadout_panel")


func _same_deck(deck: Array[String]) -> bool:
	if deck.size() != _deck_snapshot.size():
		return false
	for i in deck.size():
		if deck[i] != _deck_snapshot[i]:
			return false
	return not _card_data.is_empty()


## Собирает одну карточку. Корень — TextureButton (по требованию дизайна),
## дети — обычные Control с mouse_filter = IGNORE, чтобы клики/hover всегда
## доходили до кнопки.
func _create_card(tower_id: String, order: int) -> Dictionary:
	var stats: Dictionary = GameDB.TOWERS[tower_id]
	var accent: Color = stats.get("color", CYAN)
	var cost := int(stats["cost"])

	var card := TextureButton.new()
	card.name = "Card_%s" % tower_id
	card.custom_minimum_size = CARD_SIZE
	card.toggle_mode = true
	card.button_group = _card_group
	card.focus_mode = Control.FOCUS_ALL   # навигация с клавиатуры/геймпада
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.tooltip_text = "%s — %d кр.\nРадиус: %d · Урон: %d · Скорость: %.1f/с" % [
		CALLSIGNS.get(tower_id, String(stats["name"]).to_upper()),
		cost, int(stats["range"]), int(stats.get("damage", 0)),
		float(stats.get("fire_rate", 0.0)),
	]
	_cards_box.add_child(card)

	# Фон с индивидуальным StyleBoxFlat — его цвет границы меняется по статусу.
	var bg_style := HudKit.panel_style(CARD_BG, Color(accent, 0.20), 1, 9)
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", bg_style)
	card.add_child(bg)

	# Цветная полоска-акцент слева: тип башни считывается мгновенно.
	var strip := ColorRect.new()
	strip.color = Color(accent, 0.85)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	strip.offset_right = 3.0
	strip.offset_top = 12.0
	strip.offset_bottom = -12.0
	card.add_child(strip)

	# Подиум и вертикальный «лук» голограммы под иконкой (2.5D-ощущение).
	var pedestal := TextureRect.new()
	pedestal.texture = HudKit.pedestal_texture()
	pedestal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pedestal.stretch_mode = TextureRect.STRETCH_SCALE
	pedestal.position = Vector2((CARD_SIZE.x - 76.0) * 0.5, 48.0)
	pedestal.size = Vector2(76.0, 20.0)
	pedestal.modulate = Color(accent, 0.42)
	pedestal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(pedestal)

	var beam := TextureRect.new()
	beam.texture = HudKit.beam_texture()
	beam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	beam.stretch_mode = TextureRect.STRETCH_SCALE
	beam.position = Vector2((CARD_SIZE.x - 52.0) * 0.5, 0.0)
	beam.size = Vector2(52.0, 56.0)
	beam.modulate = Color(accent, 0.13)
	beam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(beam)

	# Иконка башни: арт уже нарисован в 2.5D, вписываем его без искажений.
	var icon := TextureRect.new()
	icon.texture = _tower_texture(tower_id)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.position = Vector2((CARD_SIZE.x - 54.0) * 0.5, 0.0)
	icon.size = Vector2(54.0, 54.0)
	icon.pivot_offset = icon.size * 0.5
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(icon)

	# Служебная нумерация слота и статус.
	var slot := _label("%02d // TWR" % (order + 1), 8, Color(MUTED, 0.95), 1)
	slot.set_anchors_preset(Control.PRESET_TOP_LEFT)
	slot.offset_left = 8.0
	slot.offset_top = 4.0
	slot.offset_right = 74.0
	slot.offset_bottom = 16.0
	card.add_child(slot)

	var status := _label("READY", 8, GREEN, 1)
	status.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	status.offset_left = -78.0
	status.offset_right = -8.0
	status.offset_top = 4.0
	status.offset_bottom = 16.0
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	card.add_child(status)

	var divider := ColorRect.new()
	divider.color = Color(accent, 0.16)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.set_anchors_preset(Control.PRESET_TOP_WIDE)
	divider.offset_left = 10.0
	divider.offset_right = -10.0
	divider.offset_top = 58.0
	divider.offset_bottom = 59.0
	card.add_child(divider)

	var name_label := _label(
			String(CALLSIGNS.get(tower_id, String(stats["name"]).to_upper())), 12, TEXT, 2)
	name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_label.offset_top = 62.0
	name_label.offset_bottom = 80.0
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(name_label)

	var cost_label := _label("(%d кр.)" % cost, 10, AMBER, 1)
	cost_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	cost_label.offset_top = 81.0
	cost_label.offset_bottom = 98.0
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(cost_label)

	# Тонкая белая рамка на hover и неоновая — на selected.
	var hover_frame := Panel.new()
	hover_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hover_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_frame.visible = false
	hover_frame.add_theme_stylebox_override("panel", HudKit.panel_style(
			Color.TRANSPARENT, Color(1, 1, 1, 0.55), 1, 9))
	card.add_child(hover_frame)

	var glow_frame := Panel.new()
	glow_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow_frame.visible = false
	glow_frame.add_theme_stylebox_override("panel", HudKit.panel_style(
			Color.TRANSPARENT, CYAN, 2, 9, Color(CYAN, 0.42), 9))
	card.add_child(glow_frame)

	card.pressed.connect(_on_card_pressed.bind(tower_id))
	card.mouse_entered.connect(_on_card_hovered.bind(tower_id))
	card.mouse_exited.connect(_on_card_unhovered.bind(tower_id))

	return {
		"button": card,
		"bg": bg,
		"bg_style": bg_style,
		"icon": icon,
		"status": status,
		"cost": cost_label,
		"cost_value": cost,
		"accent": accent,
		"glow": glow_frame,
		"hover": hover_frame,
		"glow_tween": null,
	}


## Максимальный уровень среди построенных башен этого типа (0 — нет башен).
func _best_level(tower_id: String) -> int:
	if _map == null:
		return 0
	var best := 0
	for node in _map.get_node("Towers").get_children():
		if node is Tower and (node as Tower).tower_id == tower_id:
			best = maxi(best, (node as Tower).level)
	return best


## Перекраска всех карточек под текущее золото и выбранный слот.
func _refresh_card_states() -> void:
	var gold := _current_gold()
	for tower_id in _card_data:
		var data: Dictionary = _card_data[tower_id]
		var selected: bool = tower_id == _selected_tower_id
		var hovered: bool = tower_id == _hovered_tower_id
		var affordable: bool = gold >= int(data["cost_value"])
		var accent: Color = data["accent"]

		var glow_frame: Panel = data["glow"]
		var hover_frame: Panel = data["hover"]
		glow_frame.visible = selected
		hover_frame.visible = hovered and not selected

		var status: Label = data["status"]
		var placed := _map.tower_count(tower_id) if _map != null else 0
		var best := _best_level(tower_id) if _map != null else 0
		# ЭТАП 8: строить можно и в штурме, поэтому «фаза» больше не гасит
		# карточки — статус всегда про выбор, деньги и уровень парка.
		var suffix := "" if best <= 0 else " · УР %d" % best
		if selected:
			status.text = "ВЫБРАНО · ×%d%s" % [placed, suffix]
			status.add_theme_color_override("font_color", CYAN)
		elif affordable:
			status.text = "ГОТОВО · ×%d%s" % [placed, suffix]
			status.add_theme_color_override("font_color", GREEN)
		else:
			status.text = "МАЛО КРЕДИТОВ"
			status.add_theme_color_override("font_color", RED)

		var cost_label: Label = data["cost"]
		cost_label.add_theme_color_override("font_color", AMBER if affordable else RED)

		var icon: TextureRect = data["icon"]
		icon.modulate = Color.WHITE if affordable else Color(0.55, 0.62, 0.70, 0.65)

		var bg_style: StyleBoxFlat = data["bg_style"]
		bg_style.bg_color = CARD_BG if affordable else CARD_BG_LOCKED
		bg_style.border_color = Color(accent, 0.55 if selected else (0.20 if affordable else 0.08))

		_set_glow_pulse(data, selected)
	_update_slots_label()


# ============================================================ ВЗАИМОДЕЙСТВИЕ =

func _on_card_pressed(tower_id: String) -> void:
	if _locked:
		return
	_select_tower(tower_id, true)


func _select_tower(tower_id: String, play_sound: bool) -> void:
	if _locked or not _card_data.has(tower_id):
		return
	_selected_tower_id = tower_id

	var button: TextureButton = _card_data[tower_id]["button"]
	if not button.button_pressed:
		button.button_pressed = true

	if _map != null:
		_map.set_build_tower_id(tower_id)
	if play_sound:
		AudioManager.play_sfx("click", -10.0)

	_refresh_card_states()
	_refresh_range_preview()


func _on_card_hovered(tower_id: String) -> void:
	if _locked:
		return
	_hovered_tower_id = tower_id
	_refresh_card_states()
	_refresh_range_preview()
	_animate_card_scale(tower_id, Vector2(1.018, 1.018))


func _on_card_unhovered(tower_id: String) -> void:
	if _hovered_tower_id == tower_id:
		_hovered_tower_id = ""
	_refresh_card_states()
	_refresh_range_preview()
	_animate_card_scale(tower_id, Vector2.ONE)


## Приоритет радиуса: карточка под курсором -> выбранная карточка.
## Если обе пусты/карта не активна, GameMap просто скрывает кольцо.
func _refresh_range_preview() -> void:
	if _map == null:
		return
	if not visible or _locked:
		_map.hide_range_preview()
		return

	var preview_id := _hovered_tower_id
	if preview_id == "" or not _card_data.has(preview_id):
		preview_id = _selected_tower_id

	if preview_id == "":
		_map.hide_range_preview()
	else:
		_map.show_range_preview(preview_id)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or _locked or not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	var index := key_event.keycode - KEY_1
	if index < 0 or index >= _card_data.size():
		return
	var ids := _card_data.keys()
	_select_tower(String(ids[index]), true)
	get_viewport().set_input_as_handled()


func _on_visibility_changed() -> void:
	_refresh_range_preview()


func _on_game_ended(_defender_won: bool) -> void:
	_locked = true
	for tower_id in _card_data:
		var data: Dictionary = _card_data[tower_id]
		(data["button"] as TextureButton).disabled = true
		_set_glow_pulse(data, false)
	if _map != null:
		_map.hide_range_preview()


# ================================================================ GOLD/HP ====

func _on_gold_changed(peer_id: int, amount: int) -> void:
	if peer_id != _local_peer():
		return
	var delta := 0 if _last_gold < 0 else amount - _last_gold
	_last_gold = amount
	_gold_label.text = "КРЕДИТЫ · %d" % amount
	_refresh_card_states()
	if delta != 0:
		_spawn_gold_delta(delta)
		_punch_gold()


func _on_base_hp_changed(hp: int, max_hp: int) -> void:
	var animate := _last_base_hp >= 0 and hp != _last_base_hp
	_last_base_hp = hp
	_refresh_base(hp, max_hp, animate)


func _refresh_from_state() -> void:
	var local := _local_peer()
	var gold := int(GameState.gold.get(local, 0))
	_gold_label.text = "КРЕДИТЫ · %d" % gold
	# Если золото уже установлено (позднее создание HUD), не показываем
	# ложную дельту при первом сигнале. Если ещё нет — ждём setup_match.
	_last_gold = gold if GameState.gold.has(local) else -1

	_last_base_hp = GameState.base_hp
	_refresh_base(GameState.base_hp, GameState.ROUND_BASE_HP, false)
	_refresh_card_states()


func _refresh_base(hp: int, max_hp: int, animate: bool) -> void:
	if _base_bar == null:
		return
	var safe_max := maxi(max_hp, 1)
	var ratio := clampf(float(hp) / float(safe_max), 0.0, 1.0)
	var tint := _hp_color(ratio)

	_base_bar.max_value = safe_max
	_base_fill.bg_color = tint
	_base_fill.shadow_color = Color(tint, 0.50)
	_base_label.text = "БАЗА: %d / %d" % [hp, max_hp]
	_base_label.add_theme_color_override("font_color",
			Color(0.88, 1.0, 0.92) if ratio > 0.5 else Color.WHITE)

	if _base_tween != null and _base_tween.is_valid():
		_base_tween.kill()
	if animate:
		_base_tween = create_tween()
		_base_tween.tween_property(_base_bar, "value", float(hp), 0.28) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_punch_base_label()
	else:
		_base_bar.value = hp


func _hp_color(ratio: float) -> Color:
	if ratio >= 0.5:
		return AMBER.lerp(GREEN, (ratio - 0.5) / 0.5)
	return RED.lerp(AMBER, ratio / 0.5)


func _punch_base_label() -> void:
	if _base_label_tween != null and _base_label_tween.is_valid():
		_base_label_tween.kill()
	_base_label.pivot_offset = _base_label.size * 0.5
	_base_label.scale = Vector2(1.16, 1.16)
	_base_label_tween = create_tween()
	_base_label_tween.tween_property(_base_label, "scale", Vector2.ONE, 0.30) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _punch_gold() -> void:
	if _gold_tween != null and _gold_tween.is_valid():
		_gold_tween.kill()
	_gold_panel.pivot_offset = _gold_panel.size * 0.5
	_gold_panel.scale = Vector2(1.055, 1.055)
	_gold_tween = create_tween()
	_gold_tween.tween_property(_gold_panel, "scale", Vector2.ONE, 0.26) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Всплывающая дельта над капсулой золота. Живёт на корне HUD, поэтому
## не участвует в layout верхней панели.
func _spawn_gold_delta(delta: int) -> void:
	var positive := delta > 0
	var popup := _label(("+%d" if positive else "%d") % delta, 15,
			GREEN if positive else RED, 4)
	popup.z_index = 20
	add_child(popup)

	var start := _gold_panel.global_position - global_position
	start.x += _gold_panel.size.x * 0.5 - 16.0
	start.y += _gold_panel.size.y + 2.0
	popup.position = start

	var tween := popup.create_tween()
	tween.set_parallel(true)
	tween.tween_property(popup, "position:y", start.y + 24.0, 0.68) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(popup, "modulate:a", 0.0, 0.68) \
			.set_delay(0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(popup.queue_free)


# ============================================================== АНИМАЦИИ =====

func _set_glow_pulse(data: Dictionary, enabled: bool) -> void:
	var glow: Panel = data["glow"]
	var tween: Tween = data["glow_tween"]
	if enabled:
		if tween != null and tween.is_valid():
			return
		glow.modulate.a = 1.0
		tween = glow.create_tween().set_loops()
		tween.tween_property(glow, "modulate:a", 0.62, 0.9) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(glow, "modulate:a", 1.0, 0.9) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		data["glow_tween"] = tween
	else:
		if tween != null and tween.is_valid():
			tween.kill()
		glow.modulate.a = 1.0
		data["glow_tween"] = null


func _animate_card_scale(tower_id: String, target: Vector2) -> void:
	if not _card_data.has(tower_id):
		return
	var card: TextureButton = _card_data[tower_id]["button"]
	card.pivot_offset = card.size * 0.5
	var tween := card.create_tween()
	tween.tween_property(card, "scale", target, 0.16) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# ================================================================ ХЕЛПЕРЫ ====

func _label(value: String, font_size: int, color: Color, outline := 2) -> Label:
	var label := Label.new()
	label.text = value
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.88))
	label.add_theme_constant_override("outline_size", outline)
	return label


func _fit_loadout_panel() -> void:
	if _loadout_panel == null or not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	var panel_width := minf(LOADOUT_WIDTH, viewport_size.x - SIDE_MARGIN * 2.0)
	var required := _loadout_panel.get_combined_minimum_size()
	var panel_height := required.y
	_loadout_panel.size = Vector2(panel_width, panel_height)
	_loadout_panel.position = Vector2(
			(viewport_size.x - panel_width) * 0.5,
			maxf(TOP_BAR_HEIGHT + 8.0, viewport_size.y - panel_height - 12.0))


## «ПОСТРОЕНО 05» — счётчик башен (лимита больше нет, но видеть парк полезно).
func _update_slots_label() -> void:
	if _slots_label == null:
		return
	var used := _map.total_towers() if _map != null else 0
	_slots_label.text = "ПОСТРОЕНО %02d" % used
	_slots_label.add_theme_color_override("font_color", CYAN)


func _on_ability_pressed(ability: String) -> void:
	if GameState.game_over:
		return
	if multiplayer.is_server():
		GameState.apply_ability(multiplayer.get_unique_id(), ability)
	else:
		GameState.request_ability.rpc_id(1, ability)


## Один раз за раунд: гасим кнопку, чтобы клик не уходил в сервер впустую.
func _refresh_ability_buttons() -> void:
	for ability in _ability_buttons:
		var button: Button = _ability_buttons[ability]
		if not is_instance_valid(button):
			continue
		var used: Array = GameState.abilities_used.get(_local_peer(), [])
		var available := not used.has(ability) and not GameState.game_over
		if ability == "repair":
			available = available and GameState.base_hp < GameState.ROUND_BASE_HP \
					and GameState.base_hp > 0
		else:
			available = available and GameState.is_assault()
		button.disabled = not available
		button.modulate = Color.WHITE if available else Color(0.55, 0.6, 0.66)


func _on_ability_used(_ability: String) -> void:
	_refresh_ability_buttons()


func _on_round_ended(_round_index: int, _attacker_won: bool,
		_defender_wins: int, _attacker_wins: int) -> void:
	_refresh_ability_buttons()
	_refresh_card_states()


func _on_phase_changed(_round_index: int, _phase: int, _duration: float) -> void:
	_refresh_ability_buttons()
	_refresh_card_states()
	_update_slots_label()


func _process(_delta: float) -> void:
	# Кнопки способностей зависят от HP/фазы — обновляем недорого каждый кадр.
	_refresh_ability_buttons()


func _local_peer() -> int:
	var peer_api := multiplayer
	if not is_inside_tree() or peer_api == null:
		return 1
	var peer := peer_api.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return 1
	return peer_api.get_unique_id()


func _current_gold() -> int:
	return int(GameState.gold.get(_local_peer(), 0))


func _tower_texture(tower_id: String) -> Texture2D:
	var path := "res://assets/img/%s.png" % tower_id
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null
