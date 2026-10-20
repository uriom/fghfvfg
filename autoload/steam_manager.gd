extends Node
## Автозагрузка «SteamManager»: инициализация GodotSteam, лобби, MMR/ранги
## и ранговый подбор соперников (Ranked Matchmaking).
##
## ВАЖНО ПРО АРХИТЕКТУРУ: здесь нет прямых идентификаторов Steam /
## SteamMultiplayerPeer — доступ только динамический:
##   Engine.get_singleton("Steam")            — синглтон GodotSteam;
##   ClassDB.instantiate("SteamMultiplayerPeer") — пир (в NetworkManager).
## Благодаря этому проект компилируется и работает БЕЗ установленного
## GodotSteam (сеть остаётся на ENet, ранговый поиск недоступен).
##
## ЭТАП 5:
##   * MMR (по умолчанию 1000, +/-25 за матч) — в Steam Stats ("MMR") с
##     локальным зеркалом user://profile.cfg (работает без Steam);
##   * лиги: Бронза/Серебро/Золото/Платина/Алмаз;
##   * quick_play(): поиск лобби mode=towerduel_ranked с MMR +-150 (5 c),
##     затем своё публичное лобби (15 c), затем расширение до +-300.

signal steam_initialized                    # Steam готов (после успешного steamInit)
signal lobby_created_ok(lobby_id: int)      # наше Steam-лобби создано
signal lobby_joined_ok(lobby_id: int, owner_steam_id: int)  # мы вошли в лобби
signal lobbies_received(lobby_ids: Array)   # список публичных лобби (custom-таб)
signal matchmaking_status(text: String)     # статус поиска для меню
signal matchmaking_stopped(reason: String)  # поиск завершён/отменён

const LOBBY_MODE := "towerduel"             # custom-лобби («с другом»)
const RANKED_MODE := "towerduel_ranked"     # ранговые лобби матчмейкинга

# --- Достижения (API-имена = настройкам в Steamworks Partner Portal):
const ACH_FIRST_BLOOD := "FIRST_BLOOD"
const ACH_MASTER_BUILDER := "MASTER_BUILDER"
const ACH_SURVIVOR := "SURVIVOR"

# --- Статистика (Portal: Администрирование -> Статистика):
const STAT_MATCHES := "matches_played"
const STAT_WINS_DEFENDER := "wins_defender"
const STAT_UNITS_KILLED := "units_killed_total"
const STAT_MMR := "MMR"

# --- MMR и лиги.
const MMR_DEFAULT := 1000
const MMR_DELTA := 25              # +/- за матч
const PROFILE_PATH := "user://profile.cfg"

# --- Ranked matchmaking.
const MM_SEARCH_TIME := 5.0        # фаза 1: ищем чужие лобби (±MMR_RANGE)
const MM_HOST_TIME := 15.0         # фаза 2: хостим своё и ждём
const MM_RANGE := 150              # стартальный диапазон MMR
const MM_WIDE_RANGE := 300         # расширенный диапазон
const MM_SEARCH_EVERY := 1.5       # период опроса списка лобби
const MM_COUNTDOWN := 3.0          # отсчёт до авто-старта матча

# Константы Steamworks литералами: динамический Object не открывает доступ
# к константам класса (Steam.LOBBY_TYPE_PUBLIC и т.п.).
const LOBBY_TYPE_PUBLIC := 0                    # k_ELobbyTypePublic
const LOBBY_CREATED_OK := 1                     # код успеха lobby_created
const CHAT_ROOM_ENTER_RESPONSE_SUCCESS := 0     # код успеха lobby_joined
const LOBBY_DISTANCE_FILTER_WORLDWIDE := 3      # k_ELobbyDistanceFilter
const LOBBY_COMPARE_EQUAL := 0                  # k_ELobbyComparisonEqual
const LOBBY_COMPARE_LESS_OR_EQUAL := -2         # k_ELobbyComparisonEqualToOrLessThan
const LOBBY_COMPARE_GREATER_OR_EQUAL := 2       # k_ELobbyComparisonEqualToOrGreaterThan

enum MMPhase { IDLE, SEARCHING, HOSTING, COUNTDOWN }

