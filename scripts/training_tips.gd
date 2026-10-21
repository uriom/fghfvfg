class_name TrainingTips
extends CanvasLayer
## Контекстные подсказки первого матча (docs/GDD_AUDIT_RU.md, SPEC-03).
##
## ПРОБЛЕМА, КОТОРУЮ РЕШАЕМ: в прототипе не было ни обучения, ни объяснения
## правил — новый игрок видел сетку, три карточки и таймер. Ни цели, ни
## условий победы, ни разницы между башнями. Здесь — «обучение без экрана
## обучения»: короткие подсказки в момент, когда они нужны, не блокируют игру.
##
## ЛОГИКА: один шаг за раз. Шаг показывается, когда выполнено ЕГО условие
## (`when`), и не повторяется. Порядок важен: сначала «построй башню», потом
## «вот почему мортира не бьёт воздух» и т.д. Игрок может закрыть панель
## («Понятно») — панель свернётся в маленькую кнопку «?».
##
## ПЕРСИСТЕНТНОСТЬ: user://tutorial.cfg хранит, что подсказки уже показаны,
## чтобы второй матч не начинался с лекции. Кнопка «?» возвращает их.
##
## СЕТЬ: живёт только в соло-режиме (создаётся game.gd при NetworkManager.is_solo()),
## поэтому ни одного RPC.

const SAVE_PATH := "user://tutorial.cfg"

## Шаги обучения. `when` — метод-условие; `text` — текст подсказки.
const STEPS := [
	{
		"id": "build",
		"when": "_need_first_tower",
		"text": "Выбери башню внизу и кликни по клетке у дороги. "
				+ "Снайпер бьёт дальше всех — начни с него.",
	},
	{
		"id": "limit",
		"when": "_need_second_tower",
		"text": "Каждой башни можно поставить не больше 2 штук. "
				+ "Снайпер — танки, мортира — толпу, тесла — воздух.",
	},
	{
		"id": "assault",
		"when": "_assault_started",
		"text": "ШТУРМ! Ты не строишь в бою — держи базу до конца раунда (60 с). "
				+ "Башни переживут раунд и останутся в следующем.",
	},
	{
		"id": "air",
		"when": "_need_air_hint",
		"text": "Летающих не достают мортира, криостан и огнемёт. "
				+ "Тесла бьёт ТОЛЬКО воздух, снайпер — универсал с ×0,75.",
	},
	{
		"id": "repair",
		"when": "_need_repair_hint",
		"text": "База трещит? Один раз за раунд доступен РЕМОНТ (+2 HP) — "
				+ "кнопка внизу, справа от карточек.",
	},
	{
		"id": "rounds",
		"when": "_two_rounds_played",
		"text": "Матч до 2 побед из 3 раундов. Бюджет Защитника падает, "
				+ "атакующего растёт — третий раунд решает всё.",
	},
]

const PANEL_BG := Color(0.012, 0.032, 0.055, 0.95)
const CYAN := Color(0.22, 0.95, 1.0)
const AMBER := Color(1.0, 0.78, 0.34)
const MUTED := Color(0.62, 0.76, 0.86)

var _seen: Dictionary = {}      # id -> true
var _active_id := ""            # что показано сейчас
var _collapsed := false

var _root: Control
var _panel: PanelContainer
var _text: Label
var _toggle: Button


