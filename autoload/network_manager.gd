extends Node
## Автозагрузка «NetworkManager»: лобби, P2P-соединение, роли, старт матча.
##
## ЭТАП 2 — два транспорта, переключаемых из главного меню:
##   * Transport.ENET  — прямой P2P по IP:PORT (для локального тестирования);
##   * Transport.STEAM — GodotSteam: Steam-лобби + SteamMultiplayerPeer
##     (P2P через сеть Steam, работает без проброса портов).
##
## Модель сети ЕДИНА для обоих транспортов: сервер (хост = Защитник) —
## арбитр, валидирует постройки/спавн/экономику и рассылает результаты.
## High-level Multiplayer API абстрагирует транспорт, поэтому остальная
## игра (RPC, спавнеры, синхронизаторы) от режима не зависит.
##
## GodotSteam НЕ обязательно установлен: Steam-режим просто недоступен,
## пока SteamManager.available == false (см. steam_manager.gd).

signal player_list_changed              # состав лобби обновился
signal lobby_message(text: String)      # текстовые статусы для UI меню
signal opponent_left                    # соперник отключился

enum Role { NONE, DEFENDER, ATTACKER }
enum Transport { ENET, STEAM }

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const PORT := 24565
const MAX_CLIENTS := 1                  # режим 1v1: максимум один клиент
const STEAM_CHANNEL := 0                # канал SteamMultiplayerPeer
## Соло-тренировка: оффлайн-пир, игрок = Защитник (peer 1), бот = Штурмовик
## (виртуальный peer 2). Бот ходит серверными методами напрямую, поэтому
## отдельного сетевого транспорта не нужно — матч идёт «на одном столе».
const BOT_PEER := 2

## peer_id -> {"name": String, "role": Role}. Одинаковый у обоих пиров,
## синхронизируется сервером через _sync_players().
var players: Dictionary = {}

var transport := Transport.ENET         # дефолт: без GodotSteam только ENet
## Идёт ли соло-матч. Сбрасывается в end_session().
var solo := false

var _my_name := "Игрок"


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# Steam-режим включаем по умолчанию, только если GodotSteam живой.
	if SteamManager.available:
		transport = Transport.STEAM
		SteamManager.lobby_created_ok.connect(_on_steam_lobby_created)
		SteamManager.lobby_joined_ok.connect(_on_steam_lobby_joined)


# ----------------------------------------------------------- Транспорт ------

## Переключение режима сети (вызывается из меню). Недоступный Steam
## молча подменяется на ENet с сообщением в статус.
func set_transport(value: Transport) -> void:
	if value == Transport.STEAM and not SteamManager.available:
		lobby_message.emit("GodotSteam недоступен — остаёмся на ENet.")
		value = Transport.ENET
	transport = value


func is_steam_transport() -> bool:
	return transport == Transport.STEAM and SteamManager.available


# --------------------------------------------------------------- Лобби ------

## Создать лобби (хост). Хост всегда играет за Защитника.
## ranked = true — лобби рангового матчмейкинга (mode=towerduel_ranked).
func host_game(player_name: String, ranked := false) -> void:
	if not _is_offline():
		lobby_message.emit("Вы уже в сети — завершите сеанс перед новым подключением.")
		return
	_my_name = player_name
	match transport:
		Transport.STEAM:
			_host_steam(ranked)
		_:
			_host_enet()


## ENet: подключиться к хосту по адресу. Клиент всегда играет за Штурмовика.
func join_game(address: String, player_name: String) -> void:
	if transport == Transport.STEAM:
		lobby_message.emit("В режиме Steam подключайтесь через список лобби или приглашение.")
		return
	if not _is_offline():
		lobby_message.emit("Вы уже в сети — завершите сеанс перед новым подключением.")
		return
	_my_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		lobby_message.emit("Не удалось создать подключение (ошибка %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	lobby_message.emit("Подключаемся к %s…" % address)


## Steam: войти в лобби из списка (сам peer создаётся по сигналу входа).
func join_steam_lobby(p_lobby_id: int) -> void:
	if not is_steam_transport():
		return
	if not _is_offline():
		lobby_message.emit("Вы уже в сети — завершите сеанс перед новым подключением.")
		return
	if p_lobby_id == SteamManager.lobby_id:
		return
	lobby_message.emit("Входим в Steam-лобби…")
	SteamManager.join_lobby(p_lobby_id)


## Хост запускает матч: обе стороны загружают сцену game.tscn.
func start_match() -> void:
	if not multiplayer.is_server():
		return
	if players.size() < 2:
		lobby_message.emit("Для старта нужно два игрока.")
		return
	_start_match.rpc()


## Соло-тренировка против бота: мгновенный старт без сети.
## Игрок всегда Защитник — так первый матч учит строить и держать базу.
func start_solo() -> void:
	# Чистим возможный прошлый сеанс, но без смены сцены.
	SteamManager.stop_matchmaking()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	solo = true
	players = {
		1: _host_entry(),
		BOT_PEER: {
			"name": "ТРЕНЕР",
			"role": Role.ATTACKER,
			"towers": LoadoutManager.effective_towers(),
			"units": LoadoutManager.effective_units(),
		},
	}
	player_list_changed.emit()
	_start_match.rpc()


## Идёт ли сейчас соло-матч (без сетевого соперника).
func is_solo() -> bool:
	return solo and _is_offline()


## Полностью завершить сетевой сеанс и вернуться в меню.
func end_session() -> void:
	# Гасим активный поиск матча (тихо, без повторного end_session).
	SteamManager.stop_matchmaking()
	AudioManager.stop_music()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	SteamManager.leave_lobby()
	solo = false
	players.clear()
	player_list_changed.emit()
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path != MENU_SCENE:
		get_tree().change_scene_to_file(MENU_SCENE)


# ---------------------------------------------------- Транспорт: ENet -------

func _host_enet() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		lobby_message.emit("Не удалось занять порт %d (ошибка %d)." % [PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	players = {1: _host_entry()}
	player_list_changed.emit()
	lobby_message.emit("Лобби создано на порту %d. Ожидаем штурмовика…" % PORT)


# ---------------------------------------------------- Транспорт: Steam ------

func _host_steam(ranked := false) -> void:
	if SteamManager.lobby_id != 0:
		lobby_message.emit("Steam-лобби уже создано — приглашайте друга.")
		return
	lobby_message.emit("Создаём Steam-лобби…")
	SteamManager.create_lobby(MAX_CLIENTS + 1, ranked)


## Наше Steam-лобби создано — поднимаем host-пир и открываем слот Защитника.
func _on_steam_lobby_created(steam_lobby_id: int) -> void:
	var peer := _make_steam_host_peer()
	if peer == null:
		lobby_message.emit("SteamMultiplayerPeer недоступен — проверьте установку GodotSteam.")
		return
	multiplayer.multiplayer_peer = peer
	players = {1: _host_entry()}
	player_list_changed.emit()
	lobby_message.emit("Steam-лобби готово (id %d). Пригласите друга или ждём из поиска…"
			% steam_lobby_id)


## Запись хоста в составе лобби: роль Защитника + его бойевой дек
## (используется сервером для валидации и обоими HUD для кнопок).
func _host_entry() -> Dictionary:
	return {
		"name": _my_name,
		"role": Role.DEFENDER,
		"towers": LoadoutManager.effective_towers(),
		"units": LoadoutManager.effective_units(),
	}


## Мы вошли в Steam-лобби. Хост уже поднял свой пир; гость создаёт клиентский.
func _on_steam_lobby_joined(_steam_lobby_id: int, owner_steam_id: int) -> void:
	if owner_steam_id == SteamManager.steam_id:
		return   # это своё лобби: host-пир уже создан в _on_steam_lobby_created
	var peer := _make_steam_client_peer(owner_steam_id)
	if peer == null:
		lobby_message.emit("SteamMultiplayerPeer недоступен — проверьте установку GodotSteam.")
		return
	multiplayer.multiplayer_peer = peer
	lobby_message.emit("Подключаемся к хосту через Steam…")


## Пир-хост: слушать друзей из лобби. Класс берём из ClassDB, чтобы проект
## компилировался без установленного GodotSteam.
func _make_steam_host_peer() -> MultiplayerPeer:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return null
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.create_host(STEAM_CHANNEL)
	if err != OK:
		return null
	# Разрешаем ретрансляцию через серверы Valve, если прямой P2P невозможен.
	if "server_relay" in peer:
		peer.server_relay = true
	return peer as MultiplayerPeer


func _make_steam_client_peer(owner_steam_id: int) -> MultiplayerPeer:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return null
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.create_client(owner_steam_id, STEAM_CHANNEL)
	if err != OK:
		return null
	if "server_relay" in peer:
		peer.server_relay = true
	return peer as MultiplayerPeer


# ------------------------------------------------------ Роли и утилиты ------

func local_role() -> Role:
	var id := multiplayer.get_unique_id()
	if players.has(id):
		return players[id]["role"]
	return Role.NONE


func defender_peer() -> int:
	if solo:
		return 1
	for id in players:
		if players[id]["role"] == Role.DEFENDER:
			return id
	return 1


func attacker_peer() -> int:
	if solo:
		return BOT_PEER
	for id in players:
		if players[id]["role"] == Role.ATTACKER:
			return id
	return -1


func _is_offline() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer == null or peer is OfflineMultiplayerPeer


# ------------------------------------------------------------- RPC ----------

## Клиент представляется серверу сразу после подключения: имя + его дек
## (башни Защитника здесь не нужны — клиент всегда Штурмовик, но шлём оба
## списка для симметрии и будущих режимов).
@rpc("any_peer", "call_remote", "reliable")
func _register(p_name: String, p_towers: Array, p_units: Array) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	players[sender] = {
		"name": p_name,
		"role": Role.ATTACKER,
		"towers": p_towers,
		"units": p_units,
	}
	_sync_players.rpc(players)
	lobby_message.emit("%s подключился к лобби." % p_name)


## Сервер рассылает всем актуальный состав лобби (источник истины — сервер).
@rpc("authority", "call_local", "reliable")
func _sync_players(p_players: Dictionary) -> void:
	players = p_players
	player_list_changed.emit()


## Сервер командует всем (включая себя) загрузить сцену матча.
@rpc("authority", "call_local", "reliable")
func _start_match() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


# ----------------------------------------------------- Сигналы сети ---------

func _on_peer_connected(_id: int) -> void:
	# Имя подключившегося он пришлёт сам через _register(). Ничего не делаем.
	pass


func _on_peer_disconnected(id: int) -> void:
	if not players.has(id):
		return
	var left_name: String = players[id]["name"]
	players.erase(id)
	opponent_left.emit()
	if multiplayer.is_server():
		_sync_players.rpc(players)
	lobby_message.emit("%s покинул игру." % left_name)
	# Если матч был в процессе — даём секунды прочитать сообщение и выходим.
	# После финала (game_over) НЕ рвём сессию сами: у победителя открыт экран
	# статистики, он вернётся в лобби кнопкой (end_session).
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path == GAME_SCENE and not GameState.game_over:
		await get_tree().create_timer(2.0).timeout
		end_session()


func _on_connected_to_server() -> void:
	_register.rpc_id(1, _my_name, LoadoutManager.effective_towers(), LoadoutManager.effective_units())


func _on_connection_failed() -> void:
	end_session()
	lobby_message.emit("Не удалось подключиться к серверу.")


func _on_server_disconnected() -> void:
	end_session()
	lobby_message.emit("Соединение с хостом потеряно.")
