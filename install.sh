#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$PROJECT_DIR/templates"

for lib in "$PROJECT_DIR"/lib/*.sh; do
  source "$lib"
done

DOMAIN=""
SNI=""
XHTTP_SUB=""
PROTOCOLS_SELECTED=""
CLIENT_NAME="admin"
CONFIGURE_UFW="yes"
INSTALL_CLIENT_SUB="yes"
SSH_PORT_NEW=""
SSH_PORT_FINAL=""
CF_TOKEN=""
ACME_EMAIL=""
HOST=""
CERT=""; KEY=""
PANEL_USER=""; PANEL_PASS=""; PANEL_PORT_CHOICE=""; PANEL_PATH_CHOICE=""
SUB_TITLE="xui-deployer"
ASSUME_YES="no"
DRY_RUN="no"

PROTO_KEYS=(reality ws xhttp)
PROTO_LABELS=(
  "VLESS REALITY (маскировка, основной вход на 443)"
  "VLESS WebSocket (через nginx/TLS на 443)"
  "VLESS XHTTP (отдельный поддомен, HTTP/2, packet-up)"
)
PROTO_DEFAULT="0 1 2"

usage() {
  cat <<EOF
xui-deployer – установка 3X-UI (архитектура «всё TCP на 443» через nginx)

  --domain ДОМЕН        свой домен (A-запись на этот сервер): REALITY self-steal
                        и поддомен для XHTTP. Без домена – маскировка под чужой сайт.
  --sni САЙТ            чужой сайт для маскировки REALITY (если без домена).
  --xhttp-sub ПОДДОМЕН  поддомен для XHTTP (по умолчанию xhttp.<домен>, A-запись туда же).
  --protocols СПИСОК    через запятую: reality,ws,xhttp
                        или all / minimal (по умолчанию: все три).
  --user ИМЯ            имя первого клиента (по умолчанию admin).
  --ssh-port ПОРТ       сменить порт SSH до включения UFW.
  --cf-token ТОКЕН      Cloudflare API token для DNS-01 (сертификаты без порта 80).
  --email EMAIL         email для acme.sh (Let's Encrypt).
  --no-ufw              не трогать файрвол.
  --no-client-sub       не ставить client-sub (подписка будет отдаваться панелью напрямую).
  --dry-run             прогон мастера и печать плана без изменений системы.
  -y, --yes             не задавать вопросов, взять значения по умолчанию/флагов.
  -h, --help            эта справка.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    --sni)        SNI="${2:-}"; shift 2 ;;
    --xhttp-sub)  XHTTP_SUB="${2:-}"; shift 2 ;;
    --protocols)  PROTOCOLS_SELECTED="${2:-}"; shift 2 ;;
    --user)       CLIENT_NAME="${2:-}"; shift 2 ;;
    --ssh-port)   SSH_PORT_NEW="${2:-}"; shift 2 ;;
    --cf-token)   CF_TOKEN="${2:-}"; shift 2 ;;
    --email)      ACME_EMAIL="${2:-}"; shift 2 ;;
    --no-ufw)     CONFIGURE_UFW="no"; shift ;;
    --no-client-sub) INSTALL_CLIENT_SUB="no"; shift ;;
    --dry-run)    DRY_RUN="yes"; shift ;;
    -y|--yes)     ASSUME_YES="yes"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
done
export DRY_RUN

pick_sni() {
  local c
  for c in dl.google.com www.amazon.com www.samsung.com www.yahoo.com; do
    if curl -fsS -m 6 --tlsv1.3 --http2 -o /dev/null "https://$c" 2>/dev/null; then
      printf '%s' "$c"; return 0
    fi
  done
  printf '%s' "dl.google.com"
}

change_ssh_port() {
  [[ -n $SSH_PORT_NEW ]] || return 0
  [[ $SSH_PORT_NEW =~ ^[0-9]+$ ]] && (( SSH_PORT_NEW >= 1 && SSH_PORT_NEW <= 65535 )) || die "--ssh-port: порт 1..65535"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] смена порта SSH на $SSH_PORT_NEW${C_N}"; SSH_PORT_FINAL="$SSH_PORT_NEW"; return 0
  fi
  warn "Меняю порт SSH на $SSH_PORT_NEW. Не закрывайте текущую сессию, пока не проверите новую."
  command -v ufw >/dev/null && ufw allow "$SSH_PORT_NEW/tcp" >/dev/null 2>&1 || true
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -qE '^\s*Port\s+' /etc/ssh/sshd_config; then
      sed -i -E "s/^\s*Port\s+.*/Port $SSH_PORT_NEW/" /etc/ssh/sshd_config
    else
      printf 'Port %s\n' "$SSH_PORT_NEW" >> /etc/ssh/sshd_config
    fi
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT_NEW
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
  fi
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  SSH_PORT_FINAL="$SSH_PORT_NEW"
  ok "SSH переведён на порт $SSH_PORT_NEW"
}

