extends VBoxContainer
## HUD Штурмовика: золото, HP базы противника, кнопки отправки юнитов/волн.
## Кнопки генерируются из GameDB (с описанием способностей). Отправка —
## RPC строго серверу (rpc_id(1)).

@onready var gold_label: Label = $GoldLabel
@onready var hp_label: Label = $HPLabel
@onready var unit_buttons: VBoxContainer = $UnitButtons
@onready var unit_spawner: UnitSpawner = %UnitSpawner


func _ready() -> void:
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.base_hp_changed.connect(_on_base_hp_changed)


## Кнопки юнитов строятся ИЗ ДЕКА Штурмовика этого матча (вызывает game.gd
## ПОСЛЕ GameState.setup_match — деки приходят из лобби-RPC).
func rebuild_from_deck() -> void:
	for child in unit_buttons.get_children():
		child.queue_free()
	for unit_id in GameState.attacker_units:
		var stats: Dictionary = GameDB.UNITS[unit_id]

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.text = "%s — %d зол. | HP %d | базе %d%s" % [
			stats["name"], stats["cost"], stats["hp"], stats["damage"],
			_trait_tags(stats),
		]
		row.add_child(info)

		var send_btn := Button.new()
		send_btn.text = "Отправить"
		send_btn.pressed.connect(_on_send_one.bind(unit_id))
		row.add_child(send_btn)

		var wave_btn := Button.new()
		wave_btn.text = "Волна x%d" % unit_spawner.wave_size
		wave_btn.pressed.connect(_on_send_wave.bind(unit_id))
		row.add_child(wave_btn)

		unit_buttons.add_child(row)


## Строка способностей юнита: «летает, иммун к замедлению», «аура защиты»…
func _trait_tags(stats: Dictionary) -> String:
	var tags: Array[String] = []
	if stats["flying"]:
		tags.append("летает")
	if stats.get("ignores_slow", false):
		tags.append("иммун к замедлению")
	if stats.has("aura_radius"):
		tags.append("аура: -%d%% урона союзникам рядом"
				% int(round(float(stats["aura_reduction"]) * 100.0)))
	if tags.is_empty():
		return ""
	return " | " + ", ".join(tags)


func _on_send_one(unit_id: String) -> void:
	# 1 — peer_id хоста: только он валидирует и спавнит.
	unit_spawner.request_unit.rpc_id(1, unit_id)


func _on_send_wave(unit_id: String) -> void:
	unit_spawner.request_wave.rpc_id(1, unit_id)


var _last_gold := -1   # для определения дохода/траты при анимации


func _on_gold_changed(peer_id: int, amount: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		return
	var delta := 0 if _last_gold < 0 else amount - _last_gold
	_last_gold = amount
	gold_label.text = "Золото: %d" % amount
	if delta > 0:
		_punch(gold_label, Color(0.55, 1.0, 0.55), "+%d" % delta)
	elif delta < 0:
		_punch(gold_label, Color(1.0, 0.5, 0.4), "%d" % delta)


func _on_base_hp_changed(hp: int, max_hp: int) -> void:
	hp_label.text = "База врага: %d / %d HP" % [hp, max_hp]
	_punch(hp_label, Color(0.6, 1.0, 0.6))


## Мини-анимация «удара»: короткий рост масштаба + вспышка цвета + дельта.
## suffix («+100», «-50») показывается поверх суммы на время вспышки.
func _punch(label: Label, flash: Color = Color(1.0, 0.9, 0.4), suffix := "") -> void:
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.3, 1.3)
	label.modulate = flash
	var base_text := label.text
	if suffix != "":
		label.text = "%s  (%s)" % [base_text, suffix]
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate", Color.WHITE, 0.35)
	if suffix != "":
		tween.chain().tween_callback(label.set_text.bind(base_text))
