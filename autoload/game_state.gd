# gdlint: ignore=max-public-methods
extends Node
## Автозагрузка «GameState»: единственный источник истины по золоту, HP базы,
## фазам раунда, статистике матча и победе.
##
## ЭТАП 7 — FAST SIEGE (после плейтеста):
##   ПОДГОТОВКА (10 с) -> ШТУРМ (окно спавна 30 с + добивание) -> сразу
##   следующая подготовка. Паузы «ИТОГ» больше нет: раунд заканчивается в
##   тот кадр, когда поле опустело или база пала.
## Раунд выигрывает Штурмовик, если снёс базу; иначе — Защитник.
## Башни и купленные уровни переживают раунды, HP базы сбрасывается.
## Матч заканчивается, когда кто-то взял 2 раунда (максимум 3).
##
## Правило синхронизации: НИКТО не меняет gold/base_hp напрямую.
## Сервер (хост) — арбитр: игровые события вызывают серверные методы
## (try_spend, award_kill, base_leaked...), те считают новое значение и
## рассылают его через @rpc("authority", "call_local").
##
## Раунды, в отличие от старых волн, синхронизируются ЦЕЛИКОМ (номер, фаза,
## остаток времени): расхождение фаз ломает планирование, поэтому клиент не
## досчитывает переходы сам.

signal gold_changed(peer_id: int, amount: int)
signal base_hp_changed(hp: int, max_hp: int)
signal game_ended(defender_won: bool)
signal phase_changed(round_index: int, phase: int, duration: float)
signal round_ended(round_index: int, attacker_won: bool,
		defender_wins: int, attacker_wins: int)
signal ability_used(ability: String)
signal unit_level_changed(unit_id: String, level: int)

enum Phase { PLANNING, ASSAULT, FINISHED }
enum Ability { REPAIR, OVERCLOCK, BREAKTHROUGH }

## Матч — 10 волн (ЭТАП 8): побеждает тот, кто взял 6 раундов. Раньше
## встречи матч не заканчивается (минимум 6 волн), позже — не тянется.
const ROUNDS_TO_WIN := 6
const MAX_ROUNDS := 10
const ROUND_BASE_HP := 15
## Совместимость: старые HUD/тесты читали BASE_MAX_HP. Теперь это HP раунда.
const BASE_MAX_HP := ROUND_BASE_HP

const PLANNING_TIME := 10.0
## Окно спавна: 30 с штурмовик может покупать и выпускать юнитов. Дальше —
## только ожидание, пока последний юнит не дойдёт или не умрёт.
const SPAWN_WINDOW := 30.0
## Жёсткий предохранитель на «добивание»: если юнит застрял (баг/сеть),
## раунд не должен длиться вечно.
const ASSAULT_MAX_TIME := 75.0
## Сколько секунд пустого поля нужно, чтобы засчитать оборону победой.
const CLEAR_GRACE := 1.2

## Бюджет волны НЕ сгорает: остаток переносится. ЭТАП 8 — 10 волн.
## Ключевая асимметрия: башни и уровни защитника переживают волны (его доход
## копится), армия штурмовика умирает каждую волну (его касса — доход текущей
## волны). Поэтому кривая у обоих геометрическая, но приращения защитника
## меньше: иначе к 5-й волне оборона становится стеной, а к 10-й —
## подавляющей (tools/balance_audit.py, профиль v4, режим decks).
const ROUND_BUDGET_ATTACKER: Array[int] = [
	260, 340, 440, 560, 720, 900, 1140, 1440, 1820, 2300,
]
const ROUND_BUDGET_DEFENDER: Array[int] = [
	280, 72, 92, 112, 148, 176, 220, 276, 348, 436,
]
## Доход атакующего во время штурма — чтобы простой не превращался в тишину.
const TRICKLE_ATTACKER := 2.0

## Способности Защитника (SPEC-01): по одному применению каждого типа за раунд.
const OVERCLOCK_MULT := 1.4
const OVERCLOCK_TIME := 4.0
const REPAIR_AMOUNT := 2

var defender_peer := 1
var attacker_peer := -1
var base_hp := ROUND_BASE_HP
var gold: Dictionary = {}       # peer_id -> int
var game_over := false

# --- Деки на матч (пришли через лобби-RPC, одинаковы у обоих пиров).
var defender_towers: Array[String] = LoadoutManager.DEFAULT_TOWERS.duplicate()
var attacker_units: Array[String] = LoadoutManager.DEFAULT_UNITS.duplicate()