func _ready() -> void:
	layer = 5
	_load_progress()
	_build_ui()
	# Подсказки проверяются 4 раза в секунду — этого хватает и это дёшево.
	var timer := Timer.new()
	timer.wait_time = 0.25
	timer.timeout.connect(_check_steps)
	add_child(timer)
	timer.start()
	_check_steps()


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.name = "TipPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# Панель по центру НАД нижним доком (док ~150 px + отступ): слева внизу
	# она перекрывала карточки башен и перехватывала клики.
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -230.0
	_panel.offset_right = 230.0
	_panel.offset_top = -262.0
	_panel.offset_bottom = -172.0
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = Color(CYAN, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.4)
	style.shadow_size = 10
	_panel.add_theme_stylebox_override("panel", style)
	_panel.visible = false
	_root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	margin.add_child(row)

	var badge := Label.new()
	badge.text = "!"
	badge.add_theme_font_size_override("font_size", 20)
	badge.add_theme_color_override("font_color", AMBER)
	badge.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	row.add_child(badge)

	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("font_size", 11)
	_text.add_theme_color_override("font_color", Color(0.92, 0.97, 1.0))
	row.add_child(_text)

	var close := Button.new()
	close.text = "OK"
	close.tooltip_text = "Понятно, скрыть подсказки"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(34.0, 24.0)
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close.add_theme_font_size_override("font_size", 9)
	close.pressed.connect(_dismiss_current)
	row.add_child(close)

	# Свёрнутое состояние: маленькая «?» слева снизу.
	_toggle = Button.new()
	_toggle.name = "TipsToggle"
	_toggle.text = "?"
	_toggle.tooltip_text = "Показать подсказки обучения"
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.custom_minimum_size = Vector2(30.0, 30.0)
	_toggle.anchor_left = 0.0
	_toggle.anchor_right = 0.0
	_toggle.anchor_top = 1.0
	_toggle.anchor_bottom = 1.0
	_toggle.offset_left = 16.0
	_toggle.offset_top = -206.0
	_toggle.offset_bottom = -176.0
	_toggle.offset_right = 46.0
	_toggle.add_theme_font_size_override("font_size", 15)
	_toggle.pressed.connect(_on_toggle_pressed)
	_toggle.visible = false
	_root.add_child(_toggle)


# --------------------------------------------------------------- Шаги -------

func _check_steps() -> void:
	if GameState.game_over or _collapsed:
		return
	if _active_id != "":
		return
	for step in STEPS:
		var id := String(step["id"])
		if _seen.has(id):
			continue
		if call(String(step["when"])):
			_show(String(step["id"]), String(step["text"]))
			return


func _show(id: String, text: String) -> void:
	_active_id = id
	_text.text = text
	_panel.visible = true
	_toggle.visible = false
	_panel.modulate = Color(1, 1, 1, 0)
	var tween := create_tween()
	tween.tween_property(_panel, "modulate:a", 1.0, 0.18)


func _dismiss_current() -> void:
	if _active_id != "":
		_seen[_active_id] = true
		_save_progress()
	_active_id = ""
	_panel.visible = false
	_toggle.visible = true
	_check_steps()


func _on_toggle_pressed() -> void:
	# «?» снова показывает весь курс с начала — для тех, кто пропустил.
	_seen.clear()
	_collapsed = false
	_toggle.visible = false
	_check_steps()


# ----------------------------------------------------------- Условия --------

func _tower_total() -> int:
	var map := get_tree().current_scene.get_node_or_null("Map")
	return map.total_towers() if map != null else 0


func _need_first_tower() -> bool:
	return GameState.is_planning() and _tower_total() == 0


func _need_second_tower() -> bool:
	return GameState.is_planning() and _tower_total() == 1


func _assault_started() -> bool:
	return GameState.phase_time_left > 0.0 and GameState.is_assault() \
			and GameState.stats.get("rounds_played", 0) == 0 \
			and GameState.phase_time_left > GameState.ASSAULT_TIME - 4.0


func _need_air_hint() -> bool:
	if not GameState.is_assault():
		return false
	for node in get_tree().get_nodes_in_group("units"):
		if node is Unit and bool((node as Unit).stats.get("flying", false)):
			return true
	return false


func _need_repair_hint() -> bool:
	return GameState.base_hp < GameState.ROUND_BASE_HP and GameState.base_hp > 0 \
			and GameState.is_assault()


func _two_rounds_played() -> bool:
	return int(GameState.stats.get("rounds_played", 0)) >= 1


# -------------------------------------------------------- Сохранение --------

func _load_progress() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	for step in STEPS:
		var id := String(step["id"])
		if bool(config.get_value("tips", id, false)):
			_seen[id] = true


func _save_progress() -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH)   # сохраняем прочие ключи, если появятся
	for id in _seen:
		config.set_value("tips", id, true)
	config.save(SAVE_PATH)
