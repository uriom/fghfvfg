extends Control
## Главное меню «сессионной» игры: профиль игрока (Steam-аватар, имя, лига,
## MMR), три вкладки — Главная (ранговый поиск «В БОЙ»), Снаряжение (деки
## 3 башни + 3 юнита), Игра с другом (custom-лобби: ENet/Steam + инвайты).
##
## Переключение вкладок — с анимацией Tween (появление слева + проявление).
## Поиск матча ведёт SteamManager.quick_play(): статусы приходят в
## matchmaking_status («Идет поиск соперника… [00:12]»), отмена — кнопкой.

@onready var avatar_rect: TextureRect = %Avatar
@onready var avatar_initial: Label = %AvatarInitial
@onready var profile_name: Label = %ProfileName
@onready var profile_rank: Label = %ProfileRank
@onready var profile_mmr: Label = %ProfileMMR

@onready var tab_home_btn: Button = %TabHomeBtn
@onready var tab_loadout_btn: Button = %TabLoadoutBtn
@onready var tab_friend_btn: Button = %TabFriendBtn

@onready var home_panel: Control = %HomePanel
@onready var loadout_panel: Control = %LoadoutPanel
@onready var friend_panel: Control = %FriendPanel

@onready var role_pref_option: OptionButton = %RolePrefOption
@onready var play_btn: Button = %PlayBtn
@onready var cancel_search_btn: Button = %CancelSearchBtn
@onready var search_status: Label = %SearchStatus
@onready var player_list: Label = %PlayerList
@onready var transport_option: OptionButton = %TransportOption

@onready var tower_header: Label = %TowerHeader
@onready var tower_grid: GridContainer = %TowerGrid
@onready var unit_header: Label = %UnitHeader
@onready var unit_grid: GridContainer = %UnitGrid
@onready var loadout_status: Label = %LoadoutStatus

@onready var name_edit: LineEdit = %NameEdit
@onready var ip_row: HBoxContainer = %IpRow
@onready var ip_edit: LineEdit = %IpEdit
@onready var enet_buttons: HBoxContainer = %EnetButtons
@onready var steam_host_btn: Button = %SteamHostBtn
@onready var steam_invite_btn: Button = %SteamInviteBtn
@onready var steam_refresh_btn: Button = %SteamRefreshBtn
@onready var lobby_list: ItemList = %LobbyList
@onready var start_btn: Button = %StartBtn

@onready var status_label: Label = %Status

## Индексы ItemList -> id Steam-лобби (custom-таб).
var _lobby_ids: Array[int] = []
var _tab_tween: Tween


func _ready() -> void:
	_connect_signals()
	_setup_profile_bar()
	_setup_transport_selector()
	_setup_role_pref()
	_build_loadout_cards()
	_show_tab(0)
	AudioManager.play_music("bgm")


func _connect_signals() -> void:
	# Вкладки.
	tab_home_btn.pressed.connect(_show_tab.bind(0))
	tab_loadout_btn.pressed.connect(_show_tab.bind(1))
	tab_friend_btn.pressed.connect(_show_tab.bind(2))
	# Главная: ранговый поиск.
	play_btn.pressed.connect(_on_play_pressed)
	cancel_search_btn.pressed.connect(func() -> void:
		SteamManager.stop_matchmaking()
		cancel_search_btn.visible = false)
	SteamManager.matchmaking_status.connect(_on_matchmaking_status)
	SteamManager.matchmaking_stopped.connect(_on_matchmaking_stopped)
	# Снаряжение.
	%ResetLoadoutBtn.pressed.connect(_on_reset_loadout)
	# Игра с другом: ENet.
	%HostBtn.pressed.connect(func() -> void:
		AudioManager.play_sfx("click")
		NetworkManager.host_game(_player_name()))
	%JoinBtn.pressed.connect(func() -> void:
		AudioManager.play_sfx("click")
		var address := ip_edit.text.strip_edges()
		NetworkManager.join_game(address if not address.is_empty() else "127.0.0.1",
				_player_name()))
	# Игра с другом: Steam custom-лобби.
	steam_host_btn.pressed.connect(func() -> void:
		NetworkManager.host_game(_player_name()))
	steam_invite_btn.pressed.connect(func() -> void: SteamManager.invite_friends())
	steam_refresh_btn.pressed.connect(func() -> void:
		lobby_list.clear()
		_lobby_ids.clear()
		SteamManager.refresh_lobby_list())
	lobby_list.item_selected.connect(_on_lobby_selected)
	start_btn.pressed.connect(func() -> void:
		AudioManager.play_sfx("click")
		NetworkManager.start_match())
	# Общие состояния лобби.
	NetworkManager.player_list_changed.connect(_update_lobby)
	NetworkManager.lobby_message.connect(_on_lobby_message)
	SteamManager.lobbies_received.connect(_on_lobbies_received)


# ------------------------------------------------------------- Профиль ------

