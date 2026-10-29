# Интеграция sing-box

## Версия и сборка ядра
- **sing-box v1.14.4** (commit `c005f35300ce76427dc285481ec5695f5b179cd2`), пакет `experimental/libbox`.
- Сборка: `gomobile bind` (форк `github.com/sagernet/gomobile` v0.1.12, как в `go.mod` sing-box), Go 1.25.5, NDK 28.0.13004108 (версия, закреплённая в sing-box), `-androidapi 24`, ABI arm64-v8a + armeabi-v7a.
- Теги: `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0`. Не включены (по сравнению с официальным клиентом): `with_naive_outbound`, `with_tailscale`, `with_openvpn`, `with_openconnect`, `with_usbip`.
- Результат: `addons/android_vpn_bridge/bin/libbox.aar`, SHA-256 в `SHA256SUMS` (проверяется `tools/build_apk.sh`). Пересборка: `tools/build_libbox.sh` (проверяет commit исходников).
- Лицензия GPL-3.0-or-later → приложение также GPL-3.0-or-later; исходники ядра — upstream по закреплённому commit.

## Используемый API libbox (проверено по исходникам 1.14.4)
- `Libbox.setup(SetupOptions)` — basePath = `filesDir` (там же `command.sock`), workingPath = `filesDir/sing-box` (кэш правил), tempPath = `cacheDir`, `fixAndroidStack` как в официальном клиенте.
- `Libbox.checkConfig(json)` — валидация перед запуском.
- `CommandServer(handler, PlatformInterface)` + `start()` + `startOrReloadService(config, OverrideOptions)` / `closeService()` / `close()` / `resetNetwork()` / `pause()`/`wake()` (Doze).
- `CommandClient(handler, options)` с командами `CommandLog`, `CommandStatus` (интервал 1 с), `CommandGroup`; `urlTest(groupTag)`.
- `PlatformInterface` (Kotlin `BoxPlatform`):
  - `openTun(TunOptions)` → `VpnService.Builder`: адреса, DNS (если `dnsMode != disabled`), маршруты `inet4/6RouteRange` (исключения уже применены ядром), `addAllowedApplication`/`addDisallowedApplication`, `setUnderlyingNetworks`, `establish()`.
  - `usePlatformAutoDetectInterfaceControl = true`, `autoDetectInterfaceControl(fd)` → `VpnService.protect(fd)` — **защита от петли**: собственные сокеты ядра идут мимо TUN.
  - `startDefaultInterfaceMonitor` → `NetworkRequest` (по умолчанию `NOT_VPN`) — реальная сеть, а не собственный VPN; `updateDefaultInterface(name, index, metered, false)`.
  - `getInterfaces()` — интерфейсы, адреса (без zone id), DNS-серверы, шлюзы, тип, metered.
  - `localDNSTransport() = null` — встроенный резолвер `local` с DNS из `getInterfaces`.
  - Неиспользуемые возможности (shell, bridge, SSH-агент, системный прокси) явно бросают `UnsupportedOperationException`.

## Генерация конфигурации (`ConfigBuilder`)
```jsonc
{
  "log": {"level": "warn", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"},
      {"type": "local", "tag": "local"}
    ],
    "rules": [ /* direct-домены → local, блок → reject */ ],
    "final": "remote", "strategy": "prefer_ipv4"
  },
  "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 9000, "auto_route": true, "strict_route": true, "stack": "mixed",
                "include_package": [], "exclude_package": []}],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": ["server"], "default": "server"},
    {"type": "vless", "tag": "server", /* параметры профиля без изменений */},
    {"type": "direct", "tag": "direct"}
  ],
  "endpoints": [ /* WireGuard-профиль как endpoint "server" */ ],
  "route": {
    "rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"},
              {"ip_is_private": true, "outbound": "direct"}, /* правила режима */],
    "rule_set": [ /* remote .srs (SagerNet sing-geoip/geosite), http_client.detour = proxy */ ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": {"server": "local"}
  },
  "experimental": {"cache_file": {"enabled": true}}
}
```
Особенности 1.14, учтённые в генераторе: новый формат DNS-серверов (старый удалён в 1.14), действия правил (`sniff`, `hijack-dns`, `reject`) вместо специальных outbound, WireGuard только как endpoint, `http_client` вместо устаревшего `download_detour`, `default_domain_resolver` для адресов серверов (иначе их имена разрешались бы через туннель).

Сессия проверки задержки: только outbounds `test-N` + selector `nexus-test`, без inbounds; `urlTest("nexus-test")` выполняет HTTP-запрос через каждый outbound (цель по умолчанию ядра `https://www.gstatic.com/generate_204`), результаты приходят через `CommandGroup`.

## Определение «Подключено»
1. Служба сообщает STARTED только после успешного `startOrReloadService` (TUN создан).
2. `SingBoxManager` выполняет `urlTest("proxy")` и ждёт результат с временем позже начала проверки и задержкой > 0.
3. Только после этого — CONNECTED; иначе ядро останавливается и показывается ошибка «сервер не отвечает».
Проверку можно отключить в настройках — тогда в интерфейсе отображается пометка «соединение не проверялось».

## Проверка на хосте
`tests/test_config_validation.gd` запускает `sing-box check` (сборка 1.14.4 с теми же тегами) для конфигураций всех протоколов и режимов; `tests/test_e2e_proxy.gd` поднимает реальные серверы sing-box на 127.0.0.1 и проверяет передачу трафика через клиентские outbounds, сгенерированные приложением.
