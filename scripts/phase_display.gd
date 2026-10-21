class_name PhaseDisplay
extends Control
## Компактный индикатор фазы раунда для верхней панели HUD.
##
## Показывает:
##   * ПОДГОТОВКА — «РАУНД 2/3 · 1:1» + таймер до штурма (янтарный, 10 с);
##   * ШТУРМ      — таймер ОКНА СПАВНА (cyan, последние 10 с — красный);
##   * ДОБИВАНИЕ  — окно спавна закрыто, ждём, пока дойдёт последний юнит.
## Паузы «ИТОГ» больше нет: раунд заканчивается сразу, как опустело поле.
##
## СЕТЕВАЯ МОДЕЛЬ: сервер присылает границы фаз (GameState.phase_changed),
## между ними каждый пир считает время локально. Расхождение возможно только
## на доли секунды и не влияет на геймплей: правила считает сервер.
##
## ПРАВИЛО ПРОЕКТА: никакого _draw. Вся графика — стандартные Label,
## ProgressBar, ColorRect и StyleBoxFlat.

const CYAN := Color(0.22, 0.95, 1.0)
const AMBER := Color(1.0, 0.78, 0.34)
const RED := Color(1.0, 0.30, 0.42)
const GREEN := Color(0.35, 0.95, 0.55)
const TEXT := Color(0.92, 0.97, 1.0)
const MUTED := Color(0.55, 0.72, 0.82, 0.75)
const WARNING_SECONDS := 10.0

## Фон-подложка нужна, только если индикатор используется отдельно.
@export var show_background := false
@export var background_color := Color(0.01, 0.03, 0.055, 0.78)

var _round := 1
var _phase := GameState.Phase.PLANNING
var _time_left := 10.0
var _phase_total := 10.0
var _shown_second := -1
var _finished := false

var _phase_label: Label
var _time_label: Label
var _bar: ProgressBar
var _bar_fill: StyleBoxFlat
var _accent: ColorRect
var _pulse_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if custom_minimum_size.x <= 0.0:
		custom_minimum_size = Vector2(250.0, 42.0)

	_build_visual()

	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_ended.connect(_on_round_ended)
	GameState.game_ended.connect(_on_game_ended)
	resized.connect(_update_pivot)
	visibility_changed.connect(_update_pivot)

	# Стартовое состояние читаем из GameState: индикатор корректен, даже если
	# сигнал фазы успел пройти до его появления в дереве.
	_round = GameState.round_index
	_phase = GameState.round_phase
	_time_left = GameState.phase_time_left
	_phase_total = _duration_of(_phase)
	_update_display(true)
	call_deferred("_update_pivot")


func _process(delta: float) -> void:
	if _finished or GameState.game_over:
		return
	if _time_left <= 0.0:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	_update_bar()

	# Текст пересобираем только при смене целой секунды.
	var seconds := ceili(_time_left)
	if seconds != _shown_second:
		_update_display()


# --------------------------------------------------------------- Построение --

func _build_visual() -> void:
	if show_background:
		var panel := Panel.new()
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_theme_stylebox_override("panel", _style(
				background_color, Color(CYAN, 0.25), 1, 7))
		add_child(panel)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pad_x := 10 if show_background else 0
	pad.add_theme_constant_override("margin_left", pad_x)
	pad.add_theme_constant_override("margin_right", pad_x)
	add_child(pad)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(column)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	# Вертикальный неоновый штрих слева — визуальный «статус-бар» фазы.
	_accent = ColorRect.new()
	_accent.custom_minimum_size = Vector2(3.0, 18.0)
	_accent.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_accent.color = CYAN
	_accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_accent)

	_phase_label = _label("РАУНД 1/3 · 0:0", 12, MUTED)
	_phase_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_phase_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	_time_label = _label("12s", 16, TEXT)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_time_label)

	# Полоса остатка фазы: 4 px, без процентов и без мыши.
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0.0, 4.0)
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bar.show_percentage = false
	_bar.max_value = 100.0
	_bar.value = 100.0
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_theme_stylebox_override("background",
			_style(Color(1, 1, 1, 0.08), Color.TRANSPARENT, 0, 2))
	_bar_fill = _style(CYAN, Color.TRANSPARENT, 0, 2)
	_bar.add_theme_stylebox_override("fill", _bar_fill)
	column.add_child(_bar)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 2)
	return label


func _style(bg: Color, border: Color, width: int, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(width)
	box.set_corner_radius_all(radius)
	box.anti_aliasing = true
	return box


# ----------------------------------------------------------- Логика фаз ------

func _duration_of(phase: int) -> float:
	if phase == GameState.Phase.ASSAULT:
		return GameState.SPAWN_WINDOW
	return GameState.PLANNING_TIME


## Подпись фазы. У штурма два состояния: открытое окно спавна и добивание.
func _phase_name(phase: int) -> String:
	if phase == GameState.Phase.ASSAULT:
		return "СПАВН" if _spawn_open() else "ДОБИВАНИЕ"
	return "ПОДГОТОВКА"


func _spawn_open() -> bool:
	return GameState.spawn_window_open() and _time_left > 0.0


func _on_phase_changed(round_index: int, phase: int, duration: float) -> void:
	_round = round_index
	_phase = phase
	_time_left = duration
	_phase_total = maxf(duration, 1.0)
	_update_display(true)
	_punch()


func _on_round_ended(_round_index: int, _attacker_won: bool,
		_defender_wins: int, _attacker_wins: int) -> void:
	# Счёт раундов показан в заголовке — обновляем сразу, не дожидаясь секунды.
	_update_display(true)


func _on_game_ended(_defender_won: bool) -> void:
	_finished = true
	_update_bar()


func _update_display(force := false) -> void:
	var seconds := maxi(ceili(_time_left), 0)
	if not force and seconds == _shown_second:
		return
	_shown_second = seconds

	var tint := CYAN
	if _phase == GameState.Phase.ASSAULT:
		if not _spawn_open():
			tint = GREEN
		else:
			tint = RED if _time_left <= WARNING_SECONDS else CYAN
	else:
		tint = AMBER
	_phase_label.text = "РАУНД %d/%d · %d:%d" % [
		_round, GameState.MAX_ROUNDS, GameState.defender_wins, GameState.attacker_wins,
	]
	_phase_label.add_theme_color_override("font_color", Color(MUTED, 1.0))
	if _phase == GameState.Phase.ASSAULT and not _spawn_open():
		_time_label.text = "ДОБИВАНИЕ"
	else:
		_time_label.text = "%s %ds" % [_phase_name(_phase), seconds]
	_time_label.add_theme_color_override("font_color", tint)
	_accent.color = tint
	_bar_fill.bg_color = tint
	_update_bar()


func _update_bar() -> void:
	if _bar == null:
		return
	# В добивании таймера нет — полоса гаснет, чтобы не обещать обратный отсчёт.
	_bar.value = clampf(_time_left / maxf(_phase_total, 1.0), 0.0, 1.0) * 100.0


# ------------------------------------------------------------- Анимации ------

func _punch() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_update_pivot()
	scale = Vector2(1.07, 1.07)
	modulate = Color(1.35, 1.35, 1.35, 1.0)
	_pulse_tween = create_tween()
	_pulse_tween.set_parallel(true)
	_pulse_tween.tween_property(self, "scale", Vector2.ONE, 0.26) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pulse_tween.tween_property(self, "modulate", Color.WHITE, 0.32)


func _update_pivot() -> void:
	pivot_offset = size * 0.5
