extends RefCounted
## The companion app's look, modelled on Adobe's Spectrum design language: neutral charcoal
## surfaces, a single blue accent, pill-shaped buttons, quiet line icons and monogram tiles.

const BG := Color("#1b1b1b")
const TOPBAR := Color("#232323")
const SIDEBAR := Color("#1f1f1f")
const CARD := Color("#262626")
const CARD_HOVER := Color("#2e2e2e")
const RAISED := Color("#323232")
const BORDER := Color("#353535")
const FIELD := Color("#1c1c1c")
const FIELD_BORDER := Color("#4a4a4a")
const TEXT := Color("#f2f2f2")
const BODY := Color("#c8c8c8")
const MUTED := Color("#9b9b9b")
const FAINT := Color("#707070")
const ACCENT := Color("#2680eb")
const ACCENT_HOVER := Color("#378ef0")
const ACCENT_DOWN := Color("#1473e6")
const GOOD := Color("#2d9d78")
const GOOD_TEXT := Color("#33c59a")
const WARN := Color("#e68619")
const BAD := Color("#e34850")

## Monogram tile colours (foreground, background), in the style of Adobe app icons.
const TILE_BLUE := [Color("#4fb3ff"), Color("#0a2135")]
const TILE_GREEN := [Color("#47e2a5"), Color("#08291d")]
const TILE_PURPLE := [Color("#c69bff"), Color("#22113a")]
const TILE_ORANGE := [Color("#ffae4f"), Color("#331d06")]
const TILE_PINK := [Color("#ff7cc8"), Color("#330a24")]

