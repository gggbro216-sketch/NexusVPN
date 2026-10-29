# android/

Каталог Godot для Android: сюда `--install-android-build-template` (или Project → Install Android Build Template) устанавливает Gradle-шаблон `android/build/`. Он генерируется и не хранится в git.

Исходный код нативного плагина находится в [`../android_plugin/`](../android_plugin) (Kotlin, модуль `nexus_vpn_bridge`), собранные AAR — в [`../addons/android_vpn_bridge/bin/`](../addons/android_vpn_bridge/bin). См. [docs/BUILD_ANDROID.md](../docs/BUILD_ANDROID.md).
