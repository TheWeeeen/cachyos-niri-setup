#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Замена NVIDIA-драйвера на ветку 580xx (нужна для Pascal: GTX 10xx без GSP).
#  Запуск:  curl -sL d1mms.ru/nv|sudo bash
#  Убирает nvidia-open-dkms/nvidia-utils, ставит nvidia-580xx-* из репо CachyOS,
#  пересобирает initramfs и перезагружает.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m  !!\033[0m %s\n' "$*"; }
err() { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
REBOOT=1; [[ "${1:-}" == "--no-reboot" ]] && REBOOT=0

say "1/5 репозиторий cachyos"
cp -a /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d-%H%M%S)"
if grep -q '^\[cachyos\]' /etc/pacman.conf; then
    ok "репозиторий уже подключён"
else
    # shellcheck disable=SC2016  # $arch/$repo подставляет сам pacman
    printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/$arch/$repo\n' >> /etc/pacman.conf
    ok "репозиторий добавлен"
fi
pacman -Syy --noconfirm >/dev/null 2>&1 || warn "pacman -Syy вернул ошибку"

say "2/5 проверка пакетов 580xx"
if ! pacman -Si nvidia-580xx-dkms &>/dev/null; then
    err "nvidia-580xx-dkms не найден в репозиториях — дальше не иду"
    exit 1
fi
ver=$(pacman -Si nvidia-580xx-dkms | awk -F': *' '/^Version/{print $2; exit}')
ok "nvidia-580xx-dkms $ver доступен"

say "3/5 удаляю открытый драйвер"
for p in nvidia-open-dkms nvidia-dkms nvidia-utils nvidia-settings opencl-nvidia; do
    if pacman -Qq "$p" &>/dev/null; then
        pacman -Rdd --noconfirm "$p" >/dev/null 2>&1 && ok "удалён $p" || warn "не удалось удалить $p"
    fi
done

say "4/5 ставлю ветку 580xx"
PKGS=(nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings opencl-nvidia-580xx)
if grep -q '^\[multilib\]' /etc/pacman.conf; then
    PKGS+=(lib32-nvidia-580xx-utils)
fi
if pacman -S --needed --noconfirm "${PKGS[@]}"; then
    ok "поставлено: ${PKGS[*]}"
else
    err "установка не прошла — лог выше"
    exit 1
fi

say "5/5 initramfs"
if mkinitcpio -P >/tmp/mkinitcpio.log 2>&1; then
    ok "initramfs пересобран"
else
    err "mkinitcpio упал:"; tail -5 /tmp/mkinitcpio.log
fi

printf '\n  ядро:     %s\n' "$(uname -r)"
printf '  драйвер:  %s\n' "$(pacman -Q nvidia-580xx-dkms 2>/dev/null || echo "?")"
printf '  cmdline:  %s\n' "$(cat /proc/cmdline)"

if [[ $REBOOT -eq 1 ]]; then
    say "перезагрузка через 10 секунд (Ctrl+C — отменить)"
    sleep 10
    systemctl reboot
else
    echo; echo "Готово. Перезагрузись: sudo reboot"
fi