## 24x24 line icons. "CUR" is replaced with the icon colour where a fill is needed.
const ICONS := {
	"home": "<path d='M3.5 11L12 3.8L20.5 11'/><path d='M5.8 9.4V20.2H10V14.6H14V20.2H18.2V9.4'/>",
	"host": "<path d='M12 15.5V4'/><path d='M7 8.8L12 4L17 8.8'/><path d='M4 14.5V19.5A0.8 0.8 0 0 0 4.8 20.3H19.2A0.8 0.8 0 0 0 20 19.5V14.5'/>",
	"join": "<path d='M12 4V15.5'/><path d='M7 10.7L12 15.5L17 10.7'/><path d='M4 14.5V19.5A0.8 0.8 0 0 0 4.8 20.3H19.2A0.8 0.8 0 0 0 20 19.5V14.5'/>",
	"live": "<circle cx='12' cy='12' r='2.2' fill='CUR'/><path d='M8.2 8.2A5.4 5.4 0 0 0 8.2 15.8'/><path d='M15.8 8.2A5.4 5.4 0 0 1 15.8 15.8'/><path d='M5.2 5.2A9.6 9.6 0 0 0 5.2 18.8'/><path d='M18.8 5.2A9.6 9.6 0 0 1 18.8 18.8'/>",
	"layers": "<path d='M12 3.5L20.5 8L12 12.5L3.5 8Z'/><path d='M3.5 12.2L12 16.7L20.5 12.2'/><path d='M3.5 16.4L12 20.9L20.5 16.4'/>",
	"settings": "<path d='M4 6.5H20'/><path d='M4 12H20'/><path d='M4 17.5H20'/><circle cx='9' cy='6.5' r='2.3' fill='CUR'/><circle cx='15.5' cy='12' r='2.3' fill='CUR'/><circle cx='7.5' cy='17.5' r='2.3' fill='CUR'/>",
	"search": "<circle cx='10.8' cy='10.8' r='6.3'/><path d='M15.6 15.6L20.3 20.3'/>",
	"copy": "<rect x='8.5' y='8.5' width='11.5' height='11.5' rx='2'/><path d='M15.5 8.5V5.2A1.2 1.2 0 0 0 14.3 4H5.2A1.2 1.2 0 0 0 4 5.2V14.3A1.2 1.2 0 0 0 5.2 15.5H8.5'/>",
	"link": "<path d='M10.2 13.8A4 4 0 0 0 15.8 13.8L18.8 10.8A4 4 0 0 0 13.2 5.2L12 6.4'/><path d='M13.8 10.2A4 4 0 0 0 8.2 10.2L5.2 13.2A4 4 0 0 0 10.8 18.8L12 17.6'/>",
	"folder": "<path d='M3.5 7.2A1.7 1.7 0 0 1 5.2 5.5H9.3L11.3 7.6H18.8A1.7 1.7 0 0 1 20.5 9.3V17.3A1.7 1.7 0 0 1 18.8 19H5.2A1.7 1.7 0 0 1 3.5 17.3Z'/>",
	"arrow": "<path d='M5 12H19'/><path d='M13.5 6.5L19 12L13.5 17.5'/>",
	"plus": "<path d='M12 5V19'/><path d='M5 12H19'/>",
	"refresh": "<path d='M19.5 12A7.5 7.5 0 1 1 17.3 6.7'/><path d='M19.5 4.5V9.5H14.5'/>",
	"people": "<circle cx='9' cy='8.5' r='3.3'/><path d='M3.3 19.5A5.7 5.7 0 0 1 14.7 19.5'/><circle cx='16.8' cy='9.3' r='2.5'/><path d='M15.6 14.4A4.8 4.8 0 0 1 21 19.5'/>",
	"warning": "<path d='M12 4L21 19.5H3Z'/><path d='M12 10V14.2'/><circle cx='12' cy='16.9' r='0.9' fill='CUR'/>",
	"check": "<path d='M5 12.5L10 17.5L19.5 7'/>",
	"download": "<path d='M12 4V15'/><path d='M7.5 10.5L12 15L16.5 10.5'/><path d='M5 19.5H19'/>",
	"stop": "<rect x='6' y='6' width='12' height='12' rx='2'/>",
	"globe": "<circle cx='12' cy='12' r='8.5'/><path d='M3.5 12H20.5'/><path d='M12 3.5C14.5 6 15.5 9 15.5 12C15.5 15 14.5 18 12 20.5C9.5 18 8.5 15 8.5 12C8.5 9 9.5 6 12 3.5Z'/>",
	"key": "<circle cx='8' cy='15.5' r='4'/><path d='M10.9 12.6L19.5 4'/><path d='M16.5 7L19 9.5'/><path d='M14.2 9.3L16.2 11.3'/>",
	"user": "<circle cx='12' cy='8.5' r='3.8'/><path d='M4.5 20A7.5 7.5 0 0 1 19.5 20'/>",
}

static var bold: Font = null
static var semibold: Font = null
static var _cache := {}


static func _box(color: Color, radius := 8, border := Color(0, 0, 0, 0), bw := 0, pad := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_content_margin_all(pad)
	s.anti_aliasing = true
	s.corner_detail = 10
	return s


static func _pill(bg: Color, border := Color(0, 0, 0, 0), bw := 0) -> StyleBoxFlat:
	var s := _box(bg, 16, border, bw, 0)
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


static func _svg(svg: String, scale := 1.0) -> Texture2D:
	var key := str(scale) + svg
	if _cache.has(key):
		return _cache[key]
	var img := Image.new()
	img.load_svg_from_string(svg, scale)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## A line icon as a texture (white by default so Button icon colours can tint it).
static func icon(name: String, size := 20, color := Color.WHITE) -> Texture2D:
	var hex := "#" + color.to_html(false)
	var body := String(ICONS.get(name, "")).replace("CUR", hex)
	var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='%s' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'>%s</svg>" % [hex, body]
	return _svg(svg, size / 24.0)


## A rounded monogram tile, like an Adobe app icon ("Ps", "Ai"…).
static func tile(text: String, colors: Array, size := 44) -> Control:
	var p := PanelContainer.new()
	var sb := _box(colors[1], int(size * 0.24), Color(colors[0], 0.25), 1, 0)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", bold)
	l.add_theme_font_size_override("font_size", int(size * 0.4))
	l.add_theme_color_override("font_color", colors[0])
	p.add_child(l)
	return p


## A tile holding a line icon instead of letters.
static func icon_tile(icon_name: String, colors: Array, size := 44) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(colors[1], int(size * 0.24), Color(colors[0], 0.25), 1, 0))
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := TextureRect.new()
	t.texture = icon(icon_name, int(size * 0.55), colors[0])
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	p.add_child(t)
	return p


