extends Node2D
## Корневая сцена матча: раздаёт роли, включает нужный HUD,
## рисует дорогу/базу, крутит фазы раунда и показывает финальный экран.
##
## ЭТАП 8 — SIEGE x10: матч = до 10 волн, победа после 6 взятых раундов
##   ПОДГОТОВКА (10 с) -> ШТУРМ (окно спавна 30 с + добивание).
## Раунд берёт Штурмовик, если снёс базу; иначе — Защитник.
## Паузы «ИТОГ» нет: следующий раунд начинается сразу, как опустело поле.
## Башни, их уровни и уровни юнитов переживают раунды; HP базы сбрасывается.
## База нарисована как портал: вращающиеся кольца, воронка и орбита рун.
##
## Здесь же создаются соло-режим «Тренировка» (BotController) и подсказки
## первого матча (TrainingTips) — они работают только вне сети.

const REFERENCE_VIEW_SIZE := Vector2(1152.0, 648.0)
const END_SCREEN := preload("res://scenes/end_game_screen.tscn")
const BOT_SCRIPT := preload("res://scripts/bot_controller.gd")
const TIPS_SCRIPT := preload("res://scripts/training_tips.gd")
## Пульс портала: сколько секунд на один оборот внешнего кольца и воронки.
const PORTAL_ORBIT_TIME := 9.0
const PORTAL_VORTEX_TIME := 4.6

var my_role := NetworkManager.Role.NONE
var _bot: Node = null
var _tips: Node = null
# Портал базы: собран из стандартных нод (правило проекта — никакого _draw).
var _base_marker: Node2D
var _portal_spin: Node2D
var _portal_vortex: Node2D
var _portal_runes: Node2D
var _ring_poly: Polygon2D
var _disk_poly: Polygon2D
var _core_poly: Polygon2D
var _portal_outer: Line2D
var _portal_inner: Line2D
var _portal_beam: Polygon2D
var _portal_lights: Array[Polygon2D] = []

@onready var road: Path2D = $Road
@onready var camera: Camera2D = $Camera
@onready var result_label: Label = %Result


func _ready() -> void:
	get_viewport().size_changed.connect(_fit_camera_to_viewport)
	_fit_camera_to_viewport()
	my_role = NetworkManager.local_role()
	# Одинаковая инициализация состояния на обоих пирах (золото, HP, деки).
	# Деки пришли через лобби-RPC — у обоих игроков одинаковые списки.
	var host_info: Dictionary = NetworkManager.players.get(NetworkManager.defender_peer(), {})
	var guest_info: Dictionary = NetworkManager.players.get(NetworkManager.attacker_peer(), {})
	GameState.setup_match(NetworkManager.defender_peer(), NetworkManager.attacker_peer(),
			host_info.get("towers", []), guest_info.get("units", []))
	# Кнопки HUD и дефолтная башня карты — строго из деков этого матча
	# (вызываем после setup_match: деки уже известны обоим пирам).
	%Map.apply_match_deck()
	%DefenderHUD.rebuild_from_deck()
	%AttackerHUD.rebuild_from_deck()

	# Дорога: Line2D повторяет кривую Path2D, база стоит в её конце.
	$Road/RoadLine.points = road.curve.get_baked_points()
	_build_road_visuals()
	_spawn_base_marker()
	GameState.base_hp_changed.connect(_on_base_hp_changed)

	# Управление и HUD — строго по своей роли.
	var is_defender := my_role == NetworkManager.Role.DEFENDER
	%Map.set_active(is_defender)
	%DefenderHUD.visible = is_defender
	%AttackerHUD.visible = not is_defender

	GameState.game_ended.connect(_on_game_ended)
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_ended.connect(_on_round_ended)
	NetworkManager.opponent_left.connect(_on_opponent_left)
	AudioManager.play_music("bgm")
	var pause_menu := preload("res://scripts/pause_menu.gd").new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)
	# Соло-режим: ИИ-соперник и подсказки живут только вне сетевой сессии.
	if NetworkManager.is_solo():
		_bot = BOT_SCRIPT.new()
		_bot.name = "BotOpponent"
		add_child(_bot)
		_tips = TIPS_SCRIPT.new()
		_tips.name = "TrainingTips"
		add_child(_tips)


