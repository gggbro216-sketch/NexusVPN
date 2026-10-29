# Архитектура NEXUS VPN

## Слои

```
┌──────────────────────── Godot (UI-процесс) ─────────────────────────┐
│ scenes/*        экраны (код-построение UI, UI kit scripts/ui/ui.gd)  │
│ autoloads       Log, Bus, Settings, Platform, Profiles,             │
│                 Subscriptions, History, SingBoxManager, Latency,    │
│                 Style, Nav, App                                     │
│ scripts/vpn     SingBoxManager ── VpnBackend (интерфейс адаптера)   │
│                   ├─ AndroidVpnBackend  → плагин NexusVpnBridge     │
│                   └─ UnsupportedVpnBackend (desktop: честно "нет") │
│ scripts/parsers ссылки → ProfileModel (outbound sing-box)            │
│ scripts/routing режимы/правила/DNS → секции конфигурации            │
│ ConfigBuilder   профиль + настройки → полная конфигурация sing-box  │
└───────────────┬──────────────────────────────────────────────────────┘
                │ JNI (Godot Android plugin v2, сигналы с JSON)
┌───────────────▼────────── Android, UI-процесс ──────────────────────┐
│ NexusVpnPlugin  методы @UsedByGodot, разрешения, файлы, QR, keystore │
│ CoreClient      libbox CommandClient → <filesDir>/command.sock      │
│                 (статус, журналы, URL-тесты); сессии проверки       │
│                 задержки (CommandServer без TUN)                    │
│ CoreState       чтение состояния (файл) + приём broadcast            │
└───────────────┬──────────────────────────────────────────────────────┘
                │ Intent (START/STOP/RESET_NETWORK), unix-socket, broadcast
┌───────────────▼────────── Android, процесс :vpn ────────────────────┐
│ NexusVpnService (VpnService, foreground systemExempted)              │
│ BoxCore         libbox CommandServer.startOrReloadService(config)   │
│ BoxPlatform     PlatformInterface: openTun → VpnService.Builder,    │
│                 autoDetectInterfaceControl → protect(fd),           │
│                 getInterfaces, монитор сети по умолчанию            │
│ NetworkMonitor  NetworkRequest (NOT_VPN) → updateDefaultInterface   │
└──────────────────────────────────────────────────────────────────────┘
```

### Почему отдельный процесс `:vpn`
При выходе Godot вызывает `ProcessPhoenix.forceQuit` → `Process.killProcess` (проверено по байткоду godot-lib 4.7.2). Если бы VpnService жил в процессе Godot, VPN обрывался бы при закрытии интерфейса. Официальный клиент sing-box для Android использует ту же схему (UI и служба разделены, общение через command-сокет libbox).

## Модули GDScript

| Путь | Назначение |
|---|---|
| `scripts/core/platform.gd` | доступ к плагину, события жизненного цикла |
| `scripts/core/app_controller.gd` | запуск: автоподключение, обновление подписок, буфер обмена |
| `scripts/core/event_bus.gd` | общие сигналы (toast, навигация, импорт, сеть) |
| `scripts/vpn/singbox_manager.gd` | **единый API** управления ядром, машина состояний, переподключение |
| `scripts/vpn/config_builder.gd` | генерация конфигураций (VPN и сессии проверки) |
| `scripts/vpn/vpn_backend.gd`, `android_backend.gd`, `unsupported_backend.gd` | платформенные адаптеры |
| `scripts/profiles/*` | модель, менеджер, зашифрованное хранилище, валидация |
| `scripts/parsers/*` | VLESS, VMess, Trojan, SS, Hysteria2/TUIC/AnyTLS/SOCKS, WireGuard, JSON sing-box, подписки |
| `scripts/subscriptions/*` | менеджер подписок, безопасная загрузка |
| `scripts/network/*` | проверка задержки, проверка внешнего IP |
| `scripts/routing/*` | режимы маршрутизации, правила, DNS |
| `scripts/storage/*` | настройки, история, JsonStore (атомарная запись + .bak), SecureStorage |
| `scripts/diagnostics/*` | журнал с маскировкой, отчёт без секретов |
| `scripts/ui/*` | тема, иконки, навигация, toast, UI kit |

## API SingBoxManager

| Метод | Возврат (await) | Поведение |
|---|---|---|
| `start_vpn(profile_id := "")` | `{ok, error}` | сборка конфигурации → проверка ядром (`checkConfig`) → разрешение VPN → запуск службы → ожидание STARTED (30 с) → URL-тест через `proxy` (до 3 попыток) → CONNECTED |
| `stop_vpn()` | `{ok, error}` | отмена текущего сценария, остановка, ожидание STOPPED (12 с) |
| `restart_vpn()` | `{ok, error}` | stop + start с тем же профилем |
| `switch_server(id)` | `{ok, error}` | выбор активного; при активном VPN — переподключение |
| `get_status()` | `Dictionary` | состояние, сообщение, профиль, время, IP, версия ядра |
| `get_logs(level)` | `Array[Dictionary]` | записи журнала ядра (уже замаскированы) |
| `get_statistics()` | `Dictionary` | `up/down` (байт/с), `up_total/down_total`, соединения, источник |
| `test_connection(id)` | `{id: запись}` | проверка задержки (см. Latency) |
| `validate_profile(id)` | `{ok, error, warnings}` | сборка + проверка ядром |

Асинхронные операции не блокируют главный поток: ожидание реализовано через таймеры SceneTree, нативные операции выполняются в потоках `nexus-core`/`nexus-io`. Устаревшие сценарии отменяются счётчиком операций.

## Хранение данных

| Файл | Формат | Защита |
|---|---|---|
| `user://profiles.dat` (+`.bak`) | JSON, схема v2 (профили + подписки) | AES-256 (`FileAccess.open_encrypted`), ключ из Android Keystore |
| `user://keystore.json` | обёрнутый ключ данных | AES-GCM ключом Keystore (неэкспортируемым) |
| `user://settings.json` | настройки, схема v1 | без секретов |
| `user://history.json` | история сессий | только названия профилей |
| `user://logs/app.log` | журнал (ротация 1 МБ) | секреты маскируются при записи |
| `files/nexus_active_config.json` | конфигурация для службы | внутреннее хранилище приложения (нужна службе и «Постоянной VPN») |

Запись атомарная: `.tmp` → проверка чтением → предыдущая версия в `.bak` → переименование. При повреждении — восстановление из `.bak`; при недоступном ключе база не перезаписывается (режим «заблокировано» с предложением сброса).
