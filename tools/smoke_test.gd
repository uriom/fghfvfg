extends Node
## End-to-end smoke-тест сетевого кода. Запускается в ДВУХ процессах:
##   godot --headless --path <проект> res://tools/smoke_test.tscn -- host
##   godot --headless --path <проект> res://tools/smoke_test.tscn -- join
##
## Проверяет: подключение, старт матча, фазу ПОДГОТОВКИ, постройку башни,
## очередь юнитов, отказ по золоту, переход в ШТУРМ, репликацию спавна,
## убийство башней, прорыв базы и смену волны (матч до 10 волн).

const GAME_SCENE := "res://scenes/game.tscn"
const DEADLINE_MS := 12000
## Страж всего теста: 12 с подготовки не ждём — фазы прокручиваем вручную
## через GameState.tick_phase(), поэтому тест укладывается в минуту.
const GUARD_SECONDS := 60.0

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
	get_tree().create_timer(GUARD_SECONDS).timeout.connect(func() -> void:
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
	# Дек через лобби-RPC долетел до матча (серверная валидация и HUD
	# строятся из GameState.defender_towers).
	_check(GameState.defender_towers.size() == LoadoutManager.DECK_SIZE,
			"дек защитника в матче: %s" % ", ".join(GameState.defender_towers))

	var map: GameMap = get_tree().current_scene.get_node("Map")
	var defender := GameState.defender_peer

	# 1. Стартовая фаза — ПОДГОТОВКА, бюджет раунда 1 выдан защитнику.
	_check(GameState.round_phase == GameState.Phase.PLANNING,
			"матч стартует в ПОДГОТОВКЕ")
	_check(GameState.gold[defender] == GameState.ROUND_BUDGET_DEFENDER[0],
			"бюджет защитника = %d" % GameState.gold[defender])

	# 2. Строительство в ПОДГОТОВКЕ. Ставим снайпера у дороги.
	var cell := _cell_near_road(map)
	map._request_build(cell)
	await _sleep(0.4)
	_check(map.occupied.has(cell), "башня построена в %s" % cell)
	var sniper_cost: int = int(GameDB.TOWERS[GameState.defender_towers[0]]["cost"])
	var gold_after_tower: int = GameState.ROUND_BUDGET_DEFENDER[0] - sniper_cost
	_check(GameState.gold[defender] == gold_after_tower,
			"кредиты защитника после постройки = %d" % GameState.gold[defender])
	_check(GameState.stats["towers_built"] == 1, "статистика: 1 башня")

	# 3. Лимит на тип: вторая башня разрешена, третья — нет.
	var cell2 := _cell_near_road(map, cell)
	var before_second := GameState.gold[defender]
	map._request_build(cell2)
	await _sleep(0.3)
	_check(map.total_towers() == 2, "вторая башня того же типа разрешена")
	await _sleep(0.2)
	_check(GameState.gold[defender] < before_second or before_second < sniper_cost,
			"списание за вторую башню прошло")

	# 4. Штурм: прокручиваем подготовку серверным тиком (без ожидания 12 с).
	GameState.tick_phase(GameState.PLANNING_TIME + 0.1)
	await _sleep(0.3)
	_check(GameState.is_assault(), "фаза ШТУРМ началась")
	_check(GameState.gold[GameState.attacker_peer] > 0,
			"у штурмовика есть кредиты на старте штурма")

	# 5. Очередь клиента выкладывается на дорогу.
	await _wait(func() -> bool: return _unit_count() >= 4,
			func() -> String: return "юниты из очереди заспавнились (%d)" % _unit_count())

	# 6. Проверка боя: жертву замираем у башни, остальных отправляем к базе —
	#    они прорываются и освобождают дорогу, башня добивает жертву.
	var units := get_tree().get_nodes_in_group("units")
	var victim: Unit = units[0]
	victim.set_process(false)
	victim.progress = _progress_near_tower(map, cell)
	var road_len := (victim.get_parent() as Path2D).curve.get_baked_length()
	for i in range(1, units.size()):
		(units[i] as Unit).progress = road_len - 5.0

	await _wait(func() -> bool: return GameState.base_hp < GameState.ROUND_BASE_HP,
			func() -> String: return "прорыв: HP базы = %d" % GameState.base_hp)
	await _wait(func() -> bool: return GameState.gold[defender] > gold_after_tower,
			func() -> String: return "награда за убийство: %d" % GameState.gold[defender])
	_check(GameState.stats["units_leaked"] >= 1, "статистика: прорывы учтены")

	# 7. Конец раунда вручную: Защитник выстоял -> счёт 1:0, затем раунд 2.
	GameState.finish_round_by_timeout()
	await _sleep(0.3)
	_check(GameState.defender_wins == 1, "раунд 1 за защитником")
	# Паузы «ИТОГ» больше нет: следующий раунд начинается сразу.
	GameState.tick_phase(0.1)
	await _sleep(0.4)
	_check(GameState.round_index == 2, "начался раунд 2")
	_check(GameState.base_hp == GameState.ROUND_BASE_HP, "HP базы сброшено")
	_check(GameState.gold[defender] >= GameState.ROUND_BUDGET_DEFENDER[1],
			"защитнику выдан бюджет раунда 2")


# ---------------------------------------------------------------- КЛИЕНТ ----

func _run_join() -> void:
	NetworkManager.join_game("127.0.0.1", "JoinBot")
	await _wait_game_scene()
	await _sleep(1.0)   # дать хосту инициализировать матч
	var spawner: UnitSpawner = get_tree().current_scene.get_node("Road/UnitSpawner")
	var my_id := multiplayer.get_unique_id()

	# Round-trip снаряжения: сохранить, загрузить, сравнить деки.
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

	# 1. Фаза и бюджет: ПОДГОТОВКА, 170 кредитов в раунде 1.
	_check(GameState.round_phase == GameState.Phase.PLANNING,
			"клиент видит ПОДГОТОВКУ")
	var start_gold := GameState.ROUND_BUDGET_ATTACKER[0]
	_check(GameState.gold[my_id] == start_gold,
			"стартовый бюджет штурмовика = %d" % GameState.gold[my_id])

	# 2. Негатив: босс дороже остатка после первой покупки.
	spawner.enqueue_unit("boss", 1)
	await _sleep(0.4)
	_check(GameState.gold[my_id] == start_gold - int(GameDB.UNITS["boss"]["cost"]),
			"босс куплен за %d" % int(GameDB.UNITS["boss"]["cost"]))
	spawner.enqueue_unit("boss", 1)
	await _sleep(0.4)
	_check(GameState.gold[my_id] == start_gold - int(GameDB.UNITS["boss"]["cost"]),
			"второй босс отклонён (нет кредитов), остаток = %d" % GameState.gold[my_id])

	# 3. Очередь: пять дешёвых «бегунов» докупаем остатком.
	var fast_cost: int = int(GameDB.UNITS["fast"]["cost"])
	var left_over: int = GameState.gold[my_id]
	var affordable := mini(4, left_over / fast_cost)
	for i in affordable:
		spawner.enqueue_unit("fast", 1)
		await _sleep(0.25)
	_check(GameState.gold[my_id] == left_over - affordable * fast_cost,
			"очередь оплачена, остаток = %d" % GameState.gold[my_id])
	_check(spawner.queue_size() >= 1, "очередь не пуста: %d" % spawner.queue_size())

	# 4. Хост открывает штурм — очередь начинает выкладываться.
	await _wait(func() -> bool: return GameState.is_assault(),
			func() -> String: return "клиент увидел ШТУРМ")
	await _wait(func() -> bool: return _unit_count() >= 3,
			func() -> String: return "юниты из очереди видны клиенту (%d)" % _unit_count())

	# 5. Синхронизация состояния: прорыв на хосте доходит сюда + бонус.
	await _wait(func() -> bool: return GameState.base_hp < GameState.ROUND_BASE_HP,
			func() -> String: return "клиент увидел HP базы = %d" % GameState.base_hp)
	await _wait(func() -> bool: return GameState.stats["units_leaked"] >= 1,
			func() -> String: return "клиент увидел прорыв в статистике")

	# 6. Конец раунда и старт раунда 2 реплицируются.
	await _wait(func() -> bool: return GameState.round_index == 2,
			func() -> String: return "клиент увидел раунд 2 (текущий %d)" % GameState.round_index)
	await _wait(func() -> bool: return GameState.round_phase == GameState.Phase.PLANNING,
			func() -> String: return "клиент видит ПОДГОТОВКУ раунда 2")
	await _wait(func() -> bool: return GameState.gold[my_id] >= GameState.ROUND_BUDGET_ATTACKER[1],
			func() -> String: return "бюджет раунда 2 у штурмовика: %d" % GameState.gold[my_id])
	await _sleep(1.0)   # граце-пауза: хост успевает допечатать финал до дисконнекта


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


func _cell_near_road(map: GameMap, exclude := Vector2i(-1, -1)) -> Vector2i:
	# Строим в клетке рядом с дорогой, чтобы башня доставала юнитов.
	var best := Vector2i(-1, -1)
	var best_dist := INF
	for x in range(0, 18):
		for y in range(0, 10):
			var cell := Vector2i(x, y)
			if cell == exclude or not map.is_cell_buildable(cell):
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
