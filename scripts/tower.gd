class_name Tower
extends Node2D
## Башня Защитника: ищет цель и атакует по специализации.
##
## СЕТЕВАЯ МОДЕЛЬ (не менялась): поиск цели выполняется НА ВСЕХ пирах
## одинаково — клиент видит атаки без трафика. Урон наносит только сервер:
##   * "beam"          — хитскан: мгновенный урон + FXManager.beam.rpc;
##   * "lob"/"frost"/"flame" — Projectile летает у всех, урон — на сервере;
##   * "chain"         — цепная молния Теслы, урон — сервер, FX — RPC.
##
## ВИЗУАЛ 2.5D: у каждой башни цельный PNG-арт, который рисуется ОДИН раз.
## Старый вариант накладывал две копии одной полной иллюстрации и вращал
## верхнюю: платформа двоилась и ствол выглядел оторванным. Теперь полный
## спрайт остаётся целым, а выстрел читается по вспышке/трассеру/снаряду.
## Зона обстрела — служебные RangeDisc/RangeRing (Polygon2D/Line2D).

const BODY_RADIUS := 18.0      # точка вспышки/вылета снаряда от центра башни
const CIRCLE_SEGMENTS := 48
const RECOIL_DISTANCE := 2.5   # лёгкий импульс цельного арта при выстреле
const RECOIL_TIME := 0.12
const BASE_SIZE := 50.0        # размер цельной читаемой иллюстрации, px

var tower_id := ""
var owner_peer := 1
var cell := Vector2i.ZERO
var stats: Dictionary = {}

var _cooldown := 0.0
var _target: Unit = null
var _recoil_tween: Tween      # активный твин отдачи (перезапускается)

@onready var range_disc: Polygon2D = $RangeDisc
@onready var range_ring: Line2D = $RangeRing
@onready var splash_ring: Line2D = $SplashRing
@onready var base_sprite: Sprite2D = $BaseSprite
@onready var turret_sprite: Sprite2D = $TurretSprite


## Вызывается GameMap._spawn_tower() ДО добавления в дерево, на обоих пирах.
func setup(p_tower_id: String, p_owner: int, p_cell: Vector2i, p_position: Vector2) -> void:
	tower_id = p_tower_id
	owner_peer = p_owner
	cell = p_cell
	position = p_position


func _ready() -> void:
	if not GameDB.TOWERS.has(tower_id):
		push_error("Tower: неизвестный тип башни '%s'" % tower_id)
		queue_free()
		return
	stats = GameDB.TOWERS[tower_id]
	_build_visual()


func _physics_process(delta: float) -> void:
	if GameState.game_over:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	_update_target()
	if _target == null:
		return
	# Иллюстрация башни цельная, не разрезаем и не дублируем её ради
	# визуального наведения. Точный угол всё равно задаёт muzzle/projectile.
	var aim_angle := (_target.global_position - global_position).angle()
	if _cooldown == 0.0:
		_shoot(aim_angle)


## Целимся в юнита, который дальше всех зашёл по пути (и досягаем для башни).
## Одинаково на обоих пирах.
func _update_target() -> void:
	var best: Unit = null
	var best_progress := -1.0
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_dead:
			continue
		if unit.stats["flying"] and not stats["can_target_flying"]:
			continue
		if global_position.distance_to(unit.global_position) > stats["range"]:
			continue
		if unit.progress_ratio > best_progress:
			best_progress = unit.progress_ratio
			best = unit
	_target = best


func _shoot(aim_angle: float) -> void:
	_cooldown = 1.0 / float(stats["fire_rate"])
	var muzzle := global_position + Vector2.from_angle(aim_angle) * BODY_RADIUS
	_play_recoil(aim_angle)
	var kind := String(stats.get("kind", "bullet"))
	if kind != "beam":
		_spawn_muzzle_flash(muzzle, aim_angle)
	match kind:
		"beam":
			# Хитскан: урон и эффекты — только сервер. Клиент увидит луч,
			# когда сервер разошлёт FXManager.beam (call_local RPC).
			if multiplayer.is_server():
				_target.take_damage(damage_of())
				FXManager.beam.rpc(muzzle, _target.global_position, stats["color"])
		"chain":
			# Тесла: разряд по цепочке целей. Урон — сервер, картинка — RPC.
			if multiplayer.is_server():
				_chain_shot(muzzle)
		_:
			# Снаряд создаётся на всех пирах (визуал), урон — на сервере.
			# Звук выстрела здесь же: точка синхронна у обоих игроков.
			if kind == "lob":
				AudioManager.play_sfx("lob_fire", -4.0)
			elif kind == "flame":
				AudioManager.play_sfx("flame_fire", -9.0, 1.1)
			else:
				AudioManager.play_sfx("frost_fire", -4.0)
			var projectile := Projectile.new()
			projectile.setup(muzzle, _target, stats)
			get_parent().add_child(projectile)


## Короткий импульс цельной башни и отдельная цветная вспышка в дуле.
func _play_recoil(aim_angle: float) -> void:
	if _recoil_tween != null and _recoil_tween.is_valid():
		_recoil_tween.kill()
	base_sprite.position = Vector2.from_angle(aim_angle) * -RECOIL_DISTANCE
	_recoil_tween = create_tween()
	_recoil_tween.tween_property(base_sprite, "position", Vector2.ZERO, RECOIL_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _spawn_muzzle_flash(muzzle: Vector2, aim_angle: float) -> void:
	var flash := Polygon2D.new()
	flash.polygon = PackedVector2Array([
		Vector2(5, 0), Vector2(2, -2), Vector2(0, -6), Vector2(-2, -2),
		Vector2(-5, 0), Vector2(-2, 2), Vector2(0, 6), Vector2(2, 2),
	])
	flash.color = Color(stats["color"], 0.95)
	flash.rotation = aim_angle
	flash.z_index = 9
	get_parent().add_child(flash)
	flash.global_position = muzzle
	flash.scale = Vector2(0.35, 0.35)
	var flash_tween := create_tween()
	flash_tween.set_parallel(true)
	flash_tween.tween_property(flash, "scale", Vector2.ONE * 1.7, 0.09) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	flash_tween.tween_property(flash, "modulate:a", 0.0, 0.09)
	flash_tween.chain().tween_callback(flash.queue_free)


## Цепная молния Теслы: главная цель + до N соседних звеньев с затуханием
## урона (chain_falloff = 0.6, т.е. -40% на звено). Поиск звена ведём
## ОТ ПОСЛЕДНЕЙ цели (молния «перескакивает»).
func _chain_shot(muzzle: Vector2) -> void:
	var points := PackedVector2Array([muzzle, _target.global_position])
	_target.take_damage(damage_of())
	var linked: Array[Unit] = [_target]
	var hop_damage := damage_of()
	for _i in int(stats.get("chain_targets", 2)):
		var link := _find_chain_link(linked[-1], linked)
		if link == null:
			break
		linked.append(link)
		hop_damage *= float(stats.get("chain_falloff", 0.6))
		link.take_damage(hop_damage)
		points.append(link.global_position)
	FXManager.chain.rpc(points, stats["color"])


func _find_chain_link(from: Unit, exclude: Array[Unit]) -> Unit:
	var best: Unit = null
	var best_dist := float(stats.get("chain_range", 120.0))
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_dead or exclude.has(unit):
			continue
		var dist := from.global_position.distance_to(unit.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = unit
	return best


func damage_of() -> float:
	return float(stats["damage"])


# ------------------------------------------------------------- Графика -------

## Текстура арта башни; при отсутствии файла вернём null — башня останется
## без спрайтов, но с зоной обстрела (бой не ломается).
func _tower_texture() -> Texture2D:
	var path := "res://assets/img/%s.png" % tower_id
	return load(path) if ResourceLoader.exists(path) else null


## Равномерный масштаб, вписывающий текстуру в квадрат target_size px.
func _fit_scale(tex: Texture2D, target_size: float) -> float:
	var big := maxf(tex.get_width(), tex.get_height())
	return target_size / maxf(big, 1.0)


func _build_visual() -> void:
	var tex := _tower_texture()
	# Зона обстрела: полупрозрачный диск + тонкое кольцо.
	range_disc.polygon = _circle_pts(float(stats["range"]))
	range_ring.points = _circle_line(float(stats["range"]))
	# Кольцо сплеша мортиры (остальным не нужно).
	if String(stats.get("kind")) == "lob":
		splash_ring.points = _circle_line(float(stats.get("splash_radius", 60.0)))
		splash_ring.default_color = Color(stats["color"], 0.35)
		splash_ring.visible = true
	# В assets лежит целая иллюстрация башни, а не раздельные база/ствол.
	# Рисуем её ровно один раз: две наложенные копии давали двоение корпуса.
	base_sprite.visible = tex != null
	turret_sprite.visible = false
	if tex != null:
		base_sprite.texture = tex
		base_sprite.scale = Vector2.ONE * _fit_scale(tex, BASE_SIZE)
		base_sprite.modulate = Color.WHITE


## Точки замкнутой окружности радиуса r (для Line2D с closed = true).
func _circle_line(r: float) -> PackedVector2Array:
	return _circle_pts(r)


## Точки заполненного N-угольника радиуса r (для Polygon2D).
func _circle_pts(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in CIRCLE_SEGMENTS:
		var a := TAU * i / CIRCLE_SEGMENTS
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts
