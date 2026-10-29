@tool
extends EditorPlugin
## Registers the native Android bridge with Godot's Android exporter
## (Godot Android plugin v2). Requires "Use Gradle Build" in the export preset.

const PLUGIN_NAME := "NexusVpnBridge"
## Paths are relative to res://addons/.
const LIBRARIES := [
	"android_vpn_bridge/bin/nexus_vpn_bridge-release.aar",
	"android_vpn_bridge/bin/libbox.aar",
]
## Maven dependencies of the bridge (must match android/nexus_vpn_bridge/build.gradle.kts).
const DEPENDENCIES := [
	"com.google.zxing:core:3.5.3",
	"com.google.android.gms:play-services-code-scanner:16.1.0",
]

var _export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	func _get_name() -> String:
		return PLUGIN_NAME

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		for lib in LIBRARIES:
			if not FileAccess.file_exists("res://addons/" + lib):
				push_error("%s: missing %s — run tools/build_libbox.sh and tools/build_android_plugin.sh" % [PLUGIN_NAME, lib])
		return PackedStringArray(LIBRARIES)

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(DEPENDENCIES)
