#!/usr/bin/env python3
"""Воспроизводимый балансный аудит Tower Duel (профиль v3).

Скрипт повторяет расчёты из docs/GDD_AUDIT_RU.md, используя ТОЛЬКО данные,
которые уже есть в проекте: координаты дороги из scenes/game.tscn, размер
клетки и зоны строительства из scripts/map.gd, статы из scripts/game_db.gd,
экономику из autoload/game_state.gd. Godot не требуется.

Профили данных:
  v1 — снимок, на котором построен аудит (коммит 46079d6): волны, 5 башен,
       старт 220, матч 600 с. Только для сверки старых таблиц отчёта.
  v2 — COMBAT v2: матрица урона, броня, приоритеты, лимиты 2/8, BO3.
  v3 — текущий проект (ЭТАП 7): лимитов нет, уровни башен и юнитов 1..10,
       подготовка 10 с, окно спавна 30 с, добивание.

Запуск:
    python3 tools/balance_audit.py                    # профиль v3, всё
    python3 tools/balance_audit.py --profile v2 decks
    python3 tools/balance_audit.py coverage           # только покрытие пути
    python3 tools/balance_audit.py economy            # экономика раундов
    python3 tools/balance_audit.py upgrades           # уровни 1..10
    python3 tools/balance_audit.py sim                # сценарии боя
    python3 tools/balance_audit.py decks              # «дека × состав атаки»

Зачем: любую правку баланса можно проверить за секунды, без двух ПК и
матча целиком.
"""

from __future__ import annotations

import argparse
import copy
import math
import sys
from dataclasses import dataclass, field

# --------------------------------------------------------------- Данные проекта

# scenes/game.tscn -> Curve2D_road: (0,0) (24,120) (1128,120) (1128,312) (24,312)
ROAD_POINTS = [(0.0, 0.0), (24.0, 120.0), (1128.0, 120.0), (1128.0, 312.0), (24.0, 312.0)]

# scripts/map.gd: cell_size = (48,48), buildable_rect = (0,96,1152,288), road_half_width = 27
CELL_SIZE = 48
BUILDABLE_RECT = (0.0, 96.0, 1152.0, 288.0)
ROAD_HALF_WIDTH = 27.0
SAMPLE_STEP = 2.0  # шаг сэмплирования пути, px

# Матрица урона (scripts/game_db.gd, COMBAT v2). В v1 матрицы не было.
DAMAGE_MATRIX = {
    "ap": {"light": 0.75, "heavy": 1.50, "air": 0.75},
    "he": {"light": 1.25, "heavy": 0.90, "air": 1.00},
    "fire": {"light": 1.50, "heavy": 0.80, "air": 1.00},
    "cryo": {"light": 1.00, "heavy": 0.80, "air": 1.00},
    "arc": {"light": 1.25, "heavy": 0.80, "air": 1.50},
}

# scripts/game_db.gd (v1, коммит 46079d6): cost, damage, rate, range, air
TOWERS_V1 = {
    "sniper": dict(cost=50, damage=22.0, rate=1.0, rng=260.0, air=True),
    "splash": dict(cost=90, damage=16.0, rate=0.8, rng=200.0, air=True),
    "frost": dict(cost=70, damage=3.0, rate=1.2, rng=170.0, air=True),
    "flamer": dict(cost=60, damage=4.0, rate=4.0, rng=130.0, air=False),
    "tesla": dict(cost=110, damage=12.0, rate=1.1, rng=210.0, air=True),
}

# scripts/game_db.gd (v2): cost, damage, rate, range, air, damage_type, priority
TOWERS_V2 = {
    "sniper": dict(cost=55, damage=20.0, rate=0.85, rng=200.0, air=True,
                   dtype="ap", priority="strongest"),
    "splash": dict(cost=85, damage=26.0, rate=0.75, rng=190.0, air=False,
                   dtype="he", priority="cluster",
                   splash=90.0, falloff=0.5),
    "frost": dict(cost=55, damage=3.0, rate=1.2, rng=165.0, air=False,
                  dtype="cryo", priority="progress",
                  slow=0.5, slow_time=2.0),
    "flamer": dict(cost=60, damage=3.5, rate=5.0, rng=120.0, air=False,
                   dtype="fire", priority="weakest",
                   splash=45.0, falloff=0.6),
    "tesla": dict(cost=95, damage=13.0, rate=1.0, rng=200.0, air=True,
                  dtype="arc", priority="densest", ground=False,
                  chain=2, chain_range=120.0, chain_falloff=0.6),
}

# ЭТАП 7: уровни. Те же константы, что в scripts/game_db.gd.
TOWER_MAX_LEVEL = 10
UNIT_MAX_LEVEL = 10
TOWER_DAMAGE_STEP = 0.22
TOWER_RATE_STEP = 0.03
TOWER_RANGE_STEP = 0.025
UNIT_HP_STEP = 0.10
UNIT_SPEED_STEP = 0.015
UNIT_DAMAGE_LEVELS = (10,)

UNITS_V1 = {
    "fast": dict(cost=15, hp=30.0, speed=150.0, dmg=1, bounty=10, kill=8),
    "rider": dict(cost=25, hp=55.0, speed=125.0, dmg=1, bounty=16, kill=11),
    "flying": dict(cost=30, hp=60.0, speed=110.0, dmg=2, bounty=18, kill=12),
    "tank": dict(cost=45, hp=160.0, speed=55.0, dmg=3, bounty=25, kill=20),
    "boss": dict(cost=120, hp=700.0, speed=38.0, dmg=8, bounty=90, kill=70),
}

UNITS_V2 = {
    "fast": dict(cost=15, hp=40.0, speed=150.0, dmg=1, bounty=8, kill=4, armor="light"),
    "rider": dict(cost=30, hp=90.0, speed=125.0, dmg=2, bounty=15, kill=8, armor="light"),
    "tank": dict(cost=50, hp=225.0, speed=55.0, dmg=3, bounty=25, kill=13, armor="heavy",
                 aura=110.0, aura_reduction=0.25),
    "flying": dict(cost=30, hp=90.0, speed=115.0, dmg=1, bounty=15, kill=8, armor="air"),
    # speed 46: путь 54,8 с при окне спавна 30 с — босс успевает дойти.
    "boss": dict(cost=150, hp=800.0, speed=46.0, dmg=6, bounty=65, kill=33, armor="heavy",
                 radius=21.0),
}

