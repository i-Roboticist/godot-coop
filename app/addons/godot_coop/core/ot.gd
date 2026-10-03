@tool
extends RefCounted
## Operational transformation for plain text (a GDScript port of ot.js's TextOperation).
##
## An operation is a list of components: positive int = retain n chars, negative int = delete n
## chars, String = insert text. The host orders operations; clients transform concurrent edits so
## everyone converges on the same text, Google-Docs style.

var ops: Array = []
var base_length := 0
var target_length := 0


static func create() -> RefCounted:
	return load("res://addons/godot_coop/core/ot.gd").new()


static func _is_retain(c) -> bool:
	return typeof(c) == TYPE_INT and c > 0


static func _is_delete(c) -> bool:
	return typeof(c) == TYPE_INT and c < 0


static func _is_insert(c) -> bool:
	return typeof(c) == TYPE_STRING


static func _at(arr: Array, i: int):
	return arr[i] if i < arr.size() else null


func retain(n: int) -> RefCounted:
	if n <= 0:
		return self
	base_length += n
	target_length += n
	if not ops.is_empty() and _is_retain(ops[-1]):
		ops[-1] += n
	else:
		ops.append(n)
	return self


func insert(s: String) -> RefCounted:
	if s.is_empty():
		return self
	target_length += s.length()
	if not ops.is_empty() and _is_insert(ops[-1]):
		ops[-1] += s
	elif not ops.is_empty() and _is_delete(ops[-1]):
		# Keep inserts before deletes so equal operations have one canonical form.
		if ops.size() >= 2 and _is_insert(ops[-2]):
			ops[-2] += s
		else:
			var last = ops[-1]
			ops[-1] = s
			ops.append(last)
	else:
		ops.append(s)
	return self


func delete(n: int) -> RefCounted:
	if n == 0:
		return self
	if n > 0:
		n = -n
	base_length -= n
	if not ops.is_empty() and _is_delete(ops[-1]):
		ops[-1] += n
	else:
		ops.append(n)
	return self


func is_noop() -> bool:
	return ops.is_empty() or (ops.size() == 1 and _is_retain(ops[0]))


func apply(text: String):
	if text.length() != base_length:
		return null
	var parts := PackedStringArray()
	var idx := 0
	for c in ops:
		if _is_retain(c):
			if idx + c > text.length():
				return null
			parts.append(text.substr(idx, c))
			idx += c
		elif _is_insert(c):
			parts.append(c)
		else:
			idx -= c
	if idx != text.length():
		return null
	return "".join(parts)


func invert(text: String) -> RefCounted:
	var inv := create()
	var idx := 0
	for c in ops:
		if _is_retain(c):
			inv.retain(c)
			idx += c
		elif _is_insert(c):
			inv.delete(c.length())
		else:
			inv.insert(text.substr(idx, -c))
			idx -= c
	return inv


