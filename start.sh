#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Один запуск: скачивает установщик и запускает его КАК СИСТЕМНУЮ СЛУЖБУ,
#  чтобы смерть графической сессии (чёрный экран, greeter, повторный вход)
#  не прерывала установку.
#
#  Запуск из live-сессии CachyOS:
#     curl -fsSL <ссылка на этот файл> -o /tmp/s.sh && sudo bash /tmp/s.sh
#
#  Дальше ничего делать не нужно: скрипт сам дождётся конца и покажет итог.
#  Лог: /tmp/inst.log
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# установщик берём по прибитому к коммиту адресу — без кэша CDN
INSTALLER_URL="https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/a44288c8031c23ead2ec6f684a1a0d60361622d9/install-simple.sh"
INSTALLER=/tmp/install-simple.sh
LOG=/tmp/inst.log
UNIT=inst

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

say "проверка окружения"
[[ -d /sys/firmware/efi ]] || { echo "нужна UEFI-загрузка"; exit 1; }
command -v pacstrap >/dev/null || { echo "это не live-ISO CachyOS"; exit 1; }

say "загрузка установщика"
curl -fsSL "$INSTALLER_URL" -o "$INSTALLER"
bash -n "$INSTALLER" || { echo "скачался битый установщик"; exit 1; }
rm -f "$LOG"

say "запуск"
if command -v systemd-run >/dev/null 2>&1; then
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    systemd-run --unit="$UNIT" \
        --property=StandardOutput=append:"$LOG" \
        --property=StandardError=append:"$LOG" \
        /bin/bash "$INSTALLER"
    echo "установка идёт отдельной службой ($UNIT), лог: $LOG"
    echo "прогресс: sudo journalctl -u $UNIT -f"
    # ждём, пока юнит жив; 2 с * 1200 = 40 минут максимум
    for _ in $(seq 1 1200); do
        systemctl is-active --quiet "$UNIT" || break
        sleep 2
    done
else
    setsid nohup /bin/bash "$INSTALLER" >>"$LOG" 2>&1 &
    echo "systemd-run нет, запущено через setsid, лог: $LOG"
    for _ in $(seq 1 1200); do
        pgrep -f "$INSTALLER" >/dev/null 2>&1 || break
        sleep 2
    done
fi

say "итог"
result=$(systemctl show -p Result --value "$UNIT" 2>/dev/null || true)
if grep -q "6/6 готово" "$LOG" 2>/dev/null || [[ "$result" == "success" ]]; then
    echo "УСТАНОВКА ЗАВЕРШЕНА"
    cat <<'EOF'

  reboot -> F11 -> «Linux Boot Manager»
  dmitry / dmitry     root / cachyos     (сменить: passwd)

  рабочий стол:
    curl -fsSLO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/cachyos-niri-setup.sh
    chmod +x cachyos-niri-setup.sh && ./cachyos-niri-setup.sh
EOF
else
    echo "установка НЕ завершилась (result: ${result:-неизвестно}) — последние строки:"
    tail -25 "$LOG" 2>/dev/null || sudo journalctl -u "$UNIT" --no-pager 2>/dev/null | tail -25
fi
