@tool
extends RefCounted
## Project Settings sync. project.godot isn't synced as a file while editors are open (each editor
## keeps its own copy in memory and would overwrite it); instead individual setting changes are
## sent and applied through the ProjectSettings API. Changes to autoloads or enabled editor
## plugins can run code, so they wait for your approval.

const Wire := preload("res://addons/godot_coop/core/wire.gd")
const Util := preload("res://addons/godot_coop/core/util.gd")
const Net := preload("res://addons/godot_coop/core/net.gd")

const RISKY_PREFIXES := ["autoload/", "editor_plugins/"]

var plugin
var _wire := Wire.new()
var _snapshot := {}
var held: Array = []          # [{"by", "set", "erase"}] waiting for review
var _due := false


func _session():
	return plugin.session


func setup(p) -> void:
	plugin = p


func session_started() -> void:
	_snapshot = _capture()


func _capture() -> Dictionary:
	var out := {}
	for p in ProjectSettings.get_property_list():
		if not (p.usage & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = p.name
		if name.begins_with("_") or name.find("/") == -1:
			continue
		out[name] = _wire.to_wire(ProjectSettings.get_setting(name))
	return out


func on_project_settings_changed() -> void:
	_due = true


func process() -> void:
	if not _due:
		return
	_due = false
	var now := _capture()
	var changed := {}
	var erased := []
	for k in now:
		if not _snapshot.has(k) or not Util.same(now[k], _snapshot[k]):
			changed[k] = now[k]
	for k in _snapshot:
		if not now.has(k):
			erased.append(k)
	_snapshot = now
	if changed.is_empty() and erased.is_empty():
		return
	if not _session().can_edit():
		plugin.toast("You're a viewer, so project setting changes aren't shared.", 1)
		return
	_session().send({"t": "proj_set", "set": changed, "erase": erased}, Net.CH_CTRL)


static func _is_risky(keys: Array) -> bool:
	for k in keys:
		for p in RISKY_PREFIXES:
			if String(k).begins_with(p):
				return true
	return false


func on_message(m: Dictionary) -> void:
	match String(m.get("t", "")):
		"proj_set", "proj_full":
			# Send our own pending change first, so applying this doesn't swallow it.
			if _due:
				process()
			var changes: Dictionary = m.get("set", {}) if m.get("set") is Dictionary else {}
			var removed: Array = m.get("erase", []) if m.get("erase") is Array else []
			if m.t == "proj_full":
				# Only take what differs from ours.
				var mine := _capture()
				var diff := {}
				for k in changes:
					if not mine.has(k) or not Util.same(mine[k], changes[k]):
						diff[k] = changes[k]
				changes = diff
				removed = []
			if changes.is_empty() and removed.is_empty():
				return
			var keys := changes.keys() + removed
			var own: bool = m.t == "proj_set" and int(m.get("by", 0)) == _session().my_pid
			if _is_risky(keys) and not plugin.trust_host and not own:
				held.append({"by": int(m.get("by", 1)), "set": changes, "erase": removed})
				plugin.notify("%s changed autoloads or editor plugins. Review it in the Co-op dock." % _session().peer_name(int(m.get("by", 1))), Color.ORANGE, Callable())
				plugin.refresh_ui()
				return
			_apply(changes, removed)
		"proj_get":
			# Host: a newly joined editor wants our settings.
			_session().send({"t": "proj_full", "to": int(m.get("from", 0)), "set": _capture()}, Net.CH_CTRL)


func accept_held(i: int) -> void:
	if i < 0 or i >= held.size():
		return
	var h: Dictionary = held[i]
	held.remove_at(i)
	_apply(h["set"], h["erase"])
	plugin.refresh_ui()


func reject_held(i: int) -> void:
	if i >= 0 and i < held.size():
		held.remove_at(i)
	plugin.refresh_ui()


func _apply(changes: Dictionary, removed: Array) -> void:
	for k in changes:
		ProjectSettings.set_setting(String(k), _wire.from_wire(changes[k]))
	for k in removed:
		ProjectSettings.set_setting(String(k), null)
	_snapshot = _capture()
	ProjectSettings.save()
	_snapshot = _capture()
	_due = false
