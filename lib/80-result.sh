
STATE_DIR="/etc/xui-deployer"
RESULT_FILE="/root/xui-deployer.txt"

fetch_links() {
  [[ $DRY_RUN == yes ]] && return 0
  curl -fsSk -m 15 -A "v2rayNG/1.8.5" "${SUB_URL}${SUBID}" 2>/dev/null | base64 -d 2>/dev/null || true
}

write_result() {
  step "Сохранение результата"
  local user pass panel_port panel_path sub_link panel_url links
  user="${XUI_USERNAME:-$PANEL_USER}"
  pass="${XUI_PASSWORD:-$PANEL_PASS}"
  panel_port="${XUI_PANEL_PORT:-$PANEL_PORT_CHOICE}"
  panel_path="${XUI_WEB_BASE_PATH:-$PANEL_PATH_CHOICE}"
  sub_link="${SUB_URL}${SUBID}"
  panel_url="https://$HOST/$panel_path/"
  links="$(fetch_links)"

  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] запись $RESULT_FILE и $STATE_DIR/state.env${C_N}"
    info "  панель: $panel_url  логин: $user"
    info "  подписка: $sub_link"
    return 0
  fi

  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/state.env" <<EOF
HOST=$HOST
DOMAIN=$DOMAIN
XHTTP_SUB=$XHTTP_SUB
PROTOCOLS="$PROTOCOLS_SELECTED"
SSH_PORT=$SSH_PORT_FINAL
PANEL_PORT=$panel_port
PANEL_PATH=$panel_path
PANEL_USER=$user
SUBID=$SUBID
SUB_URL=$SUB_URL
SUB_LINK=$sub_link
PANEL_URL=$panel_url
REALITY_SNI=$REALITY_SNI
CLIENT_SUB_ACTIVE=$CLIENT_SUB_ACTIVE
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$STATE_DIR/state.env"

  {
    cat <<EOF
xui-deployer – данные для входа (файл виден только root)
Развёрнуто: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Панель:   $panel_url
Логин:    $user
Пароль:   $pass

Подписка (все протоколы одной ссылкой, клиент ${CLIENT_NAME}):
$sub_link

Домен маскировки: ${DOMAIN:-<IP / $REALITY_SNI>}
XHTTP-поддомен:   ${XHTTP_SUB:-<через IP:443>}
Протоколы:        $PROTOCOLS_SELECTED
client-sub:       $CLIENT_SUB_ACTIVE

Ссылки по протоколам:
${links:-(подписка пока не отдала ссылки – проверьте xui-deployer links)}

Управление:  xui-deployer info | status | links | routing | backup | restart
Конфиги:     /etc/nginx/xui-stream.conf, /etc/nginx/conf.d/xui-front.conf
Сертификаты: /root/cert/ (acme.sh, автопродление)
Состояние:   $STATE_DIR/state.env
EOF
  } > "$RESULT_FILE"
  chmod 600 "$RESULT_FILE"

  if [[ -f "$PROJECT_DIR/bin/xui-deployer" ]]; then
    install -m 0755 "$PROJECT_DIR/bin/xui-deployer" /usr/local/bin/xui-deployer
  fi
  ok "Результат сохранён: $RESULT_FILE"
}

print_summary() {
  local user pass panel_path sub_link panel_url
  user="${XUI_USERNAME:-$PANEL_USER}"
  pass="${XUI_PASSWORD:-$PANEL_PASS}"
  panel_path="${XUI_WEB_BASE_PATH:-$PANEL_PATH_CHOICE}"
  sub_link="${SUB_URL}${SUBID}"
  panel_url="https://$HOST/$panel_path/"
  printf '\n%s\n' "${C_G}${C_B}═══ Готово ═══${C_N}"
  printf '  %sПанель:%s   %s\n' "$C_B" "$C_N" "$panel_url"
  printf '  %sЛогин:%s    %s\n' "$C_B" "$C_N" "$user"
  printf '  %sПароль:%s   %s\n' "$C_B" "$C_N" "$pass"
  printf '  %sПодписка:%s %s\n' "$C_B" "$C_N" "$sub_link"
  if [[ $DRY_RUN != yes ]]; then
    local links
    links="$(fetch_links)"
    if [[ -n $links ]]; then
      printf '\n  %sСсылки по протоколам:%s\n' "$C_B" "$C_N"
      printf '%s\n' "$links" | sed 's/^/    /'
    fi
  fi
  printf '\n  Реквизиты: %s\n  Управление: %s\n\n' "$RESULT_FILE" "xui-deployer {info|status|links|routing|backup|restart}"
}