# --- Состояние раунда (источник истины — сервер).
var round_index := 1
var round_phase := Phase.PLANNING
var phase_time_left := PLANNING_TIME
## Окно спавна: true — штурмовик может покупать, false — только добивание.
var spawn_open := true
var spawn_window_left := SPAWN_WINDOW
## Уровни типов юнитов (ЭТАП 7): id -> 1..10. Общие для обоих пиров.
var unit_levels: Dictionary = {}
var defender_wins := 0
var attacker_wins := 0
var overclock_left := 0.0
## peer_id -> Array[String] применённых в этом раунде способностей.
var abilities_used: Dictionary = {}

## Статистика матча (считается ТОЛЬКО на сервере; клиент получает слепок
## в _end_match и показывает на финальном экране).
var stats := _fresh_stats()

## Время с пустого поля (для мгновенного конца раунда после добивания).
var _clear_time := 0.0
var _assault_time := 0.0

## Накопитель капельного дохода (сервер), чтобы не терять дробные кредиты.
var _trickle := 0.0
## Раунд уже засчитан. Защита от двойного счёта, если таймер и прорыв
## пришли в один кадр.
var _round_resolved := false


func _process(delta: float) -> void:
	# Оверклок тикает у всех: сервер считает по нему урон, клиент — картинку.
	if overclock_left > 0.0 and not game_over:
		overclock_left = maxf(overclock_left - delta, 0.0)


func _fresh_stats() -> Dictionary:
	return {
		"units_killed": 0,          # защитник: убито юнитов
		"towers_built": 0,          # защитник: построено башен
		"units_sent": 0,            # штурмовик: отправлено юнитов (вкл. волны)
		"waves_sent": 0,            # штурмовик: отправлено формаций
		"units_leaked": 0,          # штурмовик: юнитов прорвалось к базе
		"gold_spent_defender": 0,
		"gold_spent_attacker": 0,
		"rounds_played": 0,
		"repairs_used": 0,
		"overclocks_used": 0,
		"breakthroughs_used": 0,
		"tower_upgrades": 0,
		"unit_upgrades": 0,
	}


## Чистит присланный дек: только известные GameDB id, без дублей, максимум
## 3; пустому/битому списку подставляются дефолты — матч не ломается.
func _sanitize_deck(raw: Array, table: String) -> Array[String]:
	var known: Dictionary = GameDB.TOWERS if table == "TOWERS" else GameDB.UNITS
	var defaults: Array[String] = LoadoutManager.DEFAULT_TOWERS if table == "TOWERS" \
			else LoadoutManager.DEFAULT_UNITS
	var out: Array[String] = []
	for id in raw:
		var tid := String(id).strip_edges()
		if known.has(tid) and not out.has(tid):
			out.append(tid)
		if out.size() >= LoadoutManager.DECK_SIZE:
			return out
	for id in defaults:
		if out.size() >= LoadoutManager.DECK_SIZE:
			break
		if not out.has(id):
			out.append(id)
	return out


## Вызывается из game.gd при загрузке сцены матча на каждом пиру.
func setup_match(p_defender: int, p_attacker: int,
		p_towers: Array = [], p_units: Array = []) -> void:
	defender_peer = p_defender
	attacker_peer = p_attacker
	defender_towers = _sanitize_deck(p_towers, "TOWERS")
	attacker_units = _sanitize_deck(p_units, "UNITS")
	game_over = false
	round_index = 1
	defender_wins = 0
	attacker_wins = 0
	overclock_left = 0.0
	_round_resolved = false
	abilities_used = {defender_peer: [], attacker_peer: []}
	_trickle = 0.0
	unit_levels = {}
	for id in attacker_units:
		unit_levels[String(id)] = 1
	spawn_open = true
	spawn_window_left = SPAWN_WINDOW
	_clear_time = 0.0
	_assault_time = 0.0
	stats = _fresh_stats()
	base_hp = ROUND_BASE_HP
	round_phase = Phase.PLANNING
	phase_time_left = PLANNING_TIME
	# Бюджет раунда 1 начисляем ЛОКАЛЬНО одинаковым кодом на обоих пирах:
	# серверный бродкаст в момент загрузки сцены мог бы прийти раньше
	# клиентского setup_match и быть им затёрт.
	gold = {
		defender_peer: ROUND_BUDGET_DEFENDER[0],
		attacker_peer: ROUND_BUDGET_ATTACKER[0],
	}
	gold_changed.emit(defender_peer, gold[defender_peer])
	gold_changed.emit(attacker_peer, gold[attacker_peer])
	base_hp_changed.emit(base_hp, ROUND_BASE_HP)
	phase_changed.emit(round_index, round_phase, PLANNING_TIME)


# ------------------------------------------------------------ Фазы (сервер) --

func is_planning() -> bool:
	return round_phase == Phase.PLANNING and not game_over


func is_assault() -> bool:
	return round_phase == Phase.ASSAULT and not game_over


## Может ли штурмовик покупать прямо сейчас: подготовка или окно спавна.
## После 30-й секунды штурма окно закрывается — остаётся только добивание.
func can_buy_units() -> bool:
	if game_over:
		return false
	if round_phase == Phase.PLANNING:
		return true
	return round_phase == Phase.ASSAULT and spawn_open


## Открыто ли окно спавна (для индикатора фазы).
func spawn_window_open() -> bool:
	return is_assault() and spawn_open


func fire_rate_multiplier() -> float:
	return OVERCLOCK_MULT if overclock_left > 0.0 else 1.0


## Тик раунда. Вызывается ТОЛЬКО сервером из game.gd.
func tick_phase(delta: float) -> void:
	if game_over or not multiplayer.is_server():
		return
	phase_time_left = maxf(phase_time_left - delta, 0.0)
	match round_phase:
		Phase.ASSAULT:
			_tick_trickle(delta)
			_assault_time += delta
			if spawn_open:
				spawn_window_left = maxf(spawn_window_left - delta, 0.0)
				if spawn_window_left <= 0.0:
					_close_spawn()
			_tick_assault_end(delta)
		Phase.PLANNING:
			if phase_time_left <= 0.0:
				_start_assault()


func _tick_trickle(delta: float) -> void:
	_trickle += TRICKLE_ATTACKER * delta
	var whole := int(floor(_trickle))
	if whole <= 0:
		return
	_trickle -= float(whole)
	_set_gold.rpc(attacker_peer, int(gold.get(attacker_peer, 0)) + whole)


func _start_assault() -> void:
	round_phase = Phase.ASSAULT
	_round_resolved = false
	spawn_open = true
	spawn_window_left = SPAWN_WINDOW
	phase_time_left = SPAWN_WINDOW
	_clear_time = 0.0
	_assault_time = 0.0
	_trickle = 0.0
	_sync_phase.rpc(round_index, round_phase, SPAWN_WINDOW, true)


## Окно спавна закрыто: покупки запрещены, идёт только добивание.
func _close_spawn() -> void:
	spawn_open = false
	phase_time_left = 0.0
	_sync_spawn.rpc(false)


## Конец раунда по состоянию поля. Два условия:
##   * поле пусто (нет юнитов и очередь пуста) дольше CLEAR_GRACE — оборона
##     выстояла, раунд за защитником;
##   * жёсткий лимит ASSAULT_MAX_TIME — предохранитель от вечного раунда.
## Пока идёт окно спавна, пустое поле не завершает раунд: штурмовик может
## копить кредиты на дорогой залп.
func _tick_assault_end(delta: float) -> void:
	if _assault_time >= ASSAULT_MAX_TIME:
		_finish_round(false)
		return
	# Пока окно спавна открыто, пустое поле — это не «оборона выстояла», а
	# пауза перед залпом: штурмовик вправе копить кредиты все 30 с. Раунд
	# может закончиться досрочно только в добивании.
	if spawn_open:
		_clear_time = 0.0
		return
	if _field_is_clear():
		_clear_time += delta
		if _clear_time >= CLEAR_GRACE:
			_finish_round(false)
	else:
		_clear_time = 0.0


## На поле нет ни одного живого юнита и в очереди пусто.
func _field_is_clear() -> bool:
	var spawner := get_tree().current_scene.get_node_or_null("Road/UnitSpawner")
	if spawner != null and spawner.has_method("queue_size") and spawner.queue_size() > 0:
		return false
	return get_tree().get_nodes_in_group("units").is_empty()


