class_name GameDB
## Статичная «база данных» игры: характеристики юнитов и башен.
##
## ЭТАП 6 — COMBAT v2 (см. docs/GDD_AUDIT_RU.md, SPEC-02):
##   * у башен появился damage_type, у юнитов — armor_class;
##   * урон умножается на матрицу DAMAGE_MATRIX (камень-ножницы-бумага);
##   * у каждой башни свой приоритет цели (strongest / weakest / cluster / densest);
##   * цены/урон пересчитаны так, чтобы ни одна башня не доминировала.
##
## ЭТАП 7 — UPGRADE v1 (после плейтеста):
##   * лимитов постройки больше нет: ширина обороны ограничена только
##     клетками и кредитами;
##   * у башен и у типов юнитов есть уровни 1..10 (см. TOWER_MAX_LEVEL);
##   * уровни покупаются за кредиты прямо в матче и переживают раунды.
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
## снайпер почти не наносил урона воздуху, и 10 змеев (300 кр по цене v2) сносили 20/15 HP
## базы даже через теслу. 0.75 оставляло снайпера «аварийным» ПВО.
## ЭТАП 8: 0.90 — воздух достаёт весь парк, кроме мортиры, поэтому штраф
## снайпера по нему стал мягче: 0.75 превращало его в почти бесполезного
## против змеев, а деки без теслы (A) не могли ответить вообще.
##
## fire/heavy 0.60 -> 0.80: при 0.60 огнемёт был бесполезен против танкового
## кулака, и деки «снайпер + тесла + огнемёт» / «снайпер + крио + огнемёт»
## проигрывали раунд одной кнопкой «танки» (tools/balance_audit.py decks).
## С 0.80 огнемёт остаётся слабейшим ответом на тяжёлую броню (у снайпера
## ×1.50), но перестаёт быть нулём.
const DAMAGE_MATRIX := {
	"ap":   {"light": 0.75, "heavy": 1.50, "air": 0.90},
	"he":   {"light": 1.25, "heavy": 0.90, "air": 1.00},
	"fire": {"light": 1.50, "heavy": 0.80, "air": 1.00},
	"cryo": {"light": 1.00, "heavy": 0.80, "air": 1.00},
	"arc":  {"light": 1.25, "heavy": 0.80, "air": 1.50},
}

# --- Уровни (ЭТАП 7) ---------------------------------------------------------
## Апгрейд — «вертикальная» альтернатива застройке: одна башня 10-го уровня
## стоит дороже трёх свежих, но занимает одну клетку и покрывает больше пути.
const TOWER_MAX_LEVEL := 10
const UNIT_MAX_LEVEL := 10
## Во сколько раз растёт характеристика за уровень (1 + STEP * (уровень - 1)).
const TOWER_DAMAGE_STEP := 0.22     # +22 % урона за уровень -> x2,98 на 10-м
const TOWER_RATE_STEP := 0.03       # +3 % скорострельности -> x1,27
const TOWER_RANGE_STEP := 0.025     # +2,5 % радиуса -> x1,225
const UNIT_HP_STEP := 0.10          # +10 % HP за уровень -> x1,90 на 10-м
const UNIT_SPEED_STEP := 0.015      # +1,5 % скорости -> x1,135
## Урон базе растёт ОДИН раз — на максимуме. Плюс на 5-м уровне давал
## удвоенный урон половине армии уже в R2: массовый заход fast на 5-м уровне
## снимал раунд без всякой тактики (tools/balance_audit.py, режим levels).
## Теперь прокачка — это живучесть, а «+1 к осаде» — награда за 10-й уровень.
const UNIT_DAMAGE_LEVELS := [10]
## Достижение «Мастер-строитель»: столько башен за матч.
const TOWERS_FOR_ACHIEVEMENT := 8