var steam: Object = null      # динамическая ссылка на синглтон GodotSteam
var available := false        # GodotSteam установлен и Steam инициализирован
var steam_id := 0
var persona_name := ""
var lobby_id := 0             # 0 — мы не в лобби

# --- MMR / лига.
var mmr := MMR_DEFAULT

# --- Состояние матчмейкинга (весь цикл живёт здесь, управление — меню).
var mm_phase: MMPhase = MMPhase.IDLE
var mm_range := MM_RANGE
var mm_elapsed := 0.0         # время в текущей фазе (для таймера в UI)
var mm_total_elapsed := 0.0   # общее время поиска («[00:12]»)
var mm_search_cooldown := 0.0
var _mm_host_ranked := false  # наше текущее лобби — ранговое (мы хост)
var _mm_countdown_left := 0.0
var _mm_teardown_guard := false   # защита от рекурсии stop_matchmaking <-> end_session


func _ready() -> void:
	_load_mmr()
	if not Engine.has_singleton("Steam"):
		return
	steam = Engine.get_singleton("Steam")
	# steamInit синхронный; ответ — словарь с полем result (0 = успех).
	var response: Dictionary = steam.steamInit(false)
	if int(response.get("result", -1)) != 0:
		push_warning("SteamManager: steamInit не удался: %s" % str(response))
		steam = null
		return
	available = true
	steam_id = int(steam.getSteamID())
	persona_name = String(steam.getPersonaName())
	# Загружаем текущие статы игрока — до setStat*/storeStats это обязательно,
	# иначе агрегаты будут считаться от нуля на каждой сессии.
	steam.requestCurrentStats()
	# MMR из Steam перекрывает локальное зеркало (свежее), 0 = стата не задана.
	var steam_mmr := int(steam.getStatInt(STAT_MMR))
	if steam_mmr > 0:
		mmr = steam_mmr
	steam.connect("lobby_created", _on_lobby_created)
	steam.connect("lobby_joined", _on_lobby_joined)
	steam.connect("join_requested", _on_join_requested)
	steam.connect("lobby_match_list", _on_lobby_match_list)
	steam_initialized.emit()


func _process(delta: float) -> void:
	_tick_matchmaking(delta)


# ================================================================ MMR =======

## Применить результат матча: победа +25, поражение -25. Вызывается ЛОКАЛЬНО
## на каждом пире из GameState._end_match — каждый updating свой рейтинг.
func apply_match_result(won: bool) -> void:
	mmr = maxi(mmr + (MMR_DELTA if won else -MMR_DELTA), 0)
	if available:
		steam.setStatInt(STAT_MMR, mmr)
		steam.storeStats()
	_save_mmr()


func rank_name() -> String:
	if mmr < 1050:
		return "Бронза"
	if mmr < 1200:
		return "Серебро"
	if mmr < 1350:
		return "Золото"
	if mmr < 1500:
		return "Платина"
	return "Алмаз"


func rank_color() -> Color:
	if mmr < 1050:
		return Color(0.78, 0.5, 0.33)
	if mmr < 1200:
		return Color(0.8, 0.85, 0.92)
	if mmr < 1350:
		return Color(1.0, 0.85, 0.4)
	if mmr < 1500:
		return Color(0.6, 0.95, 0.9)
	return Color(0.55, 0.8, 1.0)


func _load_mmr() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) == OK:
		mmr = clampi(int(cfg.get_value("profile", "mmr", MMR_DEFAULT)), 0, 99999)


func _save_mmr() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PROFILE_PATH)   # не затираем чужие ключи
	cfg.set_value("profile", "mmr", mmr)
	cfg.save(PROFILE_PATH)


