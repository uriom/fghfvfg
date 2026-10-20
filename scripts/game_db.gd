class_name GameDB
## Статичная «база данных» игры: характеристики юнитов и башен.
##
## ЭТАП 2 — три специализации башен и юнитов:
##   Башни:
##     sniper — одиночная атака: высокий урон, мгновенный луч (хитскан);
##     splash — AoE-сплеш: урон по площади с линейным спадом к краю;
##     frost  — замедление: малый урон + -50% скорости цели на N секунд.
##   Юниты:
##     fast   — скоростной: низкое HP, высокая скорость;
##     tank   — танк: высокое HP, низкая скорость, АУРА защиты союзников;
##     flying — летающий: игнорирует замедления (криостан бессилен).
##
## Хранится словарями, чтобы балансировать прямо в коде. Когда данных станет
## много — легко переносится в кастомные Resource (.tres) с @export-полями.

const UNITS := {
	"fast": {
		"name": "Бегун",
		"cost": 15,          # цена для штурмовика
		"hp": 30.0,
		"speed": 150.0,      # скорость по дороге, пикселей/сек
		"damage": 1,         # урон базе при прорыве
		"bounty": 10,        # золото штурмовику за прорыв
		"kill_reward": 8,    # золото защитнику за убийство
		"flying": false,
		"ignores_slow": false,
		"color": Color(0.4, 0.8, 1.0),
	},
	"tank": {
		"name": "Танк",
		"cost": 45,
		"hp": 160.0,
		"speed": 55.0,
		"damage": 3,
		"bounty": 25,
		"kill_reward": 20,
		"flying": false,
		"ignores_slow": false,
		"aura_radius": 110.0,    # радиус защитной ауры (рисуется у юнита)
		"aura_reduction": 0.35,  # -35% входящего урона союзникам в радиусе
		"color": Color(1.0, 0.55, 0.3),
	},
	"flying": {
		"name": "Змей",
		"cost": 30,
		"hp": 60.0,
		"speed": 110.0,
		"damage": 2,
		"bounty": 18,
		"kill_reward": 12,
		"flying": true,
		"ignores_slow": true,    # летающие не замедляются криостаном
		"color": Color(0.8, 0.45, 1.0),
	},
	"rider": {
		"name": "Наездник",
		"cost": 25,
		"hp": 55.0,
		"speed": 125.0,          # быстрый, но заметно живучее бегуна
		"damage": 1,
		"bounty": 16,
		"kill_reward": 11,
		"flying": false,
		"ignores_slow": false,
		"color": Color(0.55, 0.9, 0.35),
	},
	"boss": {
		"name": "Босс",
		"cost": 120,
		"hp": 700.0,
		"speed": 38.0,           # медленный таран: доходит — базе больно
		"damage": 8,
		"bounty": 90,
		"kill_reward": 70,
		"flying": false,
		"ignores_slow": false,
		"radius": 21.0,          # крупный корпус (рисование + радиус сплеша)
		"color": Color(0.95, 0.3, 0.35),
	},
}

const TOWERS := {
	"sniper": {
		"name": "Снайпер",
		"cost": 50,
		"kind": "beam",          # хитскан-луч: без снаряда, урон мгновенно
		"range": 260.0,
		"damage": 22.0,
		"fire_rate": 1.0,        # выстрелов в секунду
		"can_target_flying": true,
		"color": Color(0.45, 0.95, 0.55),
	},
	"splash": {
		"name": "Мортира",
		"cost": 90,
		"kind": "lob",           # навесной снаряд с уроном по площади
		"range": 200.0,
		"damage": 16.0,
		"fire_rate": 0.8,
		"splash_radius": 85.0,   # радиус взрыва (визуализируется кольцом)
		"splash_falloff_min": 0.5,  # доля урона на краю: 100% в центре -> 50% на краю
		"can_target_flying": true,
		"projectile_speed": 240.0,
		"color": Color(0.95, 0.8, 0.35),
	},
	"frost": {
		"name": "Криостан",
		"cost": 70,
		"kind": "frost",         # снаряд замедления
		"range": 170.0,
		"damage": 3.0,           # сам урон мал — ценность в контроле
		"fire_rate": 1.2,
		"slow_percent": 0.5,     # -50% скорости цели
		"slow_duration": 2.0,    # на 2 секунды
		"pulse_radius": 70.0,    # радиус визуального импульса
		"can_target_flying": true,
		"projectile_speed": 340.0,
		"color": Color(0.5, 0.85, 1.0),
	},
	"tesla": {
		"name": "Тесла",
		"cost": 110,
		"kind": "chain",         # цепная молния: цель + до 2 соседних юнитов
		"range": 210.0,
		"damage": 12.0,
		"chain_targets": 2,      # сколько доп. целей цепляет разряд
		"chain_range": 120.0,    # радиус поиска следующего звена
		"chain_falloff": 0.6,    # каждое звено бьёт на 60% слабее
		"fire_rate": 1.1,
		"can_target_flying": true,
		"color": Color(0.75, 0.6, 1.0),
	},
	"flamer": {
		"name": "Огнемёт",
		"cost": 60,
		"kind": "flame",         # шквал лёгких снарядов в упор
		"range": 130.0,
		"damage": 4.0,
		"fire_rate": 4.0,
		"can_target_flying": false,   # короткая рука — только по земле
		"projectile_speed": 520.0,
		"color": Color(1.0, 0.45, 0.25),
	},
}

# Порядок кнопок в интерфейсах (и плиток выбора снаряжения).
const UNIT_ORDER: Array[String] = ["fast", "rider", "tank", "flying", "boss"]
const TOWER_ORDER: Array[String] = ["sniper", "splash", "frost", "flamer", "tesla"]


## Цена самого дешёвого юнита — для проверки «штурмовик-банкрот» в системе
## волн (game.gd): если золота меньше — новую волну юнитами не открыть.
static func cheapest_unit_cost() -> int:
	var cheapest := 1 << 30
	for unit_id in UNIT_ORDER:
		cheapest = mini(cheapest, int(UNITS[unit_id]["cost"]))
	return cheapest