# ЭТАП 7 (снятые лимиты постройки + уровни). Отличия от v2:
#   * башни дороже на ~25 % и слабее на 20 % — иначе без лимитов защитник
#     заваливает дорогу и штурмовик не пробивается (см. раздел 4);
#   * юниты живучее на 20 % — компенсация тому же;
#   * босс 165 кр (в R1 влезает один, а не два).
TOWERS_V3 = copy.deepcopy(TOWERS_V2)
UNITS_V3 = copy.deepcopy(UNITS_V2)
TOWERS_V3["sniper"].update(cost=70, damage=16.0)
TOWERS_V3["splash"].update(cost=105, damage=21.0)
TOWERS_V3["frost"].update(cost=70)
TOWERS_V3["flamer"].update(cost=75, damage=2.8)
TOWERS_V3["tesla"].update(cost=120, damage=10.5)
for _unit in UNITS_V3.values():
    _unit["hp"] *= 1.20
UNITS_V3["boss"]["cost"] = 165

# autoload/game_state.gd — экономика
ECONOMY_V1 = dict(base_hp=20, start_gold=120, wave_stipend=100, wave_duration=60.0,
                  wave_break=5.0, match_limit=600.0)
ECONOMY_V2 = dict(base_hp=15, plan=12.0, assault=60.0, review=8.0,
                  budget_attacker=[200, 320, 480], budget_defender=[240, 100, 100],
                  trickle=1.5, rounds_to_win=2,
                  deploy_interval=0.45, queue=14)
ECONOMY_V3 = dict(base_hp=15, plan=10.0, spawn_window=30.0, review=0.0,
                  assault_max=75.0,
                  budget_attacker=[260, 180, 220], budget_defender=[280, 160, 200],
                  trickle=2.0, rounds_to_win=2,
                  deploy_interval=0.45, queue=40)

PROFILES = {
    "v1": dict(towers=TOWERS_V1, units=UNITS_V1, economy=ECONOMY_V1,
               max_levels=False),
    "v2": dict(towers=TOWERS_V2, units=UNITS_V2, economy=ECONOMY_V2,
               max_levels=False),
    "v3": dict(towers=TOWERS_V3, units=UNITS_V3, economy=ECONOMY_V3,
               max_levels=True),
}

# --------------------------------------------------------------- Геометрия пути


def _segments(points):
    return [(points[i], points[i + 1]) for i in range(len(points) - 1)]


SEGMENTS = _segments(ROAD_POINTS)
SEG_LENGTHS = [math.dist(a, b) for a, b in SEGMENTS]
PATH_LENGTH = sum(SEG_LENGTHS)


def sample_path(distance: float) -> tuple[float, float]:
    """Точка на пути по длине дуги (путь — набор прямых сегментов)."""
    distance = max(0.0, min(distance, PATH_LENGTH))
    for (a, b), length in zip(SEGMENTS, SEG_LENGTHS):
        if distance <= length:
            t = distance / length
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        distance -= length
    return ROAD_POINTS[-1]


def distance_to_path(point: tuple[float, float]) -> float:
    best = math.inf
    for a, b in SEGMENTS:
        dx, dy = b[0] - a[0], b[1] - a[1]
        length_sq = dx * dx + dy * dy
        if length_sq <= 0.0001:
            best = min(best, math.dist(point, a))
            continue
        t = ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length_sq
        t = max(0.0, min(1.0, t))
        best = min(best, math.dist(point, (a[0] + dx * t, a[1] + dy * t)))
    return best


def legal_cells() -> list[tuple[float, float]]:
    """Центры клеток, пригодных для постройки (та же логика, что GameMap)."""
    x0, y0, w, h = BUILDABLE_RECT
    cells = []
    x = x0 + CELL_SIZE * 0.5
    while x < x0 + w:
        y = y0 + CELL_SIZE * 0.5
        while y < y0 + h:
            point = (x, y)
            if (x0 <= point[0] <= x0 + w and y0 <= point[1] <= y0 + h
                    and distance_to_path(point) >= ROAD_HALF_WIDTH):
                cells.append(point)
            y += CELL_SIZE
        x += CELL_SIZE
    return cells


PATH_SAMPLES = [(s, sample_path(s))
                for s in [i * SAMPLE_STEP for i in range(int(PATH_LENGTH / SAMPLE_STEP) + 1)]]


def coverage(cell, radius) -> set[int]:
    return {i for i, (_, p) in enumerate(PATH_SAMPLES) if math.dist(p, cell) <= radius}


def coverage_fraction(cell, radius) -> float:
    return len(coverage(cell, radius)) / len(PATH_SAMPLES)


def greedy_cover(cells, radius):
    """Жадный set-cover: сколько башен нужно, чтобы накрыть весь путь."""
    chosen, covered = [], set()
    while len(covered) < len(PATH_SAMPLES):
        best, best_new = None, 0
        for cell in cells:
            if cell in chosen:
                continue
            new = len(coverage(cell, radius) - covered)
            if new > best_new:
                best, best_new = cell, new
        if best is None:
            break
        chosen.append(best)
        covered |= coverage(best, radius)
    return chosen, covered


# --------------------------------------------------------------- Уровни


def tower_stats(profile, tower_id: str, level: int = 1) -> dict:
    """Статы башни на уровне — копия GameDB.tower_stats_at()."""
    base = profile["towers"][tower_id]
    out = dict(base)
    if not profile.get("max_levels", False):
        out["level"] = 1
        return out
    lv = max(1, min(level, TOWER_MAX_LEVEL))
    steps = lv - 1
    out["level"] = lv
    out["damage"] = base["damage"] * (1.0 + TOWER_DAMAGE_STEP * steps)
    out["rate"] = base["rate"] * (1.0 + TOWER_RATE_STEP * steps)
    out["rng"] = base["rng"] * (1.0 + TOWER_RANGE_STEP * steps)
    return out


