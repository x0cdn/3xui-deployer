#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

fail=0

for f in install.sh get.sh bin/xui-deployer lib/*.sh tests/*.sh; do
  bash -n "$f" || { echo "bash -n: $f" >&2; fail=1; }
done
[[ $fail == 0 ]] && echo "bash -n: ok"

if python3 -m py_compile client-sub/client_sub.py; then
  echo "py_compile: ok"
else
  fail=1
fi
rm -rf client-sub/__pycache__

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -S warning -e SC1090,SC2034,SC2229 install.sh get.sh bin/xui-deployer lib/*.sh tests/*.sh check.sh; then
    echo "shellcheck: ok"
  else
    fail=1
  fi
else
  echo "shellcheck: не установлен, пропущен"
fi

if bash tests/client-sub-smoke.sh; then
  :
else
  fail=1
fi

if bash tests/install-validation.sh; then
  :
else
  fail=1
fi

if [[ -n ${NGINX_BIN:-} ]] || command -v nginx >/dev/null 2>&1 || [[ -x /usr/sbin/nginx ]]; then
  if bash tests/nginx-stream.sh; then
    :
  else
    fail=1
  fi
else
  echo "nginx: не установлен, проверка конфига пропущена"
fi

exit "$fail"