## Завершить раунд. attacker_won == true — база разрушена.
func _finish_round(attacker_won: bool) -> void:
	if game_over or _round_resolved or round_phase == Phase.FINISHED:
		return
	_round_resolved = true
	stats["rounds_played"] += 1
	if attacker_won:
		attacker_wins += 1
	else:
		defender_wins += 1
	# Счёт рассылаем обоим пирам: клиент не считает раунды сам.
	_sync_round_end.rpc(round_index, attacker_won, defender_wins, attacker_wins)
	# Матч решён — сразу финал, без лишнего экрана «итог раунда».
	if attacker_wins >= ROUNDS_TO_WIN or defender_wins >= ROUNDS_TO_WIN:
		finish_match(defender_wins > attacker_wins)
		return
	# 10-я волна позади, а 6 побед не набрал никто: счёт 5:5. Отдаём матч
	# обороне — «база выстояла» должна читаться как победа защитника.
	if round_index >= MAX_ROUNDS:
		finish_match(defender_wins >= attacker_wins)
		return
	# Поле чистится: недобитые юниты не должны «доехать» до базы уже после
	# свистка, а очередь спавнера — переехать в следующий раунд.
	_clear_battlefield()
	# Паузы «ИТОГ» больше нет: сразу готовим следующий раунд.
	_start_next_round()


## Убирает всех юнитов с дороги. Вызывается ТОЛЬКО на сервере:
## MultiplayerSpawner разошлёт удаление клиенту.
func _clear_battlefield() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(node):
			node.queue_free()


## Досрочно завершить штурм (поле пусто, очередь пуста, а окно спавна уже
## закрыто). Раунд достаётся Защитнику.
func finish_round_by_timeout() -> void:
	if not multiplayer.is_server() or game_over or not is_assault():
		return
	_finish_round(false)


func _start_next_round() -> void:
	round_index += 1
	_round_resolved = false
	round_phase = Phase.PLANNING
	phase_time_left = PLANNING_TIME
	spawn_open = true
	spawn_window_left = SPAWN_WINDOW
	_clear_time = 0.0
	_assault_time = 0.0
	base_hp = ROUND_BASE_HP
	overclock_left = 0.0
	abilities_used = {defender_peer: [], attacker_peer: []}
	_trickle = 0.0
	# База и бюджеты — через call_local RPC: значения приходят обоим.
	_set_base_hp.rpc(ROUND_BASE_HP)
	_set_gold.rpc(defender_peer, int(gold.get(defender_peer, 0))
			+ ROUND_BUDGET_DEFENDER[round_index - 1])
	_set_gold.rpc(attacker_peer, int(gold.get(attacker_peer, 0))
			+ ROUND_BUDGET_ATTACKER[round_index - 1])
	_sync_phase.rpc(round_index, round_phase, PLANNING_TIME, true)


@rpc("authority", "call_local", "reliable")
func _sync_spawn(open: bool) -> void:
	spawn_open = open
	if not open:
		phase_time_left = 0.0


@rpc("authority", "call_local", "reliable")
func _sync_round_end(round_idx: int, attacker_won: bool,
		dwins: int, awins: int) -> void:
	defender_wins = dwins
	attacker_wins = awins
	round_ended.emit(round_idx, attacker_won, dwins, awins)


@rpc("authority", "call_local", "reliable")
func _sync_phase(wave_round: int, phase: int, duration: float, spawn := true) -> void:
	round_index = wave_round
	round_phase = phase
	phase_time_left = duration
	# Окно спавна едет вместе с фазой. Раньше клиент узнавал о закрытии окна
	# (_sync_spawn(false)), но о новом открытии в следующем раунде — нет, и со
	# 2-го раунда карточки штурмовика гасли: «во всех раундах нельзя спавнить».
	spawn_open = spawn
	spawn_window_left = SPAWN_WINDOW if spawn else 0.0
	# Новый раунд — способности снова доступны (сброс и у клиента).
	if phase == Phase.PLANNING:
		abilities_used = {defender_peer: [], attacker_peer: []}
		overclock_left = 0.0
	phase_changed.emit(wave_round, phase, duration)


# ------------------------------------------- Способности Защитника ----------

## Запрос способности от клиента. Сервер проверяет роль, фазу и «один раз
## за раунд» — клиент не может ни спамить, ни применять чужие способности.
@rpc("any_peer", "call_remote", "reliable")
func request_ability(ability: String) -> void:
	if not multiplayer.is_server() or game_over:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != defender_peer and sender != attacker_peer:
		return
	if not _ability_allowed(sender, ability):
		return
	_apply_ability(sender, ability)


## Серверная версия для локалхоста: хост не может вызвать RPC на себя.
func apply_ability(peer_id: int, ability: String) -> void:
	if not multiplayer.is_server() or game_over:
		return
	if peer_id != defender_peer and peer_id != attacker_peer:
		return
	if not _ability_allowed(peer_id, ability):
		return
	_apply_ability(peer_id, ability)


