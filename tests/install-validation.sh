#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

expect_fail() {
  local name="$1"; shift
  if bash install.sh --dry-run -y "$@" >"$tmp/$name.log" 2>&1; then
    echo "установщик: $name – ожидался отказ, но прошёл" >&2
    fail=1
  else
    echo "установщик: $name ok"
  fi
}

expect_ok() {
  local name="$1"; shift
  if bash install.sh --dry-run -y "$@" >"$tmp/$name.log" 2>&1; then
    echo "установщик: $name ok"
  else
    tail -5 "$tmp/$name.log" >&2
    echo "установщик: $name – неожиданный отказ" >&2
    fail=1
  fi
}

expect_fail conflict-sub --domain vpn.example.com --xhttp-sub vpn.example.com --protocols reality,ws,xhttp
expect_fail bad-domain --domain 'vpn.example.com;id' --protocols all
expect_fail sub-without-domain --xhttp-sub x.example.com --sni example.com --protocols ws,xhttp
expect_fail bad-sni --sni 'bad host' --protocols ws
expect_fail bad-client --sni example.com --protocols ws --user 'bad name'
expect_fail bad-cf-token --domain vpn.example.com --protocols ws --cf-token 'bad token!'
expect_fail bad-cf-file --domain vpn.example.com --protocols ws --cf-token-file /nonexistent/cf.token
expect_ok all-no-domain --sni example.com --protocols reality,ws,xhttp
expect_ok ws-no-domain --sni example.com --protocols ws
expect_ok all-with-domain --domain vpn.example.com --protocols reality,ws,xhttp

exit "$fail"
