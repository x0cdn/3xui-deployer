
CERT_ROOT="/root/cert"
ACME="/root/.acme.sh/acme.sh"
ACME_LOG="/var/log/xui-deployer-acme.log"
IP_CERT_DIR=""; IP_FULLCHAIN=""; IP_KEY=""
declare -A CERTS=() KEYS=()

ensure_acme() {
  if [[ -x $ACME ]]; then return 0; fi
  step "Установка acme.sh"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] установка acme.sh${C_N}"; return 0
  fi
  curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@$(hostname -f 2>/dev/null || echo localhost)}" >/dev/null 2>&1 \
    || die "Не удалось установить acme.sh."
  [[ -x $ACME ]] || die "acme.sh не появился в $ACME"
  ok "acme.sh установлен"
}

_acme_open_80() {
  command -v ufw >/dev/null 2>&1 || return 0
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then return 0; fi
  if ufw status 2>/dev/null | grep -qE '^80(/tcp)? +ALLOW'; then return 0; fi
  if ufw allow 80/tcp >/dev/null 2>&1; then ACME_OPENED_80=yes; fi
  return 0
}
_acme_close_80() {
  [[ ${ACME_OPENED_80:-no} == yes ]] || return 0
  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ACME_OPENED_80=no
}

cert_issue_ip() {
  local ip="$1"
  IP_CERT_DIR="$CERT_ROOT/ip"
  IP_FULLCHAIN="$IP_CERT_DIR/fullchain.pem"
  IP_KEY="$IP_CERT_DIR/privkey.pem"
  step "Сертификат Let's Encrypt на IP ($ip, shortlived)"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] acme.sh --issue -d $ip --standalone --keylength ec-256 --certificate-profile shortlived${C_N}"
    return 0
  fi
  ensure_acme
  mkdir -p "$IP_CERT_DIR"
  _acme_open_80
  "$ACME" --issue -d "$ip" --standalone --httpport 80 --server letsencrypt --keylength ec-256 \
    --certificate-profile shortlived >>"$ACME_LOG" 2>&1 \
    || warn "Let's Encrypt не выдал сертификат на IP (лимит/порт 80). Будет самоподписанный."
  if "$ACME" --install-cert -d "$ip" --ecc \
      --fullchain-file "$IP_FULLCHAIN" --key-file "$IP_KEY" \
      --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true" >>"$ACME_LOG" 2>&1; then
    ok "Сертификат на IP готов: $IP_CERT_DIR"
  else
    warn "Выдаю самоподписанный сертификат на IP (запасной, клиенты будут ругаться на TLS)."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$IP_KEY" -out "$IP_FULLCHAIN" -days 3650 -subj "/CN=$ip" \
      -addext "subjectAltName=IP:$ip" >/dev/null 2>&1
    chmod 600 "$IP_KEY"
  fi
  _acme_close_80
}

cert_issue_domain() {
  local name="$1" cf="${2:-}" dir
  dir="$CERT_ROOT/$name"
  CERTS[$name]="$dir/fullchain.pem"
  KEYS[$name]="$dir/privkey.pem"
  step "Сертификат Let's Encrypt на $name"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] acme.sh --issue -d $name (${cf:+dns_cf}${cf:-standalone})${C_N}"
    return 0
  fi
  ensure_acme
  mkdir -p "$dir"
  local method=(--standalone --httpport 80)
  if [[ -n $cf ]]; then
    export CF_Token="$cf"
    method=(--dns dns_cf)
  else
    _acme_open_80
  fi
  "$ACME" --issue -d "$name" "${method[@]}" --server letsencrypt --keylength ec-256 \
    >>"$ACME_LOG" 2>&1 \
    || die "Не удалось выпустить сертификат на $name. Проверьте DNS (A-запись на этот сервер) и порт 80. Лог: $ACME_LOG"
  "$ACME" --install-cert -d "$name" --ecc \
    --fullchain-file "${CERTS[$name]}" --key-file "${KEYS[$name]}" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true" >>"$ACME_LOG" 2>&1 \
    || die "Не удалось установить сертификат на $name."
  _acme_close_80
  ok "Сертификат на $name готов: $dir"
}