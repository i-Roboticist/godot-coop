@tool
extends RefCounted
## Client half of the text OT protocol, plus a per-user undo manager.
##
## States (as in ot.js): synchronized, awaiting confirmation (`outstanding`), and awaiting with a
## `buffer` of edits made while waiting. Undo/redo stacks only hold *your* edits, transformed past
## everyone else's, so Ctrl+Z never undoes a teammate's typing.

const OT := preload("res://addons/godot_coop/core/ot.gd")
const Util := preload("res://addons/godot_coop/core/util.gd")

signal send_op(rev: int, op: RefCounted, cseq: int)

const COMPOSE_MS := 700
const MAX_UNDO := 400

var rev := 0
var epoch := ""
var outstanding: RefCounted = null
var outstanding_cseq := 0
var buffer: RefCounted = null
var cseq := 0

var undo_stack: Array = []
var redo_stack: Array = []
var _undo_mode := 0          # 0 normal, 1 undoing, 2 redoing
var _last_local_ms := 0
var _last_kind := ""


func reset(p_rev: int, p_epoch: String) -> void:
	rev = p_rev
	epoch = p_epoch
	outstanding = null
	buffer = null
	undo_stack.clear()
	redo_stack.clear()


func has_pending() -> bool:
	return outstanding != null


## A local edit happened (already applied to the local document). `before` is the text before it.
func apply_client(op: RefCounted, before: String) -> void:
	_record_undo(op, before)
	if outstanding == null:
		cseq += 1
		outstanding = op
		outstanding_cseq = cseq
		send_op.emit(rev, op, cseq)
	elif buffer == null:
		buffer = op
	else:
		var c = buffer.compose(op)
		buffer = c if c != null else op


## The host confirmed our outstanding op.
func server_ack() -> void:
	rev += 1
	if buffer != null:
		cseq += 1
		outstanding = buffer
		outstanding_cseq = cseq
		buffer = null
		send_op.emit(rev, outstanding, cseq)
	else:
		outstanding = null


## Someone else's op arrived (in host terms). Returns the op to apply to the local document.
func apply_server(op: RefCounted) -> RefCounted:
	rev += 1
	if outstanding != null:
		var p := OT.transform(outstanding, op)
		if p.is_empty():
			return null
		outstanding = p[0]
		op = p[1]
		if buffer != null:
			var p2 := OT.transform(buffer, op)
			if p2.is_empty():
				return null
			buffer = p2[0]
			op = p2[1]
	_transform_stacks(op)
	return op


## After a reconnect: re-send whatever the host may not have seen.
func resend() -> void:
	if outstanding != null:
		send_op.emit(rev, outstanding, outstanding_cseq)


# --- per-user undo -------------------------------------------------------------------------

func _record_undo(op: RefCounted, before: String) -> void:
	var inv = op.invert(before)
	var now := Util.now_ms()
	var kind := "ins" if op.is_pure_insert() else ("del" if op.is_pure_delete() else "other")
	if _undo_mode == 1:
		redo_stack.append(inv)
	elif _undo_mode == 2:
		undo_stack.append(inv)
	else:
		var compose := not undo_stack.is_empty() and now - _last_local_ms < COMPOSE_MS and kind == _last_kind and kind != "other"
		if compose:
			var c = inv.compose(undo_stack[-1])
			if c != null:
				undo_stack[-1] = c
			else:
				undo_stack.append(inv)
		else:
			undo_stack.append(inv)
			if undo_stack.size() > MAX_UNDO:
				undo_stack.pop_front()
		redo_stack.clear()
	_last_local_ms = now
	_last_kind = kind


func _transform_stacks(op: RefCounted) -> void:
	undo_stack = _transform_stack(undo_stack, op)
	redo_stack = _transform_stack(redo_stack, op)


static func _transform_stack(stack: Array, op: RefCounted) -> Array:
	var out := []
	for i in range(stack.size() - 1, -1, -1):
		var p := OT.transform(stack[i], op)
		if p.is_empty():
			break
		if not p[0].is_noop():
			out.append(p[0])
		op = p[1]
	out.reverse()
	return out


func can_undo() -> bool:
	return not undo_stack.is_empty()


func can_redo() -> bool:
	return not redo_stack.is_empty()


## Returns the op that undoes your last edit (apply it locally, then call finish_undo_redo(op, before)).
func pop_undo() -> RefCounted:
	if undo_stack.is_empty():
		return null
	_undo_mode = 1
	return undo_stack.pop_back()


func pop_redo() -> RefCounted:
	if redo_stack.is_empty():
		return null
	_undo_mode = 2
	return redo_stack.pop_back()


func finish_undo_redo(op: RefCounted, before: String) -> void:
	apply_client(op, before)
	_undo_mode = 0
	_last_kind = ""
