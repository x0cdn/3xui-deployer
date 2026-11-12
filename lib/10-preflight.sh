
PREFLIGHT_PACKAGES=(curl jq openssl qrencode ca-certificates iproute2 ufw socat cron unzip python3 python3-yaml libnginx-mod-stream)

preflight_check() {
  if [[ $DRY_RUN == yes ]]; then
    warn "dry-run: проверки окружения пропущены (система не меняется)."
    return 0
  fi
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash install.sh"
  command -v apt-get >/dev/null 2>&1 || die "Поддерживается только Debian/Ubuntu (apt-get не найден)."
  [[ -d /usr/local/x-ui ]] && die "3X-UI уже установлена на этом сервере. Ставьте на чистый VPS."
  [[ -d /run/systemd/system ]] || die "Нужен systemd (запустите на полноценном VPS, не в контейнере без systemd)."
  local arch
  arch="$(uname -m)"
  [[ $arch == x86_64 || $arch == aarch64 ]] || die "Архитектура $arch не поддержана (нужна x86_64 или aarch64)."
  if port_busy 443 tcp; then
    die "Порт 443 уже занят. Освободите его (apache/nginx/caddy) перед установкой."
  fi
}

wait_apt_idle() {
  local i
  pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null 2>&1 || return 0
  info "  Система сама ставит обновления – жду освобождения замка dpkg (до 15 минут)…"
  for i in $(seq 1 180); do
    pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null 2>&1 || return 0
    sleep 5
  done
}

apt_get() { command apt-get -o DPkg::Lock::Timeout=900 "$@"; }

preflight_packages() {
  step "Установка зависимостей"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] apt-get install ${PREFLIGHT_PACKAGES[*]} nginx${C_N}"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  wait_apt_idle
  apt_get update -qq || warn "apt update завершился с ошибкой – пробую продолжить."
  apt_get install -y -qq "${PREFLIGHT_PACKAGES[@]}" nginx >/dev/null \
    || die "Не удалось установить пакеты. Проверьте apt и репозитории."
  if [[ -L /etc/nginx/sites-enabled/default || -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
  fi
  ensure_nginx_stream
  ok "Пакеты установлены (${#PREFLIGHT_PACKAGES[@]} + nginx)"
}

ensure_nginx_stream() {
  local nv
  nv="$(nginx -V 2>&1 || true)"
  if [[ $nv == *--with-stream=dynamic* ]]; then
    [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]] \
      || die "nginx собран с динамическим stream, но модуль не найден: установите libnginx-mod-stream."
  fi
  if [[ $nv != *--with-stream* && ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    die "nginx без модуля stream: установите libnginx-mod-stream и повторите."
  fi
  if [[ $nv == *--with-stream=dynamic* || -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    if ! grep -rqs 'ngx_stream_module' /etc/nginx/modules-enabled /etc/nginx/nginx.conf 2>/dev/null; then
      mkdir -p /etc/nginx/modules-enabled
      printf 'load_module modules/ngx_stream_module.so;\n' > /etc/nginx/modules-enabled/50-mod-stream.conf
    fi
  fi
  nginx -t >/dev/null 2>&1 || die "nginx не принимает базовый конфиг после установки модулей."
}

detect_public_ip() {
  local ip=""
  ip=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -fsS -m 8 https://ifconfig.me 2>/dev/null) \
    || ip=$(curl -fsS -m 8 https://ip.sb 2>/dev/null) \
    || true
  if [[ ! $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  printf '%s' "$ip"
}

detect_ssh_port() {
  local p
  p=$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')
  [[ -z $p ]] && p=$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
  [[ -z $p ]] && p=22
  printf '%s' "$p"
}