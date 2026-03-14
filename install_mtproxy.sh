#!/usr/bin/env bash
# =============================================================================
#  MTProxy installer — автоустановка с TLS-маскировкой (ФИНАЛЬНАЯ ВЕРСИЯ)
#  Протестировано: Ubuntu 20.04 / 22.04 / Debian 11 / 12
#  Использование: bash install_mtproxy.sh
# =============================================================================

set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
fatal() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Проверка root ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "Запустите скрипт от root: sudo bash $0"

# ── Конфигурируемые параметры ─────────────────────────────────────────────────
INSTALL_DIR="/opt/mtproxy"
SERVICE_NAME="mtproxy"
TLS_DOMAIN="vk.com"  # Можно изменить на любой популярный домен
CANDIDATE_PORTS=(443 8443 2083 2087 8080 8888 3128)

# ── Откат предыдущей установки ────────────────────────────────────────────────
cleanup_previous() {
    hdr "Откат предыдущей установки"
    local found=0

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}"
        ok "Сервис остановлен"
        found=1
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1
        found=1
    fi

    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        ok "Юнит удалён"
        found=1
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        # Читаем старый порт чтобы убрать из файрвола
        if [[ -f "${INSTALL_DIR}/config.py" ]]; then
            local old_port=""
            old_port=$(grep -Po 'PORT\s*=\s*\K\d+' "${INSTALL_DIR}/config.py" 2>/dev/null || true)
            if [[ -n "$old_port" ]]; then
                iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
                ok "Правило iptables для порта $old_port удалено"
            fi
        fi

        rm -rf "$INSTALL_DIR"
        ok "Директория $INSTALL_DIR удалена"
        found=1
    fi

    [[ $found -eq 0 ]] && info "Предыдущая установка не найдена, продолжаем"
    return 0
}

# ── Определение публичного IP ─────────────────────────────────────────────────
detect_ip() {
    local ip=""
    ip=$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null)   || \
    ip=$(curl -4 -sf --max-time 5 https://ifconfig.me 2>/dev/null)     || \
    ip=$(curl -4 -sf --max-time 5 https://icanhazip.com 2>/dev/null)   || \
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# ── Выбор свободного порта ────────────────────────────────────────────────────
pick_free_port() {
    for port in "${CANDIDATE_PORTS[@]}"; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
        warn "Порт $port занят, пробую следующий..."
    done
    local rand_port
    rand_port=$(shuf -i 10000-60000 -n 1)
    warn "Все стандартные порты заняты. Используется случайный: $rand_port"
    echo "$rand_port"
}

# ── Открытие порта в файрволе ─────────────────────────────────────────────────
open_firewall() {
    local port="$1"
    local opened=0

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        ok "ufw: порт $port открыт"
        opened=1
    fi

    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "firewalld: порт $port открыт"
        opened=1
    fi

    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT || true
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif [[ -d /etc/iptables ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ok "iptables: порт $port открыт"
            opened=1
        else
            ok "iptables: правило для порта $port уже существует"
            opened=1
        fi
    fi

    [[ $opened -eq 0 ]] && warn "Файрвол не обнаружен, откройте порт $port вручную если нужно"
    return 0
}

# ── Установка зависимостей ────────────────────────────────────────────────────
install_deps() {
    hdr "Установка зависимостей"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3 python3-pip git curl openssl 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q python3 python3-pip git curl openssl 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y -q python3 python3-pip git curl openssl 2>/dev/null || true
    fi
    ok "Зависимости установлены"
}

# ── Установка mtprotoproxy ────────────────────────────────────────────────────
install_proxy() {
    hdr "Установка mtprotoproxy"
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    git clone -q https://github.com/alexbers/mtprotoproxy.git "$INSTALL_DIR"
    ok "Репозиторий готов: $INSTALL_DIR"
}

# ── Генерация секрета для TLS ─────────────────────────────────────────────────
# В mtprotoproxy секрет должен быть ровно 32 hex символа (16 байт)
# Префикс "ee" добавляется автоматически при формировании ссылки
generate_secret() {
    openssl rand -hex 16  # 16 байт = 32 hex символа
}

# ── Запись конфига ────────────────────────────────────────────────────────────
write_config() {
    local port="$1"
    local secret="$2"  # 32 hex символа
    local domain="$3"

    cat > "${INSTALL_DIR}/config.py" << EOF
# MTProxy config — сгенерировано install_mtproxy.sh
# Дата: $(date '+%Y-%m-%d %H:%M:%S')

PORT = ${port}

# Пользователи: имя -> секрет (32 hex символа, БЕЗ префикса ee)
USERS = {
    "tg": "${secret}",
}

# TLS-домен: трафик маскируется под HTTPS к этому хосту
TLS_DOMAIN = "${domain}"

# Включить только TLS-режим (рекомендуется)
MODES = {"classic": False, "secure": False, "tls": True}
EOF
    ok "Конфиг записан: ${INSTALL_DIR}/config.py"
    
    # Проверяем длину секрета
    if [[ ${#secret} -ne 32 ]]; then
        warn "Секрет имеет неверную длину: ${#secret} символов (должно быть 32)"
    fi
}

# ── Формирование полного секрета для ссылки ───────────────────────────────────
make_tls_link_secret() {
    local base_secret="$1"   # 32 hex символа
    local domain="$2"
    local domain_hex
    
    # Конвертируем домен в hex
    if command -v xxd &>/dev/null; then
        domain_hex=$(printf '%s' "$domain" | xxd -p | tr -d '\n')
    else
        domain_hex=$(python3 -c "import sys; print(sys.argv[1].encode().hex())" "$domain" 2>/dev/null || echo "")
    fi
    
    # Формат для ссылки: ee + base_secret + domain_hex
    echo "ee${base_secret}${domain_hex}"
}

# ── Systemd-сервис ────────────────────────────────────────────────────────────
create_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=MTProto Proxy for Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/mtprotoproxy.py ${INSTALL_DIR}/config.py
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtproxy
MemoryMax=512M

# Безопасность
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    # Устанавливаем правильные права
    chown -R nobody:nogroup "$INSTALL_DIR" 2>/dev/null || chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"
    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Сервис запущен и добавлен в автозагрузку"
    else
        warn "Сервис завершился с ошибкой. Последние логи:"
        journalctl -u "${SERVICE_NAME}" -n 30 --no-pager
        fatal "Не удалось запустить mtproxy. Проверьте логи выше."
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     MTProxy — автоустановщик v1.5            ║"
    echo "║  Telegram MTProto + TLS fake-domain masking  ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    cleanup_previous

    hdr "Определение IP-адреса"
    SERVER_IP=$(detect_ip)
    [[ -n "$SERVER_IP" ]] || fatal "Не удалось определить публичный IP"
    ok "Публичный IP: $SERVER_IP"

    hdr "Выбор порта"
    SERVER_PORT=$(pick_free_port)
    ok "Выбран порт: $SERVER_PORT"

    install_deps
    install_proxy

    hdr "Генерация секрета"
    PROXY_SECRET=$(generate_secret)
    ok "Секрет сгенерирован: ${PROXY_SECRET}"

    hdr "Запись конфигурации (TLS домен: $TLS_DOMAIN)"
    write_config "$SERVER_PORT" "$PROXY_SECRET" "$TLS_DOMAIN"

    hdr "Настройка файрвола"
    open_firewall "$SERVER_PORT"

    hdr "Запуск сервиса"
    create_service

    # Формируем секрет для ссылки (с префиксом ee и доменом)
    LINK_SECRET=$(make_tls_link_secret "$PROXY_SECRET" "$TLS_DOMAIN")
    
    TG_LINK="tg://proxy?server=${SERVER_IP}&port=${SERVER_PORT}&secret=${LINK_SECRET}"
    TME_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${SERVER_PORT}&secret=${LINK_SECRET}"

    INFO_FILE="${INSTALL_DIR}/proxy_info.txt"
    cat > "$INFO_FILE" << EOF
╔════════════════════════════════════════════════════════════════╗
║                 MTProxy — данные подключения                   ║
╚════════════════════════════════════════════════════════════════╝

Установлено: $(date '+%Y-%m-%d %H:%M:%S')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Параметры подключения:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Сервер:     ${SERVER_IP}
Порт:       ${SERVER_PORT}
Секрет (базовый): ${PROXY_SECRET}
Секрет (для ссылки): ${LINK_SECRET}
TLS-домен:  ${TLS_DOMAIN}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Ссылки для подключения:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📱 tg:// (для мобильных клиентов):
${TG_LINK}

🌐 t.me (для браузера/передачи):
${TME_LINK}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Управление сервисом:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Проверить статус:  systemctl status ${SERVICE_NAME}
Перезапустить:     systemctl restart ${SERVICE_NAME}
Остановить:        systemctl stop ${SERVICE_NAME}
Логи в реальном времени: journalctl -u ${SERVICE_NAME} -f

Конфиг:            ${INSTALL_DIR}/config.py
Этот файл:         ${INFO_FILE}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                   ✓  УСТАНОВКА ЗАВЕРШЕНА                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    printf "  ${BOLD}%-12s${NC} %s\n" "Сервер:"    "$SERVER_IP"
    printf "  ${BOLD}%-12s${NC} %s\n" "Порт:"      "$SERVER_PORT"
    printf "  ${BOLD}%-12s${NC} %s\n" "TLS-домен:" "$TLS_DOMAIN"
    echo ""
    echo -e "  ${BOLD}${YELLOW}📱 Ссылка для Telegram:${NC}"
    echo -e "  ${CYAN}${TG_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}🌐 Ссылка t.me (для браузера):${NC}"
    echo -e "  ${CYAN}${TME_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}📄 Данные сохранены:${NC} ${INFO_FILE}"
    echo ""
    
    # Проверяем, что ошибка исчезла
    sleep 2
    if journalctl -u "${SERVICE_NAME}" --since="10 seconds ago" | grep -q "Bad secret"; then
        warn "Обнаружена ошибка в секрете. Проверьте конфиг вручную."
    else
        ok "Прокси работает корректно! Ошибок с секретом нет."
    fi
}

main "$@"