def tower_upgrade_cost(profile, tower_id: str, level: int) -> int:
    base = profile["towers"][tower_id]["cost"]
    return int(math.ceil(base * (0.18 + 0.06 * float(level))))


def unit_stats(profile, unit_id: str, level: int = 1) -> dict:
    base = profile["units"][unit_id]
    out = dict(base)
    if not profile.get("max_levels", False):
        out["level"] = 1
        return out
    lv = max(1, min(level, UNIT_MAX_LEVEL))
    steps = lv - 1
    out["level"] = lv
    out["hp"] = base["hp"] * (1.0 + UNIT_HP_STEP * steps)
    out["speed"] = base["speed"] * (1.0 + UNIT_SPEED_STEP * steps)
    bonus = sum(1 for milestone in UNIT_DAMAGE_LEVELS if lv >= milestone)
    out["dmg"] = int(base["dmg"]) + bonus
    return out


def unit_upgrade_cost(profile, unit_id: str, level: int) -> int:
    base = profile["units"][unit_id]["cost"]
    return int(math.ceil(base * (0.30 + 0.16 * float(level))))


def dps(stats: dict) -> float:
    """Сырой DPS башни по одной цели (без матрицы)."""
    return stats["damage"] * stats["rate"]


def tower_power(profile, tower_id: str, level: int, cell) -> float:
    """«Боевая ценность» башни: DPS, умноженный на долю пути под обстрелом."""
    st = tower_stats(profile, tower_id, level)
    return dps(st) * coverage_fraction(cell, st["rng"])


# --------------------------------------------------------------- Симуляция боя

DT = 0.01
HORIZON = 200.0


@dataclass
class SimUnit:
    progress: float
    hp: float
    max_hp: float
    slow_timer: float = 0.0
    slow_factor: float = 1.0
    alive: bool = True


@dataclass
class SimResult:
    leaks: int = 0
    kills: int = 0
    first_leak: float | None = None
    duration: float = 0.0
    leaked_hp: int = 0
    leak_log: list = field(default_factory=list)


def _mult(dtype: str | None, armor: str) -> float:
    if dtype is None:
        return 1.0
    return DAMAGE_MATRIX.get(dtype, {}).get(armor, 1.0)


def _allowed(tower: dict, unit: dict) -> bool:
    """Может ли башня в принципе стрелять по этому юниту."""
    flying = unit.get("armor") == "air"
    if flying and not tower["air"]:
        return False
    # Зенитка (tesla) бьёт только воздух: иначе «снайпер + сплеш + тесла»
    # закрывала все классы сразу и была единственной играбельной декой.
    if not flying and not tower.get("ground", True):
        return False
    return True


def _priority_score(tower: dict, unit: SimUnit, units, positions) -> float:
    priority = tower.get("priority", "progress")
    if priority == "strongest":
        return unit.hp
    if priority == "weakest":
        return -unit.hp
    if priority in ("cluster", "densest"):
        radius = tower.get("splash", tower.get("chain_range", 100.0))
        point = positions[id(unit)]
        count = sum(1 for other in units if other.alive and
                    math.dist(positions[id(other)], point) <= radius)
        return float(count - 1)
    return unit.progress


def _damage_unit(unit: SimUnit, unit_stats_row: dict, amount: float, dtype: str | None,
                 units: list[SimUnit], positions) -> None:
    """Урон с матрицей и аурой танка (как в Unit.take_damage)."""
    dmg = amount * _mult(dtype, unit_stats_row.get("armor", "light"))
    aura = 0.0
    for other in units:
        if other is unit or not other.alive:
            continue
        other_stats = other.stats
        if "aura" in other_stats:
            if math.dist(positions[id(other)], positions[id(unit)]) <= other_stats["aura"]:
                aura = max(aura, other_stats["aura_reduction"])
    if aura > 0.0:
        dmg *= 1.0 - aura
    dmg = min(dmg, unit.hp)
    unit.hp -= dmg
    if unit.hp <= 0.0:
        unit.alive = False


def _spawn_plan(profile, comp, levels: dict | None = None) -> list[dict]:
    """Разворачивает состав в очередь спавна.

    comp — id юнита (моно-волна) либо список [(id, count), ...] / словарь
    {id: count} для смешанного захода. Смешанная очередь чередуется по типам:
    так играет живой штурмовик, и так танк не отстаёт от бегунов на 40 секунд.
    """
    levels = levels or {}

    def row(uid: str) -> dict:
        return unit_stats(profile, uid, int(levels.get(uid, 1)))

    if isinstance(comp, str):
        return [row(comp)]
    pairs = list(comp.items()) if isinstance(comp, dict) else list(comp)
    buckets = [[row(uid)] * int(n) for uid, n in pairs if int(n) > 0]
    plan = []
    while any(buckets):
        for bucket in buckets:
            if bucket:
                plan.append(bucket.pop(0))
    return plan


