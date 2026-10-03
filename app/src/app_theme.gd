extends RefCounted
## The companion app's look: dark, rounded, with a Godot-blue accent.

const BG := Color("#14171e")
const SIDEBAR := Color("#0f1217")
const PANEL := Color("#1c212b")
const PANEL_2 := Color("#232936")
const BORDER := Color("#2c3342")
const TEXT := Color("#e8ebf1")
const MUTED := Color("#8d96a8")
const ACCENT := Color("#4f8fdc")
const ACCENT_HOVER := Color("#64a0e6")
const GOOD := Color("#51cf66")
const WARN := Color("#fcc419")
const BAD := Color("#ff6b6b")


static func _box(color: Color, radius := 10, border := Color(0, 0, 0, 0), bw := 0, pad := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_content_margin_all(pad)
	s.anti_aliasing = true
	return s


static func build() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "Inter", "Roboto", "Noto Sans", "Helvetica", "Arial"])
	var bold := SystemFont.new()
	bold.font_names = font.font_names
	bold.font_weight = 650
	t.default_font = font
	t.default_font_size = 15

	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("normal", "Label", StyleBoxEmpty.new())

	for v in [["Title", 30], ["Heading", 21], ["Subheading", 16]]:
		t.add_type(v[0])
		t.set_type_variation(v[0], "Label")
		t.set_font(&"font", v[0], bold)
		t.set_font_size(&"font_size", v[0], v[1])
	t.add_type("Muted")
	t.set_type_variation("Muted", "Label")
	t.set_color("font_color", "Muted", MUTED)
	t.set_font_size("font_size", "Muted", 14)

	# Buttons
	var btn := _box(PANEL_2, 8, BORDER, 1, 10)
	btn.content_margin_left = 16
	btn.content_margin_right = 16
	var btn_h := btn.duplicate()
	btn_h.bg_color = Color("#2b3242")
	var btn_p := btn.duplicate()
	btn_p.bg_color = Color("#1a1f29")
	var btn_d := btn.duplicate()
	btn_d.bg_color = Color("#1b1f27")
	btn_d.border_color = Color("#232834")
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", btn_h)
	t.set_stylebox("pressed", "Button", btn_p)
	t.set_stylebox("disabled", "Button", btn_d)
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), 8, ACCENT, 2, 10))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color("#5d6474"))
	t.set_constant("h_separation", "Button", 8)

	t.add_type("Primary")
	t.set_type_variation("Primary", "Button")
	var pb := _box(ACCENT, 8, Color(0, 0, 0, 0), 0, 12)
	pb.content_margin_left = 20
	pb.content_margin_right = 20
	var pbh := pb.duplicate()
	pbh.bg_color = ACCENT_HOVER
	var pbp := pb.duplicate()
	pbp.bg_color = Color("#3f7bc4")
	t.set_stylebox("normal", "Primary", pb)
	t.set_stylebox("hover", "Primary", pbh)
	t.set_stylebox("pressed", "Primary", pbp)
	t.set_color("font_color", "Primary", Color.WHITE)
	t.set_font("font", "Primary", bold)

	t.add_type("Nav")
	t.set_type_variation("Nav", "Button")
	var nb := _box(Color(0, 0, 0, 0), 8, Color(0, 0, 0, 0), 0, 10)
	nb.content_margin_left = 14
	var nbh := nb.duplicate()
	nbh.bg_color = Color("#1a1f28")
	var nbp := nb.duplicate()
	nbp.bg_color = Color("#222a38")
	t.set_stylebox("normal", "Nav", nb)
	t.set_stylebox("hover", "Nav", nbh)
	nbp.border_color = ACCENT
	nbp.border_width_left = 3
	t.set_stylebox("pressed", "Nav", nbp)
	t.set_stylebox("hover_pressed", "Nav", nbp)
	t.set_color("font_color", "Nav", MUTED)
	t.set_color("font_pressed_color", "Nav", Color.WHITE)
	t.set_color("font_hover_color", "Nav", TEXT)
	t.set_constant("h_separation", "Nav", 10)

	var cpb := _box(PANEL_2, 8, BORDER, 1, 5)
	t.set_stylebox("normal", "ColorPickerButton", cpb)
	t.set_stylebox("hover", "ColorPickerButton", cpb)
	t.set_stylebox("pressed", "ColorPickerButton", cpb)

	# Inputs
	var le := _box(Color("#10131a"), 8, BORDER, 1, 10)
	var lef := _box(Color("#10131a"), 8, ACCENT, 2, 10)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_stylebox("read_only", "LineEdit", _box(Color("#171b23"), 8, BORDER, 1, 10))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color("#5d6474"))
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.35))
	t.set_stylebox("normal", "TextEdit", le)
	t.set_stylebox("focus", "TextEdit", lef)
	t.set_stylebox("normal", "OptionButton", btn)
	t.set_stylebox("hover", "OptionButton", btn_h)
	t.set_stylebox("pressed", "OptionButton", btn_p)
	t.set_stylebox("normal", "SpinBox", le)

	# Panels
	t.add_type("Card")
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", _box(PANEL, 14, BORDER, 1, 22))
	t.add_type("CardFlat")
	t.set_type_variation("CardFlat", "PanelContainer")
	t.set_stylebox("panel", "CardFlat", _box(PANEL_2, 10, Color(0, 0, 0, 0), 0, 14))
	t.add_type("Sidebar")
	t.set_type_variation("Sidebar", "PanelContainer")
	t.set_stylebox("panel", "Sidebar", _box(SIDEBAR, 0, Color(0, 0, 0, 0), 0, 14))
	t.set_stylebox("panel", "PanelContainer", _box(BG, 0, Color(0, 0, 0, 0), 0, 0))
	t.set_stylebox("panel", "Panel", _box(BG, 0))
	t.set_stylebox("panel", "PopupPanel", _box(PANEL, 10, BORDER, 1, 12))
	t.set_stylebox("panel", "PopupMenu", _box(PANEL, 8, BORDER, 1, 6))
	t.set_stylebox("hover", "PopupMenu", _box(Color(ACCENT, 0.25), 6, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("embedded_border", "Window", _box(PANEL, 10, BORDER, 1, 12))
	t.set_stylebox("panel", "AcceptDialog", _box(PANEL, 0, Color(0, 0, 0, 0), 0, 16))

	# Progress
	t.set_stylebox("background", "ProgressBar", _box(Color("#10131a"), 6, Color(0, 0, 0, 0), 0, 0))
	t.set_stylebox("fill", "ProgressBar", _box(ACCENT, 6, Color(0, 0, 0, 0), 0, 0))
	t.set_color("font_color", "ProgressBar", Color.WHITE)

	# Check boxes
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color.WHITE)
	t.set_color("font_pressed_color", "CheckBox", TEXT)
	t.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover_pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckBox", StyleBoxEmpty.new())

	# Scrollbars
	t.set_stylebox("scroll", "VScrollBar", _box(Color(0, 0, 0, 0), 4, Color(0, 0, 0, 0), 0, 2))
	t.set_stylebox("grabber", "VScrollBar", _box(Color("#323a4b"), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color("#3c465a"), 4, Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(Color("#46516a"), 4, Color(0, 0, 0, 0), 0, 4))

	t.set_stylebox("separator", "HSeparator", _box(BORDER, 0, Color(0, 0, 0, 0), 0, 0))
	t.set_constant("separation", "HSeparator", 18)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_stylebox("panel", "Tree", _box(Color("#10131a"), 8, BORDER, 1, 6))
	t.set_color("font_color", "Tree", TEXT)
	t.set_constant("v_separation", "Tree", 6)
	return t