gen_panel_creds() {
  PANEL_USER="$(rand_str 10)"
  PANEL_PASS="$(rand_str 20)"
  PANEL_PORT_CHOICE="$(free_port 20000)"
  PANEL_PATH_CHOICE="$(rand_str 18)"
}

_normalize_protocols() {
  [[ -n $PROTOCOLS_SELECTED ]] || die "Не выбран ни один протокол."
  if [[ $PROTOCOLS_SELECTED == all ]]; then PROTOCOLS_SELECTED="$(IFS=,; echo "${PROTO_KEYS[*]}")"; fi
  if [[ $PROTOCOLS_SELECTED == minimal ]]; then PROTOCOLS_SELECTED="reality"; fi
  local p ok_list=""
  for p in $(tr ',' ' ' <<<"$PROTOCOLS_SELECTED"); do
    case "$p" in
      reality|ws|xhttp) ok_list+="$p " ;;
      *) die "Неизвестный протокол: $p (доступны: reality, ws, xhttp)" ;;
    esac
  done
  PROTOCOLS_SELECTED="$(IFS=,; echo "${ok_list% }" | tr ' ' ',')"
}

validate_config() {
  local protos=",$PROTOCOLS_SELECTED,"
  if [[ -n $DOMAIN ]]; then
    valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN (нужно имя вида vpn.example.com)"
  fi
  if [[ -n $SNI ]]; then
    [[ -z $DOMAIN ]] || SNI=""
    if [[ -n $SNI ]]; then
      valid_domain "$SNI" || die "Некорректный сайт маскировки: $SNI (нужно доменное имя)"
    fi
  fi
  if [[ -n $XHTTP_SUB ]]; then
    if [[ -z $DOMAIN ]]; then
      die "--xhttp-sub требует --domain: поддомену нужен сертификат и A-запись"
    fi
    valid_domain "$XHTTP_SUB" || die "Некорректный поддомен XHTTP: $XHTTP_SUB (нужно имя вида xhttp.example.com)"
    [[ $XHTTP_SUB != "$DOMAIN" ]] \
      || die "XHTTP-поддомен совпадает с доменом ($DOMAIN): nginx не различит их по SNI. Укажите отдельный поддомен."
  fi
  if [[ $protos == *,xhttp,* && -n $DOMAIN && -z $XHTTP_SUB ]]; then
    XHTTP_SUB="xhttp.$DOMAIN"
    valid_domain "$XHTTP_SUB" || die "Некорректный поддомен XHTTP по умолчанию: $XHTTP_SUB"
  fi
  if [[ -n $CF_TOKEN && ! $CF_TOKEN =~ ^[A-Za-z0-9_-]{20,200}$ ]]; then
    die "--cf-token: недопустимые символы в токене Cloudflare"
  fi
  [[ $CLIENT_NAME =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "Имя клиента: только буквы, цифры, точка, дефис, подчёркивание (до 64)"
}

wizard() {
  printf '\n%s\n' "${C_B}${C_C}╔══════════════════════════════════════════╗${C_N}"
  printf '%s\n'   "${C_B}${C_C}║   xui-deployer · мастер установки 3X-UI  ║${C_N}"
  printf '%s\n\n' "${C_B}${C_C}╚══════════════════════════════════════════╝${C_N}"

  if [[ -z $DOMAIN && -z $SNI ]]; then
    local dm
    ask dm "Свой домен для маскировки (A-запись на этот сервер), Enter – без домена" ""
    DOMAIN="$dm"
  fi
  if [[ -n $DOMAIN ]]; then
    valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"
    info "  Домен: $DOMAIN (REALITY self-steal, ссылки REALITY идут на домен)."
    if [[ -z $CF_TOKEN ]]; then
      local cf
      ask cf "Cloudflare API token для DNS-01 (Enter – выпуск через порт 80)" ""
      CF_TOKEN="$cf"
    fi
  else
    if [[ -z $SNI ]]; then
      local s
      ask s "Сайт для маскировки REALITY (Enter – подобрать автоматически)" ""
      SNI="$s"
      [[ -z $SNI ]] && { info "  Подбираю сайт маскировки…"; SNI="$(pick_sni)"; }
    fi
    info "  Маскировка REALITY под: $SNI (ссылки идут на IP сервера)."
  fi

  if [[ -z $PROTOCOLS_SELECTED ]]; then
    local sel idx
    ask_multiselect sel "Протоколы подключений" PROTO_LABELS "$PROTO_DEFAULT"
    local parts=()
    for idx in $sel; do parts+=("${PROTO_KEYS[$idx]}"); done
    PROTOCOLS_SELECTED="$(IFS=,; echo "${parts[*]}")"
  fi
  _normalize_protocols

  if [[ ",$PROTOCOLS_SELECTED," == *,xhttp,* ]]; then
    if [[ -n $DOMAIN ]]; then
      if [[ -z $XHTTP_SUB ]]; then
        local xs
        ask xs "Поддомен для XHTTP (A-запись на этот сервер)" "xhttp.$DOMAIN"
        XHTTP_SUB="$xs"
      fi
      [[ $XHTTP_SUB == *".$DOMAIN" || $XHTTP_SUB == "$DOMAIN" ]] || warn "Поддомен $XHTTP_SUB не входит в $DOMAIN – нужен отдельный сертификат и A-запись."
      info "  XHTTP: https://$XHTTP_SUB (отдельный сертификат, маскировка под обычный сайт)."
    else
      [[ -z $XHTTP_SUB ]] || die "--xhttp-sub требует --domain: поддомену нужен сертификат и A-запись"
      warn "Без домена XHTTP будет работать через IP:443 (менее заметно для DPI, чем поддомен)."
    fi
  fi

  local cn; ask cn "Имя первого клиента" "$CLIENT_NAME"; CLIENT_NAME="$cn"

  gen_panel_creds
  if ask_yesno "Сгенерировать логин/пароль панели автоматически?" "yes"; then
    :
  else
    local u p; ask u "Логин панели" "$PANEL_USER"; PANEL_USER="$u"
    ask p "Пароль панели" "$PANEL_PASS"; PANEL_PASS="$p"
  fi

  ask_yesno "Ставить client-sub (подписка с учётом приложения: Clash/Mihomo, Hiddify…)?" "yes" \
    && INSTALL_CLIENT_SUB="yes" || INSTALL_CLIENT_SUB="no"

  if [[ -z $SSH_PORT_NEW ]]; then
    local sp; ask sp "Новый порт SSH (Enter – оставить текущий)" ""
    SSH_PORT_NEW="$sp"
  fi

  ask_yesno "Настроить файрвол UFW?" "yes" && CONFIGURE_UFW="yes" || CONFIGURE_UFW="no"

  printf '\n%s\n' "${C_B}План установки:${C_N}"
  printf '  Адрес:      %s\n' "$HOST_IP"
  printf '  Домен:      %s\n' "${DOMAIN:-нет (маскировка под $SNI)}"
  printf '  Протоколы:  %s\n' "$PROTOCOLS_SELECTED"
  [[ -n $XHTTP_SUB ]] && printf '  XHTTP:      %s\n' "$XHTTP_SUB"
  printf '  Клиент:     %s\n' "$CLIENT_NAME"
  printf '  Панель:     логин %s, порт %s (за nginx)\n' "$PANEL_USER" "$PANEL_PORT_CHOICE"
  printf '  client-sub: %s\n' "$INSTALL_CLIENT_SUB"
  printf '  SSH порт:   %s\n' "${SSH_PORT_NEW:-без изменений}"
  printf '  UFW:        %s\n' "$CONFIGURE_UFW"
  confirm "Продолжить установку?" || die "Отменено пользователем."
}

main() {
  preflight_check
  HOST_IP="$(detect_public_ip)"
  [[ -n $HOST_IP ]] || die "Не удалось определить внешний IP. Запустите на VPS с белым IP."
  SSH_PORT_FINAL="$(detect_ssh_port)"

  if [[ $ASSUME_YES == yes ]]; then
    [[ -n $PROTOCOLS_SELECTED ]] || PROTOCOLS_SELECTED="$(IFS=,; echo "${PROTO_KEYS[*]}")"
    _normalize_protocols
    if [[ -n $DOMAIN ]]; then
      [[ ",$PROTOCOLS_SELECTED," == *,xhttp,* && -z $XHTTP_SUB ]] && XHTTP_SUB="xhttp.$DOMAIN"
    else
      [[ -n $SNI ]] || SNI="$(pick_sni)"
    fi
    gen_panel_creds
  else
    wizard
  fi

  validate_config
  HOST="$HOST_IP"

  preflight_packages
  change_ssh_port

  panel_install "$PANEL_PORT_CHOICE" "$PANEL_PATH_CHOICE" "$PANEL_USER" "$PANEL_PASS" "none" "$HOST_IP"
  panel_connect

  cert_issue_ip "$HOST_IP"
  CERT="$IP_FULLCHAIN"; KEY="$IP_KEY"
  if [[ -n $DOMAIN ]]; then
    cert_issue_domain "$DOMAIN" "$CF_TOKEN"
    if [[ -n $XHTTP_SUB && $XHTTP_SUB != "$DOMAIN" ]]; then
      cert_issue_domain "$XHTTP_SUB" "$CF_TOKEN"
    fi
  fi

  configure_settings "$HOST" "$CERT" "$KEY"
  create_inbounds "$(tr ',' ' ' <<<"$PROTOCOLS_SELECTED")"
  setup_client_sub
  configure_sub_routing
  setup_nginx
  setup_firewall "$SSH_PORT_FINAL"

  write_result
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi