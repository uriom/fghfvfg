class_name UnitSpawner
extends MultiplayerSpawner
## Спавнер юнитов: серверная логика очереди штурмовика + репликация.
##
## ЭТАП 7 — ОЧЕРЕДЬ + УДЕРЖАНИЕ КНОПКИ.
##   * покупка в ПОДГОТОВКЕ копит армию к штурму (кредиты списываются сразу);
##   * покупка в ШТУРМЕ добавляет юнитов на ходу, но только 30 с: после
##     закрытия окна спавна остаётся добить уже выпущенное;
##   * сервер выкладывает очередь по одному юниту каждые deploy_interval сек;
##   * каждая покупка несёт УРОВЕНЬ типа юнита (GameState.unit_levels), поэтому
##     прокачанный тип приходит на поле сильнее.
## «Волны ×5» больше нет: HUD покупает по одному, пока кнопку держат.
##
## Поток: HUD -> enqueue_unit() -> (RPC) -> сервер: роль/дек/золото/лимит ->
## очередь -> spawn(). Клиент может только просить; всё решает сервер.

const UNIT_SCENE := preload("res://scenes/units/unit.tscn")

## Очередь: 40 юнитов — это ~7 с беспрерывного выпуска. Накопить больше
## не даёт смысла (окно спавна 30 с), но и не режет «зажал кнопку и залил».
const MAX_QUEUE := 40
## Потолок живых юнитов: предохранитель от «каши» из нод и просадки FPS.
const MAX_ALIVE := 70

@export var deploy_interval := 0.45 # пауза между юнитами очереди, сек

var _spawn_counter := 0
var _queue: Array[String] = []
var _deploy_clock := 0.0
## Размер очереди, известный клиенту (HUD показывает «сколько ещё выйдет»).
var _remote_queue := 0


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
## count > 1 приходит от «зажатой» кнопки (HUD шлёт пакеты) или от бота —
## поэтому цена считается за весь пакет сразу.
func _server_enqueue(sender: int, unit_id: String, count: int) -> void:
	count = clampi(count, 1, MAX_QUEUE)
	if not _enqueue_allowed(sender, unit_id, count):
		return
	var total_cost: int = int(GameDB.UNITS[unit_id]["cost"]) * count
	if not GameState.try_spend(sender, total_cost):
		return
	if count >= 5:
		GameState.record_wave()
	for i in count:
		_queue.append(unit_id)
	_sync_queue.rpc(_queue.size())


## Все проверки покупки в одном месте: роль, дек, фаза, лимит очереди.
func _enqueue_allowed(sender: int, unit_id: String, count: int) -> bool:
	if GameState.game_over or sender != GameState.attacker_peer:
		return false
	# Юниты вне дека этого матча запрещены (сервер — арбитр).
	if not GameDB.UNITS.has(unit_id) or not GameState.attacker_units.has(unit_id):
		return false
	# Окно спавна: 30 с штурма. Дальше — только добивание уже купленного.
	if not GameState.can_buy_units():
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

## Клиент видит только длину очереди: HUD не врёт про «сколько ещё выйдет».
## Разведка состава убрана по итогам плейтеста (Защитник не должен читать
## заход атакующего заранее), поэтому состав по сети больше не летит.
@rpc("authority", "call_local", "reliable")
func _sync_queue(size: int) -> void:
	_remote_queue = size


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
	_sync_queue.rpc(_queue.size())


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
			"idx": _spawn_counter, "level": GameState.unit_level(unit_id)})


## Вызывается движком на ВСЕХ пирах: и при spawn() на сервере,
## и при получении спавна на клиенте. Данные (data) одинаковы у обоих.
func _spawn_unit(data: Dictionary) -> Node:
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.setup(data["unit_id"], data["attacker"], data["idx"],
			int(data.get("level", 1)))
	# Все входят в портал с нулевой отметки: зажатая кнопка выпускает поток
	# юнитов, и «растягивание» прогрессом ставило их уже посреди дороги.
	unit.progress = 0.0
	_spawn_counter += 1
	return unit
