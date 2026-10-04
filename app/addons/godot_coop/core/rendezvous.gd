@tool
extends RefCounted
## Lets a host and a joiner on different networks find each other without a server of our own.
##
## They swap a few small messages (the addresses each one can be reached at) through free public
## message services: three MQTT brokers and ntfy.sh, all at once, so one being down or blocked
## doesn't matter. The topic name and the keys come from the invite secret: the services, and
## anyone else watching them, can't read the messages, fake them or even tell which invite they
## belong to.

const Util := preload("res://addons/godot_coop/core/util.gd")

signal received(channel: String, msg: Dictionary)

const MQTT_BROKERS := [["broker.hivemq.com", 1883], ["broker.emqx.io", 1883], ["test.mosquitto.org", 1883]]
const NTFY_HOST := "ntfy.sh"
const MAX_SKEW_S := 600.0
const SEEN_KEEP_MS := 1200000
const QUEUE_MS := 10000

var use_mqtt := true
var use_ntfy := true
var _chans := {}          # channel -> {"topic", "enc", "mac"}
var _topic_chan := {}     # topic -> channel
var _mqtt: Array = []
var _sub: NtfySub = null
var _pubs: Array = []
var _queue: Array = []    # recent messages, for brokers that connect late: {"until", "topic", "text", "done": {broker index: true}}
var _seen := {}           # message id -> forget at (ms)
var _next_gc := 0
var _started := 0


func _init() -> void:
	_started = Util.now_ms()
	for b in MQTT_BROKERS:
		var m := Mqtt.new(b[0], b[1])
		m.on_publish = _on_payload
		_mqtt.append(m)
	_sub = NtfySub.new(NTFY_HOST)
	_sub.on_message = _on_payload


static func derive(secret: PackedByteArray) -> Dictionary:
	var c := Crypto.new()
	var topic := c.hmac_digest(HashingContext.HASH_SHA256, secret, "gdcoop-rdv-topic".to_utf8_buffer()).hex_encode().substr(0, 32)
	return {
		"topic": "gdcoop-" + topic,
		"enc": c.hmac_digest(HashingContext.HASH_SHA256, secret, "gdcoop-rdv-enc".to_utf8_buffer()),
		"mac": c.hmac_digest(HashingContext.HASH_SHA256, secret, "gdcoop-rdv-mac".to_utf8_buffer()),
	}


## Encrypt-then-MAC, as text: base64url([1][iv 16][AES-256-CBC ciphertext][HMAC-SHA256 32]).
static func seal(keys: Dictionary, msg: Dictionary) -> String:
	var c := Crypto.new()
	var plain := var_to_bytes(msg)
	var pad := 16 - plain.size() % 16
	for i in pad:
		plain.append(pad)
	var iv := c.generate_random_bytes(16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, keys.enc, iv)
	var out := PackedByteArray([1])
	out.append_array(iv)
	out.append_array(aes.update(plain))
	aes.finish()
	out.append_array(c.hmac_digest(HashingContext.HASH_SHA256, keys.mac, out))
	return Util.b64url_encode(out)


## The message, or null when it's malformed or wasn't made with these keys.
static func open(keys: Dictionary, text: String):
	if text.length() > 8192:
		return null
	var raw := Util.b64url_decode(text)
	if raw.size() < 1 + 16 + 16 + 32 or raw[0] != 1 or (raw.size() - 1 - 16 - 32) % 16 != 0:
		return null
	var c := Crypto.new()
	var body := raw.slice(0, raw.size() - 32)
	if not c.constant_time_compare(c.hmac_digest(HashingContext.HASH_SHA256, keys.mac, body), raw.slice(raw.size() - 32)):
		return null
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, keys.enc, body.slice(1, 17))
	var plain := aes.update(body.slice(17))
	aes.finish()
	var pad := plain[plain.size() - 1]
	if pad < 1 or pad > 16:
		return null
	var v = bytes_to_var(plain.slice(0, plain.size() - pad))
	return v if v is Dictionary else null


func add_channel(channel: String, secret: PackedByteArray) -> void:
	if _chans.has(channel):
		return
	var k := derive(secret)
	_chans[channel] = k
	_topic_chan[k.topic] = channel
	_sub.set_topics(_topic_chan.keys())