## Returns the operation equivalent to applying self then other, or null if they don't line up.
func compose(other: RefCounted) -> RefCounted:
	if target_length != other.base_length:
		return null
	var out := create()
	var ops1: Array = ops.duplicate()
	var ops2: Array = other.ops.duplicate()
	var i1 := 0
	var i2 := 0
	var op1 = _at(ops1, i1)
	i1 += 1
	var op2 = _at(ops2, i2)
	i2 += 1
	while true:
		if op1 == null and op2 == null:
			break
		if _is_delete(op1):
			out.delete(op1)
			op1 = _at(ops1, i1)
			i1 += 1
			continue
		if _is_insert(op2):
			out.insert(op2)
			op2 = _at(ops2, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			return null
		if _is_retain(op1) and _is_retain(op2):
			if op1 > op2:
				out.retain(op2)
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				out.retain(op1)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.retain(op1)
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_insert(op1) and _is_delete(op2):
			if op1.length() > -op2:
				op1 = op1.substr(-op2)
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1.length() == -op2:
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				op2 = op2 + op1.length()
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_insert(op1) and _is_retain(op2):
			if op1.length() > op2:
				out.insert(op1.substr(0, op2))
				op1 = op1.substr(op2)
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1.length() == op2:
				out.insert(op1)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.insert(op1)
				op2 = op2 - op1.length()
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_retain(op1) and _is_delete(op2):
			if op1 > -op2:
				out.delete(op2)
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == -op2:
				out.delete(op2)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.delete(op1)
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
		else:
			return null
	return out


## Given two operations made concurrently on the same text, returns [a', b'] such that
## apply(apply(s, a), b') == apply(apply(s, b), a'). Returns [] when they don't line up.
static func transform(a: RefCounted, b: RefCounted) -> Array:
	if a.base_length != b.base_length:
		return []
	var a2 := create()
	var b2 := create()
	var ops1: Array = a.ops.duplicate()
	var ops2: Array = b.ops.duplicate()
	var i1 := 0
	var i2 := 0
	var op1 = _at(ops1, i1)
	i1 += 1
	var op2 = _at(ops2, i2)
	i2 += 1
	while true:
		if op1 == null and op2 == null:
			break
		if _is_insert(op1):
			a2.insert(op1)
			b2.retain(op1.length())
			op1 = _at(ops1, i1)
			i1 += 1
			continue
		if _is_insert(op2):
			a2.retain(op2.length())
			b2.insert(op2)
			op2 = _at(ops2, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			return []
		var minl := 0
		if _is_retain(op1) and _is_retain(op2):
			if op1 > op2:
				minl = op2
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				minl = op2
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = op1
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
			a2.retain(minl)
			b2.retain(minl)
		elif _is_delete(op1) and _is_delete(op2):
			if -op1 > -op2:
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_delete(op1) and _is_retain(op2):
			if -op1 > op2:
				minl = op2
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif -op1 == op2:
				minl = op2
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = -op1
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
			a2.delete(minl)
		elif _is_retain(op1) and _is_delete(op2):
			if op1 > -op2:
				minl = -op2
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == -op2:
				minl = op1
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = op1
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
			b2.delete(minl)
		else:
			return []
	return [a2, b2]


func to_array() -> Array:
	return ops.duplicate()


static func from_array(arr) -> RefCounted:
	if not (arr is Array):
		return null
	var op := create()
	for c in arr:
		if typeof(c) == TYPE_INT:
			if c > 0:
				op.retain(c)
			elif c < 0:
				op.delete(c)
			else:
				return null
		elif typeof(c) == TYPE_STRING:
			op.insert(c)
		else:
			return null
	return op


const MAX_DIFF_STEPS := 400
const MAX_DIFF_LINES := 20000


## Edit turning `before` into `after`. Changes in separate places (several carets, Replace All)
## become separate parts of one operation, so a teammate's edit between them stays where it was.
## `cursor` is the caret offset in `after` (or -1). When the same edit could sit in several places
## (typing a character equal to its neighbour, Enter above an indented line), it ends at the caret.
static func diff(before: String, after: String, cursor := -1) -> RefCounted:
	return _op_from_hunks(before, after, _hunks(before, after, cursor))


## Three-way merge: the changes from `base` to `ours` and from `base` to `theirs`, combined.
## Changes in different places are both kept. Where they overlap: identical changes are kept once,
## an insert that contains the other side's insert wins (e.g. "extends Node" vs "extends Node" plus
## a line typed since), and anything else keeps both, theirs first.
static func merge3(base: String, ours: String, theirs: String) -> String:
	if ours == theirs or theirs == base:
		return ours
	if ours == base:
		return theirs
	var all := []   # [b0, b1, side (0 ours / 1 theirs), text]
	for h in _hunks(base, ours):
		all.append([h[0], h[1], 0, ours.substr(h[2], h[3] - h[2])])
	for h in _hunks(base, theirs):
		all.append([h[0], h[1], 1, theirs.substr(h[2], h[3] - h[2])])
	all.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	var out := PackedStringArray()
	var idx := 0
	var i := 0
	while i < all.size():
		# Gather a cluster of overlapping changes (inserts at the same point count as overlapping).
		var c0: int = all[i][0]
		var c1: int = all[i][1]
		var members := [all[i]]
		i += 1
		while i < all.size():
			var h: Array = all[i]
			var overlaps: bool = h[0] < c1 or (h[0] == c1 and (h[0] == h[1] or c0 == c1))
			if not overlaps:
				break
			c1 = maxi(c1, h[1])
			members.append(h)
			i += 1
		out.append(base.substr(idx, c0 - idx))
		idx = c1
		var mid := base.substr(c0, c1 - c0)
		var versions := ["", ""]
		var sides := {}
		for side in 2:
			var parts := PackedStringArray()
			var at := c0
			for h in members:
				if h[2] == side:
					sides[side] = true
					parts.append(base.substr(at, h[0] - at))
					parts.append(h[3])
					at = h[1]
			parts.append(base.substr(at, c1 - at))
			versions[side] = "".join(parts)
		var o: String = versions[0]
		var t: String = versions[1]
		if sides.size() < 2 or o == t:
			out.append(o if sides.has(0) else t)
		elif mid.is_empty():
			if o.begins_with(t) or o.ends_with(t):
				out.append(o)
			elif t.begins_with(o) or t.ends_with(o):
				out.append(t)
			else:
				out.append(t + o)
		else:
			var p := transform(diff(mid, o), diff(mid, t))
			var r = p[0].apply(t) if not p.is_empty() else null
			out.append(r if r != null else t)
	out.append(base.substr(idx))
	return "".join(out)


static func _op_from_hunks(before: String, after: String, hunks: Array) -> RefCounted:
	var op := create()
	var idx := 0
	for h in hunks:
		op.retain(h[0] - idx)
		op.insert(after.substr(h[2], h[3] - h[2]))
		op.delete(h[1] - h[0])
		idx = h[1]
	op.retain(before.length() - idx)
	return op


## Changed regions as [before_start, before_end, after_start, after_end], in order.
static func _hunks(before: String, after: String, cursor := -1) -> Array:
	if before == after:
		return []
	var lb := before.length()
	var la := after.length()
	var pre := 0
	var maxpre := mini(lb, la)
	while pre < maxpre and before.unicode_at(pre) == after.unicode_at(pre):
		pre += 1
	var suf := 0
	var maxsuf := maxpre - pre
	while suf < maxsuf and before.unicode_at(lb - 1 - suf) == after.unicode_at(la - 1 - suf):
		suf += 1
	var hunks := [[pre, lb - suf, pre, la - suf]]
	var mid_b := before.substr(pre, lb - suf - pre)
	var mid_a := after.substr(pre, la - suf - pre)
	if mid_b.contains("\n") and mid_a.contains("\n"):
		var split := _line_hunks(mid_b, mid_a)
		if split.size() > 1:
			hunks = []
			for h in split:
				var t := _trim_hunk(before, after, [h[0] + pre, h[1] + pre, h[2] + pre, h[3] + pre])
				if not t.is_empty():
					hunks.append(t)
	if hunks.size() == 1 and cursor >= 0:
		hunks[0] = _slide_to_cursor(before, after, hunks[0], cursor)
	return hunks


static func _trim_hunk(before: String, after: String, h: Array) -> Array:
	var b0: int = h[0]
	var b1: int = h[1]
	var a0: int = h[2]
	var a1: int = h[3]
	while b0 < b1 and a0 < a1 and before.unicode_at(b0) == after.unicode_at(a0):
		b0 += 1
		a0 += 1
	while b1 > b0 and a1 > a0 and before.unicode_at(b1 - 1) == after.unicode_at(a1 - 1):
		b1 -= 1
		a1 -= 1
	if b0 == b1 and a0 == a1:
		return []
	return [b0, b1, a0, a1]


## A pure insert or delete can often move left without changing the result ("aa" + "a" at either
## end). Move it until it ends at the caret, which is where the user actually typed.
static func _slide_to_cursor(before: String, after: String, h: Array, cursor: int) -> Array:
	var b0: int = h[0]
	var b1: int = h[1]
	var a0: int = h[2]
	var a1: int = h[3]
	if b0 == b1:
		while a1 > cursor and b0 > 0 and before.unicode_at(b0 - 1) == after.unicode_at(a1 - 1):
			b0 -= 1
			b1 -= 1
			a0 -= 1
			a1 -= 1
	elif a0 == a1:
		while a0 > cursor and b0 > 0 and before.unicode_at(b0 - 1) == before.unicode_at(b1 - 1):
			b0 -= 1
			b1 -= 1
			a0 -= 1
			a1 -= 1
	return [b0, b1, a0, a1]


static func _lines(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var start := 0
	while start < s.length():
		var nl := s.find("\n", start)
		if nl == -1:
			out.append(s.substr(start))
			break
		out.append(s.substr(start, nl - start + 1))
		start = nl + 1
	return out


## Line-level diff of two texts as char-offset hunks, or [] when they're too different to bother.
static func _line_hunks(b_text: String, a_text: String) -> Array:
	var lb := _lines(b_text)
	var la := _lines(a_text)
	if lb.size() + la.size() > MAX_DIFF_LINES:
		return []
	var script := _myers(lb, la)
	if script.is_empty():
		return []
	var hunks := []
	var ib := 0
	var ia := 0
	var ob := 0
	var oa := 0
	var cur := []
	for s in script:
		if s == 0:
			if not cur.is_empty():
				hunks.append([cur[0], ob, cur[1], oa])
				cur = []
			ob += lb[ib].length()
			oa += la[ia].length()
			ib += 1
			ia += 1
		else:
			if cur.is_empty():
				cur = [ob, oa]
			if s == 1:
				ob += lb[ib].length()
				ib += 1
			else:
				oa += la[ia].length()
				ia += 1
	if not cur.is_empty():
		hunks.append([cur[0], ob, cur[1], oa])
	return hunks


## Myers' shortest edit script: 0 = keep a line, 1 = delete a[i], 2 = insert b[j]. [] if it would
## take more than MAX_DIFF_STEPS edits.
static func _myers(a: PackedStringArray, b: PackedStringArray) -> Array:
	var n := a.size()
	var m := b.size()
	var maxd := mini(n + m, MAX_DIFF_STEPS)
	var off := maxd + 1
	var v := PackedInt32Array()
	v.resize(2 * maxd + 3)
	v.fill(0)
	var trace: Array = []
	var found := false
	for d in range(maxd + 1):
		trace.append(v.duplicate())
		for k in range(-d, d + 1, 2):
			var x: int
			if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]):
				x = v[off + k + 1]
			else:
				x = v[off + k - 1] + 1
			var y := x - k
			while x < n and y < m and a[x] == b[y]:
				x += 1
				y += 1
			v[off + k] = x
			if x >= n and y >= m:
				found = true
				break
		if found:
			break
	if not found:
		return []
	var script := []
	var x := n
	var y := m
	for d in range(trace.size() - 1, -1, -1):
		var vv: PackedInt32Array = trace[d]
		var k := x - y
		var prev_k := k + 1 if k == -d or (k != d and vv[off + k - 1] < vv[off + k + 1]) else k - 1
		var prev_x := vv[off + prev_k]
		var prev_y := prev_x - prev_k
		while x > prev_x and y > prev_y:
			script.append(0)
			x -= 1
			y -= 1
		if d > 0:
			script.append(2 if x == prev_x else 1)
		x = prev_x
		y = prev_y
	script.reverse()
	return script


## Moves a cursor offset through an operation (used for remote carets).
func transform_index(index: int) -> int:
	var new_index := index
	var rem := index
	for c in ops:
		if _is_retain(c):
			rem -= c
		elif _is_insert(c):
			new_index += c.length()
		else:
			new_index -= mini(rem, -c)
			rem += c
		if rem < 0:
			break
	return maxi(new_index, 0)


func is_pure_insert() -> bool:
	var inserts := 0
	for c in ops:
		if _is_delete(c):
			return false
		if _is_insert(c):
			inserts += 1
	return inserts == 1


func is_pure_delete() -> bool:
	var deletes := 0
	for c in ops:
		if _is_insert(c):
			return false
		if _is_delete(c):
			deletes += 1
	return deletes == 1
