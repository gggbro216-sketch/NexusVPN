# Поддержка протоколов

Поддержка определяется возможностями сборки sing-box 1.14.4 (теги в `tools/build_libbox.sh`). «E2E» — передача трафика проверена тестом `tests/test_e2e_proxy.gd` с настоящим сервером sing-box на хосте; «check» — конфигурация принимается `sing-box check`.

| Протокол | Импорт | Проверка | Примечания |
|---|---|---|---|
| VLESS TCP | `vless://` | E2E | `flow=xtls-rprx-vision` (только TLS/REALITY, только raw TCP) |
| VLESS + REALITY | `vless://…security=reality` | E2E (Vision) | `pbk` обязателен, `sid` ≤ 16 hex, uTLS включается автоматически (требование sing-box); `spx`, `pqv` игнорируются с предупреждением |
| VLESS + TLS | `security=tls` | check | `sni` (по умолчанию — домен сервера), `alpn`, `fp` (uTLS), `allowInsecure` (с предупреждением) |
| VLESS + WebSocket | `type=ws` | check | `path`, `host`, ранние данные `?ed=N` |
| VLESS + gRPC | `type=grpc` | E2E | `serviceName`; режим `multi` не поддерживается sing-box → gun с предупреждением |
| VLESS + HTTPUpgrade | `type=httpupgrade` | E2E | `path`, `host` |
| VLESS + HTTP/2 | `type=http`/`h2` | check | |
| VLESS + QUIC | `type=quic` | check | только `quicSecurity=none` |
| VLESS + XHTTP/SplitHTTP | — | — | **не реализовано в sing-box 1.14** → понятная ошибка |
| VMess | `vmess://` (base64 JSON v2rayN и URI) | E2E (WS) | шифры auto/none/zero/aes-128-gcm/chacha20-poly1305/aes-128-ctr, alterId |
| Trojan | `trojan://` | E2E (TLS) | TLS по умолчанию, транспорты как у VLESS |
| Shadowsocks | `ss://` SIP002 и legacy | check | AEAD, stream (с предупреждением), плагины `obfs-local`, `v2ray-plugin` |
| Shadowsocks 2022 | `ss://2022-…` | E2E | проверка длины ключа, многопользовательский `iPSK:uPSK` |
| Hysteria2 | `hysteria2://`, `hy2://` | E2E | `obfs=salamander`, `mport` (port hopping), `insecure` |
| TUIC v5 | `tuic://` | E2E | `congestion_control`, `udp_relay_mode`, `alpn` |
| AnyTLS | `anytls://` | E2E | |
| WireGuard | `.conf` (wg-quick), JSON | check | endpoint sing-box; DNS из файла игнорируется; AmneziaWG → ошибка |
| SOCKS4/4a/5 | `socks5://`, `socks://` | check | без шифрования (предупреждение) |
| HTTP/HTTPS-прокси | JSON sing-box (`type: http`) | check | ссылка `https://` трактуется как подписка, поэтому HTTP-прокси добавляется через JSON |
| SSH | JSON sing-box (`type: ssh`) | check | ключ должен быть встроен (`private_key`), пути к файлам отклоняются |
| Snell | JSON sing-box | — | новое в 1.14 |
| Hysteria (v1) | JSON | — | ссылки v1 не поддерживаются |
| ShadowTLS | — | — | требует цепочки outbound; используйте полную конфигурацию |
| NaiveProxy, Tailscale, OpenVPN, OpenConnect | — | — | есть в sing-box, **не включены в эту сборку** libbox |
| ShadowsocksR, mKCP, Brook, Juicity, Mieru | — | — | не поддерживаются sing-box |

## Импорт JSON sing-box
- Полная конфигурация: каждый поддерживаемый outbound/endpoint становится профилем (поля сохраняются как есть, включая неизвестные). Outbound с `detour` (цепочки) отклоняются с объяснением.
- Если конфигурация содержит TUN-вход, её можно сохранить как профиль «полная конфигурация» — запускается без изменений (настройки DNS/маршрутизации приложения к ней не применяются).
- Массив outbounds или одиночный объект outbound тоже принимаются.

## Подписки
Определение формата: список ссылок → base64 (стандартный и URL-safe, с/без `=`) → JSON sing-box → WireGuard. Распознаются и отклоняются с объяснением: HTML-страница, Clash/Mihomo YAML, Xray JSON. Обрабатываются BOM, CRLF, пустые строки, комментарии; некорректные записи пропускаются с указанием номера строки (без секретов).
