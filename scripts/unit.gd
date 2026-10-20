class_name Unit
extends PathFollow2D
## Юнит штурмовика: движется по Path2D (дороге) от спавна к базе.
##
## СЕТЕВАЯ МОДЕЛЬ (не менялась): все пиры двигают юнит локально, сервер
## раз в 0.2 сек присылает точные progress/hp/slow через MultiplayerSynchronizer
## и правит дрейф; урон принимается только на сервере (take_damage).
##
## ВИЗУАЛ 2.5D: Body — Sprite2D с полным PNG-артом юнита.
## Наземные модели получили анимированный нижний stride в шейдере + лёгкий
## bounce/lean корпуса; тяжёлые шагают медленнее, не сминаясь как резина.
## Flying парит отдельно. Только Body анимируется: HP и игровые маркеры
## остаются стабильными относительно дороги.

const RADIUS := 13.0
## Сегментов у «окружностей» (аура, ореол полёта, кольцо замедления).
const CIRCLE_SEGMENTS := 32

# --- Параметры процедурных анимаций (настраивались под 60 fps) ---
const RUN_BOB_AMPLITUDE := 4.0    # px, амплитуда бега по Y
const RUN_BOB_STEP := 0.25        # сек на полшага (вверх или вниз)
const RUN_SHAKE_ANGLE := 2.0      # градусы, вибрация поворота при беге
const RUN_SHAKE_STEP := 0.12      # сек на одно отклонение
const HEAVY_STEP := 0.3           # сек на полцикла squash/stretch
const FLY_BOB_AMPLITUDE := 3.0    # px, амплитуда парения
const FLY_BOB_STEP := 0.5         # сек, медленно — «дыхание»
const SPRITE_SIZE := 40.0         # размер нового читаемого арта юнита, px
const GAIT_SHADER := preload("res://shaders/unit_gait.gdshader")

var unit_id := ""
var attacker_peer := 1          # кто отправил юнита
var spawn_index := 0            # порядковый номер спавна (для отладки/офсета)
var stats: Dictionary = {}
var is_dead := false

## HP синхронизируется синхронизатором: присвоение через него тоже
## проходит через сеттер, поэтому «мигание от урона» работает на обоих пирах.
var hp: float = 0.0:
	set(value):
		var previous := hp
		hp = value
		if hp < previous:
			_flash()
		_update_hp_bar()

## Состояние замедления (синхронизируется on change):
## сервер пишет значения при _apply_slow(), оба пира уменьшают таймер
## в _process — ледяное кольцо видно, пока slow_timer > 0.
var slow_timer: float = 0.0
var slow_factor: float = 1.0    # множитель скорости (1.0 — не замедлен)

var _bar_pos := Vector2.ZERO   # верхний левый угол полоски HP
var _bar_width := 0.0          # её полная ширина
var _body_pivot: Node2D
var _facing_initialized := false

@onready var aura_disc: Polygon2D = $AuraDisc
@onready var aura_ring: Line2D = $AuraRing
@onready var flight_halo: Polygon2D = $FlightHalo
@onready var ground_shadow: Polygon2D = $GroundShadow
@onready var body_sprite: Sprite2D = $Body
@onready var slow_ring: Line2D = $SlowRing
@onready var hp_bar_bg: Polygon2D = $HpBarBg
@onready var hp_bar: Polygon2D = $HpBar


## Вызывается спавнером ДО добавления в дерево — одинаково на обоих пирах.
func setup(p_unit_id: String, p_attacker: int, p_spawn_index: int) -> void:
	unit_id = p_unit_id
	attacker_peer = p_attacker
	spawn_index = p_spawn_index


func _ready() -> void:
	add_to_group("units")
	if not GameDB.UNITS.has(unit_id):
		push_error("Unit: неизвестный тип юнита '%s'" % unit_id)
		queue_free()
		return
	stats = GameDB.UNITS[unit_id]
	hp = stats["hp"]
	_build_visual()
	_install_body_pivot()
	_start_locomotion()
	# Звук спавна: _ready выполняется на обоих пирах (спавн через
	# MultiplayerSpawner), поэтому сетевого вызова не требуется.
	AudioManager.play_sfx("spawn", -6.0)


func _process(delta: float) -> void:
	if is_dead:
		return
	slow_timer = maxf(slow_timer - delta, 0.0)
	# Кольцо замедления гаснет вместе с таймером (кроме иммунных к нему).
	slow_ring.visible = slow_timer > 0.0 and not stats.get("ignores_slow", false)
	# Локальное движение у всех; серверные значения периодически поправляют.
	var speed_mult := 1.0
	if slow_timer > 0.0 and not stats.get("ignores_slow", false):
		speed_mult = slow_factor
	progress += stats["speed"] * speed_mult * delta
	_orient_to_road(delta)
	if multiplayer.is_server() and progress_ratio >= 1.0:
		_reach_base()


