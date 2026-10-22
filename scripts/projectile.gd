class_name Projectile
extends Node2D
## Снаряд башни. Вид задаётся полем kind из GameDB.TOWERS:
##   "lob"    — мортира: баллистический навесной снаряд по точке упреждения,
##              при попадании урон по площади с линейным спадом к краю;
##   "frost"  — криостан: малый урон + замедление цели (кроме летающих);
##   "bullet" — одиночный снаряд (универсальная перестраховка без kind).
##
## Движение и визуал — на ВСЕХ пирах (косметика без трафика), урон и
## статусы — только на сервере (_impact). Эффекты сервер запускает через
## FXManager.rpc — картинка одинакова у обоих игроков.
## Сцена не нужна: создаётся кодом через Projectile.new().
##
## ВИЗУАЛ 2.5D (правило: никакого _draw): собирается в _ready из нод —
##   * _ball   Polygon2D  — тело снаряда;
##   * _shadow Polygon2D  — тень на земле (у мортиры отделена от тела дугой);
##   * _trail  Line2D     — хвост из последних позиций (top_level = true,
##                          точки хранятся в мировых координатах).

const ARC_HEIGHT := 36.0   # высота «навесной» дуги мортиры, чисто визуал
const TRAIL_POINTS := 8    # длина хвоста (точек Line2D)

var damage := 0.0
var speed := 320.0
var target: Unit = null
var kind := "bullet"
var splash_radius := 0.0
# Доля урона на краю сплеша (из GameDB, для мортиры = 0.5).
var splash_falloff_min := 0.5
var slow_percent := 0.0
var slow_duration := 0.0
var pulse_radius := 60.0
var color := Color(1, 1, 0.75)
# Тип урона башни (GameDB.DAMAGE_MATRIX). Матрица применяется в Unit.
var damage_type := ""
# Бьёт ли оружие воздух. У мортиры — нет: осколки не достают летающих,
# даже если те пролетают через точку разрыва (иначе «наземная» башня
# неявно становилась ПВО и ломала контр-плей).
var hits_flying := true

# У мортиры — точка упреждения, не homing-цель.
var _destination := Vector2.ZERO
var _total_distance := 1.0
var _traveled := 0.0

# Ноды визуала (создаются в _ready, см. шапку).
var _ball: Polygon2D
var _core: Polygon2D
var _shadow: Polygon2D
var _trail: Line2D


func setup(from: Vector2, p_target: Unit, tower_stats: Dictionary) -> void:
	position = from   # родитель у всех башен один и тот же узел в (0,0), локальные == глобальные
	target = p_target
	damage = float(tower_stats["damage"])
	speed = float(tower_stats.get("projectile_speed", speed))
	kind = String(tower_stats.get("kind", "bullet"))
	splash_radius = float(tower_stats.get("splash_radius", 0.0))
	splash_falloff_min = float(tower_stats.get("splash_falloff_min", 0.5))
	slow_percent = float(tower_stats.get("slow_percent", 0.0))
	slow_duration = float(tower_stats.get("slow_duration", 0.0))
	damage_type = String(tower_stats.get("damage_type", ""))
	hits_flying = bool(tower_stats.get("can_target_flying", true))
	pulse_radius = float(tower_stats.get("pulse_radius", pulse_radius))
	color = tower_stats["color"]
	_destination = p_target.global_position if p_target != null else from
	if kind == "lob" and p_target != null:
		# Артиллерия стреляет по точке упреждения на дороге, а не поворачивает
		# в воздухе вслед за целью: от снаряда можно уклониться движением.
		var travel_time := from.distance_to(_destination) / maxf(speed, 1.0)
		var road := p_target.get_parent() as Path2D
		if road != null and road.curve != null:
			var target_speed := float(p_target.stats.get("speed", 0.0))
			if p_target.slow_timer > 0.0:
				target_speed *= p_target.slow_factor
			var lead_progress := minf(p_target.progress + target_speed * travel_time,
					road.curve.get_baked_length())
			_destination = road.to_global(road.curve.sample_baked(lead_progress))
	_total_distance = maxf(from.distance_to(_destination), 1.0)
	z_index = 6


func _ready() -> void:
	_build_visual()