def simulate(profile, towers, comp, count: int | None = None, gap: float = 0.45,
             levels: dict | None = None) -> SimResult:
    """Дискретная симуляция боя.

    towers — [(cell, tower_id, level)] (допускается пара без уровня).
    Модель повторяет tower.gd / projectile.gd: выбор цели по priority,
    кулдаун 1/fire_rate, матрица урона, аура танка, сплеш со спадом, цепь
    теслы с затуханием, замедление криостаном.
    comp — id юнита (тогда count задаёт количество) или смешанный состав.
    levels — уровни типов юнитов (id -> 1..10).
    Допущения: снаряд летит мгновенно, башни не перезаряжаются между волнами.
    """
    if isinstance(comp, str) and count is not None:
        plan = [unit_stats(profile, comp, int((levels or {}).get(comp, 1)))] * int(count)
    else:
        plan = _spawn_plan(profile, comp, levels)
    total = len(plan)

    prepared = []
    for entry in towers:
        if len(entry) == 3:
            cell, tower_id, level = entry
        else:
            cell, tower_id = entry
            level = 1
        prepared.append((cell, tower_stats(profile, tower_id, int(level))))

    cooldowns = [0.0] * len(prepared)
    units: list[SimUnit] = []
    positions: dict[int, tuple[float, float]] = {}
    sent, next_spawn = 0, 0.0
    t = 0.0
    result = SimResult()

    while t < HORIZON:
        if sent < total and t >= next_spawn:
            row = plan[sent]
            u = SimUnit(0.0, row["hp"], row["hp"])
            u.stats = row
            units.append(u)
            sent += 1
            next_spawn = t + gap

        for u in units:
            if not u.alive:
                continue
            speed_mult = 1.0
            if u.slow_timer > 0.0:
                u.slow_timer = max(u.slow_timer - DT, 0.0)
                speed_mult = u.slow_factor
            u.progress += u.stats["speed"] * speed_mult * DT
            positions[id(u)] = sample_path(u.progress)

        for i, (cell, tw) in enumerate(prepared):
            cooldowns[i] = max(cooldowns[i] - DT, 0.0)
            if cooldowns[i] > 0.0:
                continue
            candidates = []
            for u in units:
                if not u.alive:
                    continue
                if not _allowed(tw, u.stats):
                    continue
                if math.dist(positions[id(u)], cell) <= tw["rng"]:
                    candidates.append(u)
            if not candidates:
                continue
            best = max(candidates,
                       key=lambda u: (_priority_score(tw, u, units, positions),
                                      u.progress))
            base = tw["damage"]
            dtype = tw.get("dtype")
            if tw.get("splash"):
                # Сплеш: урон всем в радиусе со спадом до falloff на краю.
                for other in units:
                    if not other.alive:
                        continue
                    # Наземная мортира не задевает воздух (как projectile.gd).
                    if not tw["air"] and other.stats.get("armor") == "air":
                        continue
                    unit_radius = other.stats.get("radius", 12.0)
                    dist = max(math.dist(positions[id(other)], positions[id(best)])
                               - unit_radius, 0.0)
                    if dist <= tw["splash"]:
                        k = 1.0 - (1.0 - tw["falloff"]) * min(dist / tw["splash"], 1.0)
                        _damage_unit(other, other.stats, base * k, dtype, units, positions)
            elif tw.get("chain"):
                _damage_unit(best, best.stats, base, dtype, units, positions)
                linked = [best]
                hop = base
                for _ in range(tw["chain"]):
                    centre = positions[id(linked[-1])]
                    nearest = None
                    nearest_dist = math.inf
                    for other in units:
                        if not other.alive or other in linked:
                            continue
                        d = math.dist(positions[id(other)], centre)
                        if d <= tw["chain_range"] and d < nearest_dist:
                            nearest, nearest_dist = other, d
                    if nearest is None:
                        break
                    hop *= tw["chain_falloff"]
                    _damage_unit(nearest, nearest.stats, hop, dtype, units, positions)
                    linked.append(nearest)
            else:
                _damage_unit(best, best.stats, base, dtype, units, positions)
            # Криостанов не липнет к тем, кто его игнорирует (летающие,
            # пока в их статах стоит ignores_slow).
            if tw.get("slow") and best.alive and not best.stats.get("ignores_slow"):
                best.slow_factor = min(best.slow_factor if best.slow_timer > 0.0 else 1.0,
                                       1.0 - tw["slow"])
                best.slow_timer = max(best.slow_timer, tw["slow_time"])
            cooldowns[i] = 1.0 / tw["rate"]

        # Прорыв: юнит дошёл до базы.
        for u in units:
            if u.alive and u.progress >= PATH_LENGTH:
                u.alive = False
                result.leaks += 1
                result.leak_log.append(t)
                if result.first_leak is None:
                    result.first_leak = t
                result.leaked_hp += int(u.stats["dmg"])

        result.kills = sum(1 for u in units if not u.alive) - result.leaks
        t += DT
        if sent == total and all(not u.alive for u in units):
            break

    result.duration = t
    return result


# --------------------------------------------------------------- Оборона


def _cover_cells(profile) -> list[tuple[float, float]]:
    """Клетки полного покрытия под максимальный радиус башен профиля."""
    radius = max(t["rng"] for t in profile["towers"].values())
    cells, _ = greedy_cover(legal_cells(), radius)
    return cells


def build_defense(profile, deck, budget, upgrades: bool | None = None,
                  mono: str | None = None):
    """Собирает оборону под бюджет — «как играет живой защитник».

    Сначала застройка: типы берутся по кругу из деки, клетка каждый раз та,
    что даёт максимум НОВОГО покрытия пути под радиус этой башни (так игрок
    закрывает дыры, а не лепит всё в одну точку). Когда путь закрыт или
    кредитов на постройку нет — остаток уходит в апгрейды с лучшим приростом
    силы за кредит.
    mono — строить только этот тип (поиск лучшего ответа на состав атаки).
    upgrades=False — только постройка (профили v1/v2 без уровней).
    Возвращает (towers [(cell, id, level)], spent, leftover).
    """
    if upgrades is None:
        upgrades = bool(profile.get("max_levels", False))
    available = legal_cells()
    built: list[list] = []   # [cell, tower_id, level]
    used: set = set()
    covered: set = set()
    spent = 0
    built_types = 0

    # 1. Застройка: закрываем путь, тип — по кругу из деки.
    while True:
        tower_id = mono if mono else deck[built_types % len(deck)]
        stats = tower_stats(profile, tower_id, 1)
        cost = int(profile["towers"][tower_id]["cost"])
        if spent + cost > budget:
            break
        best_cell, best_gain = None, -1
        radius_cov = None
        for cell in available:
            if cell in used:
                continue
            cover = coverage(cell, stats["rng"])
            gain = len(cover - covered)
            if gain > best_gain:
                best_cell, best_gain, radius_cov = cell, gain, cover
        if best_cell is None or best_gain <= 0:
            break   # путь уже накрыт полностью — дальше только апгрейды
        built.append([best_cell, tower_id, 1])
        used.add(best_cell)
        covered |= radius_cov
        spent += cost
        built_types += 1

    # 2. Апгрейды: пока есть что качать и чем платить.
    while upgrades:
        options = []
        for entry in built:
            cell, tower_id, level = entry
            if level >= TOWER_MAX_LEVEL:
                continue
            cost = tower_upgrade_cost(profile, tower_id, level)
            if spent + cost > budget:
                continue
            gain = (tower_power(profile, tower_id, level + 1, cell)
                    - tower_power(profile, tower_id, level, cell))
            options.append((gain / cost, cost, entry))
        if not options:
            break
        options.sort(key=lambda o: (o[0], -o[1]), reverse=True)
        _, cost, entry = options[0]
        entry[2] += 1
        spent += cost

    towers = [(cell, tower_id, level) for cell, tower_id, level in built]
    return towers, spent, budget - spent


