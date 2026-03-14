#!/usr/bin/env bash
# =============================================================================
#  MTProxy installer — автоустановка с TLS-маскировкой
#  Протестировано: Ubuntu 20.04 / 22.04 / Debian 11 / 12
#  Использование: bash install_mtproxy.sh
# =============================================================================

set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
hdr()   { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Проверка root ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fatal "Запустите скрипт от root: sudo bash $0"

# ── Конфигурируемые параметры ─────────────────────────────────────────────────
INSTALL_DIR="/opt/mtproxy"
SERVICE_NAME="mtproxy"
TLS_DOMAIN="yandex.ru"            # домен для TLS-маскировки
CANDIDATE_PORTS=(443 8443 2083 2087 8080 8888 3128)

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
        ufw allow "${port}/tcp" >/dev/null 2>&1
        ok "ufw: порт $port открыт"
        opened=1
    fi

    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        ok "firewalld: порт $port открыт"
        opened=1
    fi

    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
            # Сохраняем правило
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif [[ -d /etc/iptables ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ok "iptables: порт $port открыт"
            opened=1
        fi
    fi

    [[ $opened -eq 0 ]] && warn "Файрвол не обнаружен или правило уже существует"
}

# ── Установка зависимостей ────────────────────────────────────────────────────
install_deps() {
    hdr "Установка зависимостей"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3 python3-pip git curl openssl xxd 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3 python3-pip git curl openssl vim-common 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q python3 python3-pip git curl openssl vim-common 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum install -y -q python3 python3-pip git curl openssl vim-common 2>/dev/null || true
    fi
    ok "Зависимости установлены"
}

# ── Установка / обновление mtprotoproxy ───────────────────────────────────────
install_proxy() {
    hdr "Установка mtprotoproxy"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Обновляю существующую установку..."
        git -C "$INSTALL_DIR" pull -q
    else
        git clone -q https://github.com/alexbers/mtprotoproxy.git "$INSTALL_DIR"
    fi
    ok "Репозиторий готов: $INSTALL_DIR"
}

# ── Генерация TLS-секрета ─────────────────────────────────────────────────────
generate_secret() {
    local domain="$1"
    local base_secret
    base_secret=$(openssl rand -hex 16)

    local domain_hex
    if command -v xxd &>/dev/null; then
        domain_hex=$(printf '%s' "$domain" | xxd -p | tr -d '\n')
    else
        domain_hex=$(python3 -c "import sys; print(sys.argv[1].encode().hex())" "$domain")
    fi

    # Формат: "ee" + 16 random bytes hex + domain hex
    # Это заставляет клиент Telegram маскировать трафик под TLS к указанному домену
    echo "ee${base_secret}${domain_hex}"
}

# ── Запись конфига ────────────────────────────────────────────────────────────
write_config() {
    local port="$1"
    local secret="$2"

    cat > "${INSTALL_DIR}/config.py" << EOF
# MTProxy config — сгенерировано install_mtproxy.sh
# Дата: $(date '+%Y-%m-%d %H:%M:%S')

PORT = ${port}

# TLS-секрет: маскировка трафика под HTTPS (fake-TLS)
# Префикс "ee" + 16 байт + hex домена ${TLS_DOMAIN}
SECRET = "${secret}"

# Раскомментируйте для нескольких пользователей с разными секретами:
# USERS = {
#     "user1": "секрет1",
#     "user2": "секрет2",
# }
EOF
    ok "Конфиг записан: ${INSTALL_DIR}/config.py"
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
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/mtprotoproxy.py
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtproxy
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Сервис запущен и добавлен в автозагрузку"
    else
        warn "Сервис завершился с ошибкой. Последние логи:"
        journalctl -u "${SERVICE_NAME}" -n 20 --no-pager
        fatal "Не удалось запустить mtproxy"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     MTProxy — автоустановщик v1.0            ║"
    echo "║  Telegram MTProto + TLS fake-domain masking  ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    hdr "Определение IP-адреса"
    SERVER_IP=$(detect_ip)
    [[ -n "$SERVER_IP" ]] || fatal "Не удалось определить публичный IP"
    ok "Публичный IP: $SERVER_IP"

    hdr "Выбор порта"
    SERVER_PORT=$(pick_free_port)
    ok "Выбран порт: $SERVER_PORT"

    install_deps
    install_proxy

    hdr "Генерация секрета (TLS fake-domain: $TLS_DOMAIN)"
    PROXY_SECRET=$(generate_secret "$TLS_DOMAIN")
    ok "Секрет: $PROXY_SECRET"

    hdr "Запись конфигурации"
    write_config "$SERVER_PORT" "$PROXY_SECRET"

    hdr "Настройка файрвола"
    open_firewall "$SERVER_PORT"

    hdr "Запуск сервиса"
    create_service

    # Формируем ссылки
    TG_LINK="tg://proxy?server=${SERVER_IP}&port=${SERVER_PORT}&secret=${PROXY_SECRET}"
    TME_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${SERVER_PORT}&secret=${PROXY_SECRET}"

    # Сохраняем всё в файл
    INFO_FILE="${INSTALL_DIR}/proxy_info.txt"
    cat > "$INFO_FILE" << EOF
MTProxy — данные подключения
Установлено: $(date '+%Y-%m-%d %H:%M:%S')

Сервер:     ${SERVER_IP}
Порт:       ${SERVER_PORT}
Секрет:     ${PROXY_SECRET}
TLS-домен:  ${TLS_DOMAIN}

tg:// ссылка (для мобильных клиентов):
${TG_LINK}

t.me ссылка (для браузера / передачи):
${TME_LINK}

Управление сервисом:
  systemctl status  ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  systemctl stop    ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
EOF

    # ── Итоговый вывод ────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                   ✓  УСТАНОВКА ЗАВЕРШЕНА                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    printf "  %-14s %s\n" "Сервер:"    "$SERVER_IP"
    printf "  %-14s %s\n" "Порт:"      "$SERVER_PORT"
    printf "  %-14s %s\n" "TLS-домен:" "$TLS_DOMAIN"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Ссылка для подключения:${NC}"
    echo -e "  ${BOLD}${CYAN}${TG_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}Ссылка t.me (для браузера):${NC}"
    echo -e "  ${CYAN}${TME_LINK}${NC}"
    echo ""
    echo -e "  Данные сохранены: ${BOLD}$INFO_FILE${NC}"
    echo ""
    echo -e "  ${BOLD}Управление:${NC}"
    echo -e "  systemctl status  $SERVICE_NAME"
    echo -e "  systemctl restart $SERVICE_NAME"
    echo -e "  journalctl -u $SERVICE_NAME -f"
    echo ""
}

main "$@"
