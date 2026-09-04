#!/bin/bash
# pasarguard_watchdog_ctl.sh
# پنل مدیریت واحد: Reality (چند SNI) + CDN/WebSocket (path) روی HAProxy هیدیفای
# با روت اجرا کن: sudo ./pasarguard_watchdog_ctl.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "این اسکریپت باید با روت اجرا بشه (sudo)."; exit 1; }

CFG=/opt/hiddify-manager/haproxy/haproxy.cfg
CONF=/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf
WORKER=/opt/hiddify-manager/haproxy/pasarguard_reapply.sh
SERVICE=/etc/systemd/system/pasarguard-watchdog.service
PATH_UNIT=/etc/systemd/system/pasarguard-watchdog.path
LOG=/var/log/pasarguard_watchdog.log

# ---------------------------------------------------------------------------
# حذف/overwrite نصب‌های جدای قبلی (sni-reapply / cdn-path-reapply)
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
# ذخیره‌ی تنظیمات
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
    echo "WS_PORT=$WS_PORT"
    echo "WS_BACKEND=$WS_BACKEND"
    echo "WS_PATH=\"$WS_PATH\""
  } > "$CONF"
  echo "[+] تنظیمات ذخیره شد: $CONF"
}

# ---------------------------------------------------------------------------
# ساخت worker  -- هرچی که تو config نبود اضافه می‌کنه، هرچی بود دست نمی‌زنه
# (چک‌ها دقیق و تک‌خطی هستن تا هیچ‌وقت بلاک تکراری نوشته نشه)
# ---------------------------------------------------------------------------
write_worker() {
cat > "$WORKER" <<'EOF'
#!/bin/bash
set -euo pipefail

CONF=/opt/hiddify-manager/haproxy/pasarguard_watchdog.conf
CFG=/opt/hiddify-manager/haproxy/haproxy.cfg
LOG=/var/log/pasarguard_watchdog.log
ANCHOR_REALITY="tcp-request content accept if { req.ssl_hello_type 1 }"
ANCHOR_WS="default_backend to_httpmode"

# shellcheck source=/dev/null
source "$CONF"

CHANGED=0

# ---- Reality: هر SNI که تو use_backend نبود اضافه می‌شه ----
for SNI in "${REALITY_SNIS[@]}"; do
  grep -qF "use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$CFG" || {
    sed -i "/${ANCHOR_REALITY//\//\\/}/a\\    use_backend ${REALITY_BACKEND} if { req.ssl_sni -i ${SNI} }" "$CFG"
    CHANGED=1
  }
done

# ---- بلاک backend ریالیتی: دقیقاً یک بار ----
grep -q "^backend ${REALITY_BACKEND}\$" "$CFG" || {
  printf '\nbackend %s\n    mode tcp\n    server pg_reality 127.0.0.1:%s send-proxy-v2\n' \
    "$REALITY_BACKEND" "$REALITY_PORT" >> "$CFG"
  CHANGED=1
}

# ---- CDN / WS path ----
grep -qF "use_backend ${WS_BACKEND} if { path_beg ${WS_PATH} }" "$CFG" || {
  sed -i "/${ANCHOR_WS}/i\\    use_backend ${WS_BACKEND} if { path_beg ${WS_PATH} }" "$CFG"
  CHANGED=1
}

# ---- بلاک backend ws: دقیقاً یک بار ----
grep -q "^backend ${WS_BACKEND}\$" "$CFG" || {
  printf '\nbackend %s\n    mode http\n    server pg_ws 127.0.0.1:%s send-proxy-v2\n' \
    "$WS_BACKEND" "$WS_PORT" >> "$CFG"
  CHANGED=1
}

if [[ $CHANGED -eq 1 ]]; then
  if haproxy -c -f "$CFG"; then
    systemctl reload hiddify-haproxy
    echo "$(date '+%F %T') OK - reapplied + reloaded" >> "$LOG"
  else
    echo "$(date '+%F %T') CONFIG CHECK FAILED - reload skipped" >> "$LOG"
  fi
else
  echo "$(date '+%F %T') no change needed" >> "$LOG"
fi
EOF
chmod +x "$WORKER"
}

# ---------------------------------------------------------------------------
# ساخت واحدهای systemd
# ---------------------------------------------------------------------------
write_systemd_units() {
cat > "$SERVICE" <<EOF
[Unit]
Description=Reapply Pasarguard reality+ws backends into haproxy.cfg

[Service]
Type=oneshot
ExecStart=$WORKER
EOF

cat > "$PATH_UNIT" <<EOF
[Unit]
Description=Watch haproxy.cfg and instantly reapply pasarguard backends

[Path]
PathModified=$CFG
Unit=pasarguard-watchdog.service

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# گزینه 1: نصب کامل
# ---------------------------------------------------------------------------
do_install() {
  echo "--- تنظیمات Reality ---"
  read -rp "پورت ریالیتی (مثلا 20001): " REALITY_PORT

  REALITY_SNIS=()
  read -rp "SNI اول: " sni1
  REALITY_SNIS+=("$sni1")
  while true; do
    read -rp "SNI بعدی رو وارد کن (برای رد شدن 0 بزن): " sni_next
    [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
    REALITY_SNIS+=("$sni_next")
  done

  echo "--- تنظیمات CDN / WebSocket ---"
  read -rp "Path مربوط به CDN (مثلا /XXXXXXXXXXXXXXXX): " WS_PATH
  read -rp "پورت CDN/WS (مثلا 20011): " WS_PORT

  REALITY_BACKEND=pasarguard_reality
  WS_BACKEND=pasarguard_ws

  save_conf
  cleanup_old_units
  write_worker
  write_systemd_units

  systemctl daemon-reload
  systemctl enable --now pasarguard-watchdog.path
  systemctl start pasarguard-watchdog.service

  echo "[+] نصب کامل شد."
  do_status
}

# ---------------------------------------------------------------------------
# گزینه 2: وضعیت
# ---------------------------------------------------------------------------
do_status() {
  if [[ ! -f "$CONF" ]]; then
    echo "هنوز نصب نشده. اول گزینه 1 رو بزن."
    return
  fi
  echo "--- تنظیمات فعلی ---"
  cat "$CONF"
  echo
  echo "--- وضعیت واچ‌داگ ---"
  systemctl status pasarguard-watchdog.path --no-pager || true
  echo
  echo "--- آخرین لاگ‌ها ---"
  tail -n 15 "$LOG" 2>/dev/null || echo "لاگی هنوز ثبت نشده."
}

# ---------------------------------------------------------------------------
# گزینه 3: ویرایش
# ---------------------------------------------------------------------------
do_edit() {
  if [[ ! -f "$CONF" ]]; then
    echo "اول باید نصب کنی (گزینه 1)."
    return
  fi
  # shellcheck source=/dev/null
  source "$CONF"

  read -rp "پورت ریالیتی [$REALITY_PORT]: " v; REALITY_PORT="${v:-$REALITY_PORT}"

  echo "SNI های فعلی: ${REALITY_SNIS[*]}"
  read -rp "میخوای SNI ها رو از نو وارد کنی؟ (y/N): " redo
  if [[ "$redo" == "y" || "$redo" == "Y" ]]; then
    REALITY_SNIS=()
    read -rp "SNI اول: " sni1
    REALITY_SNIS+=("$sni1")
    while true; do
      read -rp "SNI بعدی (برای رد شدن 0 بزن): " sni_next
      [[ "$sni_next" == "0" || -z "$sni_next" ]] && break
      REALITY_SNIS+=("$sni_next")
    done
  fi

  read -rp "Path CDN [$WS_PATH]: " v; WS_PATH="${v:-$WS_PATH}"
  read -rp "پورت CDN [$WS_PORT]: " v; WS_PORT="${v:-$WS_PORT}"

  save_conf
  # اگه worker/systemd هنوز موجود نیستن (مثلا از نصب قبلی جدا اومده) بسازشون
  [[ -x "$WORKER" ]] || write_worker
  [[ -f "$SERVICE" && -f "$PATH_UNIT" ]] || { write_systemd_units; systemctl daemon-reload; systemctl enable --now pasarguard-watchdog.path; }

  echo "[+] در حال اعمال فوری تغییرات..."
  systemctl start pasarguard-watchdog.service
  do_status
}

# ---------------------------------------------------------------------------
# منو
# ---------------------------------------------------------------------------
while true; do
  echo
  echo "=========================================="
  echo " پنل مدیریت واچ‌داگ Reality + CDN (HAProxy)"
  echo "=========================================="
  echo "1) نصب / راه‌اندازی کامل"
  echo "2) وضعیت"
  echo "3) ویرایش تنظیمات"
  echo "4) خروج"
  read -rp "انتخاب: " choice
  case "$choice" in
    1) do_install ;;
    2) do_status ;;
    3) do_edit ;;
    4) exit 0 ;;
    *) echo "گزینه نامعتبره." ;;
  esac
done