## `ntfy` false skips ntfy.sh (it limits how many messages one address may post per day), for
## repeats that the MQTT brokers can carry.
func publish(channel: String, msg: Dictionary, ntfy := true) -> void:
	if not _chans.has(channel):
		return
	var now := Util.now_ms()
	var m := msg.duplicate()
	m["id"] = Util.random_hex(8)
	m["ts"] = Util.unix_time()
	_seen[m.id] = now + SEEN_KEEP_MS     # our own copy comes back from the brokers
	var topic: String = _chans[channel].topic
	var text := seal(_chans[channel], m)
	var q := {"until": now + QUEUE_MS, "topic": topic, "text": text, "done": {}}
	if use_mqtt:
		for i in _mqtt.size():
			if _mqtt[i].is_ready():
				_mqtt[i].publish(topic, text.to_ascii_buffer(), now)
				q.done[i] = true
		_queue.append(q)
	if use_ntfy and (ntfy or q.done.is_empty()):
		_pubs.append(NtfyPub.new(NTFY_HOST, topic, text))


func poll() -> void:
	var now := Util.now_ms()
	var topics := _topic_chan.keys()
	if use_mqtt:
		for i in _mqtt.size():
			var m: Mqtt = _mqtt[i]
			m.poll(now, topics)
			if m.is_ready():
				for q in _queue:
					if not q.done.has(i):
						q.done[i] = true
						m.publish(q.topic, q.text.to_ascii_buffer(), now)
	if use_ntfy:
		_sub.poll(now)
		for p in _pubs:
			p.poll(now)
		_pubs = _pubs.filter(func(p): return not p.done)
	if now >= _next_gc:
		_next_gc = now + 2000
		_queue = _queue.filter(func(q): return q.until > now)
		for id in _seen.keys():
			if _seen[id] < now:
				_seen.erase(id)


## How many of the message services we're connected to right now.
func connected_count() -> int:
	var n := 0
	if use_mqtt:
		for m in _mqtt:
			if m.is_ready():
				n += 1
	if use_ntfy and _sub.state == "streaming":
		n += 1
	return n


func age_ms() -> int:
	return Util.now_ms() - _started


func stop() -> void:
	for m in _mqtt:
		m.close()
	_sub.close()
	for p in _pubs:
		p.http.close()
	_pubs.clear()


func _on_payload(topic: String, text: String) -> void:
	if not _topic_chan.has(topic):
		return
	var channel: String = _topic_chan[topic]
	var m = open(_chans[channel], text)
	if m == null:
		return
	var id := String(m.get("id", ""))
	if id.is_empty() or _seen.has(id) or absf(Util.unix_time() - float(m.get("ts", 0.0))) > MAX_SKEW_S:
		return
	_seen[id] = Util.now_ms() + SEEN_KEEP_MS
	received.emit(channel, m)


# --- MQTT 3.1.1 over TCP (QoS 0 publish and subscribe, which is all this needs) --------------------

