
CLIENT_SUB_ACTIVE="no"
CLIENT_SUB_PORT=10460

setup_client_sub() {
  if [[ $INSTALL_CLIENT_SUB != yes ]]; then
    info "  client-sub пропущен: подписка будет отдаваться панелью напрямую."
    return 0
  fi
  step "Установка client-sub (подписка с учётом приложения)"
  if [[ $DRY_RUN == yes ]]; then
    CLIENT_SUB_ACTIVE="yes"
    info "  ${C_D}[dry-run] client_sub.py -> 127.0.0.1:$CLIENT_SUB_PORT, systemd-сервис${C_N}"
    return 0
  fi

  [[ -f "$PROJECT_DIR/client-sub/client_sub.py" ]] || die "Нет client-sub/client_sub.py в составе установщика."
  port_busy "$CLIENT_SUB_PORT" tcp && CLIENT_SUB_PORT="$(free_port "$CLIENT_SUB_PORT")"

  install -d -m 0755 /usr/local/lib/client-sub /etc/client-sub
  install -m 0644 "$PROJECT_DIR/client-sub/client_sub.py" /usr/local/lib/client-sub/client_sub.py

  jq -nc --arg path "$SUB_PATH" --arg host "$HOST" --arg link "${DOMAIN:-$HOST}" \
    --argjson port "$CLIENT_SUB_PORT" --argjson up "\"http://127.0.0.1:$SUB_PORT\"" \
    --arg cp "$SUB_CLASH_PATH" --arg jp "$SUB_JSON_PATH" '{
      listen:"127.0.0.1", port:$port, path:$path, upstream:$up,
      host:$host, link_host:$link, extra_paths:[$cp, $jp]}' \
    > /etc/client-sub/config.json
  chmod 600 /etc/client-sub/config.json

  _render "$TEMPLATES_DIR/client-sub.service.in" /etc/systemd/system/client-sub.service
  systemctl daemon-reload
  systemctl enable --now client-sub >/dev/null 2>&1 || die "client-sub не запустился: journalctl -u client-sub -n 30"
  CLIENT_SUB_ACTIVE="yes"
  ok "client-sub запущен (127.0.0.1:$CLIENT_SUB_PORT -> подписка панели :$SUB_PORT)"
}

configure_sub_routing() {
  [[ $INSTALL_CLIENT_SUB == yes ]] || return 0
  step "Раздельная маршрутизация подписки (rules.yaml)"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] при наличии /etc/client-sub/rules.yaml – профиль для Happ и JSON-подписки${C_N}"
    return 0
  fi
  local rules="/etc/client-sub/rules.yaml" py="/usr/local/lib/client-sub/client_sub.py"
  if [[ ! -s $rules ]]; then
    info "  rules.yaml нет – маршрутизация по умолчанию (весь трафик через VPN)."
    return 0
  fi
  local happ json
  if ! happ=$(python3 "$py" --routing-payload happ) || ! json=$(python3 "$py" --routing-payload json); then
    warn "rules.yaml не разобран – маршрутизацию в панель не передаю (проверьте: xui-deployer routing)."
    return 0
  fi
  local all upd
  all=$(api POST setting/all '{}')
  upd=$(jq -c --arg happ "$happ" --arg json "$json" \
    '.subEnableRouting = true | .subRoutingRules = $happ | .subJsonRoutingRules = $json' <<<"$all")
  api POST setting/update "$upd" >/dev/null
  panel_restart
  ok "маршрутизация из rules.yaml передана панели (Happ и JSON-подписка Xray)"
}