const UNITS := {
	"fast": {
		"name": "Бегун",
		"cost": 15,
		"hp": 48.0,
		"speed": 150.0,
		"damage": 1,          # урон базе при прорыве
		"bounty": 8,          # золото штурмовику за прорыв (50% цены)
		"kill_reward": 4,     # 25% цены: убийство даёт доход, но не снежный ком
		"armor_class": "light",
		"flying": false,
		"ignores_slow": false,
		"art_faces_right": false,
		"color": Color(0.4, 0.8, 1.0),
	},
	"rider": {
		"name": "Наездник",
		"cost": 30,
		"hp": 108.0,
		"speed": 125.0,       # медленнее бегуна, но одно тело вместо двух
		"damage": 2,
		"bounty": 15,
		"kill_reward": 8,     # 25% цены (аудит C1: не платить защитнику дважды)
		"armor_class": "light",
		"flying": false,
		"ignores_slow": false,
		"art_faces_right": false,
		"color": Color(0.55, 0.9, 0.35),
	},
	"tank": {
		"name": "Танк",
		"cost": 50,
		"hp": 270.0,
		"speed": 55.0,
		"damage": 3,
		"bounty": 25,
		"kill_reward": 13,
		"armor_class": "heavy",
		"flying": false,
		"ignores_slow": false,
		"art_faces_right": false,
		"aura_radius": 110.0,    # радиус защитной ауры (рисуется у юнита)
		# -25%, а не -35%: при -35% пятёрка танков в R1 снимала раунд с любой
		# декой без мортиры (tools/balance_audit.py decks). Аура остаётся
		# наказанием за фокус одной цели, но перестаёт быть непробиваемой.
		"aura_reduction": 0.25,
		"color": Color(1.0, 0.55, 0.3),
	},
	"flying": {
		"name": "Змей",
		# ЭТАП 8: 35, а не 30. Воздух теперь достаёт весь парк, кроме мортиры,
		# поэтому змей перестал быть «обходом половины обороны» — но остаётся
		# единственным юнитом, который игнорирует замедление и летит над
		# короткими стволами (огнемёт 120 px). При 30 он вытеснял наездника.
		"cost": 35,
		"hp": 108.0,           # живучее бегуна: воздух должен дотерпеть до базы
		"speed": 115.0,
		"damage": 1,           # 1: воздух — «просадка», а не кнопка победы
		"bounty": 15,
		"kill_reward": 8,     # 25% цены
		"armor_class": "air",
		"flying": true,
		"ignores_slow": true,    # летающие не замедляются криостаном
		"art_faces_right": true,   # нос корабля смотрит вправо-вверх
		"color": Color(0.8, 0.45, 1.0),
	},
	"boss": {
		"name": "Босс",
		# 165, а не 150: в R1 штурмовик получает 260 + ~60 капельно, и за 300
		# кредитов покупал ДВУХ боссов — 12 урона базе гарантированно, без
		# размена и тактики (tools/balance_audit.py, режим decks). С 165 в R1
		# влезает один босс + танк, двойка появляется только в R2.
		"cost": 165,
		"hp": 960.0,
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
		"art_faces_right": false,
		"radius": 21.0,          # крупный корпус (рисование + радиус сплеша)
		"color": Color(0.95, 0.3, 0.35),
	},
}