func _fit_camera_to_viewport() -> void:
	var view_size := get_viewport_rect().size
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		return
	# Мир масштабируется относительно базового поля, интерфейс остаётся в
	# экранных пикселях: полноэкранный режим не раздувает кнопки и шрифты.
	var fit := minf(view_size.x / REFERENCE_VIEW_SIZE.x,
			view_size.y / REFERENCE_VIEW_SIZE.y)
	fit = maxf(fit, 0.01)
	camera.zoom = Vector2.ONE * fit
	# Центрируем само поле в области между верхней статус-полосой и нижней
	# панелью, а не в пустом центре всего окна.
	var safe_bottom := maxf(64.0, view_size.y - 200.0)
	var safe_center_y := (64.0 + safe_bottom) * 0.5
	var screen_center_y := view_size.y * 0.5
	var playfield_center_y := 240.0
	camera.position = Vector2(REFERENCE_VIEW_SIZE.x * 0.5,
			playfield_center_y + (screen_center_y - safe_center_y) / fit)


## Фазы раунда тикает ТОЛЬКО сервер; клиент получает готовые переходы
## по RPC. Так расхождение таймеров не ломает планирование.
## Фазы тикает ТОЛЬКО сервер. Конец раунда теперь определяет GameState по
## состоянию поля (нет юнитов и очередь пуста), поэтому отдельного «столл»-
## таймера здесь больше нет.
func _process(delta: float) -> void:
	if GameState.game_over or not multiplayer.is_server():
		return
	GameState.tick_phase(delta)


## Фаза сменилась — короткий звук/баннер, чтобы игрок не пропустил старт.
func _on_phase_changed(_round_index: int, phase: int, _duration: float) -> void:
	match phase:
		GameState.Phase.PLANNING:
			AudioManager.play_sfx("phase_plan", -8.0)
		GameState.Phase.ASSAULT:
			AudioManager.play_sfx("phase_assault", -4.0)
			# Баннер — authority-RPC: зовёт только сервер, иначе клиент
			# получит «not authorized» и баннер не увидят оба.
			if multiplayer.is_server():
				FXManager.round_banner.rpc("ШТУРМ · 30 СЕК!",
						Color(1.0, 0.45, 0.35))


func _on_round_ended(_round_index: int, attacker_won: bool,
		_defender_wins: int, _attacker_wins: int) -> void:
	if not multiplayer.is_server():
		return
	FXManager.round_banner.rpc("РАУНД ЗА ШТУРМОВИКОМ" if attacker_won
			else "РАУНД ЗА ЗАЩИТНИКОМ",
			Color(1.0, 0.45, 0.35) if attacker_won else Color(0.35, 0.95, 0.55))


# ---------------------------------------------------------- Поле боя --------

## Несколько аккуратных слоёв вместо одинокой коричневой Line2D:
## тёмная подложка, металлическая кромка, холодный асфальт, боковые рельсы
## и редкие световые маркеры направления.
func _build_road_visuals() -> void:
	var points := road.curve.get_baked_points()
	var shadow := Line2D.new()
	shadow.name = "RoadShadow"
	shadow.points = points
	shadow.width = 52.0
	shadow.default_color = Color(0.008, 0.016, 0.026, 0.98)
	shadow.z_index = -5
	$Road.add_child(shadow)
	var shoulder := Line2D.new()
	shoulder.name = "RoadShoulder"
	shoulder.points = points
	shoulder.width = 50.0
	shoulder.default_color = Color(0.045, 0.075, 0.10, 1.0)
	shoulder.z_index = -4
	$Road.add_child(shoulder)
	var asphalt := Line2D.new()
	asphalt.name = "RoadSurface"
	asphalt.points = points
	asphalt.width = 46.0
	asphalt.default_color = Color(0.085, 0.12, 0.15, 1.0)
	asphalt.z_index = -3
	$Road.add_child(asphalt)
	var edges := [Line2D.new(), Line2D.new()]
	var edge_points := [PackedVector2Array(), PackedVector2Array()]
	for i in points.size():
		var previous := points[maxi(i - 1, 0)]
		var next := points[mini(i + 1, points.size() - 1)]
		var tangent := (next - previous).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		edge_points[0].append(points[i] + normal * 24.0)
		edge_points[1].append(points[i] - normal * 24.0)
	for i in 2:
		edges[i].name = "RoadNeonEdge%d" % i
		edges[i].points = edge_points[i]
		edges[i].width = 1.5
		edges[i].default_color = Color(0.16, 0.72, 0.86, 0.55) if i == 0 \
				else Color(0.95, 0.62, 0.25, 0.28)
		edges[i].z_index = 0
		$Road.add_child(edges[i])
	_add_lane_dashes()
	_add_lane_pulses()


