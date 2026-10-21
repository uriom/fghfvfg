class_name HudKit
## Общие фабрики элементов HUD (правило проекта: никакого _draw).
##
## Вынесены из defender_hud.gd: файл перевалил за лимит gdlint (1000 строк),
## а эти функции — чистые «конструкторы», им не нужны ни состояние, ни сцена.
## Одни и те же панели/линии/ромбы используют оба HUD, поэтому копий больше
## нет: правка стиля в одном месте меняет картинку у Защитника и Штурмовика.

## Кэш текстур: одна копия на приложение, а не на каждую карточку.
static var _pedestal: GradientTexture2D = null
static var _beam: GradientTexture2D = null


## Стиль панели: заливка, обводка, радиус, опциональная тень.
static func panel_style(bg: Color, border: Color, border_width: int, radius: int,
		shadow := Color.TRANSPARENT, shadow_size := 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.shadow_color = shadow
	box.shadow_size = shadow_size
	box.anti_aliasing = true
	return box


## Тонкий вертикальный разделитель фиксированной высоты.
static func vertical_line(height: float, color := Color(1, 1, 1, 0.12)) -> ColorRect:
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(1.0, height)
	line.color = color
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## Ромб из повёрнутого ColorRect — маркер без шрифтовых глифов.
static func diamond(color: Color, size_px: float) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(size_px + 4.0, size_px + 4.0)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rect := ColorRect.new()
	rect.color = color
	rect.size = Vector2(size_px, size_px)
	rect.position = Vector2(2.0, 2.0)
	rect.pivot_offset = rect.size * 0.5
	rect.rotation_degrees = 45.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(rect)
	return root


## Радиальный мягкий блик — «подиум» под иконкой башни. Кэш статический:
## текстура одна на всё приложение, а не по копии на каждую карточку.
static func pedestal_texture() -> GradientTexture2D:
	if _pedestal != null:
		return _pedestal
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0.85))
	gradient.set_color(1, Color(1, 1, 1, 0.0))
	_pedestal = GradientTexture2D.new()
	_pedestal.gradient = gradient
	_pedestal.fill = GradientTexture2D.FILL_RADIAL
	_pedestal.fill_from = Vector2(0.5, 0.5)
	_pedestal.fill_to = Vector2(1.0, 0.5)
	_pedestal.width = 64
	_pedestal.height = 64
	return _pedestal


## Вертикальный градиент — световой столб голограммы над подиумом.
static func beam_texture() -> GradientTexture2D:
	if _beam != null:
		return _beam
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 0.75))
	gradient.set_color(1, Color(1, 1, 1, 0.0))
	_beam = GradientTexture2D.new()
	_beam.gradient = gradient
	_beam.fill = GradientTexture2D.FILL_LINEAR
	_beam.fill_from = Vector2(0.5, 1.0)
	_beam.fill_to = Vector2(0.5, 0.0)
	_beam.width = 32
	_beam.height = 64
	return _beam

