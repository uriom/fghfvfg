extends Node
## Автозагрузка «AudioManager»: звуки и музыка.
##
## ОСОБЕННОСТЬ: все звуки СИНТЕЗИРУЮТСЯ кодом при старте (AudioStreamWAV из
## сгенерированных семплов) — проекту не нужны аудио-ассеты. Когда появятся
## свои звуки, положите .wav/.ogg в sounds/ и подмените _generate_library().
##
## СЕТЕВАЯ МОДЕЛЬ: менеджер чисто ЛОКАЛЬНЫЙ, без единого RPC. Вызовы
## вставлены в уже синхронные точки обеих сторон:
##   * FXManager.* — RPC-эффекты (authority + call_local): звук звучит
##     у обоих игроков вместе с картинкой;
##   * Unit._ready / spawn_function — выполняется на обоих пирах;
##   * map._confirm_tower — call_local RPC-подтверждение постройки;
##   * game.gd / меню — локальный UI.
## Поэтому звук не занимает сеть вообще.
##
## ПУЛ КАНАЛОВ: CHANNELS штук AudioStreamPlayer с round-robin, «дроссель»
## одинаковых звуков (не чаще раза в CHOKE_MS) и лимит запусков на кадр —
## защита от наложения и хрипов, когда волна юнитов умирает одновременно.

const SAMPLE_RATE := 22050
const CHANNELS := 12            # размер пула SFX-каналов
const CHOKE_MS := 45            # мин. пауза между одинаковыми звуками, мс
const MAX_PER_FRAME := 6        # антиспам: максимум запусков за один кадр
const MUSIC_VOLUME_DB := -14.0

var _pool: Array[AudioStreamPlayer] = []
var _music: AudioStreamPlayer
var _next := 0
var _last_played_ms: Dictionary = {}    # имя звука -> время последнего запуска
var _started_this_frame := 0
var _streams: Dictionary = {}           # имя -> AudioStreamWAV


func _ready() -> void:
	_generate_library()
	for i in CHANNELS:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_pool.append(player)
	_music = AudioStreamPlayer.new()
	_music.volume_db = MUSIC_VOLUME_DB
	add_child(_music)


func _process(_delta: float) -> void:
	_started_this_frame = 0


func _exit_tree() -> void:
	# Останавливаем воспроизведение при выходе: активный AudioStreamPlayback
	# иначе переживает очистку и движок рапортует об утечке при закрытии.
	# Lock() исключает гонку с потоком микширования (иначе стоп может
	# обрабатываться уже после проверки ObjectDB).
	AudioServer.lock()
	_music.stop()
	_music.stream = null
	for player in _pool:
		player.stop()
		player.stream = null
	AudioServer.unlock()
	OS.delay_msec(100)   # даём аудио-потоку добить релиз playback до проверки ObjectDB


# ------------------------------------------------------------- Публичное ----

## Запустить звук. volume_db — добавка к громкости, pitch можно варьировать.
func play_sfx(sound_name: String, volume_db := 0.0, pitch := 1.0) -> void:
	if not _streams.has(sound_name):
		return
	# Дроссель: одинаковый звук не чаще раза в CHOKE_MS — главный источник
	# «каши» при массовых смертях юнитов.
	var now := Time.get_ticks_msec()
	if now - int(_last_played_ms.get(sound_name, -CHOKE_MS)) < CHOKE_MS:
		return
	if _started_this_frame >= MAX_PER_FRAME:
		return
	_started_this_frame += 1
	_last_played_ms[sound_name] = now
	var player := _pool[_next]
	_next = (_next + 1) % _pool.size()
	player.stream = _streams[sound_name]
	player.volume_db = volume_db
	# Лёгкая случайная вариация высоты — звук «живой», не механический.
	player.pitch_scale = pitch * randf_range(0.95, 1.05)
	player.play()


func play_music(track_name := "bgm") -> void:
	if not _streams.has(track_name):
		return
	if _music.playing and _music.stream == _streams[track_name]:
		return
	_music.stream = _streams[track_name]
	_music.play()


func stop_music() -> void:
	_music.stop()


# ------------------------------------------------ Синтез звуков (PCM) -------
# Маленькая «студия»: тон с огибающей, шум, микс/склейка, упаковка в WAV.
# Огибающая (атака 5 мс + спад) убирает щелчки на границах семплов.

func _tone(f_from: float, f_to: float, seconds: float, volume: float, wave := "sine") -> PackedFloat32Array:
	var count := maxi(int(seconds * SAMPLE_RATE), 1)
	var out := PackedFloat32Array()
	out.resize(count)
	var phase := 0.0
	for i in count:
		var t := float(i) / float(count)
		var freq := lerpf(f_from, f_to, t)
		phase += TAU * freq / SAMPLE_RATE
		var s := 0.0
		match wave:
			"square":
				s = 1.0 if fmod(phase, TAU) < PI else -1.0
			"saw":
				s = fposmod(phase / TAU, 1.0) * 2.0 - 1.0
			_:
				s = sin(phase)
		var attack := minf(float(i) / (SAMPLE_RATE * 0.005), 1.0)
		out[i] = s * volume * attack * pow(1.0 - t, 1.5)
	return out


