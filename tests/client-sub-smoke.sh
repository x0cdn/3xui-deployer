#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/config.json" <<'JSON'
{"listen":"127.0.0.1","port":10460,"path":"test","upstream":"http://127.0.0.1:2097"}
JSON

cat > "$tmp/rules.yaml" <<'YAML'
via_vpn:
  - GEOSITE,youtube
  - DOMAIN-SUFFIX,example.org
  - IP-CIDR,203.0.113.0/24
direct_dns:
  - https://9.9.9.9/dns-query
YAML

export CLIENT_SUB_CONFIG="$tmp/config.json"
export CLIENT_SUB_RULES="$tmp/rules.yaml"

python3 client-sub/client_sub.py --check-rules >/dev/null

happ="$(python3 client-sub/client_sub.py --routing-payload happ)"
json="$(python3 client-sub/client_sub.py --routing-payload json)"

[[ $happ == happ://routing/onadd/* ]] || { echo "client-sub: happ payload не сформирован" >&2; exit 1; }
jq -e . >/dev/null <<<"$json" || { echo "client-sub: json payload невалиден" >&2; exit 1; }
[[ $(jq -r .DomainStrategy <<<"$json") == IPIfNonMatch ]] || { echo "client-sub: нет DomainStrategy" >&2; exit 1; }

echo "client-sub: ok"
