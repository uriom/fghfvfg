extends Node
## Автозагрузка «GameState»: единственный источник истины по золоту, HP базы,
## статистике матча и победе.
##
## Правило синхронизации: НИКТО не меняет gold/base_hp напрямую.
## Сервер (хост) — арбитр: игровые события вызывают серверные методы
## (try_spend, award_kill, base_leaked...), те считают новое значение и
## рассылают его через @rpc("authority", "call_local") — RPC выполняется
## и на самом сервере, и на клиенте, поэтому данные всегда совпадают.
##
## ЭТАП 3: счётчики статистики матча (stats) ведёт сервер в тех же
## авторитетных методах; при финале слепок counters уходит обоим пирам в
## _end_match, а сервер попутно разблокирует достижения Steam (SteamManager).

signal gold_changed(peer_id: int, amount: int)
signal base_hp_changed(hp: int, max_hp: int)
signal game_ended(defender_won: bool)
# ЭТАП 4: сигналы волн. На сервере эмиссия происходит внутри RPC-бродкаста
# (_sync_wave, call_local), на клиенте — при его получении: оба пира
# живут одинаковым состоянием. Сам таймер по сети НЕ гоняется — клиенты
# отсчитывают его локально от сигналов (см. scripts/wave_display.gd).
signal wave_started(wave: int, duration: float)
signal wave_ended(wave: int, break_duration: float)

const BASE_MAX_HP := 20
const START_GOLD := 120

# --- Система волн: длительность, перерыв и капитал волны.
const WAVE_DURATION := 60.0   # сек на одну волну
const WAVE_BREAK := 5.0       # пауза между волнами, сек
const WAVE_STIPEND := 100     # золото КАЖДОМУ игроку в начале каждой волны

var defender_peer := 1
var attacker_peer := -1
var base_hp := BASE_MAX_HP
var gold: Dictionary = {}       # peer_id -> int
var game_over := false

# --- Деки на матч (пришли через лобби-RPC, одинаковы у обоих пиров).
## Башни, доступные Защитнику в ЭТОМ матче (валидация сервера + HUD).
var defender_towers: Array[String] = LoadoutManager.DEFAULT_TOWERS.duplicate()
## Юниты, доступные Штурмовику в ЭТОМ матче.
var attacker_units: Array[String] = LoadoutManager.DEFAULT_UNITS.duplicate()

# --- Состояние волн (источник истины — сервер; клиент получает бродкасты).
var current_wave := 1           # номер текущей волны
var wave_time_left := WAVE_DURATION
var wave_in_progress := true
var intermission_left := 0.0    # СЕРВЕР: остаток перерыва (клиенту не нужен)

## Статистика матча (считается ТОЛЬКО на сервере; клиент получает слепок
## в _end_match и показывает на финальном экране).
var stats := _fresh_stats()


