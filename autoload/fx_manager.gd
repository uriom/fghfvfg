extends Node
## Автозагрузка «FXManager»: весь визуальный фидбек (game juice).
##
## СЕТЕВАЯ МОДЕЛЬ: каждый эффект — это RPC-метод «authority + call_local».
## Вызывать их может только сервер (владелец узла): он проводит урон/смерть
## и тут же запускает эффект (call_local выполняет его у себя), клиент
## получает картинку по сети. Клиент НИКОГДА не вызывает эффекты сам —
## валидация остаётся на сервере, а у обоих игроков эффекты совпадают.
##
## Использование с сервера: FXManager.unit_died.rpc(pos, color, flying)

# Виды цифр урона (для damage_number).
const DMG_NORMAL := 0     # обычный выстрел — жёлто-белый
const DMG_SPLASH := 1     # сплеш мортиры — оранжевый, крупнее
const DMG_FROST := 2      # урон криостана — голубой
const DMG_PROTECTED := 3  # урон сквозь ауру танка — серый, с пометкой
const DMG_IMMUNE := 4     # «ИММУН» — замедление не взяло

const SHAKE_TIME := 0.4
const NUMBER_LIFETIME := 0.7
const SPLASH_TEXTURE := preload("res://assets/img/splash boom.png")
const FROST_TEXTURE := preload("res://assets/img/frost boom.png")
const TESLA_TEXTURE := preload("res://assets/img/tesla boom.png")

var _world: Node2D            # эффекты в мировых координатах (лучи, взрывы)
var _overlay: CanvasLayer     # слой поверх всего: цифры урона, красная пелена
var _flash: ColorRect         # вспышка при уроне базе
var _shake_tween: Tween


func _ready() -> void:
	_world = Node2D.new()
	_world.name = "WorldFX"
	# Автолоады рисуются раньше текущей сцены — поднимаем Z, чтобы лечь поверх.
	_world.z_index = 60
	add_child(_world)
	_overlay = CanvasLayer.new()
	_overlay.layer = 10
	add_child(_overlay)
	_flash = ColorRect.new()
	_flash.color = Color(1.0, 0.15, 0.1, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(_flash)


# -------------------------------------------------------- RPC-эффекты -------

## Выплывающая цифра урона над юнитом.
@rpc("authority", "call_local", "unreliable")
func damage_number(world_pos: Vector2, amount: float, kind: int) -> void:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 18 if kind == DMG_SPLASH else 15)
	match kind:
		DMG_SPLASH:
			label.text = "-%d" % int(round(amount))
			label.add_theme_color_override("font_color", Color(1.0, 0.62, 0.2))
		DMG_FROST:
			label.text = "-%d" % int(round(amount))
			label.add_theme_color_override("font_color", Color(0.55, 0.9, 1.0))
		DMG_PROTECTED:
			label.text = "-%d (щит)" % int(round(amount))
			label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.85))
		DMG_IMMUNE:
			label.text = "ИММУН"
			label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
		_:
			label.text = "-%d" % int(round(amount))
			label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.75))
	# Переводим мировую точку в координаты оверлея (учитывает камеру/тряску).
	label.position = get_viewport().get_canvas_transform() * world_pos
	label.position += Vector2(randf_range(-8.0, 8.0), randf_range(-16.0, -6.0))
	_overlay.add_child(label)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 32.0, NUMBER_LIFETIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, NUMBER_LIFETIME * 0.6) \
			.set_delay(NUMBER_LIFETIME * 0.4)
	tween.chain().tween_callback(label.queue_free)


## Смерть юнита: кольцо + разлёт «искр» (вверх, если летающий).
@rpc("authority", "call_local", "reliable")
func unit_died(world_pos: Vector2, color: Color, flying: bool) -> void:
	AudioManager.play_sfx("unit_die")
	var burst := _make_burst(color, 24.0, false, 7)
	burst.position = world_pos
	_world.add_child(burst)
	_animate_burst(burst, 1.5, 0.45, Vector2.UP * (26.0 if flying else 0.0))


## Взрыв мортиры: большое кольцо + заливка площади поражения.
@rpc("authority", "call_local", "reliable")
func splash(world_pos: Vector2, radius: float) -> void:
	AudioManager.play_sfx("boom")
	_texture_burst(world_pos, SPLASH_TEXTURE, radius * 2.0, Color.WHITE, 0.48)
	var burst := _make_burst(Color(1.0, 0.6, 0.25), radius, false, 0)
	burst.position = world_pos
	_world.add_child(burst)
	_animate_burst(burst, 1.15, 0.4, Vector2.ZERO)


## Импульс криостана: голубое кольцо (визуализация зоны замедления).
@rpc("authority", "call_local", "unreliable")
func frost_pulse(world_pos: Vector2, radius: float) -> void:
	AudioManager.play_sfx("frost")
	_texture_burst(world_pos, FROST_TEXTURE, radius * 2.0, Color(0.82, 0.96, 1.0), 0.52)
	var burst := _make_burst(Color(0.55, 0.85, 1.0), radius, true, 0)
	burst.position = world_pos
	_world.add_child(burst)
	_animate_burst(burst, 1.1, 0.35, Vector2.ZERO)


