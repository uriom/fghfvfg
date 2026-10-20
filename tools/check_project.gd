extends SceneTree
## Dev-проверка проекта без редактора: загружает все скрипты и сцены,
## инстанцирует их и сообщает об ошибках компиляции.
## Запуск:
##   godot --headless --path <проект> --script res://tools/check_project.gd

const SCRIPTS := [
	"res://scripts/loadout_manager.gd",
	"res://autoload/steam_manager.gd",
	"res://autoload/network_manager.gd",
	"res://autoload/game_state.gd",
	"res://autoload/fx_manager.gd",
	"res://scripts/audio_manager.gd",
	"res://scripts/ui_theme.gd",
	"res://scripts/settings_manager.gd",
	"res://scripts/settings_dialog.gd",
	"res://scripts/pause_menu.gd",
	"res://scripts/game_db.gd",
	"res://scripts/main_menu.gd",
	"res://scripts/game.gd",
	"res://scripts/map.gd",
	"res://scripts/tower.gd",
	"res://scripts/projectile.gd",
	"res://scripts/unit.gd",
	"res://scripts/unit_spawner.gd",
	"res://scripts/defender_hud.gd",
	"res://scripts/attacker_hud.gd",
	"res://scripts/end_game_screen.gd",
	"res://scripts/wave_display.gd",
]

const SCENES := [
	"res://scenes/main_menu.tscn",
	"res://scenes/game.tscn",
	"res://scenes/towers/tower.tscn",
	"res://scenes/units/unit.tscn",
	"res://scenes/end_game_screen.tscn",
]


func _initialize() -> void:
	var errors := 0
	for path in SCRIPTS:
		if load(path) == null:
			push_error("НЕ ЗАГРУЖАЕТСЯ: %s" % path)
			errors += 1
	for path in SCENES:
		var packed: PackedScene = load(path)
		if packed == null:
			push_error("НЕ ЗАГРУЖАЕТСЯ: %s" % path)
			errors += 1
			continue
		var node := packed.instantiate()
		if node == null:
			push_error("НЕ ИНСТАНЦИРУЕТСЯ: %s" % path)
			errors += 1
		else:
			node.free()
	print("CHECK_DONE errors=%d" % errors)
	quit(errors)