func _fresh_stats() -> Dictionary:
	return {
		"units_killed": 0,          # защитник: убито юнитов
		"towers_built": 0,          # защитник: построено башен
		"units_sent": 0,            # штурмовик: отправлено юнитов (вкл. волны)
		"waves_sent": 0,            # штурмовик: отправлено волн
		"units_leaked": 0,          # штурмовик: юнитов прорвалось к базе
		"gold_spent_defender": 0,
		"gold_spent_attacker": 0,
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
## Деки приходят из лобби (NetworkManager.players) — у обоих пиров одни
## и те же списки, поэтому HUD и серверная валидация всегда согласованы.
func setup_match(p_defender: int, p_attacker: int,
		p_towers: Array = [], p_units: Array = []) -> void:
	defender_peer = p_defender
	attacker_peer = p_attacker
	base_hp = BASE_MAX_HP
	defender_towers = _sanitize_deck(p_towers, "TOWERS")
	attacker_units = _sanitize_deck(p_units, "UNITS")
	# Стартовый капитал + капитал волны 1. Начисляем ЛОКАЛЬНО одинаковым
	# кодом на обоих пирах: серверный бродкаст в момент загрузки сцены
	# мог бы прийти раньше клиентского setup_match и быть им затёрт.
	gold = {
		defender_peer: START_GOLD + WAVE_STIPEND,
		attacker_peer: START_GOLD + WAVE_STIPEND,
	}
	stats = _fresh_stats()
	game_over = false
	# Волна 1 идёт с первого кадра (клиент отсчитывает таймер локально).
	current_wave = 1
	wave_time_left = WAVE_DURATION
	wave_in_progress = true
	intermission_left = 0.0
	# Эмиссии ниже заполняют HUD, который уже подписан к этому моменту.
	gold_changed.emit(defender_peer, gold[defender_peer])
	gold_changed.emit(attacker_peer, gold[attacker_peer])
	base_hp_changed.emit(base_hp, BASE_MAX_HP)
	wave_started.emit(current_wave, WAVE_DURATION)


# ------------------------------------------- Волны (серверные операции) -----

## СЕРВЕР: завершить текущую волну (время вышло или волна «заглохла») и
## включить перерыв перед следующей. Состояние бродкастится обоим пирам.
func end_current_wave() -> void:
	if not multiplayer.is_server() or game_over or not wave_in_progress:
		return
	wave_in_progress = false
	intermission_left = WAVE_BREAK
	_sync_wave.rpc(current_wave, WAVE_BREAK, false)


## СЕРВЕР: начать следующую волну после перерыва — таймер на WAVE_DURATION,
## обоим игрокам капитал волны (+WAVE_STIPEND), синхронизация через RPC.
func start_new_wave() -> void:
	if not multiplayer.is_server() or game_over:
		return
	current_wave += 1
	_sync_wave.rpc(current_wave, WAVE_DURATION, true)
	# Капитал волны обоим игрокам; call_local обновит и сервер.
	for peer_id in [defender_peer, attacker_peer]:
		_set_gold.rpc(peer_id, gold[peer_id] + WAVE_STIPEND)


## Авторитетный бродкаст состояния волны: выполняется на сервере и клиенте,
## эмиссии сигналов — единственное место обновления для HUD.
@rpc("authority", "call_local", "reliable")
func _sync_wave(wave: int, time_left: float, in_progress: bool) -> void:
	current_wave = wave
	wave_time_left = time_left
	wave_in_progress = in_progress
	if in_progress:
		wave_started.emit(wave, time_left)
	else:
		wave_ended.emit(wave, time_left)


# ------------------------------------------------ Серверные операции --------
# Вызываются ТОЛЬКО на сервере (из unit.gd, map.gd, unit_spawner.gd...).

## Попытка списать золото. Возвращает true при успехе.
func try_spend(peer_id: int, cost: int) -> bool:
	if game_over or not gold.has(peer_id) or gold[peer_id] < cost:
		return false
	# Статистика: траты по ролям.
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
	if stats["towers_built"] == 10:
		SteamManager.unlock_achievement(SteamManager.ACH_MASTER_BUILDER)


## Сервер заспавнил юнита (вызывается из unit_spawner._try_spawn).
func record_unit_sent() -> void:
	stats["units_sent"] += 1


## Штурмовик оплатил волну (вызывается из unit_spawner.request_wave).
func record_wave() -> void:
	stats["waves_sent"] += 1


## Завершить матч. defender_won == true — база выстояла до конца таймера.
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
	base_hp_changed.emit(base_hp, BASE_MAX_HP)
	if base_hp <= 0:
		_end_match.rpc(false, stats)   # база пала — победил штурмовик


@rpc("authority", "call_local", "reliable")
func _end_match(defender_won: bool, final_stats: Dictionary) -> void:
	if game_over:
		return
	game_over = true
	stats = final_stats   # слепок сервера: у обоих игроков одинаковые цифры
	# Достижения и агрегаты Steam разблокирует сервер = машина Защитника.
	# (Все три триггера возникают на сервере; для «атакерских» ачивок в
	# будущем понадобится дублировать события клиенту — см. README.)
	if multiplayer.is_server():
		SteamManager.add_stat_int(SteamManager.STAT_MATCHES, 1)
		SteamManager.add_stat_int(SteamManager.STAT_UNITS_KILLED, int(stats["units_killed"]))
		if defender_won:
			SteamManager.unlock_achievement(SteamManager.ACH_SURVIVOR)
			SteamManager.add_stat_int(SteamManager.STAT_WINS_DEFENDER, 1)
	# MMR обновляет КАЖДЫЙ пир локально (+25/-25 по своему результату):
	# Steam-стата и локальное зеркало — на машине самого игрока.
	var i_am_defender := multiplayer.get_unique_id() == defender_peer
	SteamManager.apply_match_result(i_am_defender == defender_won)
	game_ended.emit(defender_won)
