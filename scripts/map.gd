class_name GameMap
extends Node2D
## Сетка карты и строительство башен Защитником.
##
## Сетка чисто логическая (cell_size): узел может висеть на простом Node2D,
## а может лежать на TileMapLayer — тогда следите, чтобы cell_size совпадал
## с размером тайла, и вся математика ниже останется верной.
##
## Клетка пригодна для постройки, если:
##   1) её центр внутри buildable_rect;
##   2) центр клетки не ближе road_half_width к дороге (не строим на трассе);
##   3) клетка ещё не занята башней (словарь occupied).
##
## ЭТАП 7: лимитов «2 на тип / 8 всего» больше нет. Ширина обороны ограничена
## только клетками и кредитами, а «высота» — уровнями башен (1..10): клик по
## уже построенной башне покупает ей следующий уровень.
##
## Вариант с TileSet: создайте в TileSet слой Custom Data «buildable» (bool),
## проставьте его нужным тайлам и замените is_cell_buildable() на:
##   var td := get_cell_tile_data(cell)      # если скрипт на TileMapLayer
##   return td != null and td.get_custom_data("buildable")

const TOWER_SCENE := preload("res://scenes/towers/tower.tscn")
const HOVER_INVALID := Vector2i(-9999, -9999)
const RANGE_SEGMENTS := 96          # 96 точек — визуально идеальная окружность

@export var cell_size := Vector2i(48, 48)
@export var buildable_rect := Rect2(0, 96, 1152, 288)  # шесть ровных рядов клеток
@export var road_node_path: NodePath                  # Path2D с дорогой
@export var road_half_width := 27.0                   # одна полоса дороги = один ряд клеток

## true — этот клиент Защитник: включает мышь, подсветку клетки и запросы.
var active := false
var occupied: Dictionary = {}    # Vector2i -> true (клетки с башнями)
## Тип башни, выбранный в HUD. Дефолт — первый из дека Защитника этого
## матча (GameDB.TOWER_ORDER — только запасной вариант для старых сейвов).
var build_tower_id: String = GameDB.TOWER_ORDER[0]
## Клавиатурный/геймпадный курсор постройки. HOVER_INVALID = игрок ещё не
## пользовался крестовиной, мышь остаётся главным устройством.
var _keys_cell := Vector2i(-1, -1)
var _keys_mode := false

var _road_points := PackedVector2Array()
var _hover_cell := HOVER_INVALID
var _grid_root: Node2D
var _hover_rect: Line2D
## Подпись у курсора: «СНАЙПЕР · УР 3 → 4 · 33 кр.» — чтобы апгрейд был
## обнаруживаемым без чтения документации.
var _hover_info: Label

# --- Тактический предпросмотр радиуса (HUD Защитника) ----------------------
# Собирается лениво из стандартных нод: Polygon2D-заливка + три Line2D-кольца.
# z_index = 1: поверх дороги, но под башнями (tower.tscn z_index = 3).
var _range_root: Node2D
var _range_fill: Polygon2D
var _range_glow: Line2D
var _range_ring: Line2D
var _range_inner: Line2D
var _range_pop: Tween
var _range_pulse: Tween
var _preview_tower_id := ""
var _last_preview_cell := Vector2i(12, 4)  # центральная клетка поля для предпросмотра


func _ready() -> void:
	# Готовим спавнер башен: spawn_function нужна на обоих пирах.
	$TowerSpawner.spawn_function = _spawn_tower
	# Запекаем точки дороги один раз — для проверки «не на дороге».
	if not road_node_path.is_empty():
		var road := get_node_or_null(road_node_path)
		if road is Path2D:
			_road_points = road.curve.get_baked_points()


## Дефолтная башня для кликов — первая из дека Защитника этого матча.
## Вызывает game.gd ПОСЛЕ GameState.setup_match (деки приходят из лобби).
func apply_match_deck() -> void:
	if not GameState.defender_towers.is_empty():
		build_tower_id = GameState.defender_towers[0]


# ----------------------------------------------------------- Управление -----

