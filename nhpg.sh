cat << 'EOF' > /usr/local/bin/nhpg
#!/bin/bash
set -eo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: This script must be run as root (sudo)."; exit 1; }

CONF="/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf"
WORKER="/opt/hiddify-manager/haproxy/pasarguard_reapply.sh"
HAPROXY_CFG="/opt/hiddify-manager/haproxy/haproxy.cfg"
SERVICE="/etc/systemd/system/pasarguard-watchdog.service"
PATH_UNIT="/etc/systemd/system/pasarguard-watchdog.path"
LOG="/var/log/pasarguard_watchdog.log"

# ---------------------------------------------------------------------------
# Save Configuration
# ---------------------------------------------------------------------------
save_conf() {
  cat << CONF_EOF > "$CONF"
REALITY_PORT=$REALITY_PORT
REALITY_BACKEND=pasarguard_reality
REALITY_SNIS=(
$(for s in "${REALITY_SNIS[@]}"; do echo "  \"$s\""; done)
)
CDN_PORT=$CDN_PORT
CDN_BACKEND=pasarguard_cdn
CDN_PATH="$CDN_PATH"
SELECTED_DOMAIN="$SELECTED_DOMAIN"
CONF_EOF
  echo "[+] Configuration saved: $CONF"
}

# ---------------------------------------------------------------------------
# Worker Script (HAProxy Rule Injector)
# ---------------------------------------------------------------------------
write_worker() {
  cat << 'WORKER_EOF' > "$WORKER"
#!/bin/bash
set -eo pipefail

CONF="/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf"
HAPROXY_CFG="/opt/hiddify-manager/haproxy/haproxy.cfg"
LOG="/var/log/pasarguard_watchdog.log"
ANCHOR_REALITY="tcp-request content accept if { req.ssl_hello_type 1 }"

[[ -f "$CONF" ]] || exit 0
# shellcheck source=/dev/null
source "$CONF"

HAPROXY_CHANGED=0

if [[ -f "$HAPROXY_CFG" ]]; then
  # 1. Apply CDN Route directly in frontend in-httpmode (L7 routing)
  CLEAN_PATH="${CDN_PATH#/}"
  if ! grep -qF "use_backend ${CDN_BACKEND} if { path_beg /${CLEAN_PATH} }" "$HAPROXY_CFG"; then
    sed -i "/^frontend in-httpmode$/a\\  use_backend ${CDN_BACKEND} if { path_beg /${CLEAN_PATH} }" "$HAPROXY_CFG"
    HAPROXY_CHANGED=1
  fi

  # 2. Apply Reality Routes (L4 TCP SNI routing)
  for SNI in "${REALITY_SNIS[@]}"; do
    if ! grep -qF "use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$HAPROXY_CFG"; then
      sed -i "/${ANCHOR_REALITY//\//\\/}/a\\    use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$HAPROXY_CFG"
      HAPROXY_CHANGED=1
    fi
  done

  # 3. Ensure Reality Backend exists
  if ! grep -q "^backend ${REALITY_BACKEND}\$" "$HAPROXY_CFG"; then
    printf '\nbackend %s\n    mode tcp\n    server pg_reality 127.0.0.1:%s send-proxy-v2\n' \
      "$REALITY_BACKEND" "$REALITY_PORT" >> "$HAPROXY_CFG"
    HAPROXY_CHANGED=1
  fi

  # 4. Ensure CDN Backend exists
  if ! grep -q "^backend ${CDN_BACKEND}\$" "$HAPROXY_CFG"; then
    printf '\nbackend %s\n    mode http\n    timeout connect 10s\n    timeout server 1h\n    server pg_cdn 127.0.0.1:%s\n' \
      "$CDN_BACKEND" "$CDN_PORT" >> "$HAPROXY_CFG"
    HAPROXY_CHANGED=1
  fi

  # 5. Validate & Reload HAProxy
  if [[ $HAPROXY_CHANGED -eq 1 ]]; then
    if haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then
      systemctl reload hiddify-haproxy
      echo "$(date '+%F %T') OK - HAProxy: Rules reapplied and reloaded" >> "$LOG"
    else
      echo "$(date '+%F %T') CONFIG CHECK FAILED - HAProxy reload skipped" >> "$LOG"
    fi
  else
    echo "$(date '+%F %T') No changes needed" >> "$LOG"
  fi
fi
WORKER_EOF
  chmod +x "$WORKER"
}

# ---------------------------------------------------------------------------
# Systemd Watchdog Units
# ---------------------------------------------------------------------------
write_systemd_units() {
  cat << EOF_SRV > "$SERVICE"
[Unit]
Description=Reapply PasarGuard HAProxy Rules

[Service]
Type=oneshot
ExecStart=$WORKER
EOF_SRV

  cat << EOF_PATH > "$PATH_UNIT"
[Unit]
Description=Watch HAProxy config file for PasarGuard rules

[Path]
PathModified=$HAPROXY_CFG
Unit=pasarguard-watchdog.service

[Install]
WantedBy=multi-user.target
EOF_PATH
}

# ---------------------------------------------------------------------------
# Interactive Domain Selector
# ---------------------------------------------------------------------------
select_domain_interactive() {
  echo -e "\n--- Scanning for Domains in Hiddify ---"
  
  DOMAINS_TEMP=()
  if [[ -d "/opt/hiddify-manager/ssl" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && DOMAINS_TEMP+=("$(basename "$f" .crt)")
    done < <(find /opt/hiddify-manager/ssl/ -maxdepth 1 -name "*.crt" 2>/dev/null | grep -v 'play.google' || true)
  fi

  FOUND_DOMAINS=()
  if [[ ${#DOMAINS_TEMP[@]} -gt 0 ]]; then
    mapfile -t FOUND_DOMAINS < <(printf "%s\n" "${DOMAINS_TEMP[@]}" | sort -u | grep -v '^$')
  fi

  if [[ ${#FOUND_DOMAINS[@]} -eq 0 ]]; then
    read -rp "Enter your CDN Domain manually: " SELECTED_DOMAIN
    return
  fi

  echo "Available Domains:"
  for i in "${!FOUND_DOMAINS[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${FOUND_DOMAINS[$i]}"
  done

  while true; do
    read -rp "Select Domain for CDN [1-${#FOUND_DOMAINS[@]}]: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#FOUND_DOMAINS[@]}" ]; then
      SELECTED_DOMAIN="${FOUND_DOMAINS[$((idx-1))]}"
      echo "Selected Domain: $SELECTED_DOMAIN"
      break
    else
      echo "Invalid selection. Please enter a valid number."
    fi
  done
}

# ---------------------------------------------------------------------------
# Comprehensive Architecture & Configuration Guide
# ---------------------------------------------------------------------------
show_summary() {
  echo -e "\n================================================================================"
  echo "                     NHPG: Architecture & Setup Guide                           "
  echo "================================================================================"
  if [[ -f "$CONF" ]]; then
    # shellcheck source=/dev/null
    source "$CONF"

    cat << GUIDE_EOF

[ 1. TRAFFIC ARCHITECTURE & WORKFLOW ]
 - Public Entry Point : Port 443 (Handled by Hiddify HAProxy).
 - Reality (L4 TCP)   : HAProxy detects SNI and proxies raw TCP via Proxy Protocol v2
                        directly to local port 127.0.0.1:${REALITY_PORT}.
 - CDN (L7 HTTP)      : HAProxy terminates SSL on port 443. Any request beginning with
                        path '${CDN_PATH}' is sent as Plain HTTP to 127.0.0.1:${CDN_PORT}.
 - Separation         : No port conflicts with Hiddify. Full firewall protection retained.

--------------------------------------------------------------------------------

[ 2. PASARGUARD PANEL INBOUND SETTINGS ]

>> Inbound 1: Reality
 - Protocol           : VLESS
 - Port               : ${REALITY_PORT}
 - Listen Address     : 127.0.0.1
 - Network            : tcp
 - Security           : Reality
 - Proxy Protocol     : Enable (Version 2 / send-proxy-v2)
 - Decoy SNI List     : ${REALITY_SNIS[*]}

>> Inbound 2: CDN (HTTPUpgrade / WS)
 - Protocol           : VLESS or VMess
 - Port               : ${CDN_PORT}
 - Listen Address     : 127.0.0.1
 - Transport / Network: httpupgrade (or ws)
 - Path               : ${CDN_PATH}
 - Security / TLS     : NONE / False (SSL Termination is done by HAProxy)
 - Proxy Protocol     : NONE / Off
 - Host Header in Node: Leave empty (or set to '${SELECTED_DOMAIN}')

--------------------------------------------------------------------------------

[ 3. CLIENT CONFIGURATION (v2rayNG / Streisand / Nekoray / Happ) ]

>> For Reality Connection:
 - Address            : Your Server IP (or Direct Domain)
 - Port               : 443
 - TLS                : Enable (Reality)
 - SNI                : Any configured SNI (e.g. ${REALITY_SNIS[0]})

>> For CDN Connection:
 - Address            : CDN Clean IP or Domain (${SELECTED_DOMAIN})
 - Port               : 443
 - TLS                : Enable (TLS ON)
 - Server Name (SNI)  : ${SELECTED_DOMAIN}
 - Host Header        : ${SELECTED_DOMAIN}
 - Path               : ${CDN_PATH}
 - Transport          : httpupgrade (or ws)

================================================================================
GUIDE_EOF
  else
    echo "No configuration found. Please run Option 1 first."
  fi
}

# ---------------------------------------------------------------------------
# Setup / Install
# ---------------------------------------------------------------------------
do_install() {
  echo -e "\n--- 1. Reality Configuration ---"
  read -rp "Reality Local Port [Default: 20001]: " r_port
  REALITY_PORT="${r_port:-20001}"

  REALITY_SNIS=()
  read -rp "Enter primary SNI [Default: letsencrypt.org]: " sni1
  sni1="${sni1:-letsencrypt.org}"
  REALITY_SNIS+=("$sni1")
  while true; do
    read -rp "Enter next SNI (Press Enter or 0 to finish): " sni_next
    [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
    REALITY_SNIS+=("$sni_next")
  done

  echo -e "\n--- 2. CDN (HTTPUpgrade / WS) Configuration ---"
  read -rp "CDN Local Port [Default: 30001]: " c_port
  CDN_PORT="${c_port:-30001}"

  read -rp "CDN Path [Default: /app/v2/pg]: " p_in
  p_in="${p_in:-/app/v2/pg}"
  [[ "$p_in" =~ ^/ ]] || p_in="/$p_in"
  CDN_PATH="$p_in"

  select_domain_interactive

  save_conf
  write_worker
  write_systemd_units

  # Clean any previous manual Nginx test blocks if present
  sed -i '/location \/app\/v2\/pg/,/}/d' /opt/hiddify-manager/nginx/parts/proxy_path.conf 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl reload hiddify-nginx >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable --now pasarguard-watchdog.path
  systemctl start pasarguard-watchdog.service

  echo -e "\n[+] Setup completed successfully. Watchdog is monitoring HAProxy."
  show_summary
}

# ---------------------------------------------------------------------------
# Status & Display
# ---------------------------------------------------------------------------
do_status() {
  echo -e "\n--- Systemd Watchdog Status ---"
  systemctl status pasarguard-watchdog.path --no-pager || true
  echo -e "\n--- Recent Watchdog Logs ---"
  tail -n 12 "$LOG" 2>/dev/null || echo "No logs found."
  show_summary
}

# ---------------------------------------------------------------------------
# Edit Settings
# ---------------------------------------------------------------------------
do_edit() {
  if [[ ! -f "$CONF" ]]; then
    echo "Configuration not found. Please install first (Option 1)."
    return
  fi
  # shellcheck source=/dev/null
  source "$CONF"

  echo -e "\n--- Edit Configuration ---"
  read -rp "Reality Local Port [$REALITY_PORT]: " v_rport; REALITY_PORT="${v_rport:-$REALITY_PORT}"
  read -rp "CDN Local Port [$CDN_PORT]: " v_cport; CDN_PORT="${v_cport:-$CDN_PORT}"
  read -rp "CDN Path [$CDN_PATH]: " v_path; CDN_PATH="${v_path:-$CDN_PATH}"
  [[ "$CDN_PATH" =~ ^/ ]] || CDN_PATH="/$CDN_PATH"

  echo "Current Reality SNIs: ${REALITY_SNIS[*]}"
  read -rp "Add new SNIs? [y/N]: " add_sni
  if [[ "$add_sni" =~ ^[Yy]$ ]]; then
    while true; do
      read -rp "Enter new SNI (0 to stop): " s_next
      [[ "$s_next" == "0" || -z "$s_next" ]] && break
      REALITY_SNIS+=("$s_next")
    done
  fi

  read -rp "Change selected CDN domain? [y/N]: " ch_dom
  if [[ "$ch_dom" =~ ^[Yy]$ ]]; then
    select_domain_interactive
  fi

  save_conf
  write_worker
  systemctl start pasarguard-watchdog.service
  echo -e "\n[+] Changes applied."
  show_summary
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  echo -e "\n[!] Removing PasarGuard Watchdog..."
  systemctl disable --now pasarguard-watchdog.path >/dev/null 2>&1 || true
  systemctl disable --now pasarguard-watchdog.service >/dev/null 2>&1 || true
  rm -f "$SERVICE" "$PATH_UNIT" "$CONF" "$WORKER"
  systemctl daemon-reload
  echo "[+] Watchdog removed successfully."
}

# ---------------------------------------------------------------------------
# Interactive Menu Loop
# ---------------------------------------------------------------------------
while true; do
  echo
  echo "================================================="
  echo "      NHPG: Hiddify & PasarGuard Node Linker     "
  echo "================================================="
  echo "1) Full Setup / Install"
  echo "2) View Status, Logs & Setup Guide"
  echo "3) Edit Settings / Add SNIs"
  echo "4) Force Run Worker (Manual Apply)"
  echo "5) Uninstall Watchdog"
  echo "6) Exit"
  read -rp "Select an option [1-6]: " choice
  case "$choice" in
    1) do_install ;;
    2) do_status ;;
    3) do_edit ;;
    4)
       "$WORKER" || true
       echo -e "\n[+] Worker executed manually."
       ;;
    5) do_uninstall ;;
    6) echo "Exiting..."; exit 0 ;;
    *) echo "Invalid option. Try again." ;;
  esac
done
EOF

chmod +x /usr/local/bin/nhpg