func _add_lane_dashes() -> void:
	var length := road.curve.get_baked_length()
	for distance in range(30, int(length) - 18, 62):
		var dash := Line2D.new()
		dash.width = 1.4
		dash.default_color = Color(0.74, 0.90, 0.95, 0.22)
		dash.z_index = 0
		dash.points = PackedVector2Array([
			road.curve.sample_baked(distance),
			road.curve.sample_baked(minf(float(distance + 18), length)),
		])
		$Road.add_child(dash)


func _add_lane_pulses() -> void:
	var length := road.curve.get_baked_length()
	for i in 3:
		var follower := PathFollow2D.new()
		follower.name = "LanePulse%d" % i
		follower.loop = true
		follower.rotates = false
		follower.progress = length * float(i) / 3.0
		follower.z_index = 1
		$Road.add_child(follower)
		var pip := Polygon2D.new()
		pip.polygon = PackedVector2Array([
			Vector2(0, -3.5), Vector2(2.0, 0), Vector2(0, 3.5), Vector2(-2.0, 0),
		])
		pip.color = Color(0.30, 0.91, 1.0, 0.82)
		pip.scale = Vector2(1.5, 1.0)
		follower.add_child(pip)
		var pulse := create_tween().set_loops()
		pulse.tween_property(follower, "progress", length, 18.0).from(length * float(i) / 3.0) \
				.set_trans(Tween.TRANS_LINEAR)
		pulse.tween_property(follower, "progress", 0.0, 0.001)


# -------------------------------------------------------------- База --------
# Правило проекта: НИКАКОГО процедурного рисования (_draw). Маркер базы —
# три стандартные ноды Polygon2D (кольцо, диск, ядро), собранные в коде.