## Строительная сетка из Line2D + подсветка клетки. Правило проекта:
# никакого _draw — создаются стандартные ноды один раз и переключаются
# visible / points / color.

func set_active(value: bool) -> void:
	active = value
	_ensure_grid_nodes()
	_grid_root.visible = value
	_hover_rect.visible = value and _hover_cell != HOVER_INVALID
	# Атакующему радиусы не показываем; Защитнику — только если карточка
	# уже выбрана/наведена (иначе id пуст).
	if _range_root != null:
		_range_root.visible = value and _preview_tower_id != ""
		if _range_root.visible:
			_update_range_preview_position()


## Вызывается из defender_hud.gd при выборе башни.
func set_build_tower_id(tower_id: String) -> void:
	build_tower_id = tower_id


# -------------------------------------------------- Тактический радиус ------

## HUD: показать кольцо радиуса башни на земле. Радиус берём из GameDB,
## поэтому карточка и реальная башня всегда согласованы.
func show_range_preview(tower_id: String) -> void:
	if not GameDB.TOWERS.has(tower_id):
		return
	_ensure_range_nodes()

	var needs_rebuild := _preview_tower_id != tower_id
	_preview_tower_id = tower_id

	if needs_rebuild:
		var radius := float(GameDB.TOWERS[tower_id]["range"])
		var outer := _circle_points(radius)
		_range_fill.polygon = outer
		_range_glow.points = outer
		_range_ring.points = outer
		# Второе, чуть меньшее кольцо — «энергетический контур» двойной обводки.
		_range_inner.points = _circle_points(maxf(radius - 3.0, 1.0))

	_range_root.visible = active
	_update_range_preview_position()
	if needs_rebuild or _range_root.modulate.a <= 0.01:
		_pop_range_preview()


## HUD: убрать предпросмотр (нет выбранной башни / матч окончен).
func hide_range_preview() -> void:
	_preview_tower_id = ""
	if _range_root != null:
		_range_root.visible = false
	if _range_pop != null and _range_pop.is_valid():
		_range_pop.kill()
	if _range_pulse != null and _range_pulse.is_valid():
		_range_pulse.kill()
	if _range_root != null:
		_range_root.scale = Vector2.ONE
		_range_root.modulate.a = 1.0


## Кольцо следует за клеткой под курсором; если курсор ушёл в HUD или за
## пределы карты — остаётся на последней осмысленной клетке.
func _update_range_preview_position() -> void:
	if _range_root == null or not active or _preview_tower_id == "":
		return
	var cell := _hover_cell
	if cell == HOVER_INVALID or not buildable_rect.has_point(cell_to_center(cell)):
		cell = _last_preview_cell
	else:
		_last_preview_cell = cell
	_range_root.position = cell_to_center(cell)


## Ленивая сборка нод предпросмотра (правило проекта: никакого _draw).
func _ensure_range_nodes() -> void:
	if _range_root != null:
		return
	_range_root = Node2D.new()
	_range_root.name = "RangePreview"
	_range_root.z_index = 1
	_range_root.visible = false
	add_child(_range_root)

	_range_fill = Polygon2D.new()
	_range_fill.color = Color(1, 1, 1, 0.035)
	_range_root.add_child(_range_fill)

	# Широкое едва заметное свечение + тонкое основное кольцо.
	_range_glow = Line2D.new()
	_range_glow.width = 8.0
	_range_glow.closed = true
	_range_glow.antialiased = true
	_range_glow.default_color = Color(1, 1, 1, 0.06)
	_range_root.add_child(_range_glow)

	_range_ring = Line2D.new()
	_range_ring.width = 2.0
	_range_ring.closed = true
	_range_ring.antialiased = true
	_range_ring.default_color = Color(1, 1, 1, 0.55)
	_range_root.add_child(_range_ring)

	_range_inner = Line2D.new()
	_range_inner.width = 1.0
	_range_inner.closed = true
	_range_inner.antialiased = true
	_range_inner.default_color = Color(1, 1, 1, 0.16)
	_range_root.add_child(_range_inner)


