#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NGINX_BIN="${NGINX_BIN:-$(command -v nginx || true)}"
[[ -n $NGINX_BIN ]] || NGINX_BIN=/usr/sbin/nginx
[[ -x $NGINX_BIN ]] || { echo "nginx не найден" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/logs"

mod=""
for m in ${NGINX_MODULE:-} /usr/lib/nginx/modules/ngx_stream_module.so /usr/lib64/nginx/modules/ngx_stream_module.so; do
  [[ -n $m && -f $m ]] && mod="$m" && break
done

tpl="$(cat templates/nginx-stream.conf.in)"

render_stream() {
  local map="$1" upstream="$2" content="$tpl"
  content="${content//@REALITY_MAP@/$map}"
  content="${content//@STREAM_UPSTREAM@/$upstream}"
  content="${content//listen 443;/listen 18443;}"
  content="${content//listen \[::\]:443;/listen [::]:18443;}"
  printf '%s\n' "$content"
}

check_case() {
  local name="$1" map="$2" upstream="$3"
  local conf="$tmp/$name.conf"
  {
    printf 'error_log stderr;\n'
    printf 'pid %s/nginx.pid;\n' "$tmp"
    [[ -n $mod ]] && printf 'load_module %s;\n' "$mod"
    printf 'events {}\n'
    render_stream "$map" "$upstream"
  } > "$conf"
  if ! "$NGINX_BIN" -t -c "$conf" -p "$tmp" >"$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    echo "nginx: $name – конфиг отклонён" >&2
    exit 1
  fi
  echo "nginx: $name ok"
}

reality_map="    map \$ssl_preread_server_name \$xui_upstream {
        vpn.example.com 127.0.0.1:10443;
        default 127.0.0.1:10446;
    }"

check_case with-reality "$reality_map" '$xui_upstream'
check_case without-reality "" "127.0.0.1:10446"