func _ability_allowed(peer_id: int, ability: String) -> bool:
	if round_phase == Phase.FINISHED:
		return false
	var used: Array = abilities_used.get(peer_id, [])
	if used.has(ability):
		return false
	# «ПРОРЫВ» — способность Штурмовика, остальное — Защитника.
	var for_defender := ability == "repair" or ability == "overclock"
	if for_defender != (peer_id == defender_peer):
		return false
	match ability:
		"repair":
			return base_hp < ROUND_BASE_HP and base_hp > 0
		"overclock", "breakthrough":
			return round_phase == Phase.ASSAULT
		_:
			return false


func _apply_ability(peer_id: int, ability: String) -> void:
	var used: Array = abilities_used.get(peer_id, [])
	used.append(ability)
	abilities_used[peer_id] = used
	match ability:
		"repair":
			stats["repairs_used"] += 1
			_set_base_hp.rpc(mini(base_hp + REPAIR_AMOUNT, ROUND_BASE_HP))
			_sync_ability.rpc(peer_id, ability)
		"overclock":
			stats["overclocks_used"] += 1
			_sync_overclock.rpc(OVERCLOCK_TIME)
			_sync_ability.rpc(peer_id, ability)
		"breakthrough":
			stats["breakthroughs_used"] += 1
			# Мгновенный выпуск всей очереди: залп, который пробивает оборону.
			var spawner := get_tree().current_scene.get_node_or_null("Road/UnitSpawner")
			if spawner != null and spawner.has_method("release_all"):
				spawner.release_all()
			_sync_ability.rpc(peer_id, ability)


## Бродкаст применения: оба пира обновляют HUD и слушают звук.
@rpc("authority", "call_local", "reliable")
func _sync_ability(peer_id: int, ability: String) -> void:
	# Клиент не считает способности сам — просто помечает использованную.
	var used: Array = abilities_used.get(peer_id, [])
	if not used.has(ability):
		used.append(ability)
	abilities_used[peer_id] = used
	ability_used.emit(ability)


@rpc("authority", "call_local", "reliable")
func _sync_overclock(duration: float) -> void:
	overclock_left = duration


# ------------------------------------------------ Серверные операции --------
# Вызываются ТОЛЬКО на сервере (из unit.gd, map.gd, unit_spawner.gd...).

## Попытка списать золото. Возвращает true при успехе.
func try_spend(peer_id: int, cost: int) -> bool:
	if game_over or not gold.has(peer_id) or gold[peer_id] < cost:
		return false
	if peer_id == defender_peer:
		stats["gold_spent_defender"] += cost
	else:
		stats["gold_spent_attacker"] += cost
	_set_gold.rpc(peer_id, gold[peer_id] - cost)
	return true


## Награда защитнику за убитого юнита.
func award_kill(unit_stats: Dictionary) -> void:
	if game_over:
		return
	stats["units_killed"] += 1
	if stats["units_killed"] == 1:
		SteamManager.unlock_achievement(SteamManager.ACH_FIRST_BLOOD)
	_set_gold.rpc(defender_peer, gold[defender_peer] + int(unit_stats["kill_reward"]))


## Юнит дошёл до базы: урон базе + награда штурмовику.
func base_leaked(unit_stats: Dictionary) -> void:
	if game_over:
		return
	stats["units_leaked"] += 1
	_set_gold.rpc(attacker_peer, gold[attacker_peer] + int(unit_stats["bounty"]))
	_set_base_hp.rpc(maxi(base_hp - int(unit_stats["damage"]), 0))


## Сервер подтвердил постройку башни (вызывается из map._server_place_tower).
func record_tower_built() -> void:
	if game_over:
		return
	stats["towers_built"] += 1
	if stats["towers_built"] == GameDB.TOWERS_FOR_ACHIEVEMENT:
		SteamManager.unlock_achievement(SteamManager.ACH_MASTER_BUILDER)


## Защитник купил уровень башни.
func record_tower_upgrade() -> void:
	if game_over:
		return
	stats["tower_upgrades"] += 1


## Сервер заспавнил юнита (вызывается из unit_spawner._try_spawn).
func record_unit_sent() -> void:
	stats["units_sent"] += 1


## Штурмовик оплатил формацию ×N (вызывается из unit_spawner._server_enqueue).
func record_wave() -> void:
	stats["waves_sent"] += 1


# ------------------------------------------------ Уровни юнитов (ЭТАП 7) -----

## Уровень типа юнита (1, если ещё не качали).
func unit_level(unit_id: String) -> int:
	return int(unit_levels.get(unit_id, 1))


