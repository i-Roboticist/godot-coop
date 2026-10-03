@tool
extends RefCounted
## Host-side live text document (one per script that someone has open). Orders edits and
## transforms late ones against everything that happened since the sender's revision.

const OT := preload("res://addons/godot_coop/core/ot.gd")
const MAX_HISTORY := 5000

var path := ""
var epoch := ""
var text := ""
var rev := 0
var history: Array = []      # [op, by_uuid, cseq, cid]; history[i] moved the doc from rev (history_base+i)
var history_base := 0
var watchers := {}           # peer id -> true
var last_cseq := {}          # "uuid|cid" -> highest cseq applied (dedupes resends after reconnects)
var disk_text := ""          # the file as last seen on disk: the base for merging edits made outside
var missing := false         # created for a file the host doesn't have yet
var orphaned_ms := 0         # everyone dropped off; kept for a while so they can resume


func _init(p_path := "", p_text := "") -> void:
	path = p_path
	text = p_text.replace("\r\n", "\n")
	disk_text = text
	epoch = str(randi()) + str(Time.get_ticks_usec())


## Returns the transformed op (in current-doc terms) or null when it can't be applied.
func receive(client_rev: int, op: RefCounted, by_uuid: String, cseq: int, cid := "") -> RefCounted:
	if client_rev < history_base or client_rev > rev:
		return null
	for i in range(client_rev - history_base, history.size()):
		var pair := OT.transform(op, history[i][0])
		if pair.is_empty():
			return null
		op = pair[0]
	var nt = op.apply(text)
	if nt == null:
		return null
	text = nt
	history.append([op, by_uuid, cseq, cid])
	rev += 1
	missing = false
	last_cseq[by_uuid + "|" + cid] = cseq
	if history.size() > MAX_HISTORY:
		history.pop_front()
		history_base += 1
	return op


func is_duplicate(by_uuid: String, cseq: int, cid := "") -> bool:
	return cseq <= int(last_cseq.get(by_uuid + "|" + cid, 0))


## Operations since `from_rev` as wire data, or null if that history is gone.
func ops_since(from_rev: int):
	if from_rev < history_base or from_rev > rev:
		return null
	var out := []
	for i in range(from_rev - history_base, history.size()):
		var h: Array = history[i]
		out.append([h[0].to_array(), h[1], h[2], h[3]])
	return out