## Цены и урон башен подняты/снижены под ЭТАП 7: лимиты постройки сняты
## (плейтест: «не хочу 2 на тип»), и без компенсации защитник заваливал
## дорогу башнями — штурмовик не мог пробиться ни в одном раунде
## (tools/balance_audit.py, режим decks: 1 летальная клетка из 15).
## Теперь цена +25 %, урон -20 %: та же сила стоит дороже, а ширина
## обороны упирается в кредиты, а не в счётчик.
const TOWERS := {
	"sniper": {
		"name": "Снайпер",
		"cost": 70,
		"kind": "beam",          # хитскан-луч: без снаряда, урон мгновенно
		"damage_type": "ap",     # бронебойный: силён по тяжёлым, слаб по воздуху
		"priority": "strongest", # бьёт цель с наибольшим HP в радиусе
		"range": 200.0,
		"damage": 16.0,
		"fire_rate": 0.85,
		"can_target_flying": true,
		"color": Color(0.45, 0.95, 0.55),
	},
	"splash": {
		"name": "Мортира",
		"cost": 105,
		"kind": "lob",           # навесной снаряд с уроном по площади
		"damage_type": "he",
		"priority": "cluster",   # выбирает цель в самой плотной группе
		"range": 190.0,
		"damage": 21.0,
		"fire_rate": 0.75,
		"splash_radius": 90.0,
		"splash_falloff_min": 0.5,
		# ЕДИНСТВЕННАЯ башня без ПВО: осколки не достают воздух.
		"can_target_flying": false,
		"projectile_speed": 240.0,
		"color": Color(0.95, 0.8, 0.35),
	},
	"frost": {
		"name": "Криостан",
		"cost": 70,
		"kind": "frost",
		"damage_type": "cryo",
		"priority": "progress",   # контроль лидера важнее добивания
		"range": 165.0,
		"damage": 3.0,
		"fire_rate": 1.2,
		"slow_percent": 0.5,
		"slow_duration": 2.0,
		"pulse_radius": 70.0,
		# ПВО есть у всех, кроме мортиры: воздух — не «неуязвимый класс»,
		# а просто ещё один заход. Замедление на летающих не липнет
		# (ignores_slow в статах змея), поэтому криостан по ним — чистый урон.
		"can_target_flying": true,
		"projectile_speed": 340.0,
		"color": Color(0.5, 0.85, 1.0),
	},
	"tesla": {
		"name": "Тесла",
		"cost": 120,
		"kind": "chain",
		"damage_type": "arc",    # лучший ответ на воздух
		"priority": "densest",   # цель, вокруг которой больше всего соседей
		"range": 200.0,
		"damage": 10.5,
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
		"cost": 75,
		"kind": "flame",         # шквал лёгких снарядов в упор
		"damage_type": "fire",
		"priority": "weakest",   # добивает раненых, не тратит залп на танка
		"range": 120.0,
		"damage": 2.8,
		"fire_rate": 5.0,
		# Струя задевает соседей: огнемёт — дешёвая «мортира для бедных».
		"splash_radius": 45.0,
		"splash_falloff_min": 0.6,
		# Огнемёт тоже достаёт воздух (короткая струя — цена за универсальность).
		"can_target_flying": true,
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


# ------------------------------------------------------------- Уровни --------

## Цена следующего уровня башни. Растёт линейно: 10-й уровень суммарно
## стоит ~4,4 базовой цены башни (см. отчёт tools/balance_audit.py upgrades).
static func tower_upgrade_cost(tower_id: String, level: int) -> int:
	if not TOWERS.has(tower_id) or level >= TOWER_MAX_LEVEL:
		return 0
	var base := float(TOWERS[tower_id]["cost"])
	return int(ceil(base * (0.18 + 0.06 * float(level))))


## Статы башни на уровне level (1..10) — копия с масштабированными полями.
## Чистая функция: её же использует и HUD, и симулятор баланса.
static func tower_stats_at(tower_id: String, level: int) -> Dictionary:
	var out: Dictionary = TOWERS[tower_id].duplicate(true)
	var lv := clampi(level, 1, TOWER_MAX_LEVEL)
	var steps := float(lv - 1)
	out["level"] = lv
	out["damage"] = float(out["damage"]) * (1.0 + TOWER_DAMAGE_STEP * steps)
	out["fire_rate"] = float(out["fire_rate"]) * (1.0 + TOWER_RATE_STEP * steps)
	out["range"] = float(out["range"]) * (1.0 + TOWER_RANGE_STEP * steps)
	return out


## Цена следующего уровня типа юнита (прокачивается весь тип, не отдельный юнит).
## Суммарно до 10-го — x9,9 базовой цены: прокачка одного типа стоит как
## примерно десять юнитов этого типа, то есть это осознанная «вертикаль»,
## а не автопокупка в каждом раунде.
static func unit_upgrade_cost(unit_id: String, level: int) -> int:
	if not UNITS.has(unit_id) or level >= UNIT_MAX_LEVEL:
		return 0
	var base := float(UNITS[unit_id]["cost"])
	return int(ceil(base * (0.30 + 0.16 * float(level))))


## Статы юнита на уровне level: HP, скорость и (на 5/10) урон базе.
static func unit_stats_at(unit_id: String, level: int) -> Dictionary:
	var out: Dictionary = UNITS[unit_id].duplicate(true)
	var lv := clampi(level, 1, UNIT_MAX_LEVEL)
	var steps := float(lv - 1)
	out["level"] = lv
	out["hp"] = float(out["hp"]) * (1.0 + UNIT_HP_STEP * steps)
	out["speed"] = float(out["speed"]) * (1.0 + UNIT_SPEED_STEP * steps)
	var bonus := 0
	for milestone in UNIT_DAMAGE_LEVELS:
		if lv >= int(milestone):
			bonus += 1
	out["damage"] = int(out["damage"]) + bonus
	return out


## Цена самого дешёвого юнита — для проверки «штурмовик-банкрот» и подсказок.
static func cheapest_unit_cost() -> int:
	var cheapest := 1 << 30
	for unit_id in UNIT_ORDER:
		cheapest = mini(cheapest, int(UNITS[unit_id]["cost"]))
	return cheapest
