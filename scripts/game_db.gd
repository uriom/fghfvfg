class_name GameDB
## Статичная «база данных» игры: характеристики юнитов и башен.
##
## ЭТАП 6 — COMBAT v2 (см. docs/GDD_AUDIT_RU.md, SPEC-02):
##   * у башен появился damage_type, у юнитов — armor_class;
##   * урон умножается на матрицу DAMAGE_MATRIX (камень-ножницы-бумага);
##   * у каждой башни свой приоритет цели (strongest / weakest / cluster / densest);
##   * лимиты постройки: 2 башни одного типа и 8 всего;
##   * цены/урон пересчитаны так, чтобы ни одна башня не доминировала.
##
## ЭТАП 2 (исторически) — три специализации; сейчас их пять:
##   Башни: sniper (бронебойный хитскан), splash (осколочный AoE),
##          frost (контроль), flamer (огонь по площади в упор), tesla (цепь).
##   Юниты: fast (лёгкий), rider (лёгкий, плотнее), flying (воздух, имун к
##          замедлению), tank (тяжёлый + аура), boss (тяжёлый таран).
##
## Хранится словарями, чтобы балансировать прямо в коде. Все числа ниже
## проверяются tools/balance_audit.py — после правки прогоняйте его.

# --- Проход «живучести» (9-я итерация аудита) --------------------------------
# HP всех юнитов поднят на ~25 % (30->40, 70->90, 180->225, 650->800): на
# идеальной расстановке башни убивали волну целиком, и штурмовик не мог
# забрать раунд ни одной композицией (tools/balance_audit.py decks: 0 из 45
# клеток). С новыми HP у каждой деки появляется минимум одна дыра, а темп
# боя остаётся читаемым: бегун умирает за 2 выстрела снайпера, а не за 1.

# --- Матрица урона: тип урона башни -> класс брони юнита ---------------------
# Значения > 1 — бонус, < 1 — штраф. Башни, которые не бьют воздух, всё равно
# имеют запись: это защита от будущих башен и от прямых вызовов take_damage.
## Проверено симулятором (tools/balance_audit.py --profile v2): при air=0.50
## снайпер почти не наносил урона воздуху, и 10 змеев (300 кр) сносили 20/15 HP
## базы даже через теслу. 0.75 оставляет снайпера «аварийным» ПВО, а теслу —
## специализированным (×1.5).
##
## fire/heavy 0.60 -> 0.80: при 0.60 огнемёт был бесполезен против танкового
## кулака, и деки «снайпер + тесла + огнемёт» / «снайпер + крио + огнемёт»
## проигрывали раунд одной кнопкой «танки» (tools/balance_audit.py decks).
## С 0.80 огнемёт остаётся слабейшим ответом на тяжёлую броню (у снайпера
## ×1.50), но перестаёт быть нулём.
const DAMAGE_MATRIX := {
	"ap":   {"light": 0.75, "heavy": 1.50, "air": 0.75},
	"he":   {"light": 1.25, "heavy": 0.90, "air": 1.00},
	"fire": {"light": 1.50, "heavy": 0.80, "air": 1.00},
	"cryo": {"light": 1.00, "heavy": 0.80, "air": 1.00},
	"arc":  {"light": 1.25, "heavy": 0.80, "air": 1.50},
}

# --- Лимиты постройки --------------------------------------------------------
const MAX_TOWERS_PER_TYPE := 2
const MAX_TOWERS_TOTAL := 8

const UNITS := {
	"fast": {
		"name": "Бегун",
		"cost": 15,
		"hp": 40.0,
		"speed": 150.0,
		"damage": 1,          # урон базе при прорыве
		"bounty": 8,          # золото штурмовику за прорыв (50% цены)
		"kill_reward": 4,     # 25% цены: убийство даёт доход, но не снежный ком
		"armor_class": "light",
		"flying": false,
		"ignores_slow": false,
		"art_forward": 2.9,
		"color": Color(0.4, 0.8, 1.0),
	},
	"rider": {
		"name": "Наездник",
		"cost": 30,
		"hp": 90.0,
		"speed": 125.0,       # медленнее бегуна, но одно тело вместо двух
		"damage": 2,
		"bounty": 15,
		"kill_reward": 8,     # 25% цены (аудит C1: не платить защитнику дважды)
		"armor_class": "light",
		"flying": false,
		"ignores_slow": false,
		"art_forward": 2.45,
		"color": Color(0.55, 0.9, 0.35),
	},
	"tank": {
		"name": "Танк",
		"cost": 50,
		"hp": 225.0,
		"speed": 55.0,
		"damage": 3,
		"bounty": 25,
		"kill_reward": 13,
		"armor_class": "heavy",
		"flying": false,
		"ignores_slow": false,
		"art_forward": 1.57,
		"aura_radius": 110.0,    # радиус защитной ауры (рисуется у юнита)
		# -25%, а не -35%: при -35% пятёрка танков в R1 снимала раунд с любой
		# декой без мортиры (tools/balance_audit.py decks). Аура остаётся
		# наказанием за фокус одной цели, но перестаёт быть непробиваемой.
		"aura_reduction": 0.25,
		"color": Color(1.0, 0.55, 0.3),
	},
	"flying": {
		"name": "Змей",
		"cost": 30,
		"hp": 90.0,            # живучее бегуна: воздух должен дотерпеть до базы
		"speed": 115.0,
		"damage": 1,           # 1: воздух — «просадка», а не кнопка победы
		"bounty": 15,
		"kill_reward": 8,     # 25% цены
		"armor_class": "air",
		"flying": true,
		"ignores_slow": true,    # летающие не замедляются криостаном
		"art_forward": -0.45,
		"color": Color(0.8, 0.45, 1.0),
	},
	"boss": {
		"name": "Босс",
		# 150, а не 130: за 410 кредитов R2 атакующий покупал ТРИ босса, и
		# 18 урона снимали раунд даже через теслу (деки B/C/E). Теперь в R2
		# максимум два босса (12 < 15 HP базы), тройка появляется только в R3.
		"cost": 150,
		"hp": 800.0,
		# 46, а не 36: путь 54,8 с при штурме 60 с. С прежней скоростью босс
		# физически не успевал дойти до базы за раунд и был мёртвой картой
		# (tools/balance_audit.py: 3 босса умирали на 78-й секунде).
		"speed": 46.0,
		"damage": 6,
		"bounty": 65,
		"kill_reward": 33,
		"armor_class": "heavy",
		"flying": false,
		"ignores_slow": false,
		"art_forward": 1.57,
		"radius": 21.0,          # крупный корпус (рисование + радиус сплеша)
		"color": Color(0.95, 0.3, 0.35),
	},
}