## Появление: короткий scale-всплеск + мягкое дыхание кольца.
func _pop_range_preview() -> void:
	if _range_pop != null and _range_pop.is_valid():
		_range_pop.kill()
	if _range_pulse != null and _range_pulse.is_valid():
		_range_pulse.kill()

	_range_root.modulate.a = 0.0
	_range_root.scale = Vector2(0.965, 0.965)

	_range_pop = create_tween()
	_range_pop.set_parallel(true)
	_range_pop.tween_property(_range_root, "modulate:a", 1.0, 0.16)
	_range_pop.tween_property(_range_root, "scale", Vector2.ONE, 0.24) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	_range_pulse = create_tween().set_loops()
	_range_pulse.tween_interval(0.55)
	_range_pulse.tween_property(_range_root, "scale", Vector2(1.012, 1.012), 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_range_pulse.tween_property(_range_root, "scale", Vector2.ONE, 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _circle_points(radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in RANGE_SEGMENTS:
		var angle := TAU * float(i) / float(RANGE_SEGMENTS)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion:
		# Мышь перехватывает управление обратно — так игрок не «теряет» курсор.
		_keys_mode = false
		var new_cell := world_to_cell(get_global_mouse_position())
		if new_cell != _hover_cell:
			_hover_cell = new_cell
			_update_hover_rect()
			_update_range_preview_position()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_keys_mode = false
		_hover_cell = world_to_cell(get_global_mouse_position())
		_update_hover_rect()
		_request_build(_hover_cell)


## Клавиатура и геймпад: крестовина двигает курсор по клеткам, A/Enter
## строит, B/Esc отменяет. Вызывается ДО GUI (_input), чтобы фокус на
## карточке башни не съедал подтверждение.
func _input(event: InputEvent) -> void:
	if not active or not GameState.is_planning():
		return
	if not (event is InputEventKey or event is InputEventJoypadButton \
			or event is InputEventJoypadMotion):
		return
	var step := Vector2i.ZERO
	if event.is_action_pressed("ui_left"):
		step = Vector2i.LEFT
	elif event.is_action_pressed("ui_right"):
		step = Vector2i.RIGHT
	elif event.is_action_pressed("ui_up"):
		step = Vector2i.UP
	elif event.is_action_pressed("ui_down"):
		step = Vector2i.DOWN
	if step != Vector2i.ZERO:
		_move_keys_cursor(step)
		get_viewport().set_input_as_handled()
	elif _keys_mode and event.is_action_pressed("ui_accept"):
		_request_build(_keys_cell)
		get_viewport().set_input_as_handled()
	elif _keys_mode and event.is_action_pressed("ui_cancel"):
		_keys_mode = false
		_hover_cell = HOVER_INVALID
		_update_hover_rect()
		get_viewport().set_input_as_handled()


## Стартовая позиция курсора — центр зоны строительства.
func _move_keys_cursor(step: Vector2i) -> void:
	if not _keys_mode:
		_keys_mode = true
		var start := Vector2i(buildable_rect.position) / cell_size
		var end := Vector2i(buildable_rect.end) / cell_size
		_keys_cell = Vector2i((start.x + end.x) / 2, (start.y + end.y) / 2)
	var rect := Rect2(Vector2(buildable_rect.position), Vector2(buildable_rect.size))
	var candidate := _keys_cell + step
	var centre := cell_to_center(candidate)
	# Курсор не выходит за зону строительства: край — жёсткая граница.
	if rect.has_point(centre):
		_keys_cell = candidate
	if _keys_cell != _hover_cell:
		_hover_cell = _keys_cell
		_last_preview_cell = _hover_cell
		_update_hover_rect()
		_update_range_preview_position()


# --------------------------------------------------------------- Сетка ------

func world_to_cell(world_pos: Vector2) -> Vector2i:
	var local := to_local(world_pos)
	return Vector2i(int(floor(local.x / cell_size.x)), int(floor(local.y / cell_size.y)))


func cell_to_center(cell: Vector2i) -> Vector2:
	return Vector2(cell) * Vector2(cell_size) + Vector2(cell_size) * 0.5


# ------------------------------------------------------ Постройка башен -----

## Локальный Защитник кликнул по клетке: просим сервер подтвердить постройку.
## Все причины отказа проговариваются игроку (звук + подпись у клетки):
## раньше клик по занятой клетке или без денег просто ничего не делал.
func _request_build(cell: Vector2i) -> void:
	# Клик по своей башне — покупка следующего уровня (в любой фазе).
	if occupied.has(cell):
		_request_upgrade(cell)
		return
	if not GameState.is_planning():
		_deny_build(cell, "ТОЛЬКО В ПОДГОТОВКЕ")
		return
	if not is_cell_buildable(cell):
		_deny_build(cell, "ЗДЕСЬ НЕЛЬЗЯ")
		return
	var cost := int(GameDB.TOWERS[build_tower_id]["cost"])
	var gold := int(GameState.gold.get(multiplayer.get_unique_id(), 0))
	if gold < cost:
		_deny_build(cell, "НЕ ХВАТАЕТ %d" % (cost - gold))
		return
	if multiplayer.is_server():
		# Хост и есть Защитник, а RPC на самого себя не доставляется
		# (call_remote). Поэтому валидируем локально — тем же кодом,
		# что и для клиента-защитника, если роли когда-нибудь поменяются.
		_server_place_tower(GameState.defender_peer, cell, build_tower_id)
	else:
		place_tower_request.rpc_id(1, cell, build_tower_id)   # 1 = сервер (хост)


## Клик по построенной башне: купить следующий уровень. Сервер проверяет
## цену и «не максимум»; клиент заранее объясняет отказ.
func _request_upgrade(cell: Vector2i) -> void:
	var tower := tower_at(cell)
	if tower == null:
		_deny_build(cell, "ЗДЕСЬ НЕЛЬЗЯ")
		return
	if tower.is_max_level():
		_deny_build(cell, "МАКС. УРОВЕНЬ %d" % GameDB.TOWER_MAX_LEVEL)
		return
	var cost := tower.upgrade_cost()
	var gold := int(GameState.gold.get(multiplayer.get_unique_id(), 0))
	if gold < cost:
		_deny_build(cell, "НЕ ХВАТАЕТ %d" % (cost - gold))
		return
	if multiplayer.is_server():
		_server_upgrade_tower(GameState.defender_peer, cell)
	else:
		upgrade_tower_request.rpc_id(1, cell)


## СЕРВЕР: запрос апгрейда от защитника-клиента.
@rpc("any_peer", "call_remote", "reliable")
func upgrade_tower_request(cell: Vector2i) -> void:
	if not multiplayer.is_server():
		return
	_server_upgrade_tower(multiplayer.get_remote_sender_id(), cell)


func _server_upgrade_tower(sender: int, cell: Vector2i) -> void:
	if GameState.game_over or sender != GameState.defender_peer:
		return
	var tower := tower_at(cell)
	if tower == null or tower.is_max_level():
		return
	var cost := tower.upgrade_cost()
	if not GameState.try_spend(sender, cost):
		return
	GameState.record_tower_upgrade()
	AudioManager.play_sfx("build", -3.0, 1.15)
	tower.sync_level.rpc(tower.level + 1)


## Башня в клетке (null, если пусто).
func tower_at(cell: Vector2i) -> Tower:
	for node in $Towers.get_children():
		if node is Tower and (node as Tower).cell == cell:
			return node as Tower
	return null


## Отказ с обратной связью: звук + всплывающая подпись над клеткой.
func _deny_build(cell: Vector2i, reason: String) -> void:
	AudioManager.play_sfx("deny", -6.0)
	FXManager.hint(cell_to_center(cell), reason, Color(1.0, 0.45, 0.45))


## Сколько башен указанного типа уже стоит.
func tower_count(tower_id: String) -> int:
	var count := 0
	for tower in $Towers.get_children():
		if tower is Tower and (tower as Tower).tower_id == tower_id:
			count += 1
	return count


## Всего построено башен (лимита нет — счётчик для HUD и статистики).
func total_towers() -> int:
	return $Towers.get_child_count()


func is_cell_buildable(cell: Vector2i) -> bool:
	var center := cell_to_center(cell)
	if not buildable_rect.has_point(center):
		return false
	return _distance_to_road(center) >= road_half_width


func _distance_to_road(point: Vector2) -> float:
	if _road_points.is_empty():
		return INF
	var best := INF
	for i in range(_road_points.size() - 1):
		var start := _road_points[i]
		var segment := _road_points[i + 1] - start
		var length_squared := segment.length_squared()
		if length_squared <= 0.0001:
			best = minf(best, point.distance_to(start))
			continue
		var along := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
		best = minf(best, point.distance_to(start + segment * along))
	return best


## СЕРВЕР: запрос постройки от защитника-клиента.
@rpc("any_peer", "call_remote", "reliable")
func place_tower_request(cell: Vector2i, tower_id: String) -> void:
	if not multiplayer.is_server():
		return
	_server_place_tower(multiplayer.get_remote_sender_id(), cell, tower_id)


## Серверная валидация и проведение постройки. sender — peer, платящий золото.
## Строить можно только в ПОДГОТОВКЕ; лимитов на количество нет (ЭТАП 7).
func _server_place_tower(sender: int, cell: Vector2i, tower_id: String) -> void:
	if not _can_place_tower(sender, cell, tower_id):
		return
	# Списываем золото; при неудаче (мало денег) постройка отменяется.
	if not GameState.try_spend(sender, GameDB.TOWERS[tower_id]["cost"]):
		return
	GameState.record_tower_built()   # статистика + ачивка MASTER_BUILDER
	_confirm_tower.rpc(cell, tower_id, sender)


## Все правила постройки в одном месте (роль, дек, фаза, лимиты, клетка).
func _can_place_tower(sender: int, cell: Vector2i, tower_id: String) -> bool:
	if GameState.game_over or not GameState.is_planning():
		return false
	# Строить разрешено только Защитнику, и только из своего дека.
	if sender != GameState.defender_peer or not GameDB.TOWERS.has(tower_id):
		return false
	if not GameState.defender_towers.has(tower_id):
		return false   # башни вне дека этого матча запрещены (анти-чит)
	return not occupied.has(cell) and is_cell_buildable(cell)


## Подтверждённая постройка: выполняется на ОБОИХ пирах (call_local).
@rpc("authority", "call_local", "reliable")
func _confirm_tower(cell: Vector2i, tower_id: String, owner_peer: int) -> void:
	occupied[cell] = true
	AudioManager.play_sfx("build")   # синхронная точка: звук у обоих игроков
	if multiplayer.is_server():
		# Клиент получит башню автоматически через MultiplayerSpawner.
		$TowerSpawner.spawn({"cell": cell, "tower_id": tower_id,
				"owner": owner_peer, "level": 1})


## Вызывается MultiplayerSpawner на всех пирах при спавне башни.
func _spawn_tower(data: Dictionary) -> Node:
	var tower: Tower = TOWER_SCENE.instantiate()
	tower.setup(data["tower_id"], data["owner"], data["cell"],
			cell_to_center(data["cell"]), int(data.get("level", 1)))
	return tower


# ---------------------------------------------------------------- Рисуем ----
# Сетка и подсветка — стандартные ноды (Line2D), собранные лениво один раз.

## Один раз создаёт ноды сетки (вертикальные + горизонтальные Line2D)
## и квадрат подсветки курсора (замкнутый Line2D из 4 углов клетки).
func _ensure_grid_nodes() -> void:
	if _grid_root != null:
		return
	_grid_root = Node2D.new()
	_grid_root.name = "BuildGrid"
	_grid_root.visible = false
	add_child(_grid_root)
	var grid_color := Color(0.36, 0.72, 0.88, 0.14)
	var start := Vector2i(buildable_rect.position) / cell_size
	var end := Vector2i(buildable_rect.end) / cell_size
	for x in range(start.x, end.x + 1):
		var line := Line2D.new()
		line.width = 1.0
		line.default_color = grid_color
		line.points = PackedVector2Array([
			Vector2(float(x) * cell_size.x, buildable_rect.position.y),
			Vector2(float(x) * cell_size.x, buildable_rect.end.y),
		])
		_grid_root.add_child(line)
	for y in range(start.y, end.y + 1):
		var line := Line2D.new()
		line.width = 1.0
		line.default_color = grid_color
		line.points = PackedVector2Array([
			Vector2(buildable_rect.position.x, float(y) * cell_size.y),
			Vector2(buildable_rect.end.x, float(y) * cell_size.y),
		])
		_grid_root.add_child(line)
	# Квадрат по границе клетки под курсором: 5 точек (замкнутый контур).
	_hover_rect = Line2D.new()
	_hover_rect.width = 2.0
	_hover_rect.closed = true
	_hover_rect.visible = false
	_grid_root.add_child(_hover_rect)

	_hover_info = Label.new()
	_hover_info.name = "UpgradeHint"
	_hover_info.add_theme_font_size_override("font_size", 11)
	_hover_info.add_theme_color_override("font_outline_color", Color(0, 0.02, 0.05, 0.95))
	_hover_info.add_theme_constant_override("outline_size", 5)
	_hover_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hover_info.size = Vector2(220.0, 16.0)
	_hover_info.visible = false
	_hover_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_root.add_child(_hover_info)


## Подпись апгрейда у занятой клетки: имя, текущий уровень, цена, хватает ли
## кредитов. Обновляется вместе с квадратом подсветки.
func _update_hover_info() -> void:
	if _hover_info == null:
		return
	if _hover_cell == HOVER_INVALID or not active or not GameState.is_planning():
		_hover_info.visible = false
		return
	var tower := tower_at(_hover_cell)
	if tower == null:
		_hover_info.visible = false
		return
	var name := String(GameDB.TOWERS[tower.tower_id]["name"]).to_upper()
	if tower.is_max_level():
		_hover_info.text = "%s · УР %d (МАКС)" % [name, tower.level]
		_hover_info.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	else:
		var cost := tower.upgrade_cost()
		var gold := int(GameState.gold.get(multiplayer.get_unique_id(), 0))
		var enough := gold >= cost
		_hover_info.text = "%s · УР %d → %d · %d кр." % [
			name, tower.level, tower.level + 1, cost]
		_hover_info.add_theme_color_override("font_color",
				Color(0.55, 1.0, 0.65) if enough else Color(1.0, 0.55, 0.55))
	var centre := cell_to_center(_hover_cell)
	_hover_info.position = centre + Vector2(-110.0, -40.0)
	_hover_info.visible = true


## Переставляет квадрат подсветки под _hover_cell и красит его: зелёный —
## строить можно, красный — нельзя.
func _update_hover_rect() -> void:
	if _grid_root == null:
		return
	if _hover_cell == HOVER_INVALID or not active:
		_hover_rect.visible = false
		return
	# В штурме строить нельзя — сетка гаснет, чтобы не обещать обратное.
	if not GameState.is_planning():
		_hover_rect.visible = false
		return
	var rect := Rect2(Vector2(_hover_cell) * Vector2(cell_size), Vector2(cell_size))
	_hover_rect.points = PackedVector2Array([
		rect.position, rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size, rect.position + Vector2(0, rect.size.y),
	])
	var ok := is_cell_buildable(_hover_cell) and not occupied.has(_hover_cell)
	if occupied.has(_hover_cell):
		# Занятая клетка — это апгрейд, а не ошибка: подсветка синяя.
		var tower := tower_at(_hover_cell)
		ok = tower != null and not tower.is_max_level()
		_hover_rect.default_color = Color(0.3, 0.8, 1.0, 0.65) if ok \
				else Color(1.0, 0.25, 0.25, 0.4)
	else:
		_hover_rect.default_color = Color(0.3, 1.0, 0.3, 0.5) if ok \
				else Color(1.0, 0.25, 0.25, 0.5)
	_hover_rect.visible = true
	_update_hover_info()