## Аватар игрока (средний размер). Разные версии GodotSteam возвращают
## Texture2D / Image / int-хендл — обрабатываем всё, на провал — null
## (меню покажет заглушку с инициалом).
func get_avatar_texture() -> Texture2D:
	if not available:
		return null
	var avatar = steam.getMediumFriendAvatar(steam_id)
	if avatar is Texture2D:
		return avatar
	if avatar is Image and not (avatar as Image).is_empty():
		return ImageTexture.create_from_image(avatar)
	if avatar is int and int(avatar) > 0:
		# Старые версии GodotSteam возвращают хендл: достаём RGBA через
		# getImageSize/getImageRGBA и собираем текстуру руками.
		var size_v = steam.getImageSize(int(avatar))
		if size_v is Vector2i and (size_v as Vector2i).x > 0 and (size_v as Vector2i).y > 0:
			var sz: Vector2i = size_v
			var raw_v = steam.getImageRGBA(int(avatar))
			if raw_v is PackedByteArray \
					and (raw_v as PackedByteArray).size() >= sz.x * sz.y * 4:
				var img := Image.create_from_data(sz.x, sz.y, false,
						Image.FORMAT_RGBA8, raw_v)
				return ImageTexture.create_from_image(img)
	return null


# ====================================================== Matchmaking =========

## «В БОЙ»: ранговый поиск. role_pref — LoadoutManager.RolePref.
## Фазы: SEARCHING (ищем чужие лобби ±150) -> HOSTING (своё лобби, ждём
## 15 с) -> HOSTING с расширенным поиском ±300. При входе второго игрока
## в наше лобби — отсчёт 3 с и авто-старт матча.
func quick_play(role_pref: int) -> void:
	if not available:
		matchmaking_stopped.emit("Steam недоступен — ранговый поиск невозможен.")
		return
	if mm_phase != MMPhase.IDLE:
		return
	if not NetworkManager._is_offline():
		matchmaking_stopped.emit("Сначала завершите текущую сессию.")
		return
	mm_range = MM_RANGE
	mm_elapsed = 0.0
	mm_total_elapsed = 0.0
	mm_search_cooldown = 0.0
	NetworkManager.player_list_changed.connect(_on_mm_players_changed)
	# Приоритет роли: «Защитник» — сразу хостим; «Штурмовик» — подольше ищем.
	if role_pref == LoadoutManager.RolePref.DEFENDER:
		_begin_hosting()
	else:
		mm_phase = MMPhase.SEARCHING
		_emit_search_status("Ищем соперника…")


## Отменить поиск (кнопка «Отмена» / разрыв сессии). Тихая, если не искали.
func stop_matchmaking(reason := "Поиск отменён.") -> void:
	if mm_phase == MMPhase.IDLE:
		return
	var was_host := _mm_host_ranked
	mm_phase = MMPhase.IDLE
	_mm_host_ranked = false
	_mm_countdown_left = 0.0
	if NetworkManager.player_list_changed.is_connected(_on_mm_players_changed):
		NetworkManager.player_list_changed.disconnect(_on_mm_players_changed)
	# Если мы хостили ранговое лобби и соперник не нашёлся — прибираем:
	# закрываем пир и выходим из лобби (custom-лобби не трогаем).
	if was_host and NetworkManager.players.size() < 2 and not _mm_teardown_guard:
		_mm_teardown_guard = true
		NetworkManager.end_session()
		_mm_teardown_guard = false
	matchmaking_stopped.emit(reason)


func is_matchmaking() -> bool:
	return mm_phase != MMPhase.IDLE


func _tick_matchmaking(delta: float) -> void:
	if mm_phase == MMPhase.IDLE:
		return
	mm_total_elapsed += delta
	match mm_phase:
		MMPhase.SEARCHING:
			mm_elapsed += delta
			mm_search_cooldown -= delta
			if mm_search_cooldown <= 0.0:
				mm_search_cooldown = MM_SEARCH_EVERY
				_request_ranked_lobbies()
			# «Штурмовик» ищет дольше (клиентом стать охотнее), прочие — 5 с.
			var deadline := MM_SEARCH_TIME * (2.0 if _prefers_attacker() else 1.0)
			if mm_elapsed >= deadline:
				_begin_hosting()
			_emit_search_status("Ищем соперника…")
		MMPhase.HOSTING:
			mm_elapsed += delta
			mm_search_cooldown -= delta
			if mm_elapsed >= MM_HOST_TIME and mm_range < MM_WIDE_RANGE:
				mm_range = MM_WIDE_RANGE
				matchmaking_status.emit("Диапазон поиска расширен до ±%d MMR…" % mm_range)
			if mm_search_cooldown <= 0.0:
				# Хостим сами, но продолжаем поглядывать на чужие лобби:
				# найдём «более ждущего» хоста — переподключимся к нему.
				mm_search_cooldown = MM_SEARCH_EVERY * 2.0
				_request_ranked_lobbies()
			_emit_search_status("Ожидаем соперника (хостим лобби)…")
		MMPhase.COUNTDOWN:
			_mm_countdown_left -= delta
			if _mm_countdown_left <= 0.0:
				var was_ranked := _mm_host_ranked
				mm_phase = MMPhase.IDLE
				_mm_host_ranked = false
				if NetworkManager.player_list_changed.is_connected(_on_mm_players_changed):
					NetworkManager.player_list_changed.disconnect(_on_mm_players_changed)
				if was_ranked:
					NetworkManager.start_match()
			else:
				matchmaking_status.emit("Соперник найден! Старт через %d…" % ceili(_mm_countdown_left))