func _setup_profile_bar() -> void:
	var display_name := _player_name()
	if SteamManager.available and not SteamManager.persona_name.is_empty():
		display_name = SteamManager.persona_name
	profile_name.text = display_name
	_refresh_rank()
	# Аватар: GodotSteam отдаёт текстуру; без Steam/неудачи — заглушка
	# с инициалом на цветном фоне.
	var avatar := SteamManager.get_avatar_texture()
	if avatar != null:
		avatar_rect.texture = avatar
		avatar_initial.visible = false
	else:
		avatar_initial.text = display_name.left(1).to_upper()
		avatar_initial.visible = true


func _refresh_rank() -> void:
	profile_rank.text = SteamManager.rank_name()
	profile_rank.add_theme_color_override("font_color", SteamManager.rank_color())
	profile_mmr.text = "%d MMR" % SteamManager.mmr


# -------------------------------------------------------------- Вкладки -----

## Показать вкладку с анимацией: панель выезжает слева и проявляется.
func _show_tab(index: int) -> void:
	var panels: Array[Control] = [home_panel, loadout_panel, friend_panel]
	var buttons: Array[Button] = [tab_home_btn, tab_loadout_btn, tab_friend_btn]
	for i in panels.size():
		panels[i].visible = i == index
		buttons[i].disabled = i == index   # активную вкладку не жмут повторно
	var panel := panels[index]
	if _tab_tween != null and _tab_tween.is_valid():
		_tab_tween.kill()
	panel.modulate = Color(1, 1, 1, 0)
	panel.position.x = -24.0
	_tab_tween = create_tween()
	_tab_tween.set_parallel(true)
	_tab_tween.tween_property(panel, "modulate:a", 1.0, 0.18) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tab_tween.tween_property(panel, "position:x", 0.0, 0.18) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# --------------------------------------------- Главная: ранговый поиск ------

## Пункты списка идут в порядке enum NetworkManager.Transport
## (0 = ENet, 1 = Steam), поэтому индекс передаётся как есть.
func _setup_transport_selector() -> void:
	transport_option.add_item("ENet (локальный тест)")
	transport_option.add_item("Steam P2P")
	transport_option.selected = NetworkManager.transport
	transport_option.item_selected.connect(func(index: int) -> void:
		NetworkManager.set_transport(index as NetworkManager.Transport)
		_apply_transport_visibility())
	if not SteamManager.available:
		transport_option.set_item_disabled(NetworkManager.Transport.STEAM, true)
	_apply_transport_visibility()


## В режиме Steam ручной ввод IP не нужен — подключение через лобби/инвайт.
func _apply_transport_visibility() -> void:
	var steam_mode := NetworkManager.transport == NetworkManager.Transport.STEAM
	ip_row.visible = not steam_mode
	enet_buttons.visible = not steam_mode
	steam_host_btn.visible = steam_mode
	steam_refresh_btn.visible = steam_mode
	lobby_list.visible = steam_mode


func _setup_role_pref() -> void:
	role_pref_option.add_item("Приоритетная роль: любая")
	role_pref_option.add_item("Приоритет: Защитник (хостом)")
	role_pref_option.add_item("Приоритет: Штурмовик (гостем)")
	role_pref_option.selected = int(LoadoutManager.role_pref)
	role_pref_option.item_selected.connect(func(index: int) -> void:
		LoadoutManager.role_pref = index
		LoadoutManager.save_to_disk())


## «В БОЙ»: ранговый матчмейкинг (только со Steam). Иначе — подсказка.
func _on_play_pressed() -> void:
	AudioManager.play_sfx("click")
	if not SteamManager.available:
		search_status.text = "Ранговый поиск требует GodotSteam — вкладка «Игра с другом» (ENet)."
		return
	if not NetworkManager._is_offline():
		search_status.text = "Завершите текущую сессию перед новым поиском."
		return
	cancel_search_btn.visible = true
	search_status.text = "Ищем соперника… [00:00]"
	SteamManager.quick_play(int(LoadoutManager.role_pref))


func _on_matchmaking_status(text: String) -> void:
	search_status.text = text


func _on_matchmaking_stopped(reason: String) -> void:
	cancel_search_btn.visible = false
	search_status.text = reason
	_refresh_rank()   # MMR мог измениться после сыгранного матча
	_update_lobby()   # вернуть кнопку «В БОЙ» в актуальное состояние


# --------------------------------------------------------- Снаряжение -------

## Плитки карт: кнопки-переключатели; зажатая плитка = в деке. Больше 3
## добавить нельзя (клик отбивается), меньше — можно, добор дефолтами.
func _build_loadout_cards() -> void:
	for child in tower_grid.get_children():
		child.queue_free()
	for child in unit_grid.get_children():
		child.queue_free()
	for tower_id in GameDB.TOWER_ORDER:
		tower_grid.add_child(_make_card(tower_id, "towers"))
	for unit_id in GameDB.UNIT_ORDER:
		unit_grid.add_child(_make_card(unit_id, "units"))
	_refresh_deck_headers()


