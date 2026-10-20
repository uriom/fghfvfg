extends Node
## Persistent local options for the Godot demo. Settings are stored as JSON in user://.

signal settings_changed

const SAVE_PATH := "user://settings.json"
const QUALITY_LABELS := ["Низкое", "Среднее", "Высокое"]
const MSAA_LEVELS := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]

var master_volume := 1.0
var music_volume := 0.72
var sfx_volume := 0.85
var fullscreen := false
var vsync := true
var quality := 2 # 0..2
var target_fps := 120
var best_score := 0


func _ready() -> void:
	_ensure_input_actions()
	_load()
	apply()


func _ensure_input_actions() -> void:
	if not InputMap.has_action("pause_menu"):
		InputMap.add_action("pause_menu")
	var has_escape := false
	var has_controller := false
	for event in InputMap.action_get_events("pause_menu"):
		if event is InputEventKey and event.keycode == KEY_ESCAPE:
			has_escape = true
		elif event is InputEventJoypadButton and event.button_index == JOY_BUTTON_B:
			has_controller = true
	if not has_escape:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		InputMap.action_add_event("pause_menu", escape)
	if not has_controller:
		var back := InputEventJoypadButton.new()
		back.button_index = JOY_BUTTON_B
		InputMap.action_add_event("pause_menu", back)


func apply() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = target_fps
	var msaa: int = MSAA_LEVELS[clampi(quality, 0, 2)]
	get_viewport().msaa_2d = msaa
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("apply_volumes"):
		audio.apply_volumes(master_volume, music_volume, sfx_volume)
	settings_changed.emit()


func update_option(key: String, value: Variant) -> void:
	var old_fullscreen := fullscreen
	var old_vsync := vsync
	var old_quality := quality
	var old_fps := target_fps
	match key:
		"master_volume": master_volume = clampf(float(value), 0.0, 1.0)
		"music_volume": music_volume = clampf(float(value), 0.0, 1.0)
		"sfx_volume": sfx_volume = clampf(float(value), 0.0, 1.0)
		"fullscreen": fullscreen = bool(value)
		"vsync": vsync = bool(value)
		"quality": quality = clampi(int(value), 0, 2)
		"target_fps": target_fps = clampi(int(value), 30, 240)
		_: return
	if fullscreen != old_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
	if vsync != old_vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	if target_fps != old_fps:
		Engine.max_fps = target_fps
	if quality != old_quality:
		get_viewport().msaa_2d = MSAA_LEVELS[quality]
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("apply_volumes"):
		audio.apply_volumes(master_volume, music_volume, sfx_volume)
	settings_changed.emit()
	_save()


func record_score(score: int) -> void:
	if score > best_score:
		best_score = score
		_save()


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if not parsed is Dictionary:
		return
	var data: Dictionary = parsed
	master_volume = clampf(float(data.get("master_volume", master_volume)), 0.0, 1.0)
	music_volume = clampf(float(data.get("music_volume", music_volume)), 0.0, 1.0)
	sfx_volume = clampf(float(data.get("sfx_volume", sfx_volume)), 0.0, 1.0)
	fullscreen = bool(data.get("fullscreen", fullscreen))
	vsync = bool(data.get("vsync", vsync))
	quality = clampi(int(data.get("quality", quality)), 0, 2)
	target_fps = clampi(int(data.get("target_fps", target_fps)), 30, 240)
	best_score = maxi(int(data.get("best_score", 0)), 0)


func _save() -> void:
	var data := {
		"master_volume": master_volume,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"fullscreen": fullscreen,
		"vsync": vsync,
		"quality": quality,
		"target_fps": target_fps,
		"best_score": best_score,
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))
