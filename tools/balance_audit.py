#!/usr/bin/env python3
"""Воспроизводимый балансный аудит Tower Duel.

Скрипт повторяет расчёты из docs/GDD_AUDIT_RU.md, используя ТОЛЬКО данные,
которые уже есть в проекте: координаты дороги из scenes/game.tscn, размер
клетки и зоны строительства из scripts/map.gd, статы из scripts/game_db.gd,
экономику из autoload/game_state.gd. Godot не требуется.

Два профиля данных:
  v1 — снимок, на котором построен аудит (коммит 46079d6): волны, 5 башен,
       старт 220, матч 600 с. Именно эти числа стоят в таблицах отчёта.
  v2 — текущий баланс проекта (COMBAT v2 + RAUNDS): матрица урона, броня,
       приоритеты целей, лимиты 2/тип и 8 всего, BO3-раунды.

Запуск:
    python3 tools/balance_audit.py                      # профиль v2, всё
    python3 tools/balance_audit.py --profile v1 all     # снимок аудита
    python3 tools/balance_audit.py coverage             # только покрытие пути
    python3 tools/balance_audit.py economy              # только экономика
    python3 tools/balance_audit.py sim                  # только симуляция боя

Зачем: любую правку баланса можно проверить за секунды, без двух ПК и
матча целиком. Это прототип пункта S8 из бэклога аудита.
"""

from __future__ import annotations

import argparse
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
    "fire": {"light": 1.50, "heavy": 0.80, "air": 1.00},   # 0.60 -> 0.80, см. game_db
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
    # speed 46: путь 54,8 с при штурме 60 с — босс успевает дойти. При 36
    # (путь 70 с) он был мёртвой картой: раунд заканчивался раньше.
    "boss": dict(cost=150, hp=800.0, speed=46.0, dmg=6, bounty=65, kill=33, armor="heavy",
                 radius=21.0),
}

# autoload/game_state.gd — экономика
ECONOMY_V1 = dict(base_hp=20, start_gold=120, wave_stipend=100, wave_duration=60.0,
                  wave_break=5.0, match_limit=600.0)
ECONOMY_V2 = dict(base_hp=15, plan=12.0, assault=60.0, review=8.0,
                  budget_attacker=[200, 320, 480], budget_defender=[240, 100, 100],
                  trickle=1.5, rounds_to_win=2,
                  deploy_interval=0.45, queue=14)

