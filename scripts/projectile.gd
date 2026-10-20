class_name Projectile
extends Node2D
## Снаряд башни. Вид задаётся полем kind из GameDB.TOWERS:
##   "lob"    — мортира: навесной снаряд (косметическая дуга), при попадании
##              урон по площади с линейным спадом от центра к краю;
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
## Доля урона на краю сплеша (из GameDB, для мортиры = 0.5).
var splash_falloff_min := 0.5
var slow_percent := 0.0
var slow_duration := 0.0
var pulse_radius := 60.0
var color := Color(1, 1, 0.75)

var _total_distance := 1.0
var _traveled := 0.0

# Ноды визуала (создаются в _ready, см. шапку).
var _ball: Polygon2D
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
	pulse_radius = float(tower_stats.get("pulse_radius", pulse_radius))
	color = tower_stats["color"]
	_total_distance = maxf(from.distance_to(p_target.global_position), 1.0)
	z_index = 6


func _ready() -> void:
	_build_visual()


## Сборка визуала из стандартных нод (один раз, без _draw).
func _build_visual() -> void:
	# Тень: слегка смещена вниз, у мортиры остаётся на «земле» под дугой.
	_shadow = Polygon2D.new()
	_shadow.polygon = _circle_pts(4.0)
	_shadow.color = Color(0, 0, 0, 0.25)
	_shadow.position = Vector2(0, 2)
	add_child(_shadow)
	# Тело снаряда: у мортиры шар крупнее и поднимается по дуге в _process.
	_ball = Polygon2D.new()
	_ball.polygon = _circle_pts(6.5 if kind == "lob" else 4.5)
	_ball.color = color
	add_child(_ball)
	# Хвост: Line2D в мировых координатах (top_level игнорирует движение
	# родителя), дополняется в _process; след тянется за снарядом.
	_trail = Line2D.new()
	_trail.width = 2.0
	_trail.top_level = true
	_trail.default_color = Color(color, 0.55)
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
	if target == null or not is_instance_valid(target) or target.is_dead:
		queue_free()   # цель умерла или дошла до базы — снаряд не нужен
		return
	var to_target := target.global_position - global_position
	var step := speed * delta
	_traveled += minf(step, to_target.length())
	if to_target.length() <= step:
		_impact()
		return
	global_position += to_target.normalized() * step
	rotation = to_target.angle()   # ориентация хвоста по движению
	_update_trail()
	if kind == "lob":
		# Навесная траектория: тело летит «по дуге» (чистый визуал,
		# попадание считается по прямой между снарядом и целью).
		var t := clampf(_traveled / _total_distance, 0.0, 1.0)
		_ball.position.y = -sin(PI * t) * ARC_HEIGHT


func _impact() -> void:
	# Урон/статусы/эффекты засчитывает только сервер — он арбитр боя.
	if multiplayer.is_server():
		match kind:
			"lob":
				_impact_splash()
			"frost":
				_impact_frost()
			_:
				target.take_damage(damage)
	queue_free()


## Взрыв мортиры: урон всем юнитам в радиусе (100% в центре, 50% на краю).
func _impact_splash() -> void:
	FXManager.splash.rpc(global_position, splash_radius)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_dead:
			continue
		var dist := global_position.distance_to(unit.global_position) - unit.get_radius()
		if dist <= splash_radius:
			# Спад урона берём из базы баланса (100% в центре -> 50% на краю).
			var falloff := 1.0 - (1.0 - splash_falloff_min) * clampf(dist / splash_radius, 0.0, 1.0)
			unit.take_damage(damage * falloff, FXManager.DMG_SPLASH)


## Попадание криостана: урон + замедление (летающим — только урон).
func _impact_frost() -> void:
	FXManager.frost_pulse.rpc(global_position, pulse_radius)
	target.take_damage(damage, FXManager.DMG_FROST)
	target._apply_slow(slow_percent, slow_duration)


## Точки заполненного N-угольника радиуса r (тело/тень снаряда).
func _circle_pts(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts
