@tool
extends EditorPlugin

const _META_PATCHED := &"_add_gdscript_patched"
const _META_CHECKBOX := &"_add_gdscript_checkbox"
const _META_EXTENSION_PICKER := &"_extension_picker"
const _META_OTHER_TYPE_EDIT := &"_other_type_edit"
const _META_EXTENSION_CALLABLE := &"_add_gdscript_extension_callable"
const _META_VISIBILITY_CALLABLE := &"_add_gdscript_visibility_callable"
const _META_CONFIRMED_CALLABLE := &"_add_gdscript_confirmed_callable"

const _ROOT_2D := 0
const _ROOT_3D := 1
const _ROOT_UI := 2
const _ROOT_OTHER := 3

var _patched_dialogs: Array[Node] = []


func _enter_tree() -> void:
	get_tree().node_added.connect(_on_node_added)
	var base := EditorInterface.get_base_control()
	if base:
		_scan(base)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for dialog in _patched_dialogs:
		if is_instance_valid(dialog):
			_unpatch(dialog)
	_patched_dialogs.clear()


func _on_node_added(node: Node) -> void:
	if node.get_class() == "SceneCreateDialog":
		_patch(node)


func _scan(node: Node) -> void:
	if node.get_class() == "SceneCreateDialog":
		_patch(node)
	for child in node.get_children():
		_scan(child)


func _patch(dialog: Node) -> void:
	if dialog.has_meta(_META_PATCHED):
		return

	var picker := _find_extension_picker(dialog)
	var main_vb := _main_vbox_from_picker(picker)
	if picker == null or main_vb == null:
		push_warning("Add Script With Scene: could not find the Create New Scene dialog layout.")
		return

	var checkbox := CheckBox.new()
	checkbox.name = "AddGDScriptCheckBox"
	checkbox.text = "Add GDScript"
	checkbox.button_pressed = true
	var validation_index := _validation_index(main_vb)
	main_vb.add_child(checkbox)
	if validation_index >= 0:
		main_vb.move_child(checkbox, validation_index)

	var other_edit := _find_other_type_edit(dialog)
	var extension_callable := _on_extension_selected.bind(dialog)
	var visibility_callable := _on_dialog_visibility_changed.bind(dialog)
	var confirmed_callable := _on_dialog_confirmed.bind(dialog)

	dialog.set_meta(_META_PATCHED, true)
	dialog.set_meta(_META_CHECKBOX, checkbox)
	dialog.set_meta(_META_EXTENSION_PICKER, picker)
	dialog.set_meta(_META_EXTENSION_CALLABLE, extension_callable)
	dialog.set_meta(_META_VISIBILITY_CALLABLE, visibility_callable)
	dialog.set_meta(_META_CONFIRMED_CALLABLE, confirmed_callable)
	if other_edit:
		dialog.set_meta(_META_OTHER_TYPE_EDIT, other_edit)

	picker.item_selected.connect(extension_callable)
	dialog.visibility_changed.connect(visibility_callable)
	# Run before the dock saves the scene, but not via call_deferred: filesystem updates
	# open a progress dialog, which Godot rejects while the message queue is flushing.
	_connect_before_existing(dialog.confirmed, _prepare_new_scene)
	dialog.confirmed.connect(confirmed_callable)

	_update_checkbox_enabled(dialog)
	_patched_dialogs.append(dialog)


func _unpatch(dialog: Node) -> void:
	if not dialog.has_meta(_META_PATCHED):
		return

	var picker: OptionButton = dialog.get_meta(_META_EXTENSION_PICKER)
	var extension_callable: Callable = dialog.get_meta(_META_EXTENSION_CALLABLE)
	var visibility_callable: Callable = dialog.get_meta(_META_VISIBILITY_CALLABLE)
	var confirmed_callable: Callable = dialog.get_meta(_META_CONFIRMED_CALLABLE)

	if is_instance_valid(picker) and picker.item_selected.is_connected(extension_callable):
		picker.item_selected.disconnect(extension_callable)
	if dialog.visibility_changed.is_connected(visibility_callable):
		dialog.visibility_changed.disconnect(visibility_callable)
	if dialog.confirmed.is_connected(confirmed_callable):
		dialog.confirmed.disconnect(confirmed_callable)
	if dialog.confirmed.is_connected(_prepare_new_scene):
		dialog.confirmed.disconnect(_prepare_new_scene)

	var checkbox: CheckBox = dialog.get_meta(_META_CHECKBOX)
	if is_instance_valid(checkbox):
		checkbox.free()

	for key in [
		_META_PATCHED,
		_META_CHECKBOX,
		_META_EXTENSION_PICKER,
		_META_OTHER_TYPE_EDIT,
		_META_EXTENSION_CALLABLE,
		_META_VISIBILITY_CALLABLE,
		_META_CONFIRMED_CALLABLE,
	]:
		if dialog.has_meta(key):
			dialog.remove_meta(key)


func _connect_before_existing(sig: Signal, callable: Callable) -> void:
	var existing: Array = sig.get_connections()
	for connection in existing:
		sig.disconnect(connection["callable"])
	sig.connect(callable)
	for connection in existing:
		sig.connect(connection["callable"], int(connection.get("flags", 0)))


func _prepare_new_scene() -> void:
	# Godot 4.7 still has the previous Scene dock selection when it shows the new scene.
	# That node has already left the tree, so asking for its path prints an error.
	EditorInterface.inspect_object(null)


func _on_extension_selected(_index: int, dialog: Node) -> void:
	if is_instance_valid(dialog):
		_update_checkbox_enabled(dialog)


func _on_dialog_visibility_changed(dialog: Node) -> void:
	if is_instance_valid(dialog) and dialog.visible:
		_update_checkbox_enabled(dialog)


func _update_checkbox_enabled(dialog: Node) -> void:
	var checkbox: CheckBox = dialog.get_meta(_META_CHECKBOX)
	var picker: OptionButton = dialog.get_meta(_META_EXTENSION_PICKER)
	if not is_instance_valid(checkbox) or not is_instance_valid(picker):
		return
	checkbox.disabled = str(picker.get_selected_metadata()) != "tscn"


func _on_dialog_confirmed(dialog: Node) -> void:
	if not is_instance_valid(dialog) or not dialog.has_meta(_META_CHECKBOX):
		return

	var checkbox: CheckBox = dialog.get_meta(_META_CHECKBOX)
	var picker: OptionButton = dialog.get_meta(_META_EXTENSION_PICKER)
	if not is_instance_valid(checkbox) or not is_instance_valid(picker):
		return
	if checkbox.disabled or not checkbox.button_pressed:
		return
	if str(picker.get_selected_metadata()) != "tscn":
		return

	var name_edit := _scene_name_edit(picker)
	if name_edit == null:
		_warn("Could not read the scene name.")
		return

	var filename := _compose_filename(name_edit.text, str(picker.get_selected_metadata()))
	var extends_type := _resolve_extends(dialog)
	if _resolve_scene_path(filename).is_empty():
		# A handler connected after ours still has to save the scene. Wait until the next
		# frame so that work finishes outside call_deferred.
		get_tree().process_frame.connect(_apply_script.bind(filename, extends_type), CONNECT_ONE_SHOT)
	else:
		_apply_script(filename, extends_type)


func _apply_script(filename: String, extends_type: String) -> void:
	var scene_path := _resolve_scene_path(filename)
	if scene_path.is_empty():
		_warn("Could not find the new scene file '%s'." % filename)
		return

	var script_path := scene_path.get_basename() + ".gd"
	if FileAccess.file_exists(script_path):
		_warn("Script already exists: %s" % script_path)
		return

	var script_class := _make_class_name(filename.get_basename())
	if script_class.is_empty():
		_warn("Could not make a valid class_name from '%s'. The script will omit class_name." % filename.get_basename())

	var script := GDScript.new()
	script.source_code = _script_source(script_class, extends_type)
	script.resource_path = script_path
	var err := ResourceSaver.save(script, script_path)
	if err != OK:
		_warn("Failed to save script '%s': %s" % [script_path, error_string(err)])
		return

	var filesystem := EditorInterface.get_resource_filesystem()
	filesystem.update_file(script_path)
	var loaded := load(script_path) as Script
	if loaded == null:
		_warn("Failed to load the new script '%s'." % script_path)
		return

	var root := EditorInterface.get_edited_scene_root()
	if root and root.scene_file_path.get_file() == filename:
		root.set_script(loaded)
		EditorInterface.edit_node(root)
		var save_err := EditorInterface.save_scene()
		if save_err != OK:
			_warn("Failed to save scene '%s': %s" % [root.scene_file_path, error_string(save_err)])
			return
		filesystem.update_file(root.scene_file_path)
		return

	var packed := load(scene_path) as PackedScene
	if packed == null:
		_warn("Failed to load scene '%s'." % scene_path)
		return

	var inst := packed.instantiate()
	inst.set_script(loaded)
	# pack() asks for the node's path, which requires it to be in a tree.
	var tree_root := EditorInterface.get_base_control().get_tree().root
	tree_root.add_child(inst)
	var repacked := PackedScene.new()
	var pack_err := repacked.pack(inst)
	tree_root.remove_child(inst)
	inst.free()
	if pack_err != OK:
		_warn("Failed to pack scene '%s': %s" % [scene_path, error_string(pack_err)])
		return

	var save_err := ResourceSaver.save(repacked, scene_path)
	if save_err != OK:
		_warn("Failed to save scene '%s': %s" % [scene_path, error_string(save_err)])
		return
	filesystem.update_file(scene_path)