## Статы юнита с учётом купленного уровня — для спавнера и HUD.
func unit_stats(unit_id: String) -> Dictionary:
	return GameDB.unit_stats_at(unit_id, unit_level(unit_id))


## Запрос апгрейда от клиента-штурмовика.
@rpc("any_peer", "call_remote", "reliable")
func request_unit_upgrade(unit_id: String) -> void:
	if not multiplayer.is_server():
		return
	apply_unit_upgrade(multiplayer.get_remote_sender_id(), unit_id)


## Серверная версия (хост не может вызвать RPC на себя).
func apply_unit_upgrade(peer_id: int, unit_id: String) -> void:
	if not multiplayer.is_server() or game_over:
		return
	if peer_id != attacker_peer or not GameDB.UNITS.has(unit_id):
		return
	if not attacker_units.has(unit_id):
		return
	if round_phase == Phase.FINISHED:
		return
	var level := unit_level(unit_id)
	if level >= GameDB.UNIT_MAX_LEVEL:
		return
	var cost := GameDB.unit_upgrade_cost(unit_id, level)
	if not try_spend(peer_id, cost):
		return
	stats["unit_upgrades"] += 1
	_sync_unit_level.rpc(unit_id, level + 1)


@rpc("authority", "call_local", "reliable")
func _sync_unit_level(unit_id: String, level: int) -> void:
	unit_levels[unit_id] = level
	unit_level_changed.emit(unit_id, level)


## Сдаться (клиент): сервер засчитывает поражение отправителю.
@rpc("any_peer", "call_remote", "reliable")
func request_surrender() -> void:
	if not multiplayer.is_server():
		return
	surrender(multiplayer.get_remote_sender_id())


## Сдаться. Победителем считается соперник сдавшегося.
func surrender(peer_id: int) -> void:
	if game_over or not multiplayer.is_server():
		return
	finish_match(peer_id != defender_peer)


## Завершить матч. defender_won == true — Защитник взял больше раундов.
func finish_match(defender_won: bool) -> void:
	if game_over:
		return
	_end_match.rpc(defender_won, stats)


# -------------------------------------------- Авторитетные рассылки ---------
# «authority» — отправить их может только владелец узла (сервер, peer 1),
# «call_local» — RPC выполняется и на самом сервере: он живёт теми же данными.

@rpc("authority", "call_local", "reliable")
func _set_gold(peer_id: int, value: int) -> void:
	gold[peer_id] = maxi(value, 0)
	gold_changed.emit(peer_id, gold[peer_id])


@rpc("authority", "call_local", "reliable")
func _set_base_hp(value: int) -> void:
	base_hp = value
	base_hp_changed.emit(base_hp, ROUND_BASE_HP)
	if base_hp <= 0:
		# База пала — раунд и, возможно, матч за Штурмовиком.
		if multiplayer.is_server():
			_finish_round(true)   # база пала — раунд за Штурмовиком


@rpc("authority", "call_local", "reliable")
func _end_match(defender_won: bool, final_stats: Dictionary) -> void:
	if game_over:
		return
	game_over = true
	round_phase = Phase.FINISHED
	stats = final_stats   # слепок сервера: у обоих игроков одинаковые цифры
	var i_am_defender := multiplayer.get_unique_id() == defender_peer
	# Тренировка с ботом не должна портить рейтинг и статистику Steam.
	if not NetworkManager.is_solo():
		_record_steam_stats(i_am_defender, defender_won)
		# MMR обновляет КАЖДЫЙ пир локально (+25/-25 по своему результату):
		# Steam-стата и локальное зеркало — на машине самого игрока.
		SteamManager.apply_match_result(i_am_defender == defender_won)
	game_ended.emit(defender_won)


## Агрегаты Steam пишет КАЖДЫЙ пир про себя: раньше это делал только сервер
## (машина Защитника), поэтому статистика Штурмовика не росла никогда.
func _record_steam_stats(i_am_defender: bool, defender_won: bool) -> void:
	SteamManager.add_stat_int(SteamManager.STAT_MATCHES, 1)
	if i_am_defender:
		SteamManager.add_stat_int(SteamManager.STAT_UNITS_KILLED,
				int(stats["units_killed"]))
		if defender_won:
			SteamManager.unlock_achievement(SteamManager.ACH_SURVIVOR)
			SteamManager.add_stat_int(SteamManager.STAT_WINS_DEFENDER, 1)
	elif not defender_won:
		SteamManager.add_stat_int(SteamManager.STAT_WINS_ATTACKER, 1)
