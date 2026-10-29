# The Godot plugin registry instantiates the plugin by reflection.
-keep class com.nexusvpn.bridge.NexusVpnPlugin { *; }
-keep class com.nexusvpn.bridge.** { *; }
# gomobile-generated bindings are called from native code.
-keep class io.nekohasekai.libbox.** { *; }
-keep class go.** { *; }