## Точки правильного N-угольника радиуса r вокруг центра.
func _circle_poly(r: float, segments := 32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments:
		var a := TAU * i / segments
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


func _spawn_base_marker() -> void:
	var points := road.curve.get_baked_points()
	if points.is_empty():
		return
	# Портал ставим чуть внутрь от конца дороги, чтобы кольца не срезались
	# краем экрана: последний сегмент дороги идёт справа налево.
	var tail := points[points.size() - 1]
	var tangent := (tail - points[maxi(points.size() - 12, 0)]).normalized()
	_base_marker = Node2D.new()
	_base_marker.name = "BasePortal"
	_base_marker.position = tail + tangent * 14.0
	_base_marker.z_index = 2
	road.add_child(_base_marker)

	# 1. Тень/подложка: тёмный диск под порталом.
	var plate := Polygon2D.new()
	plate.polygon = _circle_poly(30.0)
	plate.color = Color(0.01, 0.02, 0.035, 0.65)
	_base_marker.add_child(plate)

	# 2. Столб света: сужается вверх, создаёт «ворота».
	_portal_beam = Polygon2D.new()
	_portal_beam.polygon = PackedVector2Array([
		Vector2(-22.0, 0.0), Vector2(-9.0, -96.0), Vector2(0.0, -112.0),
		Vector2(9.0, -96.0), Vector2(22.0, 0.0),
	])
	_portal_beam.color = Color(0.4, 0.8, 1.0, 0.10)
	_portal_beam.z_index = -1
	_base_marker.add_child(_portal_beam)

	# 3. Внешнее и внутреннее кольца (разная скорость вращения).
	_portal_spin = Node2D.new()
	_base_marker.add_child(_portal_spin)
	_portal_outer = Line2D.new()
	_portal_outer.width = 3.0
	_portal_outer.closed = true
	_portal_outer.antialiased = true
	_portal_outer.points = _ring_points(30.0, 48)
	_portal_spin.add_child(_portal_outer)
	# Сегменты внешнего кольца: 4 «скобки», чтобы вращение читалось.
	for i in 4:
		var bracket := Line2D.new()
		bracket.width = 4.5
		bracket.antialiased = true
		bracket.default_color = Color(0.55, 0.95, 1.0, 0.85)
		var arc := PackedVector2Array()
		for step in 7:
			var a := float(i) * TAU / 4.0 + TAU * float(step) / 42.0
			arc.append(Vector2(cos(a), sin(a)) * 34.0)
		bracket.points = arc
		_portal_spin.add_child(bracket)

	# 4. Воронка: два встречных спиральных кольца + ядро.
	_portal_vortex = Node2D.new()
	_base_marker.add_child(_portal_vortex)
	_portal_inner = Line2D.new()
	_portal_inner.width = 2.0
	_portal_inner.antialiased = true
	_portal_inner.default_color = Color(0.9, 0.75, 1.0, 0.8)
	_portal_inner.points = _spiral_points(7.0, 24.0, 2.1)
	_portal_vortex.add_child(_portal_inner)
	_ring_poly = Polygon2D.new()
	_ring_poly.polygon = _ring_points(24.0, 40)
	_ring_poly.color = Color(0.35, 0.75, 1.0, 0.18)
	_portal_vortex.add_child(_ring_poly)

	# 5. Диск и ядро: цвет/размер зависят от HP базы.
	_disk_poly = Polygon2D.new()
	_disk_poly.polygon = _circle_poly(20.0)
	_base_marker.add_child(_disk_poly)
	_core_poly = Polygon2D.new()
	_core_poly.polygon = _star_poly(13.0, 6.0, 8)
	_base_marker.add_child(_core_poly)

	# 6. Орбита рун: 6 ромбов медленно обходят портал.
	_portal_runes = Node2D.new()
	_base_marker.add_child(_portal_runes)
	for i in 6:
		var rune := Polygon2D.new()
		rune.polygon = PackedVector2Array([
			Vector2(0, -3.2), Vector2(2.2, 0), Vector2(0, 3.2), Vector2(-2.2, 0),
		])
		var angle := TAU * float(i) / 6.0
		rune.position = Vector2(cos(angle), sin(angle)) * 40.0
		rune.color = Color(0.65, 0.95, 1.0, 0.8)
		_portal_runes.add_child(rune)
		_portal_lights.append(rune)

	_refresh_base_visual()

	# Анимации: вращение колец в разные стороны, пульс ядра, орбита рун.
	var spin := create_tween().set_loops()
	spin.tween_property(_portal_spin, "rotation", TAU, PORTAL_ORBIT_TIME) \
			.set_trans(Tween.TRANS_LINEAR).from(0.0)
	var counter := create_tween().set_loops()
	counter.tween_property(_portal_vortex, "rotation", -TAU, PORTAL_VORTEX_TIME) \
			.set_trans(Tween.TRANS_LINEAR).from(0.0)
	var runes := create_tween().set_loops()
	runes.tween_property(_portal_runes, "rotation", -TAU, PORTAL_ORBIT_TIME * 1.7) \
			.set_trans(Tween.TRANS_LINEAR).from(0.0)
	var breathe := create_tween().set_loops()
	breathe.tween_property(_core_poly, "scale", Vector2(1.22, 1.22), 0.9) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	breathe.tween_property(_core_poly, "scale", Vector2.ONE, 0.9) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var swirl := create_tween().set_loops()
	swirl.tween_property(_portal_inner, "scale", Vector2(1.18, 1.18), 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	swirl.tween_property(_portal_inner, "scale", Vector2(0.86, 0.86), 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Точки замкнутого кольца радиуса r.
func _ring_points(r: float, segments: int) -> PackedVector2Array:
	return _circle_poly(r, segments)


## Спираль: points витков от внутреннего радиуса к внешнему.
func _spiral_points(inner: float, outer: float, turns: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 40
	for i in steps + 1:
		var t := float(i) / float(steps)
		var a := TAU * turns * t
		pts.append(Vector2(cos(a), sin(a)) * lerpf(inner, outer, t))
	return pts


## Звезда с чередованием радиусов (ядро портала).
func _star_poly(outer: float, inner: float, spikes: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in spikes * 2:
		var r := outer if i % 2 == 0 else inner
		var a := TAU * float(i) / float(spikes * 2)
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## Перекраска портала под текущее HP (без единого вызова _draw).
## Чем меньше HP, тем тусклее кольца и меньше ядро — база «умирает» на глазах.
func _refresh_base_visual() -> void:
	if _base_marker == null:
		return
	var hp_ratio := float(GameState.base_hp) / float(GameState.ROUND_BASE_HP)
	var damage := 1.0 - clampf(hp_ratio, 0.0, 1.0)
	var hot := Color(0.9, 0.3, 0.25)
	var alive := Color(0.35, 0.9, 0.4)
	var base_color := hot.lerp(alive, hp_ratio)
	_disk_poly.color = Color(base_color, 0.22 + 0.3 * hp_ratio)
	_core_poly.color = base_color.lightened(0.25)
	_core_poly.polygon = _star_poly(7.0 + 7.0 * hp_ratio, 3.4, 8)
	_portal_outer.default_color = Color(base_color, 0.35 + 0.4 * hp_ratio)
	_portal_inner.default_color = Color(0.95, 0.7, 1.0, 0.55 + 0.35 * hp_ratio)
	_portal_beam.color = Color(base_color, 0.05 + 0.08 * hp_ratio)
	# Кольца «дрожат» от урона: чем меньше HP, тем заметнее биение.
	_ring_poly.color = Color(base_color, 0.10 + 0.18 * hp_ratio)
	for rune in _portal_lights:
		if rune != null:
			rune.color = Color(base_color.lightened(0.4), 0.5 + 0.5 * (1.0 - damage))


func _on_base_hp_changed(_hp: int, _max_hp: int) -> void:
	_refresh_base_visual()


# -------------------------------------------------------------- Финал -------

func _on_game_ended(defender_won: bool) -> void:
	var i_won := (my_role == NetworkManager.Role.DEFENDER) == defender_won
	var local_score := 0
	if my_role == NetworkManager.Role.DEFENDER:
		local_score = int(GameState.stats.get("units_killed", 0)) * 100 \
				+ GameState.base_hp * 25 + int(GameState.stats.get("towers_built", 0)) * 10
	else:
		local_score = int(GameState.stats.get("units_leaked", 0)) * 100 \
				+ int(GameState.stats.get("waves_sent", 0)) * 25 \
				+ int(GameState.stats.get("units_sent", 0)) * 5
	SettingsManager.record_score(local_score)
	AudioManager.stop_music()
	AudioManager.play_sfx("victory" if i_won else "defeat", -2.0)
	# Экран статистики: одинаковые цифры у обоих (слепок сервера).
	var screen := END_SCREEN.instantiate()
	screen.theme = UISkin.theme()
	$UI.add_child(screen)
	screen.setup(defender_won, GameState.stats, my_role)


func _on_opponent_left() -> void:
	# Финал уже показан (соперник вышел с экрана результатов) — не перебиваем.
	if GameState.game_over:
		return
	result_label.text = "Соперник отключился"
	result_label.visible = true
	# Возврат в меню уже запланирован в NetworkManager.