## A coloured circle with the person's initial.
static func avatar(name: String, color: Color, size := 30) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(color, int(size / 2.0), Color(0, 0, 0, 0), 0, 0))
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = name.strip_edges().substr(0, 1).to_upper() if not name.strip_edges().is_empty() else "?"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", bold)
	l.add_theme_font_size_override("font_size", int(size * 0.45))
	l.add_theme_color_override("font_color", Color("#141414") if color.get_luminance() > 0.55 else Color.WHITE)
	p.add_child(l)
	return p


## Small rounded status label ("Live", "Installed"…).
static func badge(text: String, color: Color) -> Control:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", semibold)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", color)
	var sb := _box(Color(color, 0.14), 10, Color(0, 0, 0, 0), 0, 0)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", sb)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


const BANNER_SHADER := """
shader_type canvas_item;
uniform vec2 size = vec2(800.0, 220.0);
uniform float radius = 12.0;
uniform vec4 c1 : source_color = vec4(0.05, 0.12, 0.30, 1.0);
uniform vec4 c2 : source_color = vec4(0.09, 0.36, 0.85, 1.0);
uniform vec4 c3 : source_color = vec4(0.47, 0.24, 0.82, 1.0);

float rounded(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = UV * size;
	float d = rounded(p - size * 0.5, size * 0.5, radius);
	float a = clamp(0.5 - d, 0.0, 1.0);
	float t = clamp(UV.x * 0.8 + UV.y * 0.2, 0.0, 1.0);
	vec3 col = t < 0.55 ? mix(c1.rgb, c2.rgb, t / 0.55) : mix(c2.rgb, c3.rgb, (t - 0.55) / 0.45);
	vec2 g1 = (p - vec2(size.x * 0.80, size.y * 0.30)) / size.y;
	vec2 g2 = (p - vec2(size.x * 0.97, size.y * 1.05)) / size.y;
	col += vec3(0.45, 0.65, 1.0) * 0.20 * exp(-dot(g1, g1) * 5.0);
	col += vec3(1.0, 0.45, 0.85) * 0.22 * exp(-dot(g2, g2) * 4.0);
	for (int i = 0; i < 3; i++) {
		float r = 0.38 + float(i) * 0.22;
		float ring = abs(length(g1) - r);
		col += vec3(1.0) * 0.045 * (1.0 - smoothstep(0.0, 0.010, ring));
	}
	COLOR = vec4(col, a);
}
"""


## A rounded gradient banner (Creative Cloud style) that content can be placed on.
static func banner(height := 210) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	p.custom_minimum_size.y = height
	var bg := ColorRect.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BANNER_SHADER
	mat.shader = sh
	bg.material = mat
	p.add_child(bg)
	p.resized.connect(func(): mat.set_shader_parameter("size", p.size))
	return p