func _make_card(id: String, which: String) -> Button:
	var stats: Dictionary = (GameDB.TOWERS if which == "towers" else GameDB.UNITS)[id]
	var card := Button.new()
	card.toggle_mode = true
	card.custom_minimum_size = Vector2(200, 96)
	card.button_pressed = (LoadoutManager.towers if which == "towers" \
			else LoadoutManager.units).has(id)
	card.text = _card_text(id, stats)
	card.toggled.connect(func(pressed: bool) -> void:
		_on_card_toggled(which, id, card, pressed))
	return card


## Короткая сводка характеристик для плитки (3 строки).
func _card_text(_id: String, stats: Dictionary) -> String:
	var lines: Array[String] = []
	if stats.has("kind"):       # башня
		lines.append(stats["name"] + "  ·  " + str(stats["cost"]) + " зол.")
		var kind_names := {"beam": "луч", "lob": "сплеш", "frost": "фриз",
				"chain": "цепь", "flame": "огонь"}
		lines.append("урон %s  ·  %s/с  ·  %s" % [str(stats["damage"]),
				stats["fire_rate"], kind_names.get(stats["kind"], "-")])
		lines.append("радиус %s%s" % [stats["range"],
				"" if stats["can_target_flying"] else " · только земля"])
	else:                       # юнит
		lines.append(stats["name"] + "  ·  " + str(stats["cost"]) + " зол.")
		lines.append("HP %s  ·  скор. %s  ·  базе %s" % [stats["hp"],
				stats["speed"], stats["damage"]])
		var tags: Array[String] = []
		if stats["flying"]:
			tags.append("летает")
		if stats.get("ignores_slow", false):
			tags.append("иммун к фризу")
		if stats.has("aura_radius"):
			tags.append("аура -%d%%" % int(round(float(stats["aura_reduction"]) * 100)))
		lines.append(" | ".join(tags) if not tags.is_empty() else "наземный")
	return "\n".join(lines)


func _on_card_toggled(which: String, id: String, card: Button, pressed: bool) -> void:
	AudioManager.play_sfx("click")
	if pressed and not LoadoutManager.toggle_in_deck(which, id):
		# Дек полон: откатываем нажатие, подсказываем.
		card.set_pressed_no_signal(false)
		loadout_status.text = "В деке уже %d/%d — сначала снимите другую плитку." \
				% [LoadoutManager.DECK_SIZE, LoadoutManager.DECK_SIZE]
		return
	LoadoutManager.save_to_disk()
	_refresh_deck_headers()
	loadout_status.text = "Сохранено: user://loadout.cfg"


func _refresh_deck_headers() -> void:
	tower_header.text = "Башни Защитника — %d/%d" % [LoadoutManager.towers.size(),
			LoadoutManager.DECK_SIZE]
	unit_header.text = "Юниты Штурмовика — %d/%d" % [LoadoutManager.units.size(),
			LoadoutManager.DECK_SIZE]


func _on_reset_loadout() -> void:
	LoadoutManager.towers = LoadoutManager.DEFAULT_TOWERS.duplicate()
	LoadoutManager.units = LoadoutManager.DEFAULT_UNITS.duplicate()
	LoadoutManager.save_to_disk()
	_build_loadout_cards()
	loadout_status.text = "Деки сброшены к стандартным."


# ---------------------------------------------------- Игра с другом ---------

func _on_lobby_selected(index: int) -> void:
	if index < 0 or index >= _lobby_ids.size():
		return
	NetworkManager.join_steam_lobby(_lobby_ids[index])


func _on_lobbies_received(lobby_ids: Array) -> void:
	lobby_list.clear()
	_lobby_ids.clear()
	for id in lobby_ids:
		var title := SteamManager.get_lobby_title(int(id))
		_lobby_ids.append(int(id))
		lobby_list.add_item(title if not title.is_empty() else "Лобби %d" % int(id))
	if lobby_ids.is_empty():
		status_label.text = "Открытых лобби не найдено — создайте своё."


func _update_lobby() -> void:
	var lines: Array[String] = []
	for id in NetworkManager.players:
		var info: Dictionary = NetworkManager.players[id]
		var role_name := "Защитник" if int(info["role"]) == NetworkManager.Role.DEFENDER \
				else "Штурмовик"
		lines.append("%s — %s" % [info["name"], role_name])
	player_list.text = "\n".join(lines)
	# Ручной старт — только хосту custom-лобби с двумя игроками
	# (ранговые стартуют сами после отсчёта в SteamManager).
	start_btn.visible = NetworkManager.players.size() > 0 and multiplayer.is_server()
	start_btn.disabled = NetworkManager.players.size() < 2
	steam_invite_btn.visible = SteamManager.available and SteamManager.lobby_id != 0 \
			and multiplayer.is_server() and not SteamManager.is_matchmaking()
	# Пока идёт поиск или мы в сети — «В БОЙ» недоступен.
	play_btn.disabled = not NetworkManager._is_offline() or SteamManager.is_matchmaking()


func _on_lobby_message(text: String) -> void:
	status_label.text = text


func _player_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if not n.is_empty() else "Игрок"
