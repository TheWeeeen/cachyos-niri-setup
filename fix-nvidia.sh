#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Фикс NVIDIA для Wayland/niri: включает KMS и параметр ядра.
#  Запуск:  curl -sL d1mms.ru/f|sudo bash
#  Ставит:  nvidia_drm.modeset=1 nvidia_drm.fbdev=1 в записи загрузки
#           MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm) в mkinitcpio
#           пересобирает initramfs и перезагружает.
#  Идемпотентно: повторный запуск ничего не дублирует.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
err() { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

REBOOT=1
[[ "${1:-}" == "--no-reboot" ]] && REBOOT=0

say "1/3 параметр ядра"
shopt -s nullglob
entries=(/boot/loader/entries/*.conf)
if [[ ${#entries[@]} -eq 0 ]]; then
    err "нет /boot/loader/entries/*.conf — это не systemd-boot, чинить надо иначе"
    exit 1
fi
for f in "${entries[@]}"; do
    if grep -q 'nvidia_drm.modeset=1' "$f"; then
        ok "$(basename "$f"): уже есть"
    else
        sed -i '/^options /s/$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1/' "$f"
        ok "$(basename "$f"): добавлен"
    fi
    grep '^options' "$f" | sed 's/^/     /'
done
shopt -u nullglob

say "2/3 модули в initramfs"
if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    grep '^MODULES=' /etc/mkinitcpio.conf | sed 's/^/     /'
    if mkinitcpio -P >/tmp/mkinitcpio.log 2>&1; then
        ok "initramfs пересобран"
    else
        err "mkinitcpio упал, лог: /tmp/mkinitcpio.log"
        tail -5 /tmp/mkinitcpio.log
    fi
else
    err "нет /etc/mkinitcpio.conf"
fi

say "3/3 проверка"
printf '  /dev/dri: '; find /dev/dri -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null; echo
printf '  cmdline:  '; cat /proc/cmdline; echo
printf '  nvidia:   '; (command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,driver_version --format=csv,noheader) || echo "nvidia-smi нет"

if [[ $REBOOT -eq 1 ]]; then
    say "перезагрузка через 10 секунд (Ctrl+C — отменить)"
    sleep 10
    systemctl reboot
else
    echo
    echo "Готово. Перезагрузись: sudo reboot"
fi
