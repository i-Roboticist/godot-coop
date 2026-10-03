@tool
extends RefCounted
## End-to-end encryption for one connection.
##
## Keys are derived from the invite secret plus a fresh nonce from each side, so only people holding
## the invite can read or forge traffic - including when it is forwarded through a relay server.
## Packet layout: [0xC1][flags u8][counter u64][iv 16][AES-256-CBC ciphertext][HMAC-SHA256 32].
## The MAC covers direction + channel + everything before it (encrypt-then-MAC). Counters must
## strictly increase per channel, which blocks replays.

const MARK_PLAIN := 0x50
const MARK_SEALED := 0xC1
const FLAG_COMPRESSED := 1
const HEADER_SIZE := 10
const MAX_PLAIN := 64 * 1024 * 1024

var _crypto := Crypto.new()
var _enc_key := PackedByteArray()
var _mac_key := PackedByteArray()
var _dir_out := 0
var _send_ctr := {}
var _recv_ctr := {}
var ready := false


static func derive_keys(secret: PackedByteArray, nonce_c: PackedByteArray, nonce_h: PackedByteArray) -> Array:
	var c := Crypto.new()
	var info := "gdcoop-v1".to_utf8_buffer()
	info.append_array(nonce_c)
	info.append_array(nonce_h)
	var prk := c.hmac_digest(HashingContext.HASH_SHA256, secret, info)
	var enc := c.hmac_digest(HashingContext.HASH_SHA256, prk, "enc".to_utf8_buffer())
	var mac := c.hmac_digest(HashingContext.HASH_SHA256, prk, "mac".to_utf8_buffer())
	return [enc, mac]


func setup(secret: PackedByteArray, nonce_c: PackedByteArray, nonce_h: PackedByteArray, is_host: bool) -> void:
	var k := derive_keys(secret, nonce_c, nonce_h)
	_enc_key = k[0]
	_mac_key = k[1]
	_dir_out = 1 if is_host else 0
	_send_ctr.clear()
	_recv_ctr.clear()
	ready = true


static func encode_plain(msg: Dictionary) -> PackedByteArray:
	var b := PackedByteArray([MARK_PLAIN])
	b.append_array(var_to_bytes(msg))
	return b


static func decode_plain(pkt: PackedByteArray):
	if pkt.size() < 2 or pkt[0] != MARK_PLAIN or pkt.size() > 65536:
		return null
	var v = bytes_to_var(pkt.slice(1))
	return v if v is Dictionary else null


static func is_sealed(pkt: PackedByteArray) -> bool:
	return pkt.size() > 0 and pkt[0] == MARK_SEALED


func _mac(channel: int, direction: int, data: PackedByteArray) -> PackedByteArray:
	var m := PackedByteArray([direction, channel])
	m.append_array(data)
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, _mac_key, m)


func seal(channel: int, msg: Dictionary) -> PackedByteArray:
	var plain := var_to_bytes(msg)
	var flags := 0
	if plain.size() > 1024:
		var comp := plain.compress(FileAccess.COMPRESSION_ZSTD)
		if comp.size() + 4 < plain.size():
			var sized := PackedByteArray()
			sized.resize(4)
			sized.encode_u32(0, plain.size())
			sized.append_array(comp)
			plain = sized
			flags |= FLAG_COMPRESSED
	var pad := 16 - (plain.size() % 16)
	var padding := PackedByteArray()
	padding.resize(pad)
	padding.fill(pad)
	plain.append_array(padding)
	var iv := _crypto.generate_random_bytes(16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, _enc_key, iv)
	var ct := aes.update(plain)
	aes.finish()
	var ctr: int = int(_send_ctr.get(channel, 0)) + 1
	_send_ctr[channel] = ctr
	var out := PackedByteArray()
	out.resize(HEADER_SIZE)
	out.encode_u8(0, MARK_SEALED)
	out.encode_u8(1, flags)
	out.encode_u64(2, ctr)
	out.append_array(iv)
	out.append_array(ct)
	out.append_array(_mac(channel, _dir_out, out))
	return out


## Returns the decoded Dictionary, or null when the packet is forged, replayed or malformed.
func open(channel: int, pkt: PackedByteArray):
	if not ready or pkt.size() < HEADER_SIZE + 16 + 16 + 32 or pkt[0] != MARK_SEALED:
		return null
	var body := pkt.slice(0, pkt.size() - 32)
	var mac := pkt.slice(pkt.size() - 32)
	if not _crypto.constant_time_compare(_mac(channel, 1 - _dir_out, body), mac):
		return null
	var flags := body.decode_u8(1)
	var ctr := body.decode_u64(2)
	if ctr <= int(_recv_ctr.get(channel, 0)):
		return null
	var iv := body.slice(HEADER_SIZE, HEADER_SIZE + 16)
	var ct := body.slice(HEADER_SIZE + 16)
	if ct.is_empty() or ct.size() % 16 != 0:
		return null
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, _enc_key, iv)
	var plain := aes.update(ct)
	aes.finish()
	var pad := plain[plain.size() - 1]
	if pad < 1 or pad > 16 or pad > plain.size():
		return null
	for i in range(plain.size() - pad, plain.size()):
		if plain[i] != pad:
			return null
	plain = plain.slice(0, plain.size() - pad)
	if flags & FLAG_COMPRESSED:
		if plain.size() < 4:
			return null
		var size := plain.decode_u32(0)
		if size <= 0 or size > MAX_PLAIN:
			return null
		plain = plain.slice(4).decompress(size, FileAccess.COMPRESSION_ZSTD)
		if plain.size() != size:
			return null
	_recv_ctr[channel] = ctr
	var v = bytes_to_var(plain)
	return v if v is Dictionary else null
