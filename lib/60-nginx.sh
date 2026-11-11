
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
NGINX_STREAM="$NGINX_CONF_DIR/xui-stream.conf"
NGINX_FRONT="$NGINX_CONF_DIR/conf.d/xui-front.conf"
WEB_ROOT="/var/www/xui-deployer"

_created() { [[ " ${CREATED[*]:-} " == *" $1 "* ]]; }

_render() {
  local tpl="$1" out="$2"; shift 2
  local content
  content="$(cat "$tpl")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    content="${content//@$key@/$val}"
  done
  printf '%s\n' "$content" > "$out"
}

_xhttp_locations() {
  local up="$1" ind="${2:-    }"
  cat <<EOF
${ind}location = $XHTTP_PATH {
${ind}    proxy_pass http://127.0.0.1:$up;
${ind}    proxy_http_version 1.1;
${ind}    proxy_set_header Host \$host;
${ind}    proxy_set_header X-Real-IP \$proxy_protocol_addr;
${ind}    proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
${ind}    proxy_set_header X-Forwarded-Proto https;
${ind}    proxy_buffering off;
${ind}    proxy_request_buffering off;
${ind}    proxy_read_timeout 1h;
${ind}    proxy_send_timeout 1h;
${ind}    client_max_body_size 0;
${ind}}
${ind}location ^~ $XHTTP_PATH/ {
${ind}    proxy_pass http://127.0.0.1:$up;
${ind}    proxy_http_version 1.1;
${ind}    proxy_set_header Host \$host;
${ind}    proxy_set_header X-Real-IP \$proxy_protocol_addr;
${ind}    proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
${ind}    proxy_set_header X-Forwarded-Proto https;
${ind}    proxy_buffering off;
${ind}    proxy_request_buffering off;
${ind}    proxy_read_timeout 1h;
${ind}    proxy_send_timeout 1h;
${ind}    client_max_body_size 0;
${ind}}
EOF
}

setup_nginx() {
  step "Настройка nginx (всё TCP на 443)"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] генерация $NGINX_STREAM и $NGINX_FRONT${C_N}"
    return 0
  fi

  mkdir -p "$WEB_ROOT" "$NGINX_CONF_DIR/conf.d"
  _render "$TEMPLATES_DIR/landing.html.in" "$WEB_ROOT/index.html" "TITLE=${SUB_TITLE:-xui-deployer}"

  _render "$TEMPLATES_DIR/nginx-stream.conf.in" "$NGINX_STREAM" \
    "REALITY_SNI=$REALITY_SNI" "REALITY_PORT=${INNER[reality]}" "FRONT_PORT=${INNER[front]}"
  if ! grep -q "include $NGINX_STREAM;" "$NGINX_CONF_DIR/nginx.conf"; then
    printf '\ninclude %s;\n' "$NGINX_STREAM" >> "$NGINX_CONF_DIR/nginx.conf"
  fi

  local sub_up="$SUB_PORT"
  [[ ${CLIENT_SUB_ACTIVE:-no} == yes ]] && sub_up="$CLIENT_SUB_PORT"

  {
    cat <<EOF
server {
    listen 127.0.0.1:${INNER[front]} ssl http2 proxy_protocol;
    server_name _;
    ssl_certificate $IP_FULLCHAIN;
    ssl_certificate_key $IP_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    absolute_redirect off;
    access_log off;

EOF

    if _created "VLESS-WS"; then
      cat <<EOF
    location = $WS_PATH {
        proxy_pass http://127.0.0.1:${INNER[ws]};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_read_timeout 1h;
    }

EOF
    fi

    if _created "XHTTP TLS" && [[ $XHTTP_IN_FRONT == yes ]]; then
      _xhttp_locations "${INNER[xhttp]}"
      printf '\n'
    fi

    cat <<EOF
    location $SUB_PATH { proxy_pass http://127.0.0.1:$sub_up; proxy_set_header Host \$host; }
    location $SUB_JSON_PATH { proxy_pass http://127.0.0.1:$sub_up; proxy_set_header Host \$host; }
    location $SUB_CLASH_PATH { proxy_pass http://127.0.0.1:$sub_up; proxy_set_header Host \$host; }

    location /${XUI_WEB_BASE_PATH}/ {
        proxy_pass https://127.0.0.1:$XUI_PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / { root $WEB_ROOT; index index.html; }
}
EOF

    if _created "XHTTP TLS" && [[ -n $XHTTP_SUB ]]; then
      cat <<EOF

server {
    listen 127.0.0.1:${INNER[front]} ssl http2 proxy_protocol;
    server_name $XHTTP_SUB;
    ssl_certificate ${CERTS[$XHTTP_SUB]};
    ssl_certificate_key ${KEYS[$XHTTP_SUB]};
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    absolute_redirect off;
    access_log off;

EOF
      _xhttp_locations "${INNER[xhttp]}"
      cat <<EOF

    location / { root $WEB_ROOT; index index.html; }
    location ~ /\. { deny all; }
}
EOF
    fi

    if [[ -n $DOMAIN ]]; then
      cat <<EOF

server {
    listen 127.0.0.1:${INNER[selfweb]} ssl http2;
    server_name $DOMAIN;
    ssl_certificate ${CERTS[$DOMAIN]};
    ssl_certificate_key ${KEYS[$DOMAIN]};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    location / { root $WEB_ROOT; index index.html; }
}
EOF
    fi
  } > "$NGINX_FRONT"

  nginx -t >/dev/null 2>&1 || { nginx -t >&2; die "nginx не принял конфиг (лог выше)."; }
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  ok "nginx настроен: 443 -> SNI (REALITY / фронт${XHTTP_SUB:+ / $XHTTP_SUB})"
}