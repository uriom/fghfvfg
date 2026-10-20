extends Node
## End-to-end smoke-тест сетевого кода. Запускается в ДВУХ процессах:
##   godot --headless --path <проект> res://tools/smoke_test.tscn -- host
##   godot --headless --path <проект> res://tools/smoke_test.tscn -- join
##
## Проверяет: подключение, старт матча, постройку башни, заказ юнитов и волны,
## отказы по золоту, репликацию спавна, убийство башней и прорыв базы.

const GAME_SCENE := "res://scenes/game.tscn"
const DEADLINE_MS := 15000

var role := "host"
var _fail := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		role = args[0]
	# Тестовый узел — текущая сцена, а смена сцены удаляет current_scene.
	# Переносим указатель на пустышку, чтобы раннер пережил загрузку матча.
	var dummy := Node.new()
	dummy.name = "SceneSwapDummy"
	get_tree().root.add_child.call_deferred(dummy)
	_swap_and_run.call_deferred(dummy)


func _swap_and_run(dummy: Node) -> void:
	get_tree().current_scene = dummy
	_run()


func _run() -> void:
	# Страж: если тест завис — падаем по таймауту с кодом 2.
	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		print("[%s] GUARD TIMEOUT" % role)
		get_tree().quit(2))
	if role == "host":
		await _run_host()
	else:
		await _run_join()
	print("[%s] SMOKE_%s_DONE fail=%s" % [role, role.to_upper(), _fail])
	get_tree().quit(1 if _fail else 0)


# ------------------------------------------------------------------ ХОСТ ----

func _run_host() -> void:
	NetworkManager.lobby_message.connect(func(t: String) -> void:
		print("[host] MSG: %s" % t))
	NetworkManager.host_game("HostBot")
	await _wait(func() -> bool: return NetworkManager.players.size() >= 2,
			func() -> String: return "клиент подключился (%d в лобби)" % NetworkManager.players.size())
	NetworkManager.start_match()
	await _wait_game_scene()
	await _sleep(0.5)
	# ЭТАП 5: дек через лобби-RPC долетел до матча (серверная валидация
	# и HUD строятся из GameState.defender_towers).
	_check(GameState.defender_towers.size() == LoadoutManager.DECK_SIZE,
			"дек защитника в матче: %s" % ", ".join(GameState.defender_towers))

	# 1. Ждём юнитов от штурмовика-клиента ПЕРЕД постройкой башни:
	#    снайпер-луч убивает «бегунов» на подходе, и ждать 6 живых после
	#    постройки уже нельзя.
	await _wait(func() -> bool: return _unit_count() >= 6,
			func() -> String: return "6 юнитов заспавнились на сервере (получено %d)" % _unit_count())

	# 2. Защитник (хост) строит башню у дороги.
	var map: GameMap = get_tree().current_scene.get_node("Map")
	var cell := _cell_near_road(map)
	map._request_build(cell)
	await _sleep(0.5)
	_check(map.occupied.has(cell), "башня построена в %s" % cell)
	var gold_after_tower := GameState.START_GOLD + GameState.WAVE_STIPEND - 50
	_check(GameState.gold[GameState.defender_peer] == gold_after_tower,
			"золото защитника после постройки = %d" % GameState.gold[GameState.defender_peer])

	# 3. Даём клиенту завершить денежные проверки без наших телепортов.
	await _sleep(3.0)

	# 4. Проверка боя: жертву замираем у башни, остальных отправляем к базе —
	#    они быстро прорвутся и освободят дорогу: башня добьёт жертву.
	var units := get_tree().get_nodes_in_group("units")
	var victim: Unit = units[0]
	victim.set_process(false)
	victim.progress = _progress_near_tower(map, cell)
	var road_len := (victim.get_parent() as Path2D).curve.get_baked_length()
	for i in range(1, units.size()):
		(units[i] as Unit).progress = road_len - 5.0

	await _wait(func() -> bool: return GameState.base_hp < GameState.BASE_MAX_HP,
			func() -> String: return "прорыв: HP базы = %d" % GameState.base_hp)
	# Убийство жертвы проверяем по награде (захват узла в лямбду даёт шум
	# «capture freed» — узел к этому моменту уже мёртв, что и есть успех).
	await _wait(func() -> bool: return GameState.gold[GameState.defender_peer] > gold_after_tower,
			func() -> String: return "защитник получил награду за убийство: %d" % GameState.gold[GameState.defender_peer])

	# 5. ЭТАП 4: проверка системы волн — устраиваем экономический «затык»:
	#    все живые юниты уходят в прорыв, казну штурмовика сливаем ниже цены
	#    самого дешёвого юнита. Волна обязана завершиться, а после перерыва
	#    начаться снова (волна 2) с капиталом обоим игрокам.
	for node in get_tree().get_nodes_in_group("units"):
		var leftover := node as Unit
		leftover.set_process(true)   # разморозить «жертву» боя — замороженный
		# юнит не дойдёт до базы, застрянет в группе "units" и заблокирует
		# условие «поле пусто» навсегда.
		leftover.progress = (leftover.get_parent() as Path2D).curve.get_baked_length() - 5.0
	await _sleep(1.0)   # дать прорывам (и баунти) обработаться на обоих пирах
	var drained_gold := GameDB.cheapest_unit_cost() - 10
	GameState._set_gold.rpc(GameState.attacker_peer, drained_gold)   # тестовая заливка казны
	await _wait(func() -> bool: return GameState.current_wave == 2 and GameState.wave_in_progress,
			func() -> String: return "волна 2 началась после затыка (текущая %d)" % GameState.current_wave)
	_check(GameState.gold[GameState.attacker_peer] == GameState.WAVE_STIPEND + drained_gold,
			"капитал волны 2 у штурмовика: %d" % GameState.gold[GameState.attacker_peer])