class Mqtt:
	extends RefCounted

	var host := ""
	var port := 1883
	var tcp: StreamPeerTCP = null
	var state := "idle"          # idle, resolving, connecting, handshake, ready
	var on_publish: Callable     # (topic: String, text: String)
	var _rid := -1
	var _buf := PackedByteArray()
	var _next_try := 0
	var _fails := 0
	var _since := 0
	var _last_tx := 0
	var _last_rx := 0
	var _pid := 0
	var _subscribed := {}

	func _init(h: String, p: int) -> void:
		host = h
		port = p

	func is_ready() -> bool:
		return state == "ready"

	func poll(now: int, topics: Array) -> void:
		match state:
			"idle":
				if now >= _next_try and not topics.is_empty():
					_rid = IP.resolve_hostname_queue_item(host, IP.TYPE_IPV4)
					state = "resolving"
					_since = now
			"resolving":
				var st := IP.get_resolve_item_status(_rid)
				if st == IP.RESOLVER_STATUS_WAITING and now - _since < 8000:
					return
				var ip := IP.get_resolve_item_address(_rid) if st == IP.RESOLVER_STATUS_DONE else ""
				IP.erase_resolve_item(_rid)
				_rid = -1
				tcp = StreamPeerTCP.new()
				if ip.is_empty() or tcp.connect_to_host(ip, port) != OK:
					_fail(now)
					return
				state = "connecting"
				_since = now
			"connecting":
				tcp.poll()
				var s := tcp.get_status()
				if s == StreamPeerTCP.STATUS_CONNECTED:
					tcp.set_no_delay(true)
					state = "handshake"
					_since = now
					_last_rx = now
					_send(_connect_packet(), now)
				elif s != StreamPeerTCP.STATUS_CONNECTING or now - _since > 8000:
					_fail(now)
			"handshake", "ready":
				tcp.poll()
				if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
					_fail(now)
					return
				var n := tcp.get_available_bytes()
				if n > 0:
					var r := tcp.get_data(n)
					if r[0] == OK:
						_buf.append_array(r[1])
						_last_rx = now
				while state != "idle" and _parse_one(now):
					pass
				if state == "handshake" and now - _since > 8000:
					_fail(now)
				elif state == "ready":
					for t in topics:
						if state == "ready" and not _subscribed.has(t):
							_subscribe(t, now)
					if state == "ready" and now - _last_tx > 25000:
						_send(PackedByteArray([0xC0, 0x00]), now)
					if state == "ready" and now - _last_rx > 70000:
						_fail(now)

	func publish(topic: String, payload: PackedByteArray, now: int) -> void:
		if state != "ready":
			return
		var body := _str(topic)
		body.append_array(payload)
		_send(packet(0x30, body), now)

	func close() -> void:
		if tcp != null:
			if state == "ready" or state == "handshake":
				tcp.put_data(PackedByteArray([0xE0, 0x00]))
			tcp.disconnect_from_host()
		tcp = null
		if _rid >= 0:
			IP.erase_resolve_item(_rid)
			_rid = -1
		state = "idle"

	func _subscribe(topic: String, now: int) -> void:
		_pid = _pid % 65535 + 1
		var body := PackedByteArray([_pid >> 8, _pid & 0xFF])
		body.append_array(_str(topic))
		body.append(0)
		_send(packet(0x82, body), now)
		_subscribed[topic] = true

	func _connect_packet() -> PackedByteArray:
		var body := _str("MQTT")
		body.append_array(PackedByteArray([4, 0x02, 0, 60]))     # protocol level 4, clean session, keep-alive 60 s
		body.append_array(_str("gdc" + Crypto.new().generate_random_bytes(8).hex_encode()))
		return packet(0x10, body)

	## Parses one complete packet off the buffer; false when there isn't one yet.
	func _parse_one(now: int) -> bool:
		var r := split(_buf)
		if r.is_empty():
			return false
		if r[0] < 0:
			_fail(now)
			return false
		_buf = _buf.slice(r[0])
		var type: int = r[1] >> 4
		var body: PackedByteArray = r[2]
		if type == 2:
			if body.size() >= 2 and body[1] == 0:
				state = "ready"
				_fails = 0
				_subscribed.clear()
			else:
				_fail(now)
				return false
		elif type == 3 and body.size() >= 2:
			var tl := (body[0] << 8) | body[1]
			var off := 2 + tl + (2 if (r[1] >> 1) & 3 else 0)
			if off <= body.size() and on_publish.is_valid():
				on_publish.call(body.slice(2, 2 + tl).get_string_from_utf8(), body.slice(off).get_string_from_ascii())
		return true

	func _send(p: PackedByteArray, now: int) -> void:
		if tcp != null and tcp.put_data(p) == OK:
			_last_tx = now
		else:
			_fail(now)

	func _fail(now: int) -> void:
		if tcp != null:
			tcp.disconnect_from_host()
		tcp = null
		_buf.clear()
		_subscribed.clear()
		state = "idle"
		_fails += 1
		_next_try = now + mini(30000, 1000 * (1 << mini(_fails, 5)))

	static func _str(s: String) -> PackedByteArray:
		var b := s.to_utf8_buffer()
		var out := PackedByteArray([b.size() >> 8, b.size() & 0xFF])
		out.append_array(b)
		return out

	static func packet(header: int, body: PackedByteArray) -> PackedByteArray:
		var out := PackedByteArray([header])
		var n := body.size()
		while true:
			var d := n % 128
			n /= 128
			out.append(d | (0x80 if n > 0 else 0))
			if n == 0:
				break
		out.append_array(body)
		return out

	## [total size, header byte, body] for the first complete packet in `buf`, [] if it's still
	## arriving, or [-1] if it's garbage.
	static func split(buf: PackedByteArray) -> Array:
		if buf.size() < 2:
			return []
		var length := 0
		var mult := 1
		var i := 1
		while true:
			if i >= buf.size():
				return []
			var b := buf[i]
			length += (b & 0x7F) * mult
			i += 1
			if b & 0x80 == 0:
				break
			mult *= 128
			if i > 4:
				return [-1]
		if length > 65536:
			return [-1]
		if buf.size() < i + length:
			return []
		return [i + length, buf[0], buf.slice(i, i + length)]