static func build() -> Theme:
	var t := Theme.new()
	var names := PackedStringArray(["Segoe UI", "Inter", "Roboto", "Noto Sans", "Helvetica", "Arial"])
	var font := SystemFont.new()
	font.font_names = names
	bold = SystemFont.new()
	bold.font_names = names
	bold.font_weight = 700
	semibold = SystemFont.new()
	semibold.font_names = names
	semibold.font_weight = 600
	t.default_font = font
	t.default_font_size = 14

	# Text
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("normal", "Label", StyleBoxEmpty.new())
	for v in [["Title", 28, bold, TEXT], ["Heading", 18, bold, TEXT], ["Subheading", 15, semibold, TEXT],
			["Body", 14, null, BODY], ["Muted", 13, null, MUTED], ["Caps", 11, semibold, FAINT],
			["Hero", 30, bold, Color.WHITE], ["HeroBody", 15, null, Color(1, 1, 1, 0.86)], ["Brand", 15, bold, TEXT]]:
		t.add_type(v[0])
		t.set_type_variation(v[0], "Label")
		t.set_font_size("font_size", v[0], v[1])
		t.set_color("font_color", v[0], v[3])
		if v[2] != null:
			t.set_font("font", v[0], v[2])

	# Buttons. Default = Spectrum "secondary outline": hovering fills it light with dark text.
	t.set_stylebox("normal", "Button", _pill(Color(0, 0, 0, 0), Color("#8a8a8a"), 2))
	t.set_stylebox("hover", "Button", _pill(Color("#e6e6e6"), Color("#e6e6e6"), 2))
	t.set_stylebox("pressed", "Button", _pill(Color.WHITE, Color.WHITE, 2))
	t.set_stylebox("hover_pressed", "Button", _pill(Color.WHITE, Color.WHITE, 2))
	t.set_stylebox("disabled", "Button", _pill(Color(0, 0, 0, 0), Color("#454545"), 2))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_font("font", "Button", bold)
	t.set_font_size("font_size", "Button", 14)
	t.set_color("font_color", "Button", Color("#e6e6e6"))
	t.set_color("font_hover_color", "Button", Color("#1b1b1b"))
	t.set_color("font_pressed_color", "Button", Color("#1b1b1b"))
	t.set_color("font_hover_pressed_color", "Button", Color("#1b1b1b"))
	t.set_color("font_focus_color", "Button", Color("#e6e6e6"))
	t.set_color("font_disabled_color", "Button", Color("#5c5c5c"))
	t.set_color("icon_normal_color", "Button", Color("#e6e6e6"))
	t.set_color("icon_hover_color", "Button", Color("#1b1b1b"))
	t.set_color("icon_pressed_color", "Button", Color("#1b1b1b"))
	t.set_color("icon_hover_pressed_color", "Button", Color("#1b1b1b"))
	t.set_color("icon_focus_color", "Button", Color("#e6e6e6"))
	t.set_color("icon_disabled_color", "Button", Color("#5c5c5c"))
	t.set_constant("h_separation", "Button", 8)

	# Primary = Spectrum call-to-action (accent fill).
	t.add_type("Primary")
	t.set_type_variation("Primary", "Button")
	t.set_stylebox("normal", "Primary", _pill(ACCENT))
	t.set_stylebox("hover", "Primary", _pill(ACCENT_HOVER))
	t.set_stylebox("pressed", "Primary", _pill(ACCENT_DOWN))
	t.set_stylebox("hover_pressed", "Primary", _pill(ACCENT_DOWN))
	t.set_stylebox("disabled", "Primary", _pill(Color("#2f2f2f")))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color",
			"icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		t.set_color(c, "Primary", Color.WHITE)
	t.set_color("font_disabled_color", "Primary", Color("#6a6a6a"))

	# On-colour buttons for the gradient banner.
	t.add_type("OnColor")
	t.set_type_variation("OnColor", "Button")
	t.set_stylebox("normal", "OnColor", _pill(Color.WHITE))
	t.set_stylebox("hover", "OnColor", _pill(Color("#e8e8e8")))
	t.set_stylebox("pressed", "OnColor", _pill(Color("#d4d4d4")))
	t.set_stylebox("hover_pressed", "OnColor", _pill(Color("#d4d4d4")))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "OnColor", Color("#141414"))
	t.add_type("OnColorOutline")
	t.set_type_variation("OnColorOutline", "Button")
	t.set_stylebox("normal", "OnColorOutline", _pill(Color(0, 0, 0, 0), Color.WHITE, 2))
	t.set_stylebox("hover", "OnColorOutline", _pill(Color(1, 1, 1, 0.16), Color.WHITE, 2))
	t.set_stylebox("pressed", "OnColorOutline", _pill(Color(1, 1, 1, 0.26), Color.WHITE, 2))
	t.set_stylebox("hover_pressed", "OnColorOutline", _pill(Color(1, 1, 1, 0.26), Color.WHITE, 2))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "OnColorOutline", Color.WHITE)

	# Quiet buttons: text/icon only, soft hover.
	t.add_type("Quiet")
	t.set_type_variation("Quiet", "Button")
	var q := _box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, 6)
	q.content_margin_left = 10
	q.content_margin_right = 10
	t.set_stylebox("normal", "Quiet", q)
	var qh := q.duplicate()
	qh.bg_color = Color("#333333")
	t.set_stylebox("hover", "Quiet", qh)
	t.set_stylebox("pressed", "Quiet", qh)
	t.set_stylebox("hover_pressed", "Quiet", qh)
	t.set_font("font", "Quiet", semibold)
	for c in ["font_color", "font_focus_color", "icon_normal_color", "icon_focus_color"]:
		t.set_color(c, "Quiet", BODY)
	for c in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(c, "Quiet", Color.WHITE)
	t.add_type("Link")
	t.set_type_variation("Link", "Quiet")
	var lk := _box(Color(0, 0, 0, 0), 4, Color(0, 0, 0, 0), 0, 4)
	lk.content_margin_left = 0
	lk.content_margin_right = 0
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(st, "Link", lk)
	t.set_color("font_color", "Link", ACCENT_HOVER)
	t.set_color("icon_normal_color", "Link", ACCENT_HOVER)
	t.set_color("font_hover_color", "Link", Color("#5aa9ff"))
	t.set_color("icon_hover_color", "Link", Color("#5aa9ff"))

	# Side navigation.
	t.add_type("Nav")
	t.set_type_variation("Nav", "Button")
	var nb := _box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, 8)
	nb.content_margin_left = 12
	var nbh := nb.duplicate()
	nbh.bg_color = Color("#2a2a2a")
	var nbp := nb.duplicate()
	nbp.bg_color = Color("#353535")
	t.set_stylebox("normal", "Nav", nb)
	t.set_stylebox("hover", "Nav", nbh)
	t.set_stylebox("pressed", "Nav", nbp)
	t.set_stylebox("hover_pressed", "Nav", nbp)
	t.set_font("font", "Nav", font)
	t.set_font_size("font_size", "Nav", 14)
	for c in ["font_color", "font_focus_color", "icon_normal_color", "icon_focus_color"]:
		t.set_color(c, "Nav", Color("#b4b4b4"))
	for c in ["font_hover_color", "icon_hover_color"]:
		t.set_color(c, "Nav", TEXT)
	for c in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(c, "Nav", Color.WHITE)
	t.set_constant("h_separation", "Nav", 12)

	# Text fields (Spectrum: 4px corners, 1px border, blue when focused).
	var le := _box(FIELD, 4, FIELD_BORDER, 1, 8)
	le.content_margin_left = 10
	le.content_margin_right = 10
	var lef := le.duplicate()
	lef.border_color = ACCENT
	var ler := le.duplicate()
	ler.bg_color = Color("#222222")
	ler.border_color = Color("#3c3c3c")
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_stylebox("read_only", "LineEdit", ler)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_uneditable_color", "LineEdit", BODY)
	t.set_color("font_placeholder_color", "LineEdit", FAINT)
	t.set_color("caret_color", "LineEdit", Color.WHITE)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.4))
	t.add_type("Flat")
	t.set_type_variation("Flat", "LineEdit")
	var flat := StyleBoxEmpty.new()
	flat.content_margin_left = 4
	flat.content_margin_right = 4
	t.set_stylebox("normal", "Flat", flat)
	t.set_stylebox("focus", "Flat", flat)
	t.set_stylebox("normal", "TextEdit", le)
	t.set_stylebox("focus", "TextEdit", lef)

	# Dropdowns use the field look plus a chevron.
	t.set_stylebox("normal", "OptionButton", le)
	var obh := le.duplicate()
	obh.border_color = Color("#6a6a6a")
	t.set_stylebox("hover", "OptionButton", obh)
	t.set_stylebox("pressed", "OptionButton", lef)
	t.set_stylebox("hover_pressed", "OptionButton", lef)
	t.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	t.set_font("font", "OptionButton", font)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(c, "OptionButton", TEXT)
	t.set_icon("arrow", "OptionButton", _svg("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><path d='M2.5 4.5L6 8L9.5 4.5' fill='none' stroke='#c8c8c8' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/></svg>"))
	t.set_constant("arrow_margin", "OptionButton", 10)

	# Check boxes and switches, drawn as vectors.
	var cb_off := _svg("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect x='1.5' y='1.5' width='13' height='13' rx='2.5' fill='none' stroke='#b0b0b0' stroke-width='2'/></svg>")
	var cb_on := _svg("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect x='0.5' y='0.5' width='15' height='15' rx='3' fill='#2680eb'/><path d='M4 8.3L6.8 11L12 5.4' fill='none' stroke='#ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>")
	var sw_off := _svg("<svg xmlns='http://www.w3.org/2000/svg' width='30' height='16'><rect x='1' y='1' width='28' height='14' rx='7' fill='#1c1c1c' stroke='#8a8a8a' stroke-width='2'/><circle cx='8' cy='8' r='5' fill='#d0d0d0'/></svg>")
	var sw_on := _svg("<svg xmlns='http://www.w3.org/2000/svg' width='30' height='16'><rect x='0' y='0' width='30' height='16' rx='8' fill='#2680eb'/><circle cx='22' cy='8' r='5' fill='#ffffff'/></svg>")
	for type in ["CheckBox", "CheckButton"]:
		var on := cb_on if type == "CheckBox" else sw_on
		var off := cb_off if type == "CheckBox" else sw_off
		for n in ["checked", "checked_disabled", "radio_checked"]:
			t.set_icon(n, type, on)
		for n in ["unchecked", "unchecked_disabled", "radio_unchecked"]:
			t.set_icon(n, type, off)
		if type == "CheckButton":
			t.set_icon("checked_mirrored", type, on)
			t.set_icon("unchecked_mirrored", type, off)
		var empty := StyleBoxEmpty.new()
		empty.content_margin_top = 4
		empty.content_margin_bottom = 4
		for s in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			t.set_stylebox(s, type, empty)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			t.set_color(c, type, BODY)
		t.set_constant("h_separation", type, 10)

	t.set_stylebox("normal", "ColorPickerButton", _box(FIELD, 4, FIELD_BORDER, 1, 4))
	t.set_stylebox("hover", "ColorPickerButton", _box(FIELD, 4, Color("#6a6a6a"), 1, 4))
	t.set_stylebox("pressed", "ColorPickerButton", _box(FIELD, 4, ACCENT, 1, 4))

	# Surfaces
	t.add_type("Card")
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", _box(CARD, 10, Color(0, 0, 0, 0), 0, 22))
	t.add_type("CardHover")
	t.set_type_variation("CardHover", "PanelContainer")
	t.set_stylebox("panel", "CardHover", _box(CARD_HOVER, 10, Color(0, 0, 0, 0), 0, 22))
	t.add_type("Callout")
	t.set_type_variation("Callout", "PanelContainer")
	var co := _box(Color("#2b2216"), 8, Color(0, 0, 0, 0), 0, 18)
	co.border_color = WARN
	co.border_width_left = 4
	t.set_stylebox("panel", "Callout", co)
	t.add_type("TopBar")
	t.set_type_variation("TopBar", "PanelContainer")
	var tb := _box(TOPBAR, 0, Color(0, 0, 0, 0), 0, 0)
	tb.border_color = Color("#2e2e2e")
	tb.border_width_bottom = 1
	tb.content_margin_left = 16
	tb.content_margin_right = 16
	tb.content_margin_top = 10
	tb.content_margin_bottom = 10
	t.set_stylebox("panel", "TopBar", tb)
	t.add_type("Sidebar")
	t.set_type_variation("Sidebar", "PanelContainer")
	var sbx := _box(SIDEBAR, 0, Color(0, 0, 0, 0), 0, 0)
	sbx.border_color = Color("#2a2a2a")
	sbx.border_width_right = 1
	sbx.content_margin_left = 12
	sbx.content_margin_right = 12
	sbx.content_margin_top = 18
	sbx.content_margin_bottom = 16
	t.set_stylebox("panel", "Sidebar", sbx)
	t.add_type("Search")
	t.set_type_variation("Search", "PanelContainer")
	var se := _box(Color("#2c2c2c"), 16, Color("#3a3a3a"), 1, 0)
	se.content_margin_left = 12
	se.content_margin_right = 12
	se.content_margin_top = 2
	se.content_margin_bottom = 2
	t.set_stylebox("panel", "Search", se)
	t.add_type("Row")
	t.set_type_variation("Row", "PanelContainer")
	var rw := _box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, 10)
	t.set_stylebox("panel", "Row", rw)
	t.add_type("RowHover")
	t.set_type_variation("RowHover", "PanelContainer")
	var rwh := rw.duplicate()
	rwh.bg_color = Color("#2b2b2b")
	t.set_stylebox("panel", "RowHover", rwh)
	t.add_type("Chip")
	t.set_type_variation("Chip", "PanelContainer")
	var ch := _box(Color("#2c2c2c"), 14, Color("#3a3a3a"), 1, 0)
	ch.content_margin_left = 10
	ch.content_margin_right = 12
	ch.content_margin_top = 4
	ch.content_margin_bottom = 4
	t.set_stylebox("panel", "Chip", ch)
	t.set_stylebox("panel", "PanelContainer", _box(BG, 0, Color(0, 0, 0, 0), 0, 0))
	t.set_stylebox("panel", "Panel", _box(BG, 0))
	t.set_stylebox("panel", "PopupPanel", _box(RAISED, 6, BORDER, 1, 8))
	var pm := _box(RAISED, 6, BORDER, 1, 6)
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("hover", "PopupMenu", _box(ACCENT, 4, Color(0, 0, 0, 0), 0, 4))
	t.set_color("font_color", "PopupMenu", BODY)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	var tip := _box(Color("#3a3a3a"), 4, Color(0, 0, 0, 0), 0, 8)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("panel", "AcceptDialog", _box(RAISED, 0, Color(0, 0, 0, 0), 0, 16))

	# Progress: thin Spectrum bar.
	t.set_stylebox("background", "ProgressBar", _box(Color("#3c3c3c"), 3, Color(0, 0, 0, 0), 0, 0))
	t.set_stylebox("fill", "ProgressBar", _box(ACCENT, 3, Color(0, 0, 0, 0), 0, 0))
	t.set_color("font_color", "ProgressBar", Color(0, 0, 0, 0))

	# Scrollbars
	t.set_stylebox("scroll", "VScrollBar", _box(Color(0, 0, 0, 0), 4, Color(0, 0, 0, 0), 0, 3))
	t.set_stylebox("grabber", "VScrollBar", _box(Color("#4a4a4a"), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color("#5c5c5c"), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(Color("#6e6e6e"), 4, Color(0, 0, 0, 0), 0, 4))

	t.set_stylebox("separator", "HSeparator", _box(BORDER, 0, Color(0, 0, 0, 0), 0, 0))
	t.set_constant("separation", "HSeparator", 1)
	t.set_color("default_color", "RichTextLabel", BODY)
	t.set_font("bold_font", "RichTextLabel", bold)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	return t