PROFILES = {
    "v1": dict(towers=TOWERS_V1, units=UNITS_V1, economy=ECONOMY_V1,
               max_per_type=99, max_total=99),
    "v2": dict(towers=TOWERS_V2, units=UNITS_V2, economy=ECONOMY_V2,
               max_per_type=2, max_total=8),
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


def _priority_score(tower: dict, unit: SimUnit, unit_stats: dict, units, positions) -> float:
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


def _damage_unit(unit: SimUnit, unit_stats: dict, amount: float, dtype: str | None,
                 units: list[SimUnit], positions) -> None:
    """Урон с матрицей и аурой танка (как в Unit.take_damage)."""
    dmg = amount * _mult(dtype, unit_stats.get("armor", "light"))
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


def _spawn_plan(profile: dict, comp) -> list[dict]:
    """Разворачивает состав в очередь спавна.

    comp — id юнита (моно-волна) либо список [(id, count), ...] / словарь
    {id: count} для смешанного захода. Смешанная очередь чередуется по типам:
    так игрок и кликает карточки, и так танк не отстаёт от бегунов на 40 секунд.
    """
    units = profile["units"]
    if isinstance(comp, str):
        return [units[comp]]
    pairs = list(comp.items()) if isinstance(comp, dict) else list(comp)
    buckets = [[units[uid]] * int(n) for uid, n in pairs if int(n) > 0]
    plan = []
    while any(buckets):
        for bucket in buckets:
            if bucket:
                plan.append(bucket.pop(0))
    return plan


def simulate(profile: dict, towers: list[tuple[tuple[float, float], str]],
             comp, count: int | None = None, gap: float = 0.35) -> SimResult:
    """Дискретная симуляция боя.

    towers — [(cell, tower_id)]. Модель повторяет tower.gd / projectile.gd:
    выбор цели по priority, кулдаун 1/fire_rate, матрица урона, аура танка,
    сплеш со спадом, цепь теслы с затуханием, замедление криостаном.
    comp — id юнита (тогда count задаёт количество) или смешанный состав.
    Допущения (осознанные): снаряд летит мгновенно (кроме навеса — там
    упреждение только уменьшает шанс попадания, см. ниже), башни не
    перезаряжаются между волнами.
    """
    tower_stats = profile["towers"]
    if isinstance(comp, str) and count is not None:
        plan = [profile["units"][comp]] * int(count)
    else:
        plan = _spawn_plan(profile, comp)
    total = len(plan)

    cooldowns = [0.0] * len(towers)
    units: list[SimUnit] = []
    positions: dict[int, tuple[float, float]] = {}
    sent, next_spawn = 0, 0.0
    t = 0.0
    result = SimResult()

    # Спавн с шагом gap: юниты входят по одному, как в очереди UnitSpawner.
    while t < HORIZON:
        if sent < total and t >= next_spawn:
            unit_stats = plan[sent]
            u = SimUnit(0.0, unit_stats["hp"], unit_stats["hp"])
            u.stats = unit_stats
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

        for i, (cell, tower_id) in enumerate(towers):
            tw = tower_stats[tower_id]
            cooldowns[i] = max(cooldowns[i] - DT, 0.0)
            if cooldowns[i] > 0.0:
                continue
            # Дальность — от клетки до точки на дороге.
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
                       key=lambda u: (_priority_score(tw, u, u.stats, units, positions),
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
            if tw.get("slow") and best.alive:
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
        print("Раунды BO3: ПОДГОТОВКА %.0f с / ШТУРМ %.0f с / ИТОГ %.0f с"
              % (eco["plan"], eco["assault"], eco["review"]))
        print(f"HP базы в раунде: {eco['base_hp']}, побед для матча: {eco['rounds_to_win']}")
        for i in range(3):
            trickle = eco["trickle"] * eco["assault"]
            print(f"  раунд {i + 1}: защитник {eco['budget_defender'][i]:3d} кр, "
                  f"штурмовик {eco['budget_attacker'][i]:3d} + {trickle:.0f} капельно "
                  f"= {eco['budget_attacker'][i] + trickle:.0f} кр")
        print(f"  суммарно за матч: защитник {sum(eco['budget_defender'])} кр, "
              f"штурмовик {sum(eco['budget_attacker']) + int(3 * eco['trickle'] * eco['assault'])} кр")
        # Сколько HP нужно снять штурмовику, чтобы забрать раунд.
        print(f"\nПорог раунда: {eco['base_hp']} урона базе. "
              f"Цена 1 урона базе по юнитам:")
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
        last_start = (waves - 1) * (eco["wave_duration"] + eco["wave_break"])
        print(f"Последняя волна стартует на {last_start:.0f} с и получает "
              f"{eco['match_limit'] - last_start:.0f} с вместо {eco['wave_duration']:.0f}")

    print("\nБашни: базовый DPS и DPS/кредит по классам брони")
    header = f"  {'tower':8s} {'cost':>4s} {'dps':>6s} {'range':>5s} {'dps/g':>6s}"
    if "dtype" in next(iter(towers.values())):
        header += f" {'лёгк':>6s} {'тяж':>6s} {'возд':>6s}  тип   приоритет"
    print(header)
    for name, t in towers.items():
        dps = t["damage"] * t["rate"]
        line = (f"  {name:8s} {t['cost']:4d} {dps:6.1f} {t['rng']:5.0f} "
                f"{dps / t['cost']:6.3f}")
        if "dtype" in t:
            d = t["dtype"]
            light = dps * _mult(d, "light") / t["cost"]
            heavy = dps * _mult(d, "heavy") / t["cost"]
            air = dps * _mult(d, "air") / t["cost"]
            air_s = "—" if not t["air"] else f"{air:6.3f}"
            line += f" {light:6.3f} {heavy:6.3f} {air_s:>6s}  {d:4s}  {t['priority']}"
        print(line)

    print("\nЮниты:")
    header = f"  {'unit':8s} {'cost':>4s} {'hp':>5s} {'spd':>4s} {'dmg':>4s} {'hp/g':>5s} {'g/урон':>7s}"
    if "armor" in next(iter(units.values())):
        header += "  броня"
    print(header)
    for name, u in units.items():
        line = (f"  {name:8s} {u['cost']:4d} {u['hp']:5.0f} {u['speed']:4.0f} "
                f"{u['dmg']:4d} {u['hp'] / u['cost']:5.2f} {u['cost'] / u['dmg']:7.1f}")
        if "armor" in u:
            line += f"  {u['armor']}"
        print(line)


def _mix(cells, ids):
    """Собирает оборону из клеток, соблюдая лимиты профиля (2 одного типа)."""
    return [(cells[i % len(cells)], ids[i]) for i in range(len(ids))]


# ------------------------------------------------------- Матчап дек ----------

# Деки ровно те, что игрок собирает в меню: 3 типа из 5 (LoadoutManager).
TOWER_DECKS = {
    "A sn+splash+frost": ["sniper", "splash", "frost"],
    "B sn+splash+tesla": ["sniper", "splash", "tesla"],
    "C sn+frost+flamer": ["sniper", "frost", "flamer"],
    "D splash+frost+flamer": ["splash", "frost", "flamer"],
    "E sn+tesla+flamer": ["sniper", "tesla", "flamer"],
}

# Композиции атаки: чем игрок закупается в раунд (один тип — самый читаемый
# способ проверить, есть ли у деки дыра).
ATTACK_DECKS = {
    "fast": ["fast"],
    "rider": ["rider"],
    "tank": ["tank"],
    "flying": ["flying"],
    "boss": ["boss"],
}

# «Стандартный заход» — реалистичная смешанная волна: танки держат удар,
# конница и змеи просачиваются. Моно-раш из таблицы слабее любой живой игры,
# поэтому матрица проверяет ещё и микс (доля бюджета на класс).
MIX_SHARES = {"tank": 0.40, "rider": 0.35, "flying": 0.25}


def mix_for_budget(profile, budget, shares=None) -> dict:
    """Состав волны под бюджет: целые юниты по долям бюджета."""
    shares = shares or MIX_SHARES
    comp = {}
    for uid, share in shares.items():
        cost = profile["units"][uid]["cost"]
        comp[uid] = int(budget * share) // cost
    return {uid: n for uid, n in comp.items() if n > 0}


def build_defense(profile, deck, budget):
    """Собирает оборону из деки под бюджет: по 2 башни каждого типа,
    на клетки полного покрытия, пока хватает денег."""
    towers = profile["towers"]
    cells, _ = greedy_cover(legal_cells(), 200.0)
    built, spent = [], 0
    order = deck * profile["max_per_type"]
    for tower_id in order:
        if len(built) >= profile["max_total"] or len(built) >= len(cells):
            break
        cost = towers[tower_id]["cost"]
        if spent + cost > budget:
            continue
        built.append((cells[len(built)], tower_id))
        spent += cost
    return built, spent


def report_decks(profile):
    """Матрица «дека защиты × тип атаки» по раундам.

    Показывает дыры деки: где защитник не пробивается вообще, а где раунд
    проигрывается одной кнопкой. Это проверка заявлений SPEC-01/02 о
    контр-плее, а не подбор «красивых» цифр.
    """
    econ = profile["economy"]
    print()
    print("=" * 78)
    print("4. МАТЧАП ДЕК (3 башни из 5 × 3 юнита из 5)")
    print("=" * 78)
    if "budget_defender" not in econ:
        print("  Профиль v1 не знает раундов — матрица только для v2.")
        return

    budgets = []
    total = 0
    for i, add in enumerate(econ["budget_defender"]):
        total += add
        budgets.append(total)
    # Атакующий бюджет раунда = разовый бюджет + капельный доход за штурм.
    atk = [b + int(econ["trickle"] * econ["assault"]) for b in econ["budget_attacker"]]
    print("  Бюджеты: " + "  ".join(
        f"R{i + 1} {budgets[i]} vs {atk[i]}" for i in range(len(budgets))))
    print("  В клетке: «прорвалось/урон базе» (HP базы = %d)." % econ["base_hp"])

    for round_idx, budget in enumerate(budgets):
        print(f"\n  --- Раунд {round_idx + 1}: оборона {budget} кр, "
              f"атака {atk[round_idx]} кр ---")
        header = f"  {'дека':22s}"
        for unit_id in ATTACK_DECKS:
            header += f" {unit_id:>10s}"
        header += "      микс"
        print(header)
        mix = mix_for_budget(profile, atk[round_idx])
        mix_line = " + ".join(f"{n} {uid}" for uid, n in mix.items())
        print(f"  микс: {mix_line}")
        for deck_name, deck in TOWER_DECKS.items():
            towers, spent = build_defense(profile, deck, budget)
            line = f"  {deck_name:22s}"
            for unit_id in ATTACK_DECKS:
                cost = profile["units"][unit_id]["cost"]
                count = max(1, atk[round_idx] // cost)
                r = simulate(profile, towers, unit_id, count, 0.45)
                mark = "!" if r.leaked_hp >= econ["base_hp"] else " "
                line += f" {r.leaks:2d}/{r.leaked_hp:<2d}{mark}"
            m = simulate(profile, towers, mix, gap=0.35)
            mark = "!" if m.leaked_hp >= econ["base_hp"] else " "
            line += f"   {m.leaks:2d}/{m.leaked_hp:<2d}{mark}"
            print(line)
    print("\n  «!» — атака забирает раунд (урон >= HP базы).")


def report_sim(profile, cells):
    print()
    print("=" * 78)
    print("3. СИМУЛЯЦИЯ БОЯ")
    print("=" * 78)
    radius = max(t["rng"] for t in profile["towers"].values())
    chosen, _ = greedy_cover(cells, radius)
    print("Клетки полного покрытия:", [f"({c[0]:.0f},{c[1]:.0f})" for c in chosen])

    cases = []
    if "dtype" not in next(iter(profile["towers"].values())):
        four = [(c, "sniper") for c in chosen]
        cases = [
            (four, "4 снайпера (200 кр)", "fast", 20, 0.4),
            (four, "4 снайпера", "fast", 60, 0.4),
            (four, "4 снайпера", "fast", 100, 0.4),
            (four, "4 снайпера", "tank", 5, 0.4),
            (four, "4 снайпера", "flying", 10, 0.4),
            (four, "4 снайпера", "boss", 2, 1.0),
            (four[:2], "2 снайпера (100 кр)", "fast", 20, 0.4),
            (four[:1], "1 снайпер (50 кр)", "boss", 1, 1.0),
        ]
    else:
        # Реальные сборки по раундам. Дека = 3 типа (LoadoutManager), поэтому
        # оборону собираем из ДЕКИ, а не из произвольного набора башен:
        # A (снайпер+мортира+крио) — сильный низ, B (снайпер+мортира+тесла) —
        # ПВО. Это те же числа, что в матрице дек (режим decks).
        r1a, c1a = build_defense(profile, ["sniper", "splash", "frost"], 240)
        r2a, c2a = build_defense(profile, ["sniper", "splash", "frost"], 330)
        r3a, c3a = build_defense(profile, ["sniper", "splash", "frost"], 420)
        r3b, c3b = build_defense(profile, ["sniper", "splash", "tesla"], 420)
        cases = [
            (r1a, f"R1 деки A: 3 башни {c1a}", "fast", 19, 0.45),
            (r1a, "R1 деки A", "flying", 9, 0.45),
            (r1a, "R1 деки A", "tank", 6, 0.45),
            (r2a, f"R2 деки A: 4 башни {c2a}", "fast", 28, 0.45),
            (r2a, "R2 деки A", "flying", 13, 0.45),
            (r2a, "R2 деки A", "tank", 8, 0.45),
            (r3a, f"R3 деки A: 5 башен {c3a}", "fast", 36, 0.45),
            (r3a, "R3 деки A", "rider", 19, 0.45),
            (r3a, "R3 деки A", "tank", 11, 0.45),
            (r3a, "R3 деки A", "boss", 4, 0.45),
            (r3b, f"R3 деки B (ПВО) {c3b}", "flying", 19, 0.45),
            (r3b, "R3 деки B (ПВО)", "boss", 4, 0.45),
            (r3b, "R3 деки B, ПРОРЫВ (залп)", "flying", 14, 0.05),
            (r3b, "R3 деки B, ПРОРЫВ (залп)", "tank", 14, 0.05),
        ]

    print(f"\n  {'оборона':34s} {'юниты':>12s} {'прорв':>6s} {'урон':>5s} {'бой':>6s}")
    for towers, label, unit, count, gap in cases:
        r = simulate(profile, towers, unit, count, gap)
        print(f"  {label:34s} {count:3d} x {unit:6s} {r.leaks:6d} {r.leaked_hp:5d} "
              f"{r.duration:6.1f}")


def main(argv):
    parser = argparse.ArgumentParser(description="Балансный аудит Tower Duel")
    parser.add_argument("mode", nargs="?", default="all",
                        choices=["all", "coverage", "economy", "sim", "decks"])
    parser.add_argument("--profile", default="v2", choices=sorted(PROFILES))
    args = parser.parse_args(argv[1:])
    profile = PROFILES[args.profile]

    print(f"Профиль данных: {args.profile}")
    cells = None
    if args.mode in ("all", "coverage", "sim"):
        cells = report_geometry(profile) if args.mode in ("all", "coverage") else legal_cells()
    if args.mode in ("all", "economy"):
        report_economy(profile)
    if args.mode in ("all", "sim"):
        report_sim(profile, cells)
    if args.mode in ("all", "decks"):
        report_decks(profile)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
