# MTProxy — автоустановщик для Telegram

Bash-скрипт для быстрой установки [MTProto-прокси](https://github.com/alexbers/mtprotoproxy) на VPS. Одна команда — готовая ссылка `tg://proxy`.

**Возможности:**
- Автоматически выбирает свободный порт (443 → 8443 → 2083 → и т.д.)
- Открывает порт в файрволе (ufw / firewalld / iptables)
- TLS-маскировка трафика под HTTPS (fake-TLS, домен `yandex.ru`)
- Настраивает systemd-сервис с автозапуском
- На выходе — готовая ссылка `tg://proxy?server=...`

**Протестировано:** Ubuntu 20.04 / 22.04, Debian 11 / 12

---

## Установка

Запустите от root на вашем VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/ВЫ/РЕПО/main/install_mtproxy.sh | sudo bash
```

Через 1–2 минуты скрипт выведет ссылку вида:

```
tg://proxy?server=23.94.131.195&port=8443&secret=ee7f3a...
```

Нажмите на неё — Telegram сразу предложит подключиться.

---

## Что происходит при установке

1. Определяется публичный IP сервера
2. Находится первый свободный порт из списка: `443, 8443, 2083, 2087, 8080, 8888, 3128`
3. Устанавливаются зависимости (`python3`, `git`, `openssl`)
4. Клонируется [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy)
5. Генерируется TLS-секрет с маскировкой под `yandex.ru`
6. Открывается порт в файрволе
7. Создаётся и запускается systemd-сервис

---

## Управление сервисом

```bash
systemctl status  mtproxy      # статус
systemctl restart mtproxy      # перезапуск
systemctl stop    mtproxy      # остановка
journalctl -u mtproxy -f       # логи в реальном времени
```

Данные подключения сохраняются в `/opt/mtproxy/proxy_info.txt`.

---

## Смена TLS-домена

По умолчанию трафик маскируется под `yandex.ru` — оптимально для подключений из России. Чтобы изменить домен, отредактируйте строку в начале скрипта перед запуском:

```bash
TLS_DOMAIN="yandex.ru"   # заменить на нужный
```

Хорошие варианты: `yandex.ru`, `vk.com`, `cloudflare.com`, `google.com`.

---

## Требования

- Чистый VPS с Ubuntu 20.04+ или Debian 11+
- Root-доступ
- Открытый исходящий интернет (для `git clone` и `apt`)
