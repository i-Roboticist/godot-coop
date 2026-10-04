@tool
extends RefCounted
## STUN (RFC 5389) Binding requests: asks a public server which address and port one of our UDP
## sockets appears to come from on the internet, i.e. the mapping our router made for it.

const MAGIC := [0x21, 0x12, 0xA4, 0x42]
const SERVERS := [
	["stun.l.google.com", 19302], ["stun.cloudflare.com", 3478],
	["stun1.l.google.com", 19302], ["global.stun.twilio.com", 3478],
]


## Returns [transaction id, packet].
static func request() -> Array:
	var tid := Crypto.new().generate_random_bytes(12)
	var p := PackedByteArray([0x00, 0x01, 0x00, 0x00])
	p.append_array(PackedByteArray(MAGIC))
	p.append_array(tid)
	return [tid, p]


static func _u16(b: PackedByteArray, i: int) -> int:
	return (b[i] << 8) | b[i + 1]


## The [ip, port] a Binding success response reports, or [] if `pkt` isn't the answer to `tid`.
static func parse(pkt: PackedByteArray, tid: PackedByteArray) -> Array:
	if pkt.size() < 20 or _u16(pkt, 0) != 0x0101 or pkt.slice(4, 8) != PackedByteArray(MAGIC) or pkt.slice(8, 20) != tid:
		return []
	var end := mini(pkt.size(), 20 + _u16(pkt, 2))
	var plain := []
	var i := 20
	while i + 4 <= end:
		var t := _u16(pkt, i)
		var l := _u16(pkt, i + 2)
		if i + 4 + l > end:
			break
		var v := pkt.slice(i + 4, i + 4 + l)
		if (t == 0x0020 or t == 0x8020) and l >= 8:
			var key := PackedByteArray(MAGIC) + tid
			var addr := PackedByteArray()
			for k in v.size() - 4:
				addr.append(v[4 + k] ^ key[k])
			var r := _addr(v[1], addr, _u16(v, 2) ^ 0x2112)
			if not r.is_empty():
				return r
		elif t == 0x0001 and l >= 8 and plain.is_empty():
			plain = _addr(v[1], v.slice(4), _u16(v, 2))
		i += 4 + l + ((4 - l % 4) % 4)
	return plain


static func _addr(family: int, a: PackedByteArray, port: int) -> Array:
	if family == 1 and a.size() >= 4:
		return ["%d.%d.%d.%d" % [a[0], a[1], a[2], a[3]], port]
	if family == 2 and a.size() >= 16:
		var groups := PackedStringArray()
		for g in 8:
			groups.append("%x" % _u16(a, g * 2))
		return [":".join(groups), port]
	return []