func _resolve_scene_path(filename: String) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root and root.scene_file_path.get_file() == filename:
		return root.scene_file_path

	var candidate := EditorInterface.get_current_directory().path_join(filename)
	if FileAccess.file_exists(candidate):
		return candidate
	return ""


func _resolve_extends(dialog: Node) -> String:
	var pressed := _pressed_root_checkbox(dialog)
	if pressed == null:
		return "Node"

	match int(pressed.get_meta("type")):
		_ROOT_2D:
			return "Node2D"
		_ROOT_3D:
			return "Node3D"
		_ROOT_UI:
			return "Control"
		_ROOT_OTHER:
			return _extends_from_other(dialog)
		_:
			return "Node"


func _extends_from_other(dialog: Node) -> String:
	if not dialog.has_meta(_META_OTHER_TYPE_EDIT):
		return "Node"
	var edit: LineEdit = dialog.get_meta(_META_OTHER_TYPE_EDIT)
	if not is_instance_valid(edit):
		return "Node"

	var text := edit.text.strip_edges()
	if text.is_empty():
		return "Node"

	var token := text.get_slice(" ", 0)
	if token.begins_with("res://") or token.get_extension() in ["gd", "cs"]:
		var global_name := _global_class_for_path(token)
		if not global_name.is_empty():
			return global_name
		return "\"%s\"" % token
	return token


func _global_class_for_path(path: String) -> String:
	var wanted := path.simplify_path()
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("path", "")).simplify_path() == wanted:
			return str(entry.get("class", ""))
	return ""


func _pressed_root_checkbox(dialog: Node) -> CheckBox:
	for node in dialog.find_children("*", "CheckBox", true, false):
		var box := node as CheckBox
		if box.has_meta("type") and box.button_pressed:
			return box
	return null


func _find_extension_picker(dialog: Node) -> OptionButton:
	for node in dialog.find_children("*", "OptionButton", true, false):
		var option := node as OptionButton
		if option.item_count == 0:
			continue
		var meta := str(option.get_item_metadata(0))
		if meta == "tscn" or meta == "scn":
			return option
	return null


func _main_vbox_from_picker(picker: OptionButton) -> VBoxContainer:
	if picker == null or picker.get_parent() == null or picker.get_parent().get_parent() == null:
		return null
	return picker.get_parent().get_parent().get_parent() as VBoxContainer


func _validation_index(main_vb: VBoxContainer) -> int:
	for i in main_vb.get_child_count():
		if main_vb.get_child(i).get_class() == "EditorValidationPanel":
			return i
	return -1


func _find_other_type_edit(dialog: Node) -> LineEdit:
	for node in dialog.find_children("*", "CheckBox", true, false):
		var box := node as CheckBox
		if not box.has_meta("type") or int(box.get_meta("type")) != _ROOT_OTHER:
			continue
		var parent := box.get_parent()
		if parent == null:
			return null
		for sibling in parent.get_children():
			if sibling is LineEdit:
				return sibling
	return null


func _scene_name_edit(picker: OptionButton) -> LineEdit:
	var parent := picker.get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is LineEdit:
			return child
	return null


func _compose_filename(scene_name: String, extension: String) -> String:
	var filename := scene_name.strip_edges()
	if not filename.ends_with("."):
		filename += "."
	return filename + extension


func _make_class_name(basename: String) -> String:
	var script_class := basename.to_pascal_case()
	if script_class.is_empty():
		return ""
	if not script_class.is_valid_identifier():
		script_class = "_" + script_class
	if not script_class.is_valid_identifier():
		return ""
	return script_class


func _script_source(script_class: String, extends_type: String) -> String:
	var lines: PackedStringArray = []
	if not script_class.is_empty():
		lines.append("class_name %s" % script_class)
		lines.append("")
	lines.append("extends %s" % extends_type)
	lines.append("")
	lines.append("")
	lines.append("# Called when the node enters the scene tree for the first time.")
	lines.append("func _ready() -> void:")
	lines.append("\tpass # Replace with function body.")
	lines.append("")
	return "\n".join(lines)


func _warn(message: String) -> void:
	push_warning("Add Script With Scene: " + message)
	var toaster := EditorInterface.get_editor_toaster()
	if toaster:
		toaster.push_toast(message, EditorToaster.SEVERITY_WARNING)
