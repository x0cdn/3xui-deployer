
setup_firewall() {
  local ssh="$1"
  [[ $CONFIGURE_UFW == yes ]] || { info "  UFW пропущен (--no-ufw)."; return 0; }
  step "Настройка файрвола (UFW)"
  if [[ $DRY_RUN == yes ]]; then
    info "  ${C_D}[dry-run] ufw: allow $ssh/tcp, 80/tcp, 443/tcp${C_N}"
    return 0
  fi
  command -v ufw >/dev/null 2>&1 || { warn "ufw не найден – пропущен."; return 0; }

  ufw allow "$ssh/tcp" >/dev/null
  [[ $ssh != 22 ]] && ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null || warn "ufw не включился (контейнер?) – откройте порты у хостера."
  ok "UFW настроен (SSH $ssh, 80, 443)"
}