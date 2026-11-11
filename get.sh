#!/usr/bin/env bash
set -euo pipefail

REPO="${XUI_DEPLOYER_REPO:-x0cdn/3xui-deployer}"
REF="${XUI_DEPLOYER_REF:-main}"

if [[ $REPO == OWNER/* ]]; then
  echo "get.sh: не задан репозиторий. Укажите XUI_DEPLOYER_REPO=аккаунт/xui-deployer" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Скачиваю $REPO ($REF)…"
curl -fsSL --retry 3 "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" -o "$tmp/repo.tar.gz"
tar -xzf "$tmp/repo.tar.gz" -C "$tmp"
dir="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
[[ -f "$dir/install.sh" ]] || { echo "В архиве нет install.sh" >&2; exit 1; }
bash "$dir/install.sh" "$@"