func _prefers_attacker() -> bool:
	return LoadoutManager.role_pref == LoadoutManager.RolePref.ATTACKER


## Фильтрованный запрос списка ранговых лобби под текущий диапазон MMR.
func _request_ranked_lobbies() -> void:
	steam.addRequestLobbyListDistanceFilter(LOBBY_DISTANCE_FILTER_WORLDWIDE)
	steam.addRequestLobbyListStringFilter("mode", RANKED_MODE, LOBBY_COMPARE_EQUAL)
	# Диапазон MMR двумя числовыми фильтрами: min <= mmr хоста <= max.
	steam.addRequestLobbyListNumericalFilter("mmr", mmr + mm_range, LOBBY_COMPARE_LESS_OR_EQUAL)
	steam.addRequestLobbyListNumericalFilter("mmr", mmr - mm_range, LOBBY_COMPARE_GREATER_OR_EQUAL)
	steam.requestLobbyList()


func _begin_hosting() -> void:
	mm_phase = MMPhase.HOSTING
	mm_elapsed = 0.0
	_mm_host_ranked = true
	_emit_search_status("Создаём лобби…")
	# Имя хоста — из Steam (в ранговом поиске имя из поля меню может быть
	# не заполнено); NetworkManager запомнит его и использует для лобби.
	var host_name := persona_name if not persona_name.is_empty() else "Игрок"
	NetworkManager.host_game(host_name, true)


## Список лобби пришёл: в режиме поиска пробуем войти в первое подходящее
## (Steam уже отфильтровал по mode и MMR), иначе просто ретранслируем в
## custom-таб меню.
func _on_lobby_match_list(lobby_ids: Array) -> void:
	if mm_phase == MMPhase.SEARCHING or mm_phase == MMPhase.HOSTING:
		for id in lobby_ids:
			if int(id) == lobby_id:
				continue   # своё собственное лобби пропускаем
			if mm_phase == MMPhase.HOSTING:
				# Переподключаемся к чужому лобби: своё закрываем.
				stop_matchmaking("Найден соперник, подключаемся…")
				NetworkManager.end_session()
			mm_phase = MMPhase.IDLE
			matchmaking_status.emit("Соперник найден! Подключаемся…")
			join_lobby(int(id))
			return
	lobbies_received.emit(lobby_ids)


## Второй игрок вошёл в наше ранговое лобби — стартуем отсчёт.
func _on_mm_players_changed() -> void:
	if _mm_host_ranked and mm_phase == MMPhase.HOSTING and NetworkManager.players.size() >= 2:
		mm_phase = MMPhase.COUNTDOWN
		_mm_countdown_left = MM_COUNTDOWN
	elif mm_phase == MMPhase.COUNTDOWN and NetworkManager.players.size() < 2:
		# Соперник передумал — возвращаемся в ожидание.
		mm_phase = MMPhase.HOSTING
		mm_elapsed = 0.0
		matchmaking_status.emit("Соперник отключился, ждём нового…")


