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


## Smallest single-range edit turning `before` into `after`.
static func diff(before: String, after: String) -> RefCounted:
	var op := create()
	if before == after:
		op.retain(before.length())
		return op
	var lb := before.length()
	var la := after.length()
	var pre := 0
	var maxpre := mini(lb, la)
	while pre < maxpre and before.unicode_at(pre) == after.unicode_at(pre):
		pre += 1
	var suf := 0
	var maxsuf := mini(lb, la) - pre
	while suf < maxsuf and before.unicode_at(lb - 1 - suf) == after.unicode_at(la - 1 - suf):
		suf += 1
	op.retain(pre)
	op.insert(after.substr(pre, la - pre - suf))
	op.delete(lb - pre - suf)
	op.retain(suf)
	return op


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