## Сборка визуала из стандартных нод (один раз, без _draw).
func _build_visual() -> void:
	# Тень нужна только навесной мортире: она остаётся на земле, пока шар
	# визуально взлетает по дуге. Остальные снаряды идут в плоскости боя.
	_shadow = Polygon2D.new()
	_shadow.polygon = _circle_pts(5.0 if kind == "lob" else 3.0)
	_shadow.color = Color(0, 0, 0, 0.28)
	_shadow.position = Vector2(0, 2)
	_shadow.visible = kind == "lob"
	add_child(_shadow)
	_ball = Polygon2D.new()
	match kind:
		"flame":
			# Направленное языкообразное пламя с горячим ядром, а не шар.
			_ball.polygon = PackedVector2Array([
				Vector2(-7, 0), Vector2(-3, -3), Vector2(0, -2),
				Vector2(3, -1), Vector2(8, 0), Vector2(3, 1),
				Vector2(0, 2), Vector2(-3, 3),
			])
			_ball.color = Color(1.0, 0.34, 0.08)
			_core = Polygon2D.new()
			_core.polygon = _circle_pts(2.2)
			_core.color = Color(1.0, 0.92, 0.55)
			_core.position = Vector2(1.5, 0.0)
		"frost":
			# Кристалл с холодным белым ядром — отдельный визуальный язык.
			_ball.polygon = PackedVector2Array([
				Vector2(0, -7), Vector2(3, -2), Vector2(2, 2),
				Vector2(0, 6), Vector2(-2, 2), Vector2(-3, -2),
			])
			_ball.color = Color(0.48, 0.86, 1.0)
			_core = Polygon2D.new()
			_core.polygon = _circle_pts(1.5)
			_core.color = Color(0.9, 1.0, 1.0)
		_:
			_ball.polygon = _circle_pts(6.5 if kind == "lob" else 4.5)
			_ball.color = color
	add_child(_ball)
	if _core != null:
		add_child(_core)
	# Хвост — разный вес по типу выстрела; top_level сохраняет мировые точки.
	_trail = Line2D.new()
	_trail.width = 5.0 if kind == "flame" else (3.0 if kind == "frost" else 2.0)
	_trail.top_level = true
	_trail.default_color = Color(color, 0.7 if kind == "flame" else 0.55)
	_trail.z_index = 5
	add_child(_trail)


## Обновление хвоста: храним последние TRAIL_POINTS мировых позиций.
func _update_trail() -> void:
	var pts := _trail.points
	pts.append(global_position)
	if pts.size() > TRAIL_POINTS:
		pts = pts.slice(pts.size() - TRAIL_POINTS)
	_trail.points = pts


func _process(delta: float) -> void:
	if kind != "lob" and (target == null or not is_instance_valid(target) or target.is_dead):
		queue_free()   # управляемые крио/огонь теряют цель, артиллерия летит до точки
		return
	var destination := _destination if kind == "lob" else target.global_position
	var to_target := destination - global_position
	var step := speed * delta
	_traveled += minf(step, to_target.length())
	if to_target.length() <= step:
		global_position = destination
		if kind == "lob":
			_ball.position.y = 0.0
		_impact()
		return
	global_position += to_target.normalized() * step
	rotation = to_target.angle()
	_update_trail()
	if kind == "flame":
		var flicker := 0.14 * sin(float(Time.get_ticks_msec()) * 0.045 + _traveled * 0.1)
		_ball.scale = Vector2(1.0 + flicker, 1.0 - flicker * 0.55)
	elif kind == "frost":
		_ball.rotation = sin(float(Time.get_ticks_msec()) * 0.006) * 0.18
	if kind == "lob":
		# Дуга — только высота рисунка; тень остаётся на плоскости карты.
		var t := clampf(_traveled / _total_distance, 0.0, 1.0)
		_ball.position.y = -sin(PI * t) * ARC_HEIGHT


func _impact() -> void:
	# Урон/статусы/эффекты засчитывает только сервер — он арбитр боя.
	if multiplayer.is_server():
		match kind:
			"lob":
				_impact_splash()
			"flame":
				_impact_flame()
			"frost":
				_impact_frost()
			_:
				target.take_damage(damage, FXManager.DMG_NORMAL, damage_type)
	queue_free()


## Взрыв мортиры: урон всем юнитам в радиусе (100% в центре, 50% на краю).
func _impact_splash() -> void:
	FXManager.splash.rpc(global_position, splash_radius)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_dead:
			continue
		if not hits_flying and bool(unit.stats.get("flying", false)):
			continue
		var dist := global_position.distance_to(unit.global_position) - unit.get_radius()
		if dist <= splash_radius:
			# Спад урона берём из базы баланса (100% в центре -> 50% на краю).
			var falloff := 1.0 - (1.0 - splash_falloff_min) * clampf(dist / splash_radius, 0.0, 1.0)
			unit.take_damage(damage * falloff, FXManager.DMG_SPLASH, damage_type)


## Попадание струи огнемёта: прямое попадание + ожог соседей вплотную.
## Радиус маленький (45 px из GameDB), поэтому это не «вторая мортира».
## ЭТАП 8: струя достаёт и воздух (hits_flying = can_target_flying), но
## ожог соседей по воздуху идёт с тем же малым радиусом.
func _impact_flame() -> void:
	if target == null or not is_instance_valid(target):
		return
	var impact := target.global_position
	target.take_damage(damage, FXManager.DMG_NORMAL, damage_type)
	if splash_radius <= 0.0:
		return
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_dead or unit == target:
			continue
		if not hits_flying and bool(unit.stats.get("flying", false)):
			continue
		var dist := impact.distance_to(unit.global_position) - unit.get_radius()
		if dist <= splash_radius:
			var falloff := 1.0 - (1.0 - splash_falloff_min) \
					* clampf(dist / splash_radius, 0.0, 1.0)
			unit.take_damage(damage * falloff, FXManager.DMG_SPLASH, damage_type)


## Попадание криостана: урон + замедление (летающим — только урон).
func _impact_frost() -> void:
	FXManager.frost_pulse.rpc(global_position, pulse_radius)
	target.take_damage(damage, FXManager.DMG_FROST, damage_type)
	target._apply_slow(slow_percent, slow_duration)


## Точки заполненного N-угольника радиуса r (тело/тень снаряда).
func _circle_pts(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts
