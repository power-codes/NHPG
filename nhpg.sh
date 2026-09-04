

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "This script must be run as root (sudo)."; exit 1; }

CFG=/opt/hiddify-manager/haproxy/haproxy.cfg
CONF=/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf
WORKER=/opt/hiddify-manager/haproxy/pasarguard_reapply.sh
SERVICE=/etc/systemd/system/pasarguard-watchdog.service
PATH_UNIT=/etc/systemd/system/pasarguard-watchdog.path
LOG=/var/log/pasarguard_watchdog.log

# ---------------------------------------------------------------------------
# Cleanup old separate units
# ---------------------------------------------------------------------------
cleanup_old_units() {
  for u in sni-reapply cdn-path-reapply; do
    systemctl disable --now "${u}.path" >/dev/null 2>&1 || true
    systemctl disable --now "${u}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${u}.service" "/etc/systemd/system/${u}.path"
  done
  rm -f /opt/hiddify-manager/haproxy/sni_reapply.sh \
        /opt/hiddify-manager/haproxy/cdn_path_reapply.sh
  systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Save Configuration
# ---------------------------------------------------------------------------
save_conf() {
  {
    echo "REALITY_PORT=$REALITY_PORT"
    echo "REALITY_BACKEND=$REALITY_BACKEND"
    echo "REALITY_SNIS=("
    for s in "${REALITY_SNIS[@]}"; do
      echo "  \"$s\""
    done
    echo ")"
  } > "$CONF"
  echo "[+] Configuration saved: $CONF"
}

# ---------------------------------------------------------------------------
# Write Worker Script (The Watchdog logic)
# ---------------------------------------------------------------------------
write_worker() {
cat > "$WORKER" <<'EOF'
#!/bin/bash
set -euo pipefail

CONF=/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf
CFG=/opt/hiddify-manager/haproxy/haproxy.cfg
LOG=/var/log/pasarguard_watchdog.log
ANCHOR_REALITY="tcp-request content accept if { req.ssl_hello_type 1 }"

# shellcheck source=/dev/null
source "$CONF"

CHANGED=0

# ---- Reality: Add any SNI that is missing from the config ----
for SNI in "${REALITY_SNIS[@]}"; do
  grep -qF "use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$CFG" || {
    sed -i "/${ANCHOR_REALITY//\//\\/}/a\\    use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$CFG"
    CHANGED=1
  }
done

# ---- Reality backend block: Ensure it exists exactly once ----
grep -q "^backend ${REALITY_BACKEND}\$" "$CFG" || {
  printf '\nbackend %s\n    mode tcp\n    server pg_reality 127.0.0.1:%s send-proxy-v2\n' \
    "$REALITY_BACKEND" "$REALITY_PORT" >> "$CFG"
  CHANGED=1
}

if [[ $CHANGED -eq 1 ]]; then
  if haproxy -c -f "$CFG"; then
    systemctl reload hiddify-haproxy
    echo "$(date '+%F %T') OK - Reality SNIs reapplied + HAProxy reloaded" >> "$LOG"
  else
    echo "$(date '+%F %T') CONFIG CHECK FAILED - HAProxy reload skipped" >> "$LOG"
  fi
else
  echo "$(date '+%F %T') No changes needed" >> "$LOG"
fi
EOF
chmod +x "$WORKER"
}

# ---------------------------------------------------------------------------
# Write Systemd Units
# ---------------------------------------------------------------------------
write_systemd_units() {
cat > "$SERVICE" <<EOF
[Unit]
Description=Reapply Pasarguard Reality backends into haproxy.cfg

[Service]
Type=oneshot
ExecStart=$WORKER
EOF

cat > "$PATH_UNIT" <<EOF
[Unit]
Description=Watch haproxy.cfg and instantly reapply Reality SNIs

[Path]
PathModified=$CFG
Unit=pasarguard-watchdog.service

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Option 1: Full Installation
# ---------------------------------------------------------------------------
do_install() {
  echo "--- Reality Configuration ---"
  read -rp "Enter Reality Port (e.g., 20001): " REALITY_PORT

  REALITY_SNIS=()
  read -rp "Enter first SNI: " sni1
  REALITY_SNIS+=("$sni1")
  while true; do
    read -rp "Enter next SNI (Enter 0 or leave blank to finish): " sni_next
    [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
    REALITY_SNIS+=("$sni_next")
  done

  REALITY_BACKEND=pasarguard_reality

  save_conf
  cleanup_old_units
  write_worker
  write_systemd_units

  systemctl daemon-reload
  systemctl enable --now pasarguard-watchdog.path
  systemctl start pasarguard-watchdog.service

  echo "[+] Installation completed successfully."
  do_status
}

# ---------------------------------------------------------------------------
# Option 2: Status
# ---------------------------------------------------------------------------
do_status() {
  if [[ ! -f "$CONF" ]]; then
    echo "Not installed yet. Please run Option 1 first."
    return
  fi
  echo -e "\n--- Current Configuration ---"
  cat "$CONF"
  echo -e "\n--- Watchdog Status ---"
  systemctl status pasarguard-watchdog.path --no-pager || true
  echo -e "\n--- Recent Logs ---"
  tail -n 15 "$LOG" 2>/dev/null || echo "No logs found yet."
}

# ---------------------------------------------------------------------------
# Option 3: Edit / Add SNI
# ---------------------------------------------------------------------------
do_edit() {
  if [[ ! -f "$CONF" ]]; then
    echo "You must install first (Option 1)."
    return
  fi
  # shellcheck source=/dev/null
  source "$CONF"

  read -rp "Reality Port [$REALITY_PORT] (Press Enter to keep): " v; REALITY_PORT="${v:-$REALITY_PORT}"

  echo "Current SNIs: ${REALITY_SNIS[*]}"
  echo "Choose an action for SNIs:"
  echo "  1) Add new SNIs to the current list"
  echo "  2) Overwrite (clear and enter from scratch)"
  echo "  3) Keep current SNIs unchanged"
  read -rp "Action [1/2/3]: " sni_action

  if [[ "$sni_action" == "1" ]]; then
    while true; do
      read -rp "Enter new SNI to ADD (Enter 0 to stop): " sni_next
      [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
      REALITY_SNIS+=("$sni_next")
    done
  elif [[ "$sni_action" == "2" ]]; then
    REALITY_SNIS=()
    read -rp "Enter first SNI: " sni1
    REALITY_SNIS+=("$sni1")
    while true; do
      read -rp "Enter next SNI (Enter 0 to stop): " sni_next
      [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
      REALITY_SNIS+=("$sni_next")
    done
  fi

  save_conf
  
  # Re-create worker and systemd if they were accidentally deleted
  [[ -x "$WORKER" ]] || write_worker
  [[ -f "$SERVICE" && -f "$PATH_UNIT" ]] || { write_systemd_units; systemctl daemon-reload; systemctl enable --now pasarguard-watchdog.path; }

  echo "[+] Applying changes immediately..."
  systemctl start pasarguard-watchdog.service
  do_status
}

# ---------------------------------------------------------------------------
# Main Menu
# ---------------------------------------------------------------------------
while true; do
  echo
  echo "=========================================="
  echo " Reality SNI Watchdog Manager (HAProxy)"
  echo "=========================================="
  echo "1) Full Install / Setup"
  echo "2) View Status & Logs"
  echo "3) Edit Config / Add SNI"
  echo "4) Exit"
  read -rp "Select an option: " choice
  case "$choice" in
    1) do_install ;;
    2) do_status ;;
    3) do_edit ;;
    4) echo "Exiting..."; exit 0 ;;
    *) echo "Invalid option. Please try again." ;;
  esac
done

