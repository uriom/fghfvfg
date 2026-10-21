class_name UnitSpawner
extends MultiplayerSpawner
## Спавнер юнитов: серверная логика очереди штурмовика + репликация.
##
## ЭТАП 6 — ОЧЕРЕДЬ ВМЕСТО КУЛДАУНА (SPEC-01/SPEC-02).
## Раньше одиночный спавн резался кулдауном 400 мс, а «волна» покупала сразу
## пять юнитов. Теперь у штурмовика есть очередь до MAX_QUEUE юнитов:
##   * покупка в ПОДГОТОВКЕ копит армию к штурму (кредиты списываются сразу);
##   * покупка в ШТУРМЕ добавляет юнитов на ходу (доход капает во время боя);
##   * сервер выкладывает очередь по одному юниту каждые deploy_interval сек.
## Это и есть контр-плей насыщением: много дешёвых тел против одиночной цели.
##
## Поток: HUD -> enqueue_unit() -> (RPC) -> сервер: роль/дек/золото/лимит ->
## очередь -> spawn(). Клиент может только просить; всё решает сервер.

const UNIT_SCENE := preload("res://scenes/units/unit.tscn")

## Сколько юнитов можно держать в очереди. Волна = 5, значит две волны + запас.
## 14 — это и «залп ПРОРЫВА»: разом выпущенная очередь должна ощутимо
## перегружать оборону (см. tools/balance_audit.py, кейсы burst gap 0.05).
const MAX_QUEUE := 14
## Потолок живых юнитов: предохранитель от «каши» из нод и просадки FPS.
const MAX_ALIVE := 70

@export var wave_size := 5          # размер «волны» одной кнопкой
@export var deploy_interval := 0.45 # пауза между юнитами очереди, сек

var _spawn_counter := 0
var _queue: Array[String] = []
var _deploy_clock := 0.0
## Размер и состав очереди, известные клиенту (для HUD и разведки Защитника).
var _remote_queue := 0
var _remote_comp: Array[String] = []


func _ready() -> void:
	# spawn_function обязана быть задана на ОБОИХ пирах: на сервере она
	# создаёт юнит при spawn(), на клиенте — при получении спавна.
	spawn_function = _spawn_unit
	# Конец раунда: недоставленная очередь сгорает (иначе копится армия).
	GameState.round_ended.connect(_on_round_ended)


func _process(delta: float) -> void:
	if not multiplayer.is_server() or GameState.game_over:
		return
	if _queue.is_empty():
		_deploy_clock = 0.0
		return
	# Очередь выкладывается только в штурме: подготовка — время копить армию.
	if not GameState.is_assault():
		return
	_deploy_clock += delta
	if _deploy_clock < deploy_interval:
		return
	_deploy_clock = 0.0
	_deploy_next()


# ------------------------------------------------- Запросы штурмовика -------

## Добавить count юнитов в очередь. Вызывается из HUD.
func enqueue_unit(unit_id: String, count := 1) -> void:
	if GameState.game_over:
		return
	if multiplayer.is_server():
		_server_enqueue(multiplayer.get_unique_id(), unit_id, count)
	else:
		request_enqueue.rpc_id(1, unit_id, count)


@rpc("any_peer", "call_remote", "reliable")
func request_enqueue(unit_id: String, count: int) -> void:
	if not multiplayer.is_server():
		return
	_server_enqueue(multiplayer.get_remote_sender_id(), unit_id, count)


## Серверная валидация и покупка. sender — peer, платящий кредиты.
func _server_enqueue(sender: int, unit_id: String, count: int) -> void:
	count = clampi(count, 1, wave_size)
	if not _enqueue_allowed(sender, unit_id, count):
		return
	var total_cost: int = int(GameDB.UNITS[unit_id]["cost"]) * count
	if not GameState.try_spend(sender, total_cost):
		return
	if count >= wave_size:
		GameState.record_wave()
	for i in count:
		_queue.append(unit_id)
	_sync_queue.rpc(_queue.size(), PackedStringArray(_queue))


## Все проверки покупки в одном месте: роль, дек, фаза, лимит очереди.
func _enqueue_allowed(sender: int, unit_id: String, count: int) -> bool:
	if GameState.game_over or sender != GameState.attacker_peer:
		return false
	# Юниты вне дека этого матча запрещены (сервер — арбитр).
	if not GameDB.UNITS.has(unit_id) or not GameState.attacker_units.has(unit_id):
		return false
	if GameState.round_phase == GameState.Phase.REVIEW \
			or GameState.round_phase == GameState.Phase.FINISHED:
		return false
	return _queue.size() + count <= MAX_QUEUE


func _on_round_ended(_round_index: int, _attacker_won: bool,
		_defender_wins: int, _attacker_wins: int) -> void:
	clear_queue()
	_remote_queue = 0


## Сколько юнитов ждёт выхода (HUD и проверка «штурм заглох»).
func queue_size() -> int:
	return _queue.size() if multiplayer.is_server() else _remote_queue


## Очистка очереди на конце раунда: недоставленные юниты не переезжают
## в следующий раунд (иначе копится бесплатная армия).
func clear_queue() -> void:
	if multiplayer.is_server():
		_queue.clear()
		_deploy_clock = 0.0
		_sync_queue.rpc(0, PackedStringArray())


# ------------------------------------------------------ Серверный спавн -----

## Клиент видит длину и состав очереди: HUD не врёт, а Защитник получает
## «разведку» — что именно штурмовик закупил в подготовке. Это превращает
## слепую ставку «успею ли я построить ПВО» в осмысленное решение.
@rpc("authority", "call_local", "reliable")
func _sync_queue(size: int, comp: PackedStringArray = PackedStringArray()) -> void:
	_remote_queue = size
	_remote_comp = Array(comp)


## Состав очереди для HUD (у клиента — присланный сервером).
func queue_composition() -> Array[String]:
	var source: Array[String] = _queue if multiplayer.is_server() else _remote_comp
	var out: Array[String] = []
	for id in source:
		out.append(String(id))
	return out


## «ПРОРЫВ»: выложить ВСЮ очередь немедленно (способность Штурмовика).
## Вызывается только сервером из GameState._apply_ability.
func release_all() -> void:
	if not multiplayer.is_server():
		return
	while not _queue.is_empty() and GameState.is_assault():
		var before := _queue.size()
		_deploy_next()
		if _queue.size() == before:
			break   # упёрлись в MAX_ALIVE — остаток очереди подождёт
	_sync_queue.rpc(_queue.size(), PackedStringArray(_queue))


func _deploy_next() -> void:
	if _queue.is_empty():
		return
	if not GameState.is_assault():
		return
	if get_tree().get_nodes_in_group("units").size() >= MAX_ALIVE:
		return   # предохранитель: не превращаем дорогу в кашу из нод
	var unit_id: String = _queue.pop_front()
	GameState.record_unit_sent()
	spawn({"unit_id": unit_id, "attacker": GameState.attacker_peer,
			"idx": _spawn_counter})


## Вызывается движком на ВСЕХ пирах: и при spawn() на сервере,
## и при получении спавна на клиенте. Данные (data) одинаковы у обоих.
func _spawn_unit(data: Dictionary) -> Node:
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.setup(data["unit_id"], data["attacker"], data["idx"])
	# Чуть растягиваем очередь, чтобы юниты не шли сплошной точкой.
	unit.progress = float(int(data["idx"]) % 12) * 16.0
	_spawn_counter += 1
	return unit