const TOWERS := {
	"sniper": {
		"name": "Снайпер",
		"cost": 55,
		"kind": "beam",          # хитскан-луч: без снаряда, урон мгновенно
		"damage_type": "ap",     # бронебойный: силён по тяжёлым, слаб по воздуху
		"priority": "strongest", # бьёт цель с наибольшим HP в радиусе
		"range": 200.0,
		"damage": 20.0,
		"fire_rate": 0.85,
		"can_target_flying": true,
		"color": Color(0.45, 0.95, 0.55),
	},
	"splash": {
		"name": "Мортира",
		"cost": 85,
		"kind": "lob",           # навесной снаряд с уроном по площади
		"damage_type": "he",
		"priority": "cluster",   # выбирает цель в самой плотной группе
		"range": 190.0,
		"damage": 26.0,
		"fire_rate": 0.75,
		"splash_radius": 90.0,
		"splash_falloff_min": 0.5,
		"can_target_flying": false,  # осколки не достают воздух
		"projectile_speed": 240.0,
		"color": Color(0.95, 0.8, 0.35),
	},
	"frost": {
		"name": "Криостан",
		"cost": 55,
		"kind": "frost",
		"damage_type": "cryo",
		"priority": "progress",   # контроль лидера важнее добивания
		"range": 165.0,
		"damage": 3.0,
		"fire_rate": 1.2,
		"slow_percent": 0.5,
		"slow_duration": 2.0,
		"pulse_radius": 70.0,
		"can_target_flying": false,
		"projectile_speed": 340.0,
		"color": Color(0.5, 0.85, 1.0),
	},
	"tesla": {
		"name": "Тесла",
		"cost": 95,
		"kind": "chain",
		"damage_type": "arc",    # лучший ответ на воздух
		"priority": "densest",   # цель, вокруг которой больше всего соседей
		"range": 200.0,
		"damage": 13.0,
		"chain_targets": 2,
		"chain_range": 120.0,
		"chain_falloff": 0.6,
		"fire_rate": 1.0,
		"can_target_flying": true,
		# ТОЛЬКО воздух. Иначе «снайпер + мортира + тесла» закрывала все
		# классы сразу и была единственной играбельной декой
		# (tools/balance_audit.py, режим decks). Теперь тесла — чистое ПВО.
		"can_target_ground": false,
		"color": Color(0.75, 0.6, 1.0),
	},
	"flamer": {
		"name": "Огнемёт",
		"cost": 60,
		"kind": "flame",         # шквал лёгких снарядов в упор
		"damage_type": "fire",
		"priority": "weakest",   # добивает раненых, не тратит залп на танка
		"range": 120.0,
		"damage": 3.5,
		"fire_rate": 5.0,
		# Струя задевает соседей: огнемёт — дешёвая «мортира для бедных».
		"splash_radius": 45.0,
		"splash_falloff_min": 0.6,
		"can_target_flying": false,
		"projectile_speed": 520.0,
		"color": Color(1.0, 0.45, 0.25),
	},
}

# Порядок кнопок в интерфейсах (и плиток выбора снаряжения).
const UNIT_ORDER: Array[String] = ["fast", "rider", "tank", "flying", "boss"]
const TOWER_ORDER: Array[String] = ["sniper", "splash", "frost", "flamer", "tesla"]


## Множитель урона башни по юниту. Неизвестные значения трактуются как 1.0,
## чтобы новая башня без записи в матрице не ломала бой.
static func damage_multiplier(damage_type: String, armor_class: String) -> float:
	var row: Dictionary = DAMAGE_MATRIX.get(damage_type, {})
	return float(row.get(armor_class, 1.0))


## Класс брони юнита из его статов (по умолчанию — лёгкая).
static func armor_of(unit_stats: Dictionary) -> String:
	return String(unit_stats.get("armor_class", "light"))


## Урон башни по конкретному юниту с учётом матрицы. Чистая функция: её же
## использует и бот, и симулятор баланса.
static func effective_damage(hit_damage: float, damage_type: String,
		unit_stats: Dictionary) -> float:
	return hit_damage * damage_multiplier(damage_type, armor_of(unit_stats))


## Цена самого дешёвого юнита — для проверки «штурмовик-банкрот» и подсказок.
static func cheapest_unit_cost() -> int:
	var cheapest := 1 << 30
	for unit_id in UNIT_ORDER:
		cheapest = mini(cheapest, int(UNITS[unit_id]["cost"]))
	return cheapest
