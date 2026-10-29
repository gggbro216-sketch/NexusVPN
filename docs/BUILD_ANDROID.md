# Сборка Android APK

## Проверенные версии (сборка выполнена в этой конфигурации)

| Компонент | Версия | Источник требования |
|---|---|---|
| Godot | 4.7.2-stable + export templates 4.7.2 | проект |
| JDK | 17 (OpenJDK 17.0.20) | `config.gradle` шаблона Godot (`javaVersion 17`) |
| Android SDK Platform | 36 | `compileSdk 36` шаблона |
| Build-tools | 36.1.0 | шаблон Godot |
| NDK | 29.0.14206865 (шаблон Godot), 28.0.13004108 (сборка libbox) | шаблон / sing-box |
| AGP / Kotlin / Gradle | 8.6.1 / 2.1.21 / 8.11.1 (wrapper шаблона) | шаблон |
| Go | 1.25.5 (`GOTOOLCHAIN=auto`) | `go.mod` sing-box |
| sing-box / gomobile | 1.14.4 / sagernet gomobile 0.1.12 | upstream |
| minSdk / targetSdk | 24 / 36 | шаблон Godot |

## 1. Подготовка окружения
```bash
# Android SDK (cmdline-tools)
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0" "ndk;29.0.14206865" "ndk;28.0.13004108"
# Шаблоны экспорта Godot 4.7.2: Editor → Manage Export Templates, или распаковать
# Godot_v4.7.2-stable_export_templates.tpz в ~/.local/share/godot/export_templates/4.7.2.stable/
```
Настройки редактора (Editor Settings → Export → Android) или `~/.config/godot/editor_settings-4.7.tres`:
```
export/android/android_sdk_path = "/path/to/Android/Sdk"
export/android/java_sdk_path    = "/path/to/jdk-17"
```
Отладочный keystore Godot создаёт сам (`~/.local/share/godot/keystores/debug.keystore`).

## 2. Ядро и плагин (уже лежат в репозитории)
`addons/android_vpn_bridge/bin/` содержит `libbox.aar` и `nexus_vpn_bridge-release.aar` с контрольными суммами `SHA256SUMS`. Пересобрать при необходимости:
```bash
export ANDROID_HOME=/path/to/Android/Sdk JAVA_HOME=/path/to/jdk-17
tools/build_libbox.sh            # клонирует sing-box v1.14.4, проверяет commit, собирает build/libbox/libbox.aar (~15 мин)
tools/build_android_plugin.sh    # Kotlin-плагин → addons/android_vpn_bridge/bin/, обновляет SHA256SUMS
```
Готового Android-плагина sing-box для Godot не существует — плагин написан в этом проекте (`android_plugin/`).

## 3. Экспорт APK
```bash
tools/build_apk.sh debug      # build/NexusVPN-debug.apk
# release: подпись своим ключом (не храните ключ в репозитории)
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH=/secure/release.jks
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=alias
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=...
tools/build_apk.sh release    # build/NexusVPN-release.apk
```
Из редактора: Project → Install Android Build Template, затем Project → Export → Android (включён «Use Gradle Build» — он обязателен для плагинов).

Скрипт выполняет `--install-android-build-template` (создаёт `android/build`, в git не хранится). Плагин редактора `addons/android_vpn_bridge` добавляет в Gradle-сборку оба AAR и зависимости `com.google.zxing:core:3.5.3`, `com.google.android.gms:play-services-code-scanner:16.1.0`.

Если Maven Central отвечает 429 (ограничение по IP), используйте зеркало через init-скрипт Gradle (`~/.gradle/init.d/`), заменяющий `repo.maven.apache.org` на `https://maven-central.storage-download.googleapis.com/maven2/`.

Название приложения меняется в `project.godot` (`application/config/name`) и в `export_presets.cfg` (`package/name`); идентификатор пакета — `package/unique_name`.

## 4. Установка
```bash
adb install -r build/NexusVPN-debug.apk
```
Размер (arm64 + armv7, сжатые библиотеки): debug ~109 МБ, release ~93 МБ. Для меньшего файла отключите `architectures/armeabi-v7a` в `export_presets.cfg` (только 64-битные устройства).

## Разрешения
| Разрешение | Зачем |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | сеть, состояние сети |
| `CHANGE_NETWORK_STATE` | `requestNetwork()` для отслеживания реальной (не VPN) сети |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` | фоновая работа VpnService (тип `systemExempted` разрешён VPN-приложениям, Android 14+) |
| `POST_NOTIFICATIONS` | уведомление о работающем VPN (Android 13+, запрашивается при запуске) |
| `BIND_VPN_SERVICE` (на службе) | только система может привязаться к VpnService |
| `<queries>` LAUNCHER | список приложений для раздельного туннелирования без `QUERY_ALL_PACKAGES` |

Камера не запрашивается: сканер Google работает в своём процессе. `allowBackup=false` — данные не попадают в резервные копии Android.

## Проверки перед релизом
- [ ] `tools/run_tests.sh` с `NEXUS_SINGBOX_BIN` — все тесты пройдены, без SKIP.
- [ ] `sha256sum -c addons/android_vpn_bridge/bin/SHA256SUMS`.
- [ ] Ручной чек-лист на устройствах ([TESTING.md](TESTING.md)), минимум Android 8, 12, 14/15.
- [ ] Подпись release-ключом, `apksigner verify`.
- [ ] Версия: `version/code`, `version/name` в `export_presets.cfg`, `application/config/version` в `project.godot`.
- [ ] Исходный код (GPL) опубликован для распространяемой версии.
