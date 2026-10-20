extends Control
## Финальный экран матча: победитель + статистика обоих игроков.
## Создаётся сценой game.tscn по сигналу GameState.game_ended; статистику
## считает СЕРВЕР в GameState.stats и рассылает в _end_match (RPC), поэтому
## у обоих игроков цифры совпадают. Кнопка возврата корректно закрывает
## P2P-сессию через NetworkManager.end_session().

@onready var title_label: Label = %Title
@onready var subtitle_label: Label = %Subtitle
@onready var stats_grid: GridContainer = %StatsGrid
@onready var back_btn: Button = %BackBtn


func _ready() -> void:
	theme = UISkin.theme()
	back_btn.pressed.connect(_on_back_pressed)
	modulate.a = 0.0
	var card := get_node("Center/Panel") as Control
	card.scale = Vector2(0.94, 0.94)
	var reveal := create_tween()
	reveal.set_parallel(true)
	reveal.tween_property(self, "modulate:a", 1.0, 0.22)
	reveal.tween_property(card, "scale", Vector2.ONE, 0.32) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## defender_won — победа Защитника; stats — словарь GameState.stats;
## my_role — NetworkManager.Role локального игрока.
func setup(defender_won: bool, stats: Dictionary, my_role: int) -> void:
	var i_won := (my_role == NetworkManager.Role.DEFENDER) == defender_won
	title_label.text = "ПОБЕДА!" if i_won else "ПОРАЖЕНИЕ"
	title_label.add_theme_color_override("font_color",
			Color(0.55, 1.0, 0.55) if i_won else Color(1.0, 0.45, 0.45))
	subtitle_label.text = "Победил Защитник — база выстояла до конца таймера" \
			if defender_won else "Победил Штурмовик — база разрушена"
	_fill_stats(stats)


## Таблица 3 колонки: метрика | Защитник | Штурмовик.
func _fill_stats(stats: Dictionary) -> void:
	# Оставляем шапку (первые 3 ячейки), остальное перезаполняем.
	while stats_grid.get_child_count() > 3:
		var child := stats_grid.get_child(3)
		stats_grid.remove_child(child)
		child.queue_free()
	_rows({
		"Убито юнитов": [str(int(stats.get("units_killed", 0))), "—"],
		"Построено башен": [str(int(stats.get("towers_built", 0))), "—"],
		"Отправлено юнитов": ["—", str(int(stats.get("units_sent", 0)))],
		"Отправлено волн": ["—", str(int(stats.get("waves_sent", 0)))],
		"Прорвалось к базе": ["—", str(int(stats.get("units_leaked", 0)))],
		"Потрачено золота": [
			str(int(stats.get("gold_spent_defender", 0))),
			str(int(stats.get("gold_spent_attacker", 0))),
		],
	})


func _rows(rows: Dictionary) -> void:
	for metric in rows:
		_add_cell(metric, false)
		_add_cell(rows[metric][0], true)
		_add_cell(rows[metric][1], true)


func _add_cell(text: String, is_value: bool) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if is_value \
			else HORIZONTAL_ALIGNMENT_LEFT
	stats_grid.add_child(label)


func _on_back_pressed() -> void:
	AudioManager.play_sfx("click")
	# Полный сброс: закрыть пир (ENet/Steam), покинуть Steam-лобби,
	# очистить состав игроков и вернуться в главное меню.
	NetworkManager.end_session()
