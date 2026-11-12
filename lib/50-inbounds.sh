
declare -A INNER=([reality]=10443 [xhttp]=10444 [front]=10446 [selfweb]=10447 [ws]=10451)

CLIENT_UUID=""
SUBID=""
CREATED=()
WS_PATH=""
XHTTP_PATH=""
XHTTP_IN_FRONT="no"
REALITY_SNI=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""

inbounds_init() {
  CLIENT_UUID="$(uuid)"
  SUBID="$(rand_str 16 | tr 'A-Z' 'a-z')"
  WS_PATH="/$(rand_str 10 | tr 'A-Z' 'a-z')"
  XHTTP_PATH="/$(rand_str 10 | tr 'A-Z' 'a-z')"
}

_client_base() {
  jq -nc --arg e "$CLIENT_NAME" --arg s "$SUBID" \
    '{email:$e, limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0, subId:$s, comment:"xui-deployer", reset:0}'
}

_reality_keys() {
  if [[ $DRY_RUN == yes ]]; then
    printf '{"privateKey":"<dry-run>","publicKey":"<dry-run>"}'
  else
    api GET server/getNewX25519Cert
  fi
}

add_inbound() {
  local remark="$1" port="$2" listen="$3" protocol="$4" settings="$5" stream="$6" sniff="$7"
  local body
  body=$(jq -nc --arg rm "$remark" --argjson port "$port" --arg p "$protocol" \
    --argjson s "$settings" --argjson st "$stream" --argjson sn "$sniff" --arg l "$listen" '{
      remark:$rm, enable:true, listen:$l, port:$port, protocol:$p, settings:$s, streamSettings:$st,
      sniffing:$sn, expiryTime:0, total:0}')
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] inbound $remark ($protocol, port=$port, listen=${listen:-0.0.0.0})${C_N}"
  else
    api POST inbounds/add "$body" >/dev/null || die "Не создалось подключение $remark"
    ok "Подключение: $remark (порт $port)"
  fi
  CREATED+=("$remark")
}

SNIFF_ON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
SNIFF_OFF='{"enabled":false}'

proto_reality() {
  local keys settings stream target sni link_host
  sni="${DOMAIN:-$SNI}"
  REALITY_SNI="$sni"
  link_host="${DOMAIN:-$HOST}"
  if [[ -n $DOMAIN ]]; then target="127.0.0.1:${INNER[selfweb]}"; else target="$sni:443"; fi
  keys="$(_reality_keys)"
  REALITY_PUBLIC_KEY=$(jq -r '.publicKey' <<<"$keys")
  REALITY_SHORT_ID="$(rand_hex 8)"
  settings=$(jq -nc --arg id "$CLIENT_UUID" --argjson c "$(_client_base)" \
    '{clients:[$c + {id:$id, flow:"xtls-rprx-vision"}], decryption:"none", fallbacks:[]}')
  stream=$(jq -nc --arg sni "$sni" --arg target "$target" --argjson k "$keys" --arg sid "$REALITY_SHORT_ID" \
    --arg h "$link_host" '{
    network:"tcp", security:"reality",
    externalProxy:[{forceTls:"same", dest:$h, port:443, remark:""}],
    realitySettings:{show:false, xver:0, target:$target, serverNames:[$sni], privateKey:$k.privateKey,
      minClientVer:"", maxClientVer:"", maxTimediff:0, shortIds:[$sid],
      settings:{publicKey:$k.publicKey, fingerprint:"firefox", serverName:"", spiderX:"/"}},
    tcpSettings:{acceptProxyProtocol:true, header:{type:"none"}}}')
  add_inbound "REALITY" "${INNER[reality]}" "127.0.0.1" vless "$settings" "$stream" "$SNIFF_ON"
}

proto_ws() {
  local settings stream
  settings=$(jq -nc --arg id "$CLIENT_UUID" --argjson c "$(_client_base)" \
    '{clients:[$c + {id:$id, flow:""}], decryption:"none"}')
  stream=$(jq -nc --arg path "$WS_PATH" --arg h "$HOST" \
    '{network:"ws", security:"none", wsSettings:{path:$path},
      externalProxy:[{forceTls:"tls", dest:$h, port:443, remark:"", fingerprint:"firefox", alpn:["http/1.1"]}]}')
  add_inbound "VLESS-WS" "${INNER[ws]}" "127.0.0.1" vless "$settings" "$stream" "$SNIFF_ON"
}

proto_xhttp() {
  local settings stream
  settings=$(jq -nc --arg id "$CLIENT_UUID" --argjson c "$(_client_base)" \
    '{clients:[$c + {id:$id, flow:""}], decryption:"none", encryption:"none"}')
  if [[ -n $XHTTP_SUB ]]; then
    stream=$(jq -nc --arg path "$XHTTP_PATH" --arg sub "$XHTTP_SUB" \
      '{network:"xhttp", security:"none",
        xhttpSettings:{path:$path, host:$sub, mode:"packet-up", xPaddingBytes:"100-1000", scMaxBufferedPosts:30},
        externalProxy:[{forceTls:"tls", dest:$sub, port:443, remark:"", fingerprint:"firefox", alpn:["h2","http/1.1"], sni:$sub}]}')
  else
    XHTTP_IN_FRONT="yes"
    stream=$(jq -nc --arg path "$XHTTP_PATH" --arg h "$HOST" \
      '{network:"xhttp", security:"none",
        xhttpSettings:{path:$path, mode:"auto"},
        externalProxy:[{forceTls:"tls", dest:$h, port:443, remark:"", fingerprint:"firefox", alpn:["h2","http/1.1"]}]}')
  fi
  add_inbound "XHTTP TLS" "${INNER[xhttp]}" "127.0.0.1" vless "$settings" "$stream" "$SNIFF_OFF"
}

create_inbounds() {
  local p
  inbounds_init
  for p in $1; do
    case "$p" in
      reality) proto_reality ;;
      ws)      proto_ws ;;
      xhttp)   proto_xhttp ;;
      *) warn "Неизвестный протокол: $p – пропущен." ;;
    esac
  done
}