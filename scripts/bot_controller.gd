class_name BotController
extends Node
## ИИ-соперник для соло-режима «Тренировка» (docs/GDD_AUDIT_RU.md, SPEC-03).
##
## РОЛЬ: бот играет ШТУРМОВИКОМ. Защитник — игрок. Бот живёт ТОЛЬКО на
## сервере (в соло сервер — это сам игрок, оффлайн-пир), поэтому вызывает
## серверные методы спавнера напрямую и не занимает сеть.
##
## ПОЧЕМУ НЕ «ПРОСТО СПАМ»: новичок должен увидеть контр-плей. Бот смотрит
## на состав обороны и меняет набор:
##   * много снайперов  -> дешёвая толпа (снайпер бьёт по одной цели);
##   * много мортир     -> летающие (единственная башня без ПВО);
##   * много криостана  -> тяжёлые (замедление не окупается против HP);
##   * много огнемётов  -> танки (огонь по тяжёлой броне ×0,8);
##   * много теслы      -> НЕ танки (тесла бьёт только воздух), а толпа
##     наземных, которую некому сдерживать.
## Это ровно та матрица, которую игрок изучает в первом матче.
##
## ЭКОНОМИКА: бот тратит ТОЛЬКО своё золото (GameState.gold[attacker_peer]),
## покупка идёт через тот же серверный путь, что и у человека, — читов нет.

## Пауза между решениями: имитация «человеческого» темпа и защита от спама.
## 0,55 с — человек с «зажатой» кнопкой покупает ещё быстрее (10/с), так что
## бот не должен казаться медленнее интерфейса.
const THINK_INTERVAL := 0.55
## Вероятность «задуматься и не купить» в этот тик (лёгкая тупость).
const SKIP_CHANCE := 0.12
## Не копить больше этого: иначе бот копил бы на босса весь матч.
const MAX_HOARD := 170
## Максимум юнитов в очереди, который бот держит сам (не весь лимит).
const BOT_QUEUE_CAP := 14
## С какого остатка бот начинает вкладываться в уровни юнитов.
const UPGRADE_RESERVE := 150

## Базовые веса по типам: дешёвая толпа — основа, босс — редкий «сюрприз».
const BASE_WEIGHTS := {
	"fast": 3.0,
	"rider": 2.2,
	"tank": 2.0,
	"flying": 1.6,
	"boss": 0.8,
}

var _spawner: UnitSpawner
var _think := 0.0
var _round_seen := 0
var _last_phase := GameState.Phase.PLANNING


func _ready() -> void:
	# ИИ — только серверная сущность: на клиенте его просто нет.
	if not multiplayer.is_server():
		set_process(false)
		return
	_spawner = get_parent().get_node_or_null("Road/UnitSpawner") as UnitSpawner
	GameState.phase_changed.connect(_on_phase_changed)


func _process(delta: float) -> void:
	if GameState.game_over or _spawner == null:
		return
	if GameState.round_phase == GameState.Phase.FINISHED:
		return
	_think -= delta
	if _think > 0.0:
		return
	_think = THINK_INTERVAL
	_think_once()


func _on_phase_changed(_round_index: int, _phase: int, _duration: float) -> void:
	# На старте штурма бот «просыпается» мгновенно: армия уже в очереди.
	_think = 0.0


## Один такт решения: может купить один юнит или формацию.
func _think_once() -> void:
	var peer := GameState.attacker_peer
	var gold := int(GameState.gold.get(peer, 0))
	_maybe_breakthrough(peer)
	if gold <= 0:
		return
	if _spawner.queue_size() >= BOT_QUEUE_CAP:
		return
	if randf() < SKIP_CHANCE:
		return
	# Свободные кредиты бот вкладывает «в высоту»: уровень типа юнита
	# переживает раунды, поэтому это выгоднее ещё одной пачки тел.
	if gold >= UPGRADE_RESERVE and _maybe_upgrade(peer, gold):
		return
	var unit_id := _pick_unit(gold)
	if unit_id == "":
		return
	var cost := int(GameDB.UNITS[unit_id]["cost"])
	# Покупаем пачкой, пока хватает денег и места: это компенсирует то, что
	# бот «думает» реже, чем игрок жмёт кнопку.
	var room: int = UnitSpawner.MAX_QUEUE - _spawner.queue_size()
	var wanted := mini(mini(gold / cost, 4), room)
	_spawner._server_enqueue(peer, unit_id, maxi(wanted, 1))


