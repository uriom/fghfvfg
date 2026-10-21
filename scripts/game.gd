extends Node2D
## Корневая сцена матча: раздаёт роли, включает нужный HUD,
## рисует дорогу/базу, крутит фазы раунда и показывает финальный экран.
##
## ЭТАП 6 — ROUND-BASED SIEGE: матч = BO3 из раундов
##   ПОДГОТОВКА (12 с) -> ШТУРМ (60 с) -> ИТОГ (8 с).
## Раунд берёт Штурмовик, если снёс базу; иначе — Защитник.
## Башни переживают раунды, HP базы (15) сбрасывается каждый раунд.
## Таймера «10 минут» больше нет: длительность матча задают раунды.
##
## Здесь же создаются соло-режим «Тренировка» (BotController) и подсказки
## первого матча (TrainingTips) — они работают только вне сети.

const REFERENCE_VIEW_SIZE := Vector2(1152.0, 648.0)
const END_SCREEN := preload("res://scenes/end_game_screen.tscn")
const BOT_SCRIPT := preload("res://scripts/bot_controller.gd")
const TIPS_SCRIPT := preload("res://scripts/training_tips.gd")
## Сколько секунд «тишины» (нет денег, нет очереди, нет юнитов) терпим,
## прежде чем завершить штурм досрочно. Иначе игрок смотрит в пустую дорогу.
## 6 с, а не 2: при капельном доходе 1,5 кр/с штурмовику нужно до 10 с, чтобы
## накопить на самого дешёвого юнита (15 кр). С прежними 2 с раунд
## заканчивался в момент, когда игрок просто копил на следующую покупку.
const STALL_GRACE := 6.0

var my_role := NetworkManager.Role.NONE
var _stall_time := 0.0
var _bot: Node = null
var _tips: Node = null
var _base_marker: Node2D
var _ring_poly: Polygon2D   # маркер базы собран из стандартных Polygon2D
var _disk_poly: Polygon2D
var _core_poly: Polygon2D

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
func _process(delta: float) -> void:
	if GameState.game_over or not multiplayer.is_server():
		return
	GameState.tick_phase(delta)
	_tick_stall(delta)


## Досрочный конец штурма: у атакующего нет ни денег, ни очереди, ни юнитов
## на дороге. Без этого игрок 60 секунд смотрит в пустую арену.
func _tick_stall(delta: float) -> void:
	if not GameState.is_assault():
		_stall_time = 0.0
		return
	if not _assault_is_stalled():
		_stall_time = 0.0
		return
	_stall_time += delta
	if _stall_time >= STALL_GRACE:
		_stall_time = 0.0
		GameState.finish_round_by_timeout()


func _assault_is_stalled() -> bool:
	var spawner := get_node_or_null("Road/UnitSpawner") as UnitSpawner
	if spawner != null and spawner.queue_size() > 0:
		return false
	# Если накоплений хватит на покупку внутри грейс-периода — не «заглох».
	var gold := int(GameState.gold.get(GameState.attacker_peer, 0))
	var income := GameState.TRICKLE_ATTACKER * STALL_GRACE
	if gold + int(income) >= GameDB.cheapest_unit_cost():
		return false
	return get_tree().get_nodes_in_group("units").is_empty()


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
				FXManager.round_banner.rpc("ШТУРМ!", Color(1.0, 0.45, 0.35))


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
	_base_marker = Node2D.new()
	_base_marker.position = points[points.size() - 1]
	_base_marker.z_index = 2
	# Внешнее кольцо — «подложка» базы.
	_ring_poly = Polygon2D.new()
	_ring_poly.polygon = _circle_poly(26.0)
	_ring_poly.color = Color(0.9, 0.3, 0.25).darkened(0.25)
	# Основной диск — краснеет/зеленеет по доле HP.
	_disk_poly = Polygon2D.new()
	_disk_poly.polygon = _circle_poly(20.0)
	# Ядро — «сердцебиение» базы: растёт при полном HP.
	_core_poly = Polygon2D.new()
	_core_poly.polygon = _circle_poly(15.0)
	_base_marker.add_child(_ring_poly)
	_base_marker.add_child(_disk_poly)
	_base_marker.add_child(_core_poly)
	road.add_child(_base_marker)
	_refresh_base_visual()
	var core_pulse := create_tween().set_loops()
	core_pulse.tween_property(_core_poly, "scale", Vector2(1.16, 1.16), 0.72) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	core_pulse.tween_property(_core_poly, "scale", Vector2.ONE, 0.72) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Перекраска диска/ядра под текущее HP (без единого вызова _draw).
func _refresh_base_visual() -> void:
	if _base_marker == null:
		return
	var hp_ratio := float(GameState.base_hp) / float(GameState.ROUND_BASE_HP)
	var base_color := Color(0.9, 0.3, 0.25).lerp(Color(0.35, 0.9, 0.4), hp_ratio)
	_disk_poly.color = base_color
	_core_poly.color = Color.WHITE
	# Радиус ядра 8..15: пересчёт полигона дешевле исключения ноды из дерева.
	_core_poly.polygon = _circle_poly(8.0 + 7.0 * hp_ratio)


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
