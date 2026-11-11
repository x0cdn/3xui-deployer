
XUI_VERSION="v3.11.0"
XUI_REPO="MHSanaei/3x-ui"
XUI_INSTALL_SHA256="9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d"
XUI_ENV="/etc/x-ui/install-result.env"
PANEL_LOG="/var/log/xui-deployer-panel-install.log"
API=""
TOKEN=""

panel_install() {
  local port="$1" path="$2" user="$3" pass="$4" ssl="$5" host="$6"
  step "Установка панели 3X-UI ${XUI_VERSION}"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] install.sh ${XUI_VERSION} (port=$port path=/$path/ user=$user ssl=$ssl)${C_N}"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/${XUI_REPO}/${XUI_VERSION}/install.sh" \
    || die "Не скачался установщик 3X-UI."
  local got
  got=$(sha256sum "$tmp" | awk '{print $1}')
  if [[ $got != "$XUI_INSTALL_SHA256" ]]; then
    rm -f "$tmp"
    die "SHA256 установщика не совпал с закреплённым – не запускаю (возможна подмена тега)."
  fi
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE="$ssl" XUI_SERVER_IP="$host" \
       XUI_PANEL_PORT="$port" XUI_WEB_BASE_PATH="$path" \
       XUI_USERNAME="$user" XUI_PASSWORD="$pass" \
       bash "$tmp" "$XUI_VERSION" </dev/null >"$PANEL_LOG" 2>&1; then
    tail -25 "$PANEL_LOG" >&2
    rm -f "$tmp"
    die "Установщик 3X-UI завершился с ошибкой. Лог: $PANEL_LOG"
  fi
  rm -f "$tmp"
  ok "Панель 3X-UI установлена"
}

panel_connect() {
  [[ $DRY_RUN == yes ]] && { info "  ${C_D}[dry-run] подключение к API панели${C_N}"; return 0; }
  [[ -f $XUI_ENV ]] || die "Нет $XUI_ENV – панель не установлена корректно."
  source "$XUI_ENV"
  TOKEN="${XUI_API_TOKEN:-}"
  [[ -n $TOKEN ]] || die "В $XUI_ENV нет XUI_API_TOKEN."
  local i scheme
  for i in $(seq 1 60); do
    for scheme in https http; do
      API="$scheme://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api"
      if curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/server/getNewUUID" 2>/dev/null; then
        ok "API панели доступен ($scheme, порт $XUI_PANEL_PORT)"
        return 0
      fi
    done
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

api() {
  local method="$1" path="$2" data="${3:-}" out
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] API $method $path${C_N}" >&2
    printf '{}'
    return 0
  fi
  if [[ $method == GET ]]; then
    out=$(curl -fsSk -m 25 -H "Authorization: Bearer $TOKEN" "$API/$path")
  else
    out=$(curl -fsSk -m 25 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
          -X "$method" --data-binary "$data" "$API/$path")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] \
    || die "API $path: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  jq -c '.obj' <<<"$out"
}

panel_restart() {
  [[ $DRY_RUN == yes ]] && return 0
  systemctl restart x-ui
  panel_connect
}