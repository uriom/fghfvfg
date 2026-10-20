extends Control
## Главное меню «сессионной» игры: профиль игрока (Steam-аватар, имя, лига,
## MMR), три вкладки — Главная (ранговый поиск «В БОЙ»), Снаряжение (деки
## 3 башни + 3 юнита), Игра с другом (custom-лобби: ENet/Steam + инвайты).
##
## Переключение вкладок — с анимацией Tween (появление слева + проявление).
## Поиск матча ведёт SteamManager.quick_play(): статусы приходят в
## matchmaking_status («Идет поиск соперника… [00:12]»), отмена — кнопкой.

const SETTINGS_DIALOG := preload("res://scripts/settings_dialog.gd")

var _lobby_ids: Array[int] = []
var _tab_tween: Tween
var _utility_row: HBoxContainer
var _key_art: TextureRect
var _loadout_tile_width := 200.0

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

func _ready() -> void:
	theme = UISkin.theme()
	_build_menu_backdrop()
	_add_ambient_particles()
	_build_brand_header()
	_build_utility_buttons()
	_connect_signals()
	_style_primary_action()
	for item in find_children("*", "Button", true, false):
		_wire_button_feedback(item as Button)
	_setup_profile_bar()
	_setup_transport_selector()
	_setup_role_pref()
	_build_loadout_cards()
	_show_tab(0)
	get_viewport().size_changed.connect(_fit_responsive_layout)
	call_deferred("_fit_responsive_layout")
	AudioManager.play_music("bgm")
	play_btn.grab_focus()


func _build_menu_backdrop() -> void:
	var backdrop := TextureRect.new()
	_key_art = backdrop
	backdrop.name = "KeyArt"
	backdrop.texture = load("res://assets/img/menu_keyart.png")
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.pivot_offset = get_viewport_rect().size * 0.5
	backdrop.resized.connect(func() -> void: backdrop.pivot_offset = backdrop.size * 0.5)
	add_child(backdrop)
	move_child(backdrop, 1)
	var camera_drift := create_tween().set_loops()
	camera_drift.tween_property(backdrop, "scale", Vector2.ONE * 1.035, 22.0) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	camera_drift.tween_property(backdrop, "scale", Vector2.ONE, 22.0) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var shade := ColorRect.new()
	shade.name = "KeyArtShade"
	shade.color = Color(0.005, 0.014, 0.030, 0.48)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	move_child(shade, 2)
	# Дополнительная затемняющая растяжка слева держит текст контрастным,
	# не закрывая реактор и ключевой арт справа.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.008, 0.020, 0.038, 0.97))
	gradient.set_color(1, Color(0.008, 0.020, 0.038, 0.0))
	gradient.add_point(0.58, Color(0.008, 0.020, 0.038, 0.82))
	gradient.set_color(1, Color(0.008, 0.020, 0.038, 0.82))
	var gradient_texture := GradientTexture2D.new()
	gradient_texture.gradient = gradient
	gradient_texture.fill = GradientTexture2D.FILL_LINEAR
	gradient_texture.fill_from = Vector2(0.0, 0.5)
	gradient_texture.fill_to = Vector2(1.0, 0.5)
	gradient_texture.width = 1024
	gradient_texture.height = 8
	var left_fade := TextureRect.new()
	left_fade.texture = gradient_texture
	left_fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	left_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_fade.anchor_right = 0.80
	left_fade.anchor_bottom = 1.0
	add_child(left_fade)
	move_child(left_fade, 3)


func _add_ambient_particles() -> void:
	var glow := Gradient.new()
	glow.add_point(0.0, Color(0.58, 0.94, 1.0, 0.65))
	glow.add_point(0.28, Color(0.18, 0.72, 1.0, 0.26))
	glow.add_point(1.0, Color(0.10, 0.55, 1.0, 0.0))
	var glow_texture := GradientTexture2D.new()
	glow_texture.gradient = glow
	glow_texture.fill = GradientTexture2D.FILL_RADIAL
	glow_texture.width = 32
	glow_texture.height = 32
	var particles := CPUParticles2D.new()
	particles.name = "AmbientDust"
	particles.position = Vector2(576, 340)
	particles.z_index = 0
	particles.amount = 34
	particles.lifetime = 8.0
	particles.preprocess = 8.0
	particles.emitting = true
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	particles.emission_rect_extents = Vector2(590, 330)
	particles.direction = Vector2.UP
	particles.spread = 180.0
	particles.gravity = Vector2(-2.0, -5.0)
	particles.initial_velocity_min = 3.0
	particles.initial_velocity_max = 12.0
	particles.scale_amount_min = 0.12
	particles.scale_amount_max = 0.38
	particles.color = Color(0.32, 0.88, 1.0, 0.5)
	particles.texture = glow_texture
	add_child(particles)
	move_child(particles, 4)


func _build_brand_header() -> void:
	var profile := get_node("Main/VBox/ProfilePanel/ProfileMargin/ProfileBar") as HBoxContainer
	var brand := VBoxContainer.new()
	brand.name = "BrandHeader"
	brand.custom_minimum_size.x = 152.0
	brand.add_theme_constant_override("separation", 0)
	var title := Label.new()
	title.text = "TOWER DUEL"
	title.add_theme_font_size_override("font_size", 23)
	title.add_theme_color_override("font_color", UISkin.TEXT)
	brand.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "TACTICAL DEFENSE"
	subtitle.add_theme_font_size_override("font_size", 10)
	subtitle.add_theme_color_override("font_color", UISkin.CYAN)
	brand.add_child(subtitle)
	profile.add_child(brand)
	profile.move_child(brand, 0)


func _build_utility_buttons() -> void:
	var row := HBoxContainer.new()
	_utility_row = row
	row.name = "UtilityButtons"
	row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	row.offset_left = -374.0
	row.offset_top = 18.0
	row.offset_right = -22.0
	row.offset_bottom = 60.0
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	_add_utility_button(row, "НАСТРОЙКИ", func() -> void:
		var dialog := SETTINGS_DIALOG.new()
		add_child(dialog))
	_add_utility_button(row, "ОБ ИГРЕ", _show_about)
	_add_utility_button(row, "ВЫХОД", func() -> void: get_tree().quit())
	status_label.text = "ЛУЧШИЙ РЕЗУЛЬТАТ  ·  %d" % SettingsManager.best_score


func _fit_responsive_layout() -> void:
	if not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	var width := viewport_size.x
	# Сохраняем отступ между основной колонкой и верхними кнопками, но
	# постепенно сжимаем колонки/карточки при уменьшении окна.
	var ratio := lerpf(0.56, 0.62, clampf((width - 960.0) / 192.0, 0.0, 1.0))
	var column_width := minf(width * ratio, 740.0)
	var content_width := maxf(0.0, column_width - 56.0)
	var tile_width := maxf(112.0, (content_width - 20.0) / 3.0)
	_loadout_tile_width = tile_width
	var main_column := get_node_or_null("Main") as Control
	if main_column != null and width > 0.0:
		main_column.anchor_right = column_width / width
	var tab_row := get_node_or_null("Main/VBox/Tabs") as HBoxContainer
	if tab_row != null:
		var tab_width := maxf(96.0, (content_width - 20.0) / 3.0)
		for child in tab_row.get_children():
			if child is Button:
				(child as Button).custom_minimum_size.x = tab_width
				(child as Button).add_theme_font_size_override(
						"font_size", 11 if tab_width < 132.0 else 14)
		for grid in [tower_grid, unit_grid]:
			for child in grid.get_children():
				if child is Button:
					(child as Button).custom_minimum_size.x = tile_width
					(child as Button).add_theme_font_size_override(
						"font_size", 11 if tile_width < 150.0 else 13 if tile_width < 185.0 else 15)
	if _utility_row != null:
		for child in _utility_row.get_children():
			if child is Button:
				(child as Button).custom_minimum_size.x = minf(108.0,
						maxf(82.0, (width - 44.0) / 3.0))
	if _key_art != null:
		_key_art.pivot_offset = _key_art.size * 0.5


func _add_utility_button(parent: HBoxContainer, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(108, 40)
	button.pressed.connect(callback)
	parent.add_child(button)


func _style_primary_action() -> void:
	play_btn.text = "⚔   В БОЙ  ·  РАНГОВЫЙ ПОИСК"
	play_btn.add_theme_font_size_override("font_size", 21)
	play_btn.add_theme_color_override("font_color", Color(0.012, 0.055, 0.075))
	play_btn.add_theme_color_override("font_hover_color", Color(0.012, 0.055, 0.075))
	var normal := StyleBoxFlat.new()
	normal.bg_color = UISkin.CYAN
	normal.border_color = Color(0.78, 0.98, 1.0, 0.9)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(10)
	normal.shadow_color = Color(UISkin.CYAN, 0.38)
	normal.shadow_size = 12
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.48, 0.95, 1.0)
	hover.shadow_size = 18
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.12, 0.65, 0.78)
	play_btn.add_theme_stylebox_override("normal", normal)
	play_btn.add_theme_stylebox_override("hover", hover)
	play_btn.add_theme_stylebox_override("pressed", pressed)
	play_btn.add_theme_stylebox_override("focus", hover)


func _wire_button_feedback(button: Button) -> void:
	if button == null:
		return
	button.mouse_entered.connect(func() -> void:
		AudioManager.play_sfx("click", -12.0, 1.5)
		var tween := button.create_tween()
		tween.tween_property(button, "scale", Vector2(1.025, 1.025), 0.08)
	)
	button.mouse_exited.connect(func() -> void:
		var tween := button.create_tween()
		tween.tween_property(button, "scale", Vector2.ONE, 0.10)
	)


func _show_about() -> void:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.02, 0.04, 0.84)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 230)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "TOWER DUEL  ·  ДЕМО"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var about := Label.new()
	about.text = "Тактическая дуэль двух стратегов. Постройте оборону,\n" \
			+ "отправляйте волны и не дайте противнику разрушить базу.\n\n" \
			+ "Разработка: команда Tower Duel"
	about.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(about)
	var close := Button.new()
	close.text = "ЗАКРЫТЬ"
	close.pressed.connect(overlay.queue_free)
	box.add_child(close)
	AudioManager.play_sfx("click")


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
		if i == index:
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color(0.05, 0.16, 0.21, 0.98)
			active_style.border_color = Color(UISkin.CYAN, 0.92)
			active_style.set_border_width_all(1)
			active_style.set_corner_radius_all(8)
			buttons[i].add_theme_stylebox_override("disabled", active_style)
			buttons[i].add_theme_color_override("font_disabled_color", UISkin.CYAN)
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
		tower_grid.remove_child(child)
		child.queue_free()
	for child in unit_grid.get_children():
		unit_grid.remove_child(child)
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
	card.custom_minimum_size = Vector2(_loadout_tile_width, 96)
	card.button_pressed = (LoadoutManager.towers if which == "towers" \
			else LoadoutManager.units).has(id)
	card.text = _card_text(id, stats)
	_wire_button_feedback(card)
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
