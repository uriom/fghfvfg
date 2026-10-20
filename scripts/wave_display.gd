class_name WaveDisplay
extends Control
## Компактный неоновый индикатор волны для верхней панели HUD.
##
## Показывает:
##   * во время волны  — «WAVE 3  —  44s» + тонкую полосу остатка времени;
##   * в перерыве      — «NEXT WAVE 4  —  5s»;
##   * последние 10 с   — акцент краснеет, таймер подсвечивается.
##
## СЕТЕВАЯ МОДЕЛЬ: узел самодостаточен. Сервер присылает только границы фаз
## (GameState.wave_started / wave_ended), а между ними каждый пир считает
## время локально. Поэтому индикатор можно вставить в любой HUD простым
## добавлением узла с этим скриптом.
##
## ПРАВИЛО ПРОЕКТА: никакого _draw. Вся графика — стандартные Label,
## ProgressBar, ColorRect и StyleBoxFlat.

const CYAN := Color(0.22, 0.95, 1.0)
const AMBER := Color(1.0, 0.78, 0.34)
const RED := Color(1.0, 0.30, 0.42)
const TEXT := Color(0.92, 0.97, 1.0)
const MUTED := Color(0.55, 0.72, 0.82, 0.75)
const WARNING_SECONDS := 10.0

## Фон-подложка нужна, только если индикатор используется отдельно.
## В верхней панели Defender HUD она выключена — там уже есть общий panel.
@export var show_background := false
@export var background_color := Color(0.01, 0.03, 0.055, 0.78)

var _wave := 1
var _time_left := 60.0
var _in_progress := true
var _phase_total := 60.0
var _last_in_progress := true
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

	GameState.wave_started.connect(_on_wave_started)
	GameState.wave_ended.connect(_on_wave_ended)
	GameState.game_ended.connect(_on_game_ended)
	resized.connect(_update_pivot)
	visibility_changed.connect(_update_pivot)

	# Стартовое состояние читаем из GameState: так индикатор корректен даже
	# если сигнал фазы успел пройти до его появления в дереве.
	_wave = GameState.current_wave
	_time_left = GameState.wave_time_left
	_in_progress = GameState.wave_in_progress
	_phase_total = maxf(GameState.WAVE_DURATION if _in_progress else GameState.WAVE_BREAK, 1.0)
	_update_display(true)
	call_deferred("_update_pivot")


func _process(delta: float) -> void:
	if _finished or GameState.game_over:
		return
	if _time_left <= 0.0:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	_update_bar()

	# Текст пересобираем только при смене целой секунды — меньше работы на кадр.
	var seconds := ceili(_time_left)
	if seconds != _shown_second or _in_progress != _last_in_progress:
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
	column.add_theme_constant_override("separation", 4)
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

	_phase_label = _label("WAVE 1", 15, CYAN)
	row.add_child(_phase_label)

	_time_label = _label("— 60s", 17, TEXT)
	row.add_child(_time_label)

	# Полоса остатка времени: 4 px, без процентов и без мыши.
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

func _on_wave_started(wave: int, duration: float) -> void:
	_wave = wave
	_time_left = duration
	_in_progress = true
	_phase_total = maxf(duration, 1.0)
	_update_display(true)
	_punch()


func _on_wave_ended(wave: int, break_duration: float) -> void:
	_wave = wave
	_time_left = break_duration
	_in_progress = false
	_phase_total = maxf(break_duration, 1.0)
	_update_display(true)
	_punch()


func _on_game_ended(_defender_won: bool) -> void:
	_finished = true
	_update_bar()


func _update_display(force := false) -> void:
	var seconds := maxi(ceili(_time_left), 0)
	if not force and seconds == _shown_second and _in_progress == _last_in_progress:
		return
	_shown_second = seconds
	_last_in_progress = _in_progress

	if _in_progress:
		var warning := _time_left <= WARNING_SECONDS
		var tint := RED if warning else CYAN
		_phase_label.text = "WAVE %d" % _wave
		_phase_label.add_theme_color_override("font_color", tint)
		_time_label.text = "— %ds" % seconds
		_time_label.add_theme_color_override("font_color", RED if warning else TEXT)
		_accent.color = tint
		_bar_fill.bg_color = tint
	else:
		# В перерыве номер текущей волны уже завершён — показываем следующую.
		_phase_label.text = "NEXT WAVE %d" % (_wave + 1)
		_phase_label.add_theme_color_override("font_color", AMBER)
		_time_label.text = "— %ds" % seconds
		_time_label.add_theme_color_override("font_color", AMBER)
		_accent.color = AMBER
		_bar_fill.bg_color = AMBER

	_update_bar()


func _update_bar() -> void:
	if _bar == null:
		return
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
