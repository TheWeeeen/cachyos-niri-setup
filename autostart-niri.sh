#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Автозапуск niri при загрузке: автологин на tty1 + exec niri-session.
#  Запуск:  curl -sL d1mms.ru/a|sudo bash
#  Идемпотентно: повторный запуск ничего не дублирует.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
err() { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

USER_NAME="${SUDO_USER:-}"
if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
    USER_NAME=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
fi
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { err "не нашёл домашнюю папку для $USER_NAME"; exit 1; }

say "1/3 автологин на tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
Type=simple
EOF
ok "автологин для $USER_NAME"

say "2/3 запуск niri из профиля"
PROFILE="$HOME_DIR/.bash_profile"
touch "$PROFILE"
if grep -q 'niri-session  # hermes-autostart' "$PROFILE"; then
    ok "уже прописано в $PROFILE"
else
    cat >> "$PROFILE" <<'EOF'

# hermes-autostart: niri на первой консоли
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$NIRI_SOCKET" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec niri-session  # hermes-autostart
fi
EOF
    ok "добавлено в $PROFILE"
fi
chown "$USER_NAME:$USER_NAME" "$PROFILE"

say "3/3 применяю"
systemctl daemon-reload
ok "systemd перечитан"

cat <<EOF

Готово. Проверка:
  1. sudo reboot
  2. после загрузки система сама логинит $USER_NAME и поднимает niri
  3. если нужно вернуть текстовую консоль: Ctrl+Alt+F2

Откатить:
  sudo rm -r /etc/systemd/system/getty@tty1.service.d
  sed -i '/hermes-autostart/,+3d' ~/.bash_profile
EOF