# --------------------------------------------------------------- Отчёты


def report_geometry(profile):
    print("=" * 78)
    print("1. ГЕОМЕТРИЯ АРЕНЫ")
    print("=" * 78)
    print(f"Длина пути: {PATH_LENGTH:.1f} px  (сегменты: "
          f"{', '.join(f'{l:.1f}' for l in SEG_LENGTHS)})")
    for name, u in profile["units"].items():
        print(f"  {name:7s} speed {u['speed']:5.0f} -> время пути "
              f"{PATH_LENGTH / u['speed']:6.2f} с")

    cells = legal_cells()
    print(f"Легальных клеток: {len(cells)}")
    radius = max(t["rng"] for t in profile["towers"].values())
    print(f"\nПокрытие пути одной башней (R={radius:.0f}):")
    ranked = sorted(((coverage_fraction(c, radius), c) for c in cells), reverse=True)
    for frac, cell in ranked[:5]:
        print(f"  клетка ({cell[0]:.0f}, {cell[1]:.0f}) -> {frac * 100:.1f}%")
    for threshold in (0.20, 0.30, 0.40):
        n = sum(1 for frac, _ in ranked if frac >= threshold)
        print(f"  клеток с покрытием >= {threshold * 100:.0f}%: {n} из {len(ranked)}")

    print("\nПолное покрытие пути (жадный set-cover):")
    for r in (130.0, 170.0, 200.0, 240.0, 260.0):
        chosen, covered = greedy_cover(cells, r)
        cost = len(chosen) * profile["towers"]["sniper"]["cost"]
        print(f"  R={r:.0f}: {len(chosen)} башен, {cost} кредитов, "
              f"покрыто {len(covered) / len(PATH_SAMPLES) * 100:.0f}%")
        if r == radius:
            running = set()
            for i, cell in enumerate(chosen, 1):
                running |= coverage(cell, r)
                print(f"    {i}. ({cell[0]:.0f}, {cell[1]:.0f}) -> "
                      f"{len(running) / len(PATH_SAMPLES) * 100:.1f}%")
    return cells


def report_economy(profile):
    eco = profile["economy"]
    towers = profile["towers"]
    units = profile["units"]
    print()
    print("=" * 78)
    print("2. ЭКОНОМИКА И ПРОИЗВОДНЫЕ МЕТРИКИ")
    print("=" * 78)

    if "budget_attacker" in eco:
        if eco.get("spawn_window"):
            print(f"Раунд: ПОДГОТОВКА {eco['plan']:.0f} с -> ШТУРМ "
                  f"(окно спавна {eco['spawn_window']:.0f} с + добивание)")
        else:
            print("Раунды: ПОДГОТОВКА %.0f с / ШТУРМ %.0f с / ИТОГ %.0f с"
                  % (eco["plan"], eco["assault"], eco["review"]))
        print(f"HP базы в раунде: {eco['base_hp']}, побед для матча: {eco['rounds_to_win']}")
        trickle = eco["trickle"] * (eco.get("spawn_window") or eco["assault"])
        for i in range(3):
            print(f"  раунд {i + 1}: защитник {eco['budget_defender'][i]:3d} кр, "
                  f"штурмовик {eco['budget_attacker'][i]:3d} + {trickle:.0f} капельно "
                  f"= {eco['budget_attacker'][i] + trickle:.0f} кр")
        print(f"  суммарно за матч: защитник {sum(eco['budget_defender'])} кр, "
              f"штурмовик {sum(eco['budget_attacker']) + int(3 * trickle)} кр")
        print(f"\nПорог раунда: {eco['base_hp']} урона базе. "
              f"Цена 1 урона базе по юнитам (1-й уровень):")
        for name, u in units.items():
            print(f"  {name:7s} {u['cost']:3d} кр / {u['dmg']} урона = "
                  f"{u['cost'] / u['dmg']:5.1f} кр за единицу урона")
    else:
        start = eco["start_gold"] + eco["wave_stipend"]
        print(f"Стартовый капитал: {start} (START_GOLD {eco['start_gold']} + "
              f"WAVE_STIPEND {eco['wave_stipend']})")
        waves = int(eco["match_limit"] // (eco["wave_duration"] + eco["wave_break"])) + 1
        total_income = start + (waves - 1) * eco["wave_stipend"]
        print(f"Волн в матче (при лимите {eco['match_limit']:.0f} с): ~{waves}, "
              f"базовый доход {total_income}")

    print("\nБашни: базовый DPS и DPS/кредит по классам брони (1-й уровень)")
    header = f"  {'tower':8s} {'cost':>4s} {'dps':>6s} {'range':>5s} {'dps/g':>6s}"
    if "dtype" in next(iter(towers.values())):
        header += f" {'лёгк':>6s} {'тяж':>6s} {'возд':>6s}  тип   приоритет"
    print(header)
    for name, t in towers.items():
        dmg = t["damage"] * t["rate"]
        line = (f"  {name:8s} {t['cost']:4d} {dmg:6.1f} {t['rng']:5.0f} "
                f"{dmg / t['cost']:6.3f}")
        if "dtype" in t:
            d = t["dtype"]
            light = dmg * _mult(d, "light") / t["cost"]
            heavy = dmg * _mult(d, "heavy") / t["cost"]
            air = dmg * _mult(d, "air") / t["cost"]
            air_s = "—" if not t["air"] else f"{air:6.3f}"
            line += f" {light:6.3f} {heavy:6.3f} {air_s:>6s}  {d:4s}  {t['priority']}"
        print(line)

    print("\nЮниты (1-й уровень):")
    print(f"  {'unit':8s} {'cost':>4s} {'hp':>6s} {'speed':>5s} {'dmg':>3s} "
          f"{'hp/g':>5s} {'g/dmg':>5s}  armor")
    for name, u in units.items():
        print(f"  {name:8s} {u['cost']:4d} {u['hp']:6.0f} {u['speed']:5.0f} "
              f"{u['dmg']:3d} {u['hp'] / u['cost']:5.2f} "
              f"{u['cost'] / u['dmg']:5.1f}  {u.get('armor', 'light')}")


def report_upgrades(profile):
    print()
    print("=" * 78)
    print("3. УРОВНИ 1..10")
    print("=" * 78)
    if not profile.get("max_levels", False):
        print("  Профиль без уровней (v1/v2) — отчёт только для v3.")
        return

    print("\nБашни: суммарная стоимость прокачки и прирост силы")
    print(f"  {'tower':8s} {'база':>5s} {'до 10':>7s} {'DPS1':>7s} {'DPS10':>7s} "
          f"{'x':>5s} {'радиус':>7s} {'кр/DPS':>7s}")
    for name in profile["towers"]:
        total = sum(tower_upgrade_cost(profile, name, lv)
                    for lv in range(1, TOWER_MAX_LEVEL))
        s1 = tower_stats(profile, name, 1)
        s10 = tower_stats(profile, name, TOWER_MAX_LEVEL)
        print(f"  {name:8s} {profile['towers'][name]['cost']:5d} {total:7d} "
              f"{dps(s1):7.1f} {dps(s10):7.1f} {dps(s10) / dps(s1):5.2f} "
              f"{s10['rng']:7.0f} {total / (dps(s10) - dps(s1)):7.2f}")

    print("\nЦена уровней башни (снайпер / мортира / тесла):")
    for name in ("sniper", "splash", "tesla"):
        row = [str(tower_upgrade_cost(profile, name, lv))
               for lv in range(1, TOWER_MAX_LEVEL)]
        print(f"  {name:8s} " + " ".join(f"{v:>3s}" for v in row))

    print("\nЮниты: HP / урон базе по уровням")
    print(f"  {'unit':8s} " + " ".join(f"ур{lv:<2d}" for lv in range(1, UNIT_MAX_LEVEL + 1)))
    for name in profile["units"]:
        hp_row = []
        for lv in range(1, UNIT_MAX_LEVEL + 1):
            st = unit_stats(profile, name, lv)
            hp_row.append(f"{st['hp']:.0f}/{st['dmg']}")
        print(f"  {name:8s} " + " ".join(f"{v:>5s}" for v in hp_row))

    print("\nСтоимость прокачки типа юнита (суммарно до 10-го):")
    for name in profile["units"]:
        total = sum(unit_upgrade_cost(profile, name, lv)
                    for lv in range(1, UNIT_MAX_LEVEL))
        s1 = unit_stats(profile, name, 1)
        s10 = unit_stats(profile, name, UNIT_MAX_LEVEL)
        print(f"  {name:8s} {total:4d} кр  HP x{s10['hp'] / s1['hp']:.2f}  "
              f"урон базе {s1['dmg']} -> {s10['dmg']}  "
              f"скорость x{s10['speed'] / s1['speed']:.2f}")

    # «Шире» против «выше»: одинаковый бюджет, разная стратегия.
    print("\n«Шире или выше»: бюджет 440 кредитов, дека «снайпер + мортира + тесла»")
    deck = ["sniper", "splash", "tesla"]
    wide, wide_spent, _ = build_defense(profile, deck, 440, upgrades=False)
    tall, tall_spent, _ = build_defense(profile, deck, 440, upgrades=True)
    for label, towers, spent in (("только постройка", wide, wide_spent),
                                 ("с апгрейдами", tall, tall_spent)):
        levels = [lv for _, _, lv in towers]
        print(f"  {label:18s} башен {len(towers):2d}, "
              f"уровни {levels}, потрачено {spent} кр")
    cells = _cover_cells(profile)
    for label, towers in (("только постройка", wide), ("с апгрейдами", tall)):
        covered = set()
        for i, (cell, tower_id, level) in enumerate(towers):
            st = tower_stats(profile, tower_id, level)
            covered |= coverage(cell, st["rng"])
        total_dps = sum(dps(tower_stats(profile, t, lv)) for _, t, lv in towers)
        print(f"  {label:18s} покрытие пути {len(covered) / len(PATH_SAMPLES) * 100:5.1f}%, "
              f"суммарный DPS {total_dps:6.1f}, клеток занято {len(towers)}")
    print(f"  клеток полного покрытия всего: {len(cells)}")


# --------------------------------------------------------------- Сценарии боя

ATTACKS = ("fast", "rider", "tank", "flying", "boss")
TOWER_DECKS = {
    "A sn+splash+frost": ["sniper", "splash", "frost"],
    "B sn+splash+tesla": ["sniper", "splash", "tesla"],
    "C sn+frost+flamer": ["sniper", "frost", "flamer"],
    "D splash+frost+flamer": ["splash", "frost", "flamer"],
    "E sn+tesla+flamer": ["sniper", "tesla", "flamer"],
}

# «Стандартный заход» — реалистичная смешанная волна: танки держат удар,
# конница и змеи просачиваются. Моно-раш слабее живой игры.
MIX_SHARES = {"tank": 0.40, "rider": 0.35, "flying": 0.25}


def mix_for_budget(profile, budget, shares=None) -> dict:
    shares = shares or MIX_SHARES
    comp = {}
    for uid, share in shares.items():
        cost = profile["units"][uid]["cost"]
        comp[uid] = int(budget * share) // cost
    return {uid: n for uid, n in comp.items() if n > 0}


def round_budgets(profile):
    eco = profile["economy"]
    if "budget_defender" not in eco:
        return [], []
    total_def, total_atk = 0, 0
    defs, atks = [], []
    window = eco.get("spawn_window") or eco["assault"]
    for i in range(3):
        total_def += eco["budget_defender"][i]
        total_atk += eco["budget_attacker"][i]
        defs.append(total_def)
        atks.append(total_atk + int(eco["trickle"] * window) * (i + 1))
    return defs, atks


def report_sim(profile, cells):
    print()
    print("=" * 78)
    print("3. СЦЕНАРИИ БОЯ (типовая оборона, без подбора контр-башни)")
    print("=" * 78)
    radius = max(t["rng"] for t in profile["towers"].values())
    chosen, _ = greedy_cover(cells, radius)
    print("Клетки полного покрытия:", [f"({c[0]:.0f},{c[1]:.0f})" for c in chosen])

    if not profile.get("max_levels", False):
        four = [(c, "sniper") for c in chosen]
        cases = [
            (four, "4 снайпера (200 кр)", "fast", 20, 0.4),
            (four, "4 снайпера", "fast", 100, 0.4),
            (four, "4 снайпера", "tank", 5, 0.4),
            (four, "4 снайпера", "flying", 10, 0.4),
            (four, "4 снайпера", "boss", 2, 1.0),
            (four[:2], "2 снайпера (100 кр)", "fast", 20, 0.4),
            (four[:1], "1 снайпер (50 кр)", "boss", 1, 1.0),
        ]
        for towers, label, unit_id, count, gap in cases:
            r = simulate(profile, towers, unit_id, count, gap)
            print(f"  {label:22s} {count:3d} x {unit_id:6s} прорв {r.leaks:3d}  "
                  f"урон {r.leaked_hp:3d}  бой {r.duration:5.1f} с")
        return

    defs, atks = round_budgets(profile)
    deck_a = TOWER_DECKS["A sn+splash+frost"]
    deck_b = TOWER_DECKS["B sn+splash+tesla"]
    print(f"\n  {'оборона':38s} {'атака':22s} {'прорв':>5s} {'урон':>5s} {'бой':>6s}")
    for idx, budget in enumerate(defs):
        for label, deck in (("A sn+splash+frost", deck_a), ("B sn+splash+tesla", deck_b)):
            towers, spent, _ = build_defense(profile, deck, budget)
            levels = [lv for _, _, lv in towers]
            comp = mix_for_budget(profile, atks[idx])
            r = simulate(profile, towers, comp, gap=0.45)
            row = f"R{idx + 1} {label} ({len(towers)} башен {spent}, ур {levels})"
            print(f"  {row:38s} {'микс':22s} {r.leaks:5d} {r.leaked_hp:5d} "
                  f"{r.duration:6.1f}")
            for unit_id in ("tank", "flying", "boss"):
                count = max(1, atks[idx] // profile["units"][unit_id]["cost"])
                r = simulate(profile, towers, unit_id, count, 0.45)
                print(f"  {'':38s} {f'{count} x {unit_id}':22s} {r.leaks:5d} "
                      f"{r.leaked_hp:5d} {r.duration:6.1f}")
    print("\n  «урон» — суммарный урон базе (HP раунда 15). Здесь оборона строит")
    print("  деку по кругу, а не подбирает контр-башню под состав: это «как")
    print("  играет человек, который ставит всё подряд». Худший случай для")
    print("  защитника — в разделе 4, где он отвечает лучшей башней деки.")


def match_damage(profile, unit_id, level, deck, rounds=3):
    """Урон базе за матч при стратегии «качать тип unit_id до level».

    Золото штурмовика копится между раундами (так же, как в GameState), апгрейд
    типа покупается один раз и дальше действует на все покупки. Оборона
    каждый раунд строится закопившимся бюджетом защиты (башни не сносятся).
    Счёт — сумма min(15, урон) по раундам: перебор сверх 15 не интересен.
    """
    eco = profile["economy"]
    up_total = sum(unit_upgrade_cost(profile, unit_id, lv)
                   for lv in range(1, level))
    up_paid = 0
    gold = 0
    total = 0
    def_total = 0
    for i in range(rounds):
        gold += eco["budget_attacker"][i] + int(
            eco["trickle"] * (eco.get("spawn_window") or eco["assault"]))
        def_total += eco["budget_defender"][i]
        if up_paid < up_total:
            pay = min(gold, up_total - up_paid)
            gold -= pay
            up_paid += pay
        towers, _, _ = build_defense(profile, deck, def_total)
        cost = profile["units"][unit_id]["cost"]
        count = gold // cost
        gold -= count * cost
        effective_level = level if up_paid >= up_total else 1
        r = simulate(profile, towers, unit_id, int(count), 0.45,
                     {unit_id: effective_level})
        total += min(r.leaked_hp, int(eco["base_hp"]))
    return total


def report_levels(profile):
    """Окупается ли прокачка типа юнита за матч (3 раунда, общий кошелёк)."""
    print()
    print("=" * 78)
    print("5. ЮНИТЫ: ПРОКАЧКА ПРОТИВ МАССЫ (матч из 3 раундов)")
    print("=" * 78)
    if not profile.get("max_levels", False):
        print("  Профиль без уровней (v1/v2) — отчёт только для v3.")
        return
    deck = TOWER_DECKS["A sn+splash+frost"]
    print(f"  Оборона: {deck} (общий бюджет защиты). Атака: один тип юнита.")
    print("  В клетке — суммарный урон базе за матч (макс 45 = 3 раунда по 15).")
    header = f"  {'unit':8s}"
    for lv in range(1, UNIT_MAX_LEVEL + 1):
        header += f" ур{lv:<2d}"
    print(header)
    for unit_id in ATTACKS:
        line = f"  {unit_id:8s}"
        results = []
        for level in range(1, UNIT_MAX_LEVEL + 1):
            dmg = match_damage(profile, unit_id, level, deck)
            results.append(dmg)
            line += f" {dmg:4d}"
        best = max(range(1, UNIT_MAX_LEVEL + 1), key=lambda lv: results[lv - 1])
        line += f"   лучший: ур{best}"
        print(line)
    print("\n  Если уровень 1 или 2 — лучший, прокачка не окупается;")
    print("  если лучший — 10, тип обязателен к прокачке (плохой знак).")

    # Та же проверка, но оборона — «B sn+splash+tesla» (у неё есть ПВО).
    deck_b = TOWER_DECKS["B sn+splash+tesla"]
    print(f"\n  Контроль: оборона {deck_b}")
    for unit_id in ATTACKS:
        results = [match_damage(profile, unit_id, lv, deck_b)
                   for lv in range(1, UNIT_MAX_LEVEL + 1)]
        best = max(range(1, UNIT_MAX_LEVEL + 1), key=lambda lv: results[lv - 1])
        print(f"  {unit_id:8s} ур1..10: " + " ".join(f"{d:2d}" for d in results)
              + f"   лучший: ур{best}")


def sim_income(profile, round_index):
    eco = profile["economy"]
    window = eco.get("spawn_window") or eco["assault"]
    return eco["budget_attacker"][round_index] + int(eco["trickle"] * window)


TOWER_MARK = {"sniper": "с", "splash": "м", "frost": "к", "flamer": "о",
              "tesla": "т"}


def best_defense(profile, deck, budget, unit_id, count=None, levels=None, gap=0.45):
    """Лучший ответ этой деки на конкретный состав атаки.

    Защитник не знает заранее, чем пойдут, но в момент боя видит юнитов и
    может докидывать башни (лимитов больше нет). Поэтому честная матрица —
    это минимум прорыва по «миксу» и по монозайстройке каждого типа из деки.
    Возвращает (урон, прорвалось, чем_держали).
    """
    best = None
    towers, _, _ = build_defense(profile, deck, budget)
    r = simulate(profile, towers, unit_id, count, gap, levels)
    best = (r.leaked_hp, r.leaks, "г")
    for tower_id in deck:
        towers, _, _ = build_defense(profile, deck, budget, mono=tower_id)
        r = simulate(profile, towers, unit_id, count, gap, levels)
        if r.leaked_hp < best[0]:
            best = (r.leaked_hp, r.leaks, TOWER_MARK[tower_id])
    return best


def report_decks(profile):
    print()
    print("=" * 78)
    print("4. МАТЧАП ДЕК: дека × состав атаки (лучший ответ обороны)")
    print("=" * 78)
    if "budget_defender" not in profile["economy"]:
        print("  Профиль v1 не знает раундов — матрица только для v2/v3.")
        return
    defs, atks = round_budgets(profile)
    print("  Бюджеты (накопленный доход): "
          + "  ".join(f"R{i + 1} {defs[i]} vs {atks[i]}" for i in range(3)))
    print("  В клетке: «прорвалось/урон базе» и чем держали: "
          "с=снайпер м=мортира к=криостан о=огнемёт т=тесла г=микс.")
    print("  «!» — атака забирает раунд (урон >= 15).")
    print("  Все юниты 1-го уровня; окупаемость прокачки — в разделе 5.")

    header = f"  {'дека':22s}"
    for unit_id in ATTACKS:
        header += f" {unit_id:>11s}"
    header += "       микс"
    for ri, budget in enumerate(defs):
        mix = mix_for_budget(profile, atks[ri])
        print(f"\n   R{ri + 1} (оборона {budget}, атака {atks[ri]}, "
              f"микс {'+'.join(f'{n} {u}' for u, n in mix.items())})")
        print(header)
        for deck_name, deck in TOWER_DECKS.items():
            line = f"  {deck_name:22s}"
            for unit_id in ATTACKS:
                count = max(1, atks[ri] // profile["units"][unit_id]["cost"])
                dmg, leaks, mark = best_defense(profile, deck, budget, unit_id, count)
                flag = "!" if dmg >= profile["economy"]["base_hp"] else " "
                line += f" {leaks:2d}/{dmg:<2d}{mark}{flag}".rjust(11)
            dmg, leaks, mark = best_defense(profile, deck, budget, mix)
            flag = "!" if dmg >= profile["economy"]["base_hp"] else " "
            line += f"  {leaks:2d}/{dmg:<2d}{mark}{flag}".rjust(11)
            print(line)
    print("\n  «!» — атака забирает раунд (урон >= HP базы)."
          " Прокачка юнитов сюда не входит:")
    print("  в разделе 5 она оплачивается из того же кошелька и потому честнее.")


def main(argv):
    parser = argparse.ArgumentParser(description="Балансный аудит Tower Duel")
    parser.add_argument("mode", nargs="?", default="all",
                        choices=["all", "coverage", "economy", "upgrades", "sim",
                                 "decks", "levels"])
    parser.add_argument("--profile", default="v3", choices=sorted(PROFILES))
    args = parser.parse_args(argv[1:])
    profile = PROFILES[args.profile]

    print(f"Профиль данных: {args.profile}")
    cells = None
    if args.mode in ("all", "coverage", "sim"):
        cells = report_geometry(profile) if args.mode in ("all", "coverage") else legal_cells()
    if args.mode in ("all", "economy"):
        report_economy(profile)
    if args.mode in ("all", "upgrades"):
        report_upgrades(profile)
    if args.mode in ("all", "sim"):
        report_sim(profile, cells)
    if args.mode in ("all", "decks"):
        report_decks(profile)
    if args.mode in ("all", "levels"):
        report_levels(profile)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
