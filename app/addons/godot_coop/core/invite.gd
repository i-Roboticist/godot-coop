@tool
extends RefCounted
## Invite codes: everything a teammate needs to find and authenticate with a session.
##
## Text form:  gdc1.<base64url>      Link forms: godotcoop://join/<code>  or  https://…#<code>
## Short form: ABCD-EFGH (only when a relay server is configured; resolved by asking the relay).
##
## Binary layout (v1): u8 version | 6 bytes invite id | 16 bytes secret | u8 role |
##   u8 n | n × (u8 kind, str ip, u16 port) | str relay host | u16 relay port | str room | str project

const Util := preload("res://addons/godot_coop/core/util.gd")

const PREFIX := "gdc1."
const KIND_LAN := 1
const KIND_PUBLIC := 2
const ROLE_EDITOR := 0
const ROLE_VIEWER := 1
const SHORT_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


static func make(secret: PackedByteArray, iid: PackedByteArray, role: String, candidates: Array, relay_host: String, relay_port: int, room: String, project: String) -> Dictionary:
	return {
		"iid": iid, "secret": secret, "role": role, "cands": candidates,
		"relay_host": relay_host, "relay_port": relay_port, "room": room, "project": project,
	}


static func _put_str(buf: StreamPeerBuffer, s: String) -> void:
	var b := s.to_utf8_buffer()
	if b.size() > 255:
		b = b.slice(0, 255)
	buf.put_u8(b.size())
	buf.put_data(b)


static func _get_str(buf: StreamPeerBuffer) -> String:
	var n := buf.get_u8()
	if n == 0:
		return ""
	var r := buf.get_data(n)
	if r[0] != OK:
		return ""
	return PackedByteArray(r[1]).get_string_from_utf8()


static func encode(info: Dictionary) -> String:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(1)
	buf.put_data(info.iid)
	buf.put_data(info.secret)
	buf.put_u8(ROLE_VIEWER if info.get("role", "editor") == "viewer" else ROLE_EDITOR)
	var cands: Array = info.get("cands", [])
	buf.put_u8(mini(cands.size(), 8))
	for i in mini(cands.size(), 8):
		var c: Array = cands[i]
		buf.put_u8(int(c[0]))
		_put_str(buf, String(c[1]))
		buf.put_u16(int(c[2]))
	_put_str(buf, String(info.get("relay_host", "")))
	buf.put_u16(int(info.get("relay_port", 0)))
	_put_str(buf, String(info.get("room", "")))
	_put_str(buf, String(info.get("project", "")).substr(0, 40))
	return PREFIX + Util.b64url_encode(buf.data_array)


## Accepts a raw code, a godotcoop:// link or an https link containing the code. Returns {} on error.
static func decode(text: String) -> Dictionary:
	var code := extract_code(text)
	if not code.begins_with(PREFIX):
		return {}
	var raw := Util.b64url_decode(code.substr(PREFIX.length()))
	if raw.size() < 1 + 6 + 16 + 1 + 1:
		return {}
	var buf := StreamPeerBuffer.new()
	buf.data_array = raw
	if buf.get_u8() != 1:
		return {}
	var iid := PackedByteArray(buf.get_data(6)[1])
	var secret := PackedByteArray(buf.get_data(16)[1])
	var role := "viewer" if buf.get_u8() == ROLE_VIEWER else "editor"
	var n := buf.get_u8()
	var cands := []
	for i in n:
		if buf.get_position() >= raw.size():
			return {}
		var kind := buf.get_u8()
		var ip := _get_str(buf)
		var port := buf.get_u16()
		if ip.is_empty() or port == 0:
			continue
		cands.append([kind, ip, port])
	var relay_host := _get_str(buf)
	var relay_port := buf.get_u16()
	var room := _get_str(buf)
	var project := _get_str(buf)
	if iid.size() != 6 or secret.size() != 16:
		return {}
	return make(secret, iid, role, cands, relay_host, relay_port, room, project)


static func extract_code(text: String) -> String:
	var t := text.strip_edges()
	var i := t.find(PREFIX)
	if i == -1:
		return t
	var code := t.substr(i)
	for stop in ["&", "\"", "'", " ", "?", "#", "\n"]:
		var j := code.find(stop)
		if j != -1:
			code = code.substr(0, j)
	return code


static func link(code: String) -> String:
	return "%s://join/%s" % [Util.URL_SCHEME, code]


static func web_link(base_url: String, code: String) -> String:
	if base_url.strip_edges().is_empty():
		return ""
	return base_url.strip_edges() + "#" + code


## "ABCD-EFGH" style codes handed out by a relay.
static func is_short_code(text: String) -> bool:
	var t := normalize_short_code(text)
	if t.length() != 8:
		return false
	for c in t:
		if SHORT_ALPHABET.find(c) == -1:
			return false
	return true


static func normalize_short_code(text: String) -> String:
	return text.strip_edges().to_upper().replace("-", "").replace(" ", "")


static func random_short_code() -> String:
	var b := Util.random_bytes(8)
	var s := ""
	for i in 8:
		s += SHORT_ALPHABET[b[i] % SHORT_ALPHABET.length()]
	return s


static func pretty_short_code(code: String) -> String:
	return code.substr(0, 4) + "-" + code.substr(4, 4)
