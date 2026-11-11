
SUB_PATH=""
SUB_JSON_PATH=""
SUB_CLASH_PATH=""
SUB_PORT=2097
SUB_URL=""
PANEL_URL=""
SUB_TITLE="xui-deployer"

configure_settings() {
  local host="$1" cert="$2" key="$3"
  step "Настройка панели и подписки"
  SUB_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"
  SUB_JSON_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"
  SUB_CLASH_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"
  SUB_URL="https://$host$SUB_PATH"

  if [[ $DRY_RUN == yes ]]; then
    PANEL_URL="https://$host/${PANEL_PATH_CHOICE}/"
    info "  ${C_D}[dry-run] panel/sub settings (localhost, подписка $SUB_URL)${C_N}"
    return 0
  fi

  local all upd
  all=$(api POST setting/all '{}')
  upd=$(jq -c \
    --arg cert "$cert" --arg key "$key" \
    --arg sp "$SUB_PATH" --arg jp "$SUB_JSON_PATH" --arg cp "$SUB_CLASH_PATH" \
    --arg title "$SUB_TITLE" --arg uri "$SUB_URL" '
    .webListen = "127.0.0.1"
    | .webCertFile = $cert | .webKeyFile = $key
    | .subEnable = true | .subListen = "127.0.0.1" | .subPort = 2097
    | .subPath = $sp | .subJsonPath = $jp | .subClashPath = $cp
    | .subTitle = $title | .subURI = $uri
    | .subCertFile = "" | .subKeyFile = ""
    | .subEncrypt = true
    | .subClashEnable = true | .subClashAutoDetect = true
    | .subJsonEnable = true | .subJsonAutoDetect = true
    | .subUpdates = 12
    | .remarkTemplate = "{{INBOUND}}-{{EMAIL}}"
    | .trustedProxyCIDRs = "127.0.0.1/32,::1/128"
    | .restartXrayOnClientDisable = true' <<<"$all")

  api POST setting/update "$upd" >/dev/null
  panel_restart
  PANEL_URL="https://$host/${XUI_WEB_BASE_PATH}/"
  ok "Панель и подписка настроены (слушают localhost, наружу – nginx)"
}