# ---------------------------------------------------------------- КЛИЕНТ ----

func _run_join() -> void:
	NetworkManager.join_game("127.0.0.1", "JoinBot")
	await _wait_game_scene()
	await _sleep(1.0)   # дать хосту инициализировать матч
	var spawner: UnitSpawner = get_tree().current_scene.get_node("Road/UnitSpawner")
	var my_id := multiplayer.get_unique_id()

	# ЭТАП 5: round-trip снаряжения — сохранить, загрузить, сравнить деки.
	# Дек матча уже зафиксирован в _register (дефолтный), поэтому локальные
	# переключения на результат матча не влияют — восстанавливаем сразу.
	LoadoutManager.toggle_in_deck("units", "fast")
	LoadoutManager.toggle_in_deck("units", "boss")
	LoadoutManager.save_to_disk()
	var units_before := ",".join(LoadoutManager.units)
	LoadoutManager.load_from_disk()
	_check(",".join(LoadoutManager.units) == units_before,
			"сейв/лоад снаряжения: %s" % units_before)
	LoadoutManager.toggle_in_deck("units", "boss")
	LoadoutManager.toggle_in_deck("units", "fast")
	LoadoutManager.save_to_disk()

	# Дек штурмовика в матче (пришёл через _register -> setup_match).
	_check(GameState.attacker_units.size() == LoadoutManager.DECK_SIZE
			and GameState.attacker_units.has("fast"),
			"дек штурмовика в матче: %s" % ", ".join(GameState.attacker_units))

	# 1. ЭТАП 4: волна 1 идёт с первого кадра, капитал начислен обоим.
	_check(GameState.current_wave == 1 and GameState.wave_in_progress,
			"волна 1 идёт на клиенте (текущая %d)" % GameState.current_wave)
	var start_gold := GameState.START_GOLD + GameState.WAVE_STIPEND
	_check(GameState.gold[my_id] == start_gold,
			"стартовый капитал с волной = %d" % GameState.gold[my_id])

	# 2. Негатив: волна танков (225) дороже капитала (220) — отклонена.
	spawner.request_wave.rpc_id(1, "tank")
	await _sleep(0.5)
	_check(GameState.gold[my_id] == start_gold,
			"дорогая волна отклонена, золото = %d" % GameState.gold[my_id])

	# 2. Ровно шесть одиночных «бегунов»; интервал больше серверного кулдауна.
	for i in 6:
		spawner.request_unit.rpc_id(1, "fast")
		await _sleep(0.6)   # кулдаун сервера 400 мс, даём запас

	# Видимость спавна: с ежесекундной диагностикой (ловим плавающую репликацию).
	var waited := 0.0
	var last_diag := -1
	while _unit_count() < 6 and waited < 10.0:
		var sec := int(waited)
		if sec != last_diag:
			last_diag = sec
			var road := get_tree().current_scene.get_node("Road") as Path2D
			print("[join] diag t=%d units_group=%d road_children=%d" % [sec, _unit_count(), road.get_child_count()])
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check(_unit_count() >= 6, "6 юнитов видны у клиента (получено %d)" % _unit_count())
	await _wait(func() -> bool: return GameState.gold[my_id] == start_gold - 6 * 15,
			func() -> String: return "за 6 юнитов списано золото, остаток = %d" % GameState.gold[my_id])

	# 3. Синхронизация состояния: прорыв на хосте доходит сюда.
	await _wait(func() -> bool: return GameState.base_hp < GameState.BASE_MAX_HP,
			func() -> String: return "клиент увидел HP базы = %d" % GameState.base_hp)
	await _wait(func() -> bool: return GameState.gold[my_id] > start_gold - 6 * 15,
			func() -> String: return "бони за прорыв пришла клиенту: %d" % GameState.gold[my_id])

	# 4. Не отключаемся, пока хост не завершит боевую проверку: золото
	#    защитника синхронизировано обоим, ждём его роста (+8 за убийство).
	var defender_gold_after_kill := GameState.START_GOLD + GameState.WAVE_STIPEND - 50 + 8
	await _wait(func() -> bool: return GameState.gold[GameState.defender_peer] > defender_gold_after_kill - 1,
			func() -> String: return "клиент увидел награду защитника: %d" % GameState.gold[GameState.defender_peer])

	# 5. ЭТАП 4: хост устраивает «затык» — ждём волну 2 с капиталом обоим.
	await _wait(func() -> bool: return GameState.current_wave == 2 and GameState.wave_in_progress,
			func() -> String: return "клиент увидел волну 2 (текущая %d)" % GameState.current_wave)
	await _wait(func() -> bool: return GameState.gold[my_id] == GameState.WAVE_STIPEND + GameDB.cheapest_unit_cost() - 10,
			func() -> String: return "капитал волны 2 у штурмовика: %d" % GameState.gold[my_id])
	await _wait(func() -> bool: return GameState.gold[GameState.defender_peer] == defender_gold_after_kill + GameState.WAVE_STIPEND,
			func() -> String: return "капитал волны 2 у защитника: %d" % GameState.gold[GameState.defender_peer])
	await _sleep(1.5)   # граце-пауза: хост успевает допечатать финал до дисконнекта


# ------------------------------------------------------------- Помощники ----

func _check(condition: bool, what: String) -> void:
	if condition:
		print("[%s] OK: %s" % [role, what])
	else:
		print("[%s] FAIL: %s" % [role, what])
		_fail = true


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _unit_count() -> int:
	return get_tree().get_nodes_in_group("units").size()


func _wait(predicate: Callable, what: Callable) -> void:
	# what — Callable: сообщение форматируется в момент проверки,
	# чтобы в лог попали актуальные значения.
	var deadline := Time.get_ticks_msec() + DEADLINE_MS
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			_check(true, what.call())
			return
		await get_tree().process_frame
	_check(false, what.call() + " (таймаут)")


func _wait_game_scene() -> void:
	await _wait(func() -> bool:
		return get_tree().current_scene != null \
				and get_tree().current_scene.scene_file_path == GAME_SCENE,
		func() -> String: return "сцена матча загружена")


func _cell_near_road(map: GameMap) -> Vector2i:
	# Строим в клетке рядом с дорогой, чтобы башня доставала юнитов.
	var best := Vector2i(-1, -1)
	var best_dist := INF
	for x in range(0, 18):
		for y in range(0, 10):
			var cell := Vector2i(x, y)
			if not map.is_cell_buildable(cell):
				continue
			var dist := map._distance_to_road(map.cell_to_center(cell))
			if dist > 60.0 and dist < best_dist:
				best_dist = dist
				best = cell
	return best


func _progress_near_tower(map: GameMap, cell: Vector2i) -> float:
	# Прогресс пути, ближайший к башне (запечённые точки идут с шагом 5 px).
	var tower_pos := map.cell_to_center(cell)
	var points := (get_tree().current_scene.get_node("Road") as Path2D).curve.get_baked_points()
	var best_progress := 0.0
	var best_dist := INF
	for i in points.size():
		var dist := tower_pos.distance_to(points[i])
		if dist < best_dist:
			best_dist = dist
			best_progress = float(i) * 5.0
	return best_progress