## Выстрел снайпера: мгновенный луч + искра в точке попадания.
@rpc("authority", "call_local", "unreliable")
func beam(from: Vector2, to: Vector2, color: Color) -> void:
	AudioManager.play_sfx("beam")
	var line := Line2D.new()
	line.points = PackedVector2Array([from, to])
	line.width = 5.0
	line.default_color = Color(color).lightened(0.4)
	line.z_index = 61
	_world.add_child(line)
	var hit := _make_burst(color, 12.0, false, 4)
	hit.position = to
	_world.add_child(hit)
	_animate_burst(hit, 1.4, 0.25, Vector2.ZERO)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(line, "width", 0.0, 0.14)
	tween.tween_property(line, "modulate:a", 0.0, 0.14)
	tween.chain().tween_callback(line.queue_free)


## Цепная молния Теслы: использует отдельную текстуру разряда на каждом звене.
@rpc("authority", "call_local", "unreliable")
func chain(points: PackedVector2Array, color: Color) -> void:
	AudioManager.play_sfx("beam", -4.0, 1.3)
	if points.size() < 2:
		return
	var texture_size := Vector2(TESLA_TEXTURE.get_size())
	for i in range(points.size() - 1):
		var start := points[i]
		var finish := points[i + 1]
		var segment := finish - start
		var bolt := Sprite2D.new()
		bolt.texture = TESLA_TEXTURE
		bolt.position = (start + finish) * 0.5
		bolt.rotation = segment.angle()
		bolt.scale = Vector2(segment.length() / texture_size.x, 13.0 / texture_size.y)
		bolt.modulate = Color(color).lightened(0.35)
		bolt.z_index = 61
		_world.add_child(bolt)
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(bolt, "scale:y", 0.001, 0.16)
		tween.tween_property(bolt, "modulate:a", 0.0, 0.16)
		tween.chain().tween_callback(bolt.queue_free)
	var hit := _make_burst(color, 10.0, false, 3)
	hit.position = points[points.size() - 1]
	_world.add_child(hit)
	_animate_burst(hit, 1.3, 0.2, Vector2.ZERO)


## Урон базе: тряска камеры + красная пелена по краям экрана.
@rpc("authority", "call_local", "reliable")
func base_hit() -> void:
	AudioManager.play_sfx("base_hit", -3.0)
	_shake_camera(14.0)
	_flash.color.a = 0.32
	var tween := create_tween()
	tween.tween_property(_flash, "color:a", 0.0, 0.45)


# ---------------------------------------------------------- Внутреннее ------

## Всплывающий круг/кольцо с искрами; анимируем scale/modulate извне.
class FxBurst:
	extends Node2D
	var color := Color.WHITE
	var radius := 20.0
	var ring_only := false
	var sparks := 0

	func _draw() -> void:
		if not ring_only:
			draw_circle(Vector2.ZERO, radius, Color(color, 0.35))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(color, 0.95), 3.0)
		for i in sparks:
			var ang := TAU * float(i) / float(sparks) + randf() * 0.35
			var dir := Vector2.from_angle(ang)
			draw_line(dir * radius * 0.55, dir * radius * 1.15, Color(color, 0.85), 2.0)


## Короткий арт-слой на попадании: используем подготовленный PNG-взрыв,
## подгоняем по диаметру зоны и плавно рассеиваем поверх геометрического кольца.
func _texture_burst(world_pos: Vector2, texture: Texture2D, diameter: float,
		tint: Color, lifetime: float) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.position = world_pos
	sprite.z_index = 63
	sprite.modulate = tint
	var max_side := maxf(float(texture.get_width()), float(texture.get_height()))
	var fit := diameter / maxf(max_side, 1.0)
	sprite.scale = Vector2.ONE * fit * 0.42
	_world.add_child(sprite)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE * fit, lifetime) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "modulate:a", 0.0, lifetime)
	tween.chain().tween_callback(sprite.queue_free)


func _make_burst(color: Color, radius: float, ring_only: bool, sparks: int) -> FxBurst:
	var burst := FxBurst.new()
	burst.color = color
	burst.radius = radius
	burst.ring_only = ring_only
	burst.sparks = sparks
	burst.z_index = 62
	return burst


func _animate_burst(burst: FxBurst, scale_to: float, life: float, drift: Vector2) -> void:
	burst.scale = Vector2(0.35, 0.35)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(burst, "scale", Vector2.ONE * scale_to, life) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(burst, "modulate:a", 0.0, life)
	if drift != Vector2.ZERO:
		tween.tween_property(burst, "position", burst.position + drift, life)
	tween.chain().tween_callback(burst.queue_free)


## Тряска камеры: серия случайных смещений с затуханием (через offset,
## поэтому якорь камеры не сбивается).
func _shake_camera(strength: float) -> void:
	var cameras := get_tree().get_nodes_in_group("game_camera")
	if cameras.is_empty():
		return
	var cam := cameras[0] as Camera2D
	if cam == null:
		return
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	cam.offset = Vector2.ZERO
	_shake_tween = create_tween()
	_shake_tween.tween_method(_shake_step.bind(cam, strength), 0.0, 1.0, SHAKE_TIME)
	_shake_tween.finished.connect(func() -> void: cam.offset = Vector2.ZERO)


func _shake_step(t: float, cam: Camera2D, strength: float) -> void:
	# t: 0 -> 1; амплитуда падает к нулю к концу тряски.
	cam.offset = Vector2.from_angle(randf() * TAU) * strength * (1.0 - t)