## Наносит урон. Вызывается ТОЛЬКО на сервере (снарядами башен).
## number_kind — вид цифры урона (FXManager.DMG_*), чтобы отличать сплеш.
func take_damage(amount: float, number_kind := FXManager.DMG_NORMAL) -> void:
	if not multiplayer.is_server() or is_dead:
		return
	var final := amount
	var kind := number_kind
	# Аура танка: если рядом живой танк-союзник (кроме самого юнита),
	# входящий урон снижен. Чисто серверная механика.
	var aura := _tank_aura_reduction()
	if aura > 0.0:
		final *= 1.0 - aura
		kind = FXManager.DMG_PROTECTED
	# Цифру урона показывает сервер (RPC call_local): у обоих игроков
	# одинаково, привязано к фактическому (авторитетному) урону.
	FXManager.damage_number.rpc(global_position, final, kind)
	hp = maxf(hp - final, 0.0)
	if hp <= 0.0:
		_die()


## Накладывает замедление. Вызывается снарядом криостана ТОЛЬКО на сервере.
## Летающие юниты (ignores_slow) не замедляются — им показывается «ИММУН».
func _apply_slow(percent: float, duration: float) -> void:
	if not multiplayer.is_server() or is_dead:
		return
	if stats.get("ignores_slow", false):
		FXManager.damage_number.rpc(global_position, 0.0, FXManager.DMG_IMMUNE)
		return
	# Сильнейшее из активных замедлений; самый долгий таймер из двух.
	slow_factor = minf(slow_factor if slow_timer > 0.0 else 1.0, 1.0 - clampf(percent, 0.0, 0.95))
	slow_timer = maxf(slow_timer, duration)


## Ищет максимум снижения урона от аур живых танков-союзников рядом.
func _tank_aura_reduction() -> float:
	var best := 0.0
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if other == null or other == self or other.is_dead:
			continue
		if not other.stats.has("aura_radius"):
			continue
		if global_position.distance_to(other.global_position) <= float(other.stats["aura_radius"]):
			best = maxf(best, float(other.stats["aura_reduction"]))
	return best


func _die() -> void:
	is_dead = true
	GameState.award_kill(stats)                          # золото защитнику
	FXManager.unit_died.rpc(global_position, stats["color"], stats["flying"])
	queue_free()                  # MultiplayerSpawner удалит юнит и у клиента


func _reach_base() -> void:
	is_dead = true
	GameState.base_leaked(stats)  # урон базе + награда штурмовику
	FXManager.base_hit.rpc()      # тряска камеры + красная пелена обоим игрокам
	queue_free()


func _flash() -> void:
	modulate = Color(3.0, 1.0, 1.0)
	var tween := create_tween()
	tween.tween_property(self, "modulate", Color.WHITE, 0.15)


## Радиус корпуса: у большинства RADIUS, у крупных юнитов (Босс) — из статов.
func get_radius() -> float:
	return float(stats.get("radius", RADIUS))


# ------------------------------------------------------------- Графика -------

## Текстура арта юнита; без файла спрайт просто не показывается —
## кольца/полоска HP остаются, бой не ломается.
func _unit_texture() -> Texture2D:
	var path := "res://assets/img/%s.png" % unit_id
	return load(path) if ResourceLoader.exists(path) else null


## Равномерный масштаб, вписывающий текстуру в квадрат target_size px.
func _fit_scale(tex: Texture2D, target_size: float) -> float:
	var big := maxf(tex.get_width(), tex.get_height())
	return target_size / maxf(big, 1.0)


