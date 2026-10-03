extends SceneTree
## Renders app/icon.svg into a multi-size Windows .ico (PNG-compressed entries).
##   Godot --headless --path app -s ../tools/make_icon.gd

const SIZES := [16, 24, 32, 48, 64, 128, 256]


func _init() -> void:
	var svg := FileAccess.get_file_as_bytes("res://icon.svg")
	var pngs := []
	for s in SIZES:
		var img := Image.new()
		img.load_svg_from_buffer(svg, s / 128.0)
		if img.get_width() != s:
			img.resize(s, s, Image.INTERPOLATE_LANCZOS)
		pngs.append(img.save_png_to_buffer())
	var out := StreamPeerBuffer.new()
	out.put_u16(0)
	out.put_u16(1)
	out.put_u16(SIZES.size())
	var offset := 6 + 16 * SIZES.size()
	for i in SIZES.size():
		var s: int = SIZES[i]
		out.put_u8(0 if s >= 256 else s)
		out.put_u8(0 if s >= 256 else s)
		out.put_u8(0)
		out.put_u8(0)
		out.put_u16(1)
		out.put_u16(32)
		out.put_u32(pngs[i].size())
		out.put_u32(offset)
		offset += pngs[i].size()
	for p in pngs:
		out.put_data(p)
	var f := FileAccess.open("res://icon.ico", FileAccess.WRITE)
	f.store_buffer(out.data_array)
	f.close()
	print("wrote icon.ico (%d bytes)" % out.data_array.size())
	quit()