func _emit_search_status(prefix: String) -> void:
	var seconds := int(mm_total_elapsed)
	# floori от float-деления: без предупреждения INTEGER_DIVISION.
	var mm_txt := "%02d:%02d" % [floori(seconds / 60.0), seconds % 60]
	matchmaking_status.emit("%s [%s]" % [prefix, mm_txt])


# ========================================================== Лобби API =======

## Создать публичное лобби (максимум max_members). ranked = true — лобби
## матчмейкинга (mode=towerduel_ranked + данные MMR для фильтров поиска).
func create_lobby(max_members: int, ranked := false) -> void:
	if not available:
		return
	_mm_host_ranked = ranked
	steam.createLobby(LOBBY_TYPE_PUBLIC, max_members)


## Войти в лобби (из списка, по приглашению или из матчмейкинга).
func join_lobby(p_lobby_id: int) -> void:
	if not available or p_lobby_id == 0:
		return
	steam.joinLobby(p_lobby_id)


## Выйти из лобби и закрыть P2P-сессии (вызывается из NetworkManager).
func leave_lobby() -> void:
	if not available or lobby_id == 0:
		return
	steam.leaveLobby(lobby_id)
	lobby_id = 0


## Открыть стандартный диалог приглашения друзей (Steam Overlay).
func invite_friends() -> void:
	if available and lobby_id != 0:
		steam.activateGameOverlayInviteDialog(lobby_id)


## Запросить список custom-лобби этой игры (придёт в lobbies_received).
func refresh_lobby_list() -> void:
	if not available:
		return
	steam.addRequestLobbyListDistanceFilter(LOBBY_DISTANCE_FILTER_WORLDWIDE)
	steam.addRequestLobbyListStringFilter("mode", LOBBY_MODE, LOBBY_COMPARE_EQUAL)
	steam.requestLobbyList()


## Человеческое название лобби для списка (данные хранит Steam).
func get_lobby_title(p_lobby_id: int) -> String:
	if not available:
		return ""
	return String(steam.getLobbyData(p_lobby_id, "name"))


# ---------------------------------------------------- Сигналы GodotSteam ----

func _on_lobby_created(connection: int, this_lobby_id: int) -> void:
	if connection != LOBBY_CREATED_OK:
		push_warning("SteamManager: создать лобби не удалось (код %d)" % connection)
		if _mm_host_ranked:
			stop_matchmaking("Не удалось создать лобби.")
		return
	lobby_id = this_lobby_id
	steam.setLobbyJoinable(lobby_id, true)
	if _mm_host_ranked:
		steam.setLobbyData(lobby_id, "mode", RANKED_MODE)
		steam.setLobbyData(lobby_id, "mmr", str(mmr))
		steam.setLobbyData(lobby_id, "name", "%s [%d MMR]" % [persona_name, mmr])
	else:
		steam.setLobbyData(lobby_id, "mode", LOBBY_MODE)
		steam.setLobbyData(lobby_id, "name", "%s — Tower Duel" % persona_name)
	lobby_created_ok.emit(lobby_id)


func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		push_warning("SteamManager: не удалось войти в лобби (код %d)" % response)
		if mm_phase != MMPhase.IDLE:
			stop_matchmaking("Не удалось войти в лобби соперника.")
		return
	lobby_id = this_lobby_id
	lobby_joined_ok.emit(lobby_id, int(steam.getLobbyOwner(this_lobby_id)))


## Друг принял приглашение через Overlay (или кликнул «присоединиться»
## в Steam) — автоматически входим в его лобби.
func _on_join_requested(this_lobby_id: int, _friend_id: int) -> void:
	steam.joinLobby(this_lobby_id)


# ------------------------------------------------ Достижения и статы --------

## Разблокировать достижение (безопасно вызывать повторно — Steam сам
## игнорирует уже полученные). Обязательно storeStats() для отправки.
func unlock_achievement(api_name: String) -> void:
	if not available:
		return
	steam.setAchievement(api_name)
	steam.storeStats()


## Увеличить целочисленную агрегат-статистику на delta (матчи, победы…).
func add_stat_int(api_name: String, delta: int) -> void:
	if not available:
		return
	var current := int(steam.getStatInt(api_name))
	steam.setStatInt(api_name, current + delta)
	steam.storeStats()
