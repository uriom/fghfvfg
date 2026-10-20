class_name UnitSpawner
extends MultiplayerSpawner
## Спавнер юнитов: серверная логика запросов штурмовика + репликация.
##
## Поток действий:
##   1. Штурмовик жмёт кнопку -> HUD вызывает request_unit.rpc_id(1, ...) или
##      request_wave.rpc_id(1, ...) — запрос уходит ТОЛЬКО серверу.
##   2. Сервер проверяет роль, кулдаун и золото (GameState.try_spend).
##   3. Сервер вызывает spawn(data) — MultiplayerSpawner на ОБОИХ пирах
##      вызывает _spawn_unit(data), и юнит появляется на дороге синхронно.
##
## Узел лежит дочерним к Path2D «Road», поэтому spawn_path = ".." —
## все юниты добавляются прямо к дороге (PathFollow2D требует Path2D-родителя).

const UNIT_SCENE := preload("res://scenes/units/unit.tscn")
const SINGLE_COOLDOWN_MS := 400   # защита от спама одиночных юнитов

@export var wave_size := 5        # сколько юнитов в одной волне
@export var wave_interval := 0.7  # пауза между юнитами волны, сек

var _spawn_counter := 0
var _last_single_ms: Dictionary = {}   # peer_id -> Time.get_ticks_msec()
var _wave_queue: Array[String] = []    # очередь типов юнитов текущей волны
var _wave_timer: Timer


func _ready() -> void:
	# spawn_function обязана быть задана на ОБОИХ пирах: на сервере она
	# создаёт юнит при spawn(), на клиенте — при получении спавна.
	spawn_function = _spawn_unit
	_wave_timer = Timer.new()
	_wave_timer.wait_time = wave_interval
	_wave_timer.timeout.connect(_process_wave_queue)
	add_child(_wave_timer)


# ------------------------------------------------- Запросы штурмовика -------

## Отправить одного юнита выбранного типа.
@rpc("any_peer", "call_remote", "reliable")
func request_unit(unit_id: String) -> void:
	if not multiplayer.is_server() or GameState.game_over:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _sender_is_attacker(sender) or not GameDB.UNITS.has(unit_id):
		return
	if not GameState.attacker_units.has(unit_id):
		return   # юниты вне дека этого матча запрещены (сервер — арбитр)
	# Кулдаун, чтобы даблклик не вылил дорогу юнитами.
	var now := Time.get_ticks_msec()
	if now - int(_last_single_ms.get(sender, 0)) < SINGLE_COOLDOWN_MS:
		return
	_last_single_ms[sender] = now
	_try_spawn(sender, unit_id)


## Отправить волну из wave_size юнитов. Золото списывается целиком сразу.
@rpc("any_peer", "call_remote", "reliable")
func request_wave(unit_id: String) -> void:
	if not multiplayer.is_server() or GameState.game_over:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _sender_is_attacker(sender) or not GameDB.UNITS.has(unit_id):
		return
	if not GameState.attacker_units.has(unit_id):
		return   # волна из юнитов вне дека не проходит валидацию
	var total_cost: int = GameDB.UNITS[unit_id]["cost"] * wave_size
	if not GameState.try_spend(sender, total_cost):
		return   # не хватило золота — просто игнорируем (можно добавить сигнал в UI)
	GameState.record_wave()   # статистика матча: отправлена волна
	for i in wave_size:
		_wave_queue.append(unit_id)
	if _wave_timer.is_stopped():
		_wave_timer.start()


# ------------------------------------------------------ Серверный спавн -----

func _try_spawn(attacker: int, unit_id: String) -> void:
	# Золото списываем до спавна: при неудаче юнит не появляется.
	if not GameState.try_spend(attacker, GameDB.UNITS[unit_id]["cost"]):
		return
	GameState.record_unit_sent()   # статистика матча: отправлен юнит
	spawn({"unit_id": unit_id, "attacker": attacker, "idx": _spawn_counter})


func _process_wave_queue() -> void:
	if not multiplayer.is_server():
		return
	if _wave_queue.is_empty():
		_wave_timer.stop()
		return
	var unit_id: String = _wave_queue.pop_front()
	_try_spawn(GameState.attacker_peer, unit_id)


func _sender_is_attacker(peer_id: int) -> bool:
	return peer_id == GameState.attacker_peer


## Вызывается движком на ВСЕХ пирах: и при spawn() на сервере,
## и при получении спавна на клиенте. Данные (data) одинаковы у обоих.
func _spawn_unit(data: Dictionary) -> Node:
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.setup(data["unit_id"], data["attacker"], data["idx"])
	# Чуть растягиваем очередь, чтобы юниты не шли сплошной точкой.
	unit.progress = float(int(data["idx"]) % 12) * 16.0
	_spawn_counter += 1
	return unit
