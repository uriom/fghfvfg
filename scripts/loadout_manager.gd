extends Node
## Автозагрузка «LoadoutManager»: выбор снаряжения (деки) и профильные
## настройки, сохранение в user://loadout.cfg.
##
## Игрок берёт с собой только 3 типа башен (роль Защитника) и 3 типа юнитов
## (роль Штурмовика). В бою каждый тип можно поставить 2 раза
## (GameDB.MAX_TOWERS_PER_TYPE), то есть дека из 3 башен = ровно 6 построек —
## это и есть расчётный максимум обороны под бюджет раундов 220/100/100
## (см. приложение H аудита). MAX_TOWERS_TOTAL = 8 остаётся страховкой на
## случай будущих дек большего размера. Деки
## передаются в матч через лобби-RPC (NetworkManager._register ->
## _sync_players -> GameState.setup_match), поэтому сервер валидирует
## постройки/спавн строго по декам, а HUD строит кнопки только из дека.
##
## Формат user://loadout.cfg:
##   [loadout] towers=sniper,splash,frost  units=fast,tank,flying
##   [profile] role_pref=0 (0 — любая, 1 — защитник, 2 — штурмовик)

enum RolePref { ANY, DEFENDER, ATTACKER }

const SAVE_PATH := "user://loadout.cfg"
const DECK_SIZE := 3

const DEFAULT_TOWERS: Array[String] = ["sniper", "splash", "frost"]
const DEFAULT_UNITS: Array[String] = ["fast", "tank", "flying"]

## Выбранные деки (идентификаторы из GameDB).
var towers: Array[String] = DEFAULT_TOWERS.duplicate()
var units: Array[String] = DEFAULT_UNITS.duplicate()
## Приоритетная роль для рангового поиска (int из RolePref — приведение
## `as Enum` в GDScript не поддерживается, храним как int).
var role_pref: int = RolePref.ANY


func _ready() -> void:
	load_from_disk()


# -------------------------------------------------------------- Диски -------

func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return   # первый запуск — работаем на дефолтах
	towers = _sanitize(cfg.get_value("loadout", "towers", DEFAULT_TOWERS), "TOWERS")
	units = _sanitize(cfg.get_value("loadout", "units", DEFAULT_UNITS), "UNITS")
	role_pref = clampi(int(cfg.get_value("profile", "role_pref", 0)), 0, 2)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("loadout", "towers", ",".join(towers))
	cfg.set_value("loadout", "units", ",".join(units))
	cfg.set_value("profile", "role_pref", int(role_pref))
	cfg.save(SAVE_PATH)


## Чистит сохранённый список: только известные GameDB id, без дублей,
## максимум DECK_SIZE, при нехватке добирает из дефолта. На вход ждёт
## строку "a,b,c" (формат cfg) или массив id (дефолт из get_value).
func _sanitize(raw, table: String) -> Array[String]:
	var known: Dictionary = GameDB.TOWERS if table == "TOWERS" else GameDB.UNITS
	var ids: Array = []
	if raw is Array:
		ids = raw
	else:
		ids = String(str(raw)).split(",")
	var out: Array[String] = []
	for id in ids:
		var tid := String(id).strip_edges()
		if known.has(tid) and not out.has(tid):
			out.append(tid)
		if out.size() >= DECK_SIZE:
			break
	var defaults: Array[String] = DEFAULT_TOWERS if table == "TOWERS" else DEFAULT_UNITS
	for id in defaults:
		if out.size() >= DECK_SIZE:
			break
		if not out.has(id):
			out.append(id)
	return out


# --------------------------------------------------------- Операции дек -----

## Сколько всего построек позволит эта дека при лимите 2 на тип.
func tower_capacity() -> int:
	return mini(towers.size() * GameDB.MAX_TOWERS_PER_TYPE, GameDB.MAX_TOWERS_TOTAL)


## Короткая подпись для меню/подсказок: «3 типа · до 6 построек».
func towers_summary() -> String:
	return "%d типа · до %d построек (по %d на тип)" % [
		towers.size(), tower_capacity(), GameDB.MAX_TOWERS_PER_TYPE,
	]


## Есть ли место в деке (для UI-плиток).
func deck_full(which: String) -> bool:
	var deck := towers if which == "towers" else units
	return deck.size() >= DECK_SIZE


## Переключить id в/из дека. Возвращает true, если изменение принято.
func toggle_in_deck(which: String, id: String) -> bool:
	var deck: Array[String] = towers if which == "towers" else units
	if deck.has(id):
		deck.erase(id)
		return true
	if deck.size() >= DECK_SIZE:
		return false   # слот занят — сначала снимите другую плитку
	deck.append(id)
	return true


## «Боевая» версия дека: если игрок оставил меньше DECK_SIZE, добираем
## дефолтами — матч не должен ломаться из-за недособранной колоды.
func effective_towers() -> Array[String]:
	return _sanitize(",".join(towers), "TOWERS")


func effective_units() -> Array[String]:
	return _sanitize(",".join(units), "UNITS")