func _noise(seconds: float, volume: float) -> PackedFloat32Array:
	var count := maxi(int(seconds * SAMPLE_RATE), 1)
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		var t := float(i) / float(count)
		out[i] = randf_range(-1.0, 1.0) * volume * pow(1.0 - t, 2.0)
	return out


func _mix(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var size := maxi(a.size(), b.size())
	var out := PackedFloat32Array()
	out.resize(size)
	# У Packed-массивов get() без дефолта — недостающие семплы дополняем нулями вручную.
	for i in size:
		var sa := a[i] if i < a.size() else 0.0
		var sb := b[i] if i < b.size() else 0.0
		out[i] = sa + sb
	return out


func _concat(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := a.duplicate()
	out.append_array(b)
	return out


## Дополнить тишиной до нужной длительности (для перкуссии/пауз).
func _pad(samples: PackedFloat32Array, seconds: float) -> PackedFloat32Array:
	var out := samples.duplicate()
	out.resize(maxi(int(seconds * SAMPLE_RATE), samples.size()))
	return out


func _make_wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	return wav


func _midi(note: int) -> float:
	return 440.0 * pow(2.0, float(note - 69) / 12.0)


# ---------------------------------------------------- Библиотека звуков -----

func _generate_library() -> void:
	# Выстрелы башен.
	_streams["beam"] = _make_wav(_tone(1500.0, 220.0, 0.12, 0.45))                       # снайпер: «зап»
	_streams["lob_fire"] = _make_wav(_mix(_tone(160.0, 60.0, 0.15, 0.55), _noise(0.08, 0.22)))  # мортира: хлопок
	_streams["frost_fire"] = _make_wav(_tone(1100.0, 1600.0, 0.08, 0.2))                 # криостан: «пшик»
	_streams["boom"] = _make_wav(_mix(_noise(0.4, 0.75), _tone(180.0, 40.0, 0.4, 0.6)))  # взрыв сплеша
	_streams["frost"] = _make_wav(_mix(_tone(880.0, 860.0, 0.18, 0.25), _tone(1318.0, 1290.0, 0.22, 0.2)))  # ледяной звон

	# Юниты.
	_streams["spawn"] = _make_wav(_tone(260.0, 760.0, 0.14, 0.3, "square"))              # появление
	_streams["unit_die"] = _make_wav(_mix(_tone(500.0, 90.0, 0.12, 0.45, "square"), _noise(0.06, 0.18)))

	# База и постройка.
	_streams["base_hit"] = _make_wav(_concat(_mix(_tone(660.0, 660.0, 0.18, 0.5, "square"), _noise(0.25, 0.35)), \
			_tone(470.0, 470.0, 0.2, 0.45, "square")))                                   # тревога: два тона
	_streams["build"] = _make_wav(_mix(_noise(0.05, 0.35), _tone(240.0, 180.0, 0.1, 0.4)))

	# UI и финал.
	_streams["click"] = _make_wav(_tone(1000.0, 780.0, 0.04, 0.25))
	_streams["victory"] = _make_wav(_seq_notes([72, 76, 79, 84], 0.14, 0.35, "square"))  # мажорная арпеджио вверх
	_streams["defeat"] = _make_wav(_seq_notes([64, 60, 55], 0.3, 0.35, "sine"))          # нисходящая

	_streams["bgm"] = _make_wav(_generate_bgm_samples(), true)


func _seq_notes(notes: Array, note_len: float, volume: float, wave := "sine") -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for n in notes:
		out = _concat(out, _tone(_midi(int(n)), _midi(int(n)), note_len, volume, wave))
	return out


## Фоновая музыка: 4 такта Am–F–C–G (бас + арпеджио + тихие «хэты»),
## зацикливается средствами AudioStreamWAV (loop_forward).
func _generate_bgm_samples() -> PackedFloat32Array:
	var bpm := 100.0
	var beat := 60.0 / bpm
	var chords := [
		[57, 60, 64],   # Am
		[53, 57, 60],   # F
		[48, 52, 55],   # C
		[55, 59, 62],   # G
	]
	var bass_roots := [45, 41, 36, 43]
	var bass := PackedFloat32Array()
	var arp := PackedFloat32Array()
	var hats := PackedFloat32Array()
	for ci in chords.size():
		# Бас: четыре четверти с корнем аккорда.
		for _b in 4:
			var f := _midi(bass_roots[ci])
			bass = _concat(bass, _tone(f, f, beat, 0.3))
		# Арпеджио: восемь восьмых по нотам аккорда на октаву выше.
		for e in 8:
			var fn := _midi(chords[ci][e % 3] + 12)
			arp = _concat(arp, _tone(fn, fn, beat * 0.5, 0.11, "square"))
		# Перкуссия: тихие шумовые тики на каждую восьмую.
		for _e in 8:
			hats = _concat(hats, _pad(_noise(0.025, 0.05), beat * 0.5))
	return _mix(_mix(bass, arp), hats)