# --- ntfy.sh: subscribe with one streaming HTTPS request, publish with a POST each ---------------

class NtfySub:
	extends RefCounted

	var host := ""
	var http: HTTPClient = null
	var state := "idle"          # idle, connecting, requesting, streaming
	var on_message: Callable     # (topic: String, text: String)
	var _topics: Array = []
	var _line := PackedByteArray()
	var _next_try := 0
	var _fails := 0
	var _since := 0
	var _last_rx := 0

	func _init(h: String) -> void:
		host = h

	func set_topics(t: Array) -> void:
		_topics = t.duplicate()
		close()
		_next_try = 0

	func poll(now: int) -> void:
		if _topics.is_empty():
			return
		match state:
			"idle":
				if now < _next_try:
					return
				http = HTTPClient.new()
				if http.connect_to_host(host, 443, TLSOptions.client()) != OK:
					_fail(now)
					return
				state = "connecting"
				_since = now
			"connecting":
				http.poll()
				var s := http.get_status()
				if s == HTTPClient.STATUS_CONNECTED:
					# since=30s: also get what was published while we were (re)connecting.
					if http.request(HTTPClient.METHOD_GET, "/%s/json?since=30s" % ",".join(_topics), ["User-Agent: GodotCoop"]) != OK:
						_fail(now)
						return
					state = "requesting"
					_since = now
				elif (s != HTTPClient.STATUS_RESOLVING and s != HTTPClient.STATUS_CONNECTING) or now - _since > 15000:
					_fail(now)
			"requesting", "streaming":
				http.poll()
				var s := http.get_status()
				if s == HTTPClient.STATUS_BODY:
					if state == "requesting":
						if http.get_response_code() != 200:
							_fail(now)
							return
						state = "streaming"
						_fails = 0
						_last_rx = now
					for i in 64:
						var chunk := http.read_response_body_chunk()
						if chunk.is_empty():
							break
						_last_rx = now
						_feed(chunk)
					if now - _last_rx > 100000:     # ntfy sends a keep-alive every 45 s
						_fail(now)
				elif s != HTTPClient.STATUS_REQUESTING or now - _since > 20000 and state == "requesting":
					_fail(now)

	func _feed(chunk: PackedByteArray) -> void:
		_line.append_array(chunk)
		while true:
			var nl := _line.find(10)
			if nl == -1:
				if _line.size() > 65536:
					_line.clear()
				return
			var text := _line.slice(0, nl).get_string_from_utf8()
			_line = _line.slice(nl + 1)
			var ev = JSON.parse_string(text)
			if ev is Dictionary and String(ev.get("event", "")) == "message" and on_message.is_valid():
				on_message.call(String(ev.get("topic", "")), String(ev.get("message", "")))

	func close() -> void:
		if http != null:
			http.close()
		http = null
		_line.clear()
		state = "idle"

	func _fail(now: int) -> void:
		close()
		_fails += 1
		_next_try = now + mini(30000, 1000 * (1 << mini(_fails, 5)))


class NtfyPub:
	extends RefCounted

	var http := HTTPClient.new()
	var done := false
	var _topic := ""
	var _text := ""
	var _sent := false
	var _started := 0

	func _init(host: String, topic: String, text: String) -> void:
		_topic = topic
		_text = text
		_started = Time.get_ticks_msec()
		if http.connect_to_host(host, 443, TLSOptions.client()) != OK:
			done = true

	func poll(now: int) -> void:
		if done:
			return
		http.poll()
		var s := http.get_status()
		if not _sent and s == HTTPClient.STATUS_CONNECTED:
			_sent = http.request(HTTPClient.METHOD_POST, "/" + _topic, ["Content-Type: text/plain", "User-Agent: GodotCoop"], _text) == OK
			if not _sent:
				_finish()
		elif _sent and (s == HTTPClient.STATUS_BODY or (s == HTTPClient.STATUS_CONNECTED and http.has_response())):
			_finish()
		elif s == HTTPClient.STATUS_DISCONNECTED or s == HTTPClient.STATUS_CANT_RESOLVE or s == HTTPClient.STATUS_CANT_CONNECT or s == HTTPClient.STATUS_CONNECTION_ERROR or s == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_finish()
		if now - _started > 15000:
			_finish()

	func _finish() -> void:
		http.close()
		done = true