## Покупка уровня юнита. Качаем самый дешёвый доступный тип из деки —
## так бот быстрее доходит до заметного прироста и не копит на «босса».
func _maybe_upgrade(peer: int, gold: int) -> bool:
	var best := ""
	var best_cost := 1 << 30
	for unit_id in GameState.attacker_units:
		if not GameDB.UNITS.has(unit_id):
			continue
		var level := GameState.unit_level(unit_id)
		if level >= GameDB.UNIT_MAX_LEVEL:
			continue
		var cost := GameDB.unit_upgrade_cost(unit_id, level)
		if cost < best_cost:
			best_cost = cost
			best = String(unit_id)
	if best == "" or best_cost > gold - 40:
		return false
	# Не каждый тик: иначе бот выкупает уровни раньше, чем набирает армию.
	if randf() < 0.45:
		return false
	GameState.apply_unit_upgrade(peer, best)
	return true


## «ПРОРЫВ» бот жмёт, когда очередь почти полна: залп всей армией —
## единственный способ пробить плотную оборону (и это видно игроку, так что
## он учится держать ОВЕРКЛОК на этот момент).
func _maybe_breakthrough(peer: int) -> void:
	if not GameState.is_assault():
		return
	var used: Array = GameState.abilities_used.get(peer, [])
	if used.has("breakthrough"):
		return
	if _spawner.queue_size() < 10:
		return
	GameState.apply_ability(peer, "breakthrough")


## Выбирает тип юнита под текущую оборону. Возвращает "" — копить.
func _pick_unit(gold: int) -> String:
	var deck := GameState.attacker_units
	if deck.is_empty():
		return ""
	var census := _tower_census()
	var best_id := ""
	var best_score := -INF
	for unit_id in deck:
		if not GameDB.UNITS.has(unit_id):
			continue
		var unit_stats: Dictionary = GameDB.UNITS[unit_id]
		var cost := int(unit_stats["cost"])
		if cost > gold:
			continue   # ждём накопления
		if cost > MAX_HOARD:
			continue
		var score := float(BASE_WEIGHTS.get(unit_id, 1.0))
		score *= _counter_bonus(unit_id, census)
		# Небольшой шум: один и тот же матч не выглядит заскриптованным.
		score *= randf_range(0.85, 1.15)
		# Дешёвые юниты приоритетнее при равном счёте: темп важнее силы.
		score *= 1.0 + 15.0 / (float(cost) + 30.0)
		if score > best_score:
			best_score = score
			best_id = String(unit_id)
	return best_id


## Сколько башен каждого типа стоит на карте.
func _tower_census() -> Dictionary:
	var census := {"sniper": 0, "splash": 0, "frost": 0, "flamer": 0, "tesla": 0}
	var map := get_parent().get_node_or_null("Map")
	if map == null:
		return census
	for tower in map.get_node("Towers").get_children():
		if tower is Tower:
			var id: String = (tower as Tower).tower_id
			census[id] = int(census.get(id, 0)) + 1
	return census


## Множитель «насколько этот юнит хорош против нынешней обороны».
func _counter_bonus(unit_id: String, census: Dictionary) -> float:
	var bonus := 1.0
	var snipers := int(census.get("sniper", 0))
	var splash := int(census.get("splash", 0))
	var frost := int(census.get("frost", 0))
	var flamers := int(census.get("flamer", 0))
	var tesla := int(census.get("tesla", 0))
	match unit_id:
		"fast":
			# Снайпер и мортира бьют одну цель — толпа их перегружает.
			bonus += 0.22 * float(snipers) + 0.12 * float(splash)
		"flying":
			# ЭТАП 8: воздух достаёт всё, кроме мортиры. Криостан и огнемёт
			# целятся, но бьют слабо, поэтому змей — ответ именно на мортиру.
			bonus += 0.60 * float(splash) + 0.14 * float(frost) + 0.16 * float(flamers)
		"tank":
			# Огонь ×0,8 по тяжёлой броне, криостан ×0,8, тесла по земле не
			# стреляет вовсе — танк хорош против огнемётов и криостана.
			bonus += 0.34 * float(flamers) + 0.28 * float(frost)
		"boss":
			# Одиночный ударный кулак: пробивает тонкую оборону.
			bonus += 0.30 * float(maxi(4 - int(snipers) - int(tesla), 0))
		"rider":
			# Универсал без ярких слабостей — небольшая награда за смешанный дек.
			bonus += 0.08 * float(snipers + splash + frost)
	return bonus