func _build_visual() -> void:
	var r := get_radius()
	ground_shadow.polygon = _circle_pts(r + 3.0)
	ground_shadow.scale = Vector2(1.3, 0.48) if not stats["flying"] else Vector2(1.0, 0.38)
	ground_shadow.position = Vector2(0.0, r * 0.42)
	ground_shadow.color = Color(0.005, 0.012, 0.022, 0.42 if not stats["flying"] else 0.24)
	# Аура танка: полупрозрачный диск + кольцо радиуса защиты.
	if stats.has("aura_radius"):
		aura_disc.polygon = _circle_pts(float(stats["aura_radius"]))
		aura_ring.points = _circle_pts(float(stats["aura_radius"]))
	else:
		aura_disc.visible = false
		aura_ring.visible = false
	# Ореол «полёта» — только у летающих.
	if stats["flying"]:
		flight_halo.polygon = _circle_pts(r + 5.0)
		flight_halo.color = Color(stats["color"], 0.25)
	else:
		flight_halo.visible = false
	# Кольцо замедления вокруг корпуса (показывается в _process).
	slow_ring.points = _circle_pts(r + 7.0)
	# Спрайт персонажа: вписан в SPRITE_SIZE, у босса — крупнее по радиусу.
	var tex := _unit_texture()
	if tex != null:
		body_sprite.texture = tex
		body_sprite.scale = Vector2.ONE * _fit_scale(tex, SPRITE_SIZE + (r - RADIUS) * 2.0)
		if not stats["flying"]:
			var gait := ShaderMaterial.new()
			gait.shader = GAIT_SHADER
			gait.set_shader_parameter("gait_speed", 4.6 if stats.has("radius") or stats.has("aura_radius") else 8.0)
			gait.set_shader_parameter("gait_amount", 0.035)
			gait.set_shader_parameter("gait_phase", float(spawn_index % 9) * 0.71)
			body_sprite.material = gait
	else:
		body_sprite.visible = false
	# Полоска HP над корпусом.
	_bar_width = r * 2.4
	_bar_pos = Vector2(-_bar_width * 0.5, -r - 11.0)
	hp_bar_bg.polygon = _rect_pts(_bar_pos, _bar_width, 5.0)
	_update_hp_bar()


## Вращаем только BodyPivot по касательной пути: полоска HP, аура и кольца
## остаются горизонтальными. art_forward задаёт направление «вперёд» в текстуре.
func _install_body_pivot() -> void:
	var old_index := body_sprite.get_index()
	remove_child(body_sprite)
	_body_pivot = Node2D.new()
	_body_pivot.name = "BodyPivot"
	add_child(_body_pivot)
	move_child(_body_pivot, old_index)
	_body_pivot.add_child(body_sprite)


func _orient_to_road(delta: float) -> void:
	if _body_pivot == null:
		return
	var road := get_parent() as Path2D
	if road == null or road.curve == null:
		return
	var before := road.curve.sample_baked(maxf(progress - 5.0, 0.0))
	var after := road.curve.sample_baked(progress + 5.0)
	var direction := road.to_global(after) - road.to_global(before)
	if direction.length_squared() < 0.001:
		return
	var desired := direction.angle() - float(stats.get("art_forward", 0.0))
	if not _facing_initialized:
		_body_pivot.rotation = desired
		_facing_initialized = true
	else:
		_body_pivot.rotation = lerp_angle(_body_pivot.rotation, desired, clampf(delta * 10.0, 0.0, 1.0))


## Пружинящий бег: небольшая gait-деформация нижней части текстуры,
## синхронная с вертикальным шагом и наклоном корпуса. Летающие парят.
func _start_locomotion() -> void:
	var heavy := stats.has("aura_radius") or stats.has("radius")
	var bob_amplitude := FLY_BOB_AMPLITUDE if stats["flying"] else (1.5 if heavy else 2.5)
	var half_step := FLY_BOB_STEP if stats["flying"] else (HEAVY_STEP if heavy else RUN_BOB_STEP)
	var bob := create_tween().set_loops()
	bob.tween_property(body_sprite, "position:y", -bob_amplitude, half_step) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	bob.tween_property(body_sprite, "position:y", bob_amplitude, half_step) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if not stats["flying"]:
		var tilt := create_tween().set_loops()
		var angle := deg_to_rad(1.8 if heavy else 2.6)
		var tilt_step := HEAVY_STEP if heavy else RUN_SHAKE_STEP * 2.0
		tilt.tween_property(body_sprite, "rotation", angle, tilt_step) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tilt.tween_property(body_sprite, "rotation", -angle, tilt_step) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		var breathe := create_tween().set_loops()
		breathe.tween_property(flight_halo, "scale", Vector2.ONE * 1.12, FLY_BOB_STEP) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		breathe.tween_property(flight_halo, "scale", Vector2.ONE * 0.94, FLY_BOB_STEP) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Точки замкнутой окружности радиуса r.
func _circle_pts(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in CIRCLE_SEGMENTS:
		var a := TAU * i / CIRCLE_SEGMENTS
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## Прямоугольник w x h с верхним левым углом в pos (полоски HP).
func _rect_pts(pos: Vector2, w: float, h: float) -> PackedVector2Array:
	return PackedVector2Array([
		pos, pos + Vector2(w, 0), pos + Vector2(w, h), pos + Vector2(0, h),
	])


## Пересчёт зелёной заливки полоски HP (вызывается сеттером hp).
func _update_hp_bar() -> void:
	if stats.is_empty() or hp_bar == null:
		return   # hp присваивается до _ready — нод ещё нет
	var ratio: float = clampf(hp / maxf(float(stats["hp"]), 1.0), 0.0, 1.0)
	hp_bar.polygon = _rect_pts(_bar_pos, _bar_width * ratio, 5.0)
