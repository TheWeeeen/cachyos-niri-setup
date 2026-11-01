#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Замена NVIDIA-драйвера на ветку 580xx (Pascal: GTX 10xx без GSP).
#  Запуск:  curl -sL d1mms.ru/nv|sudo bash
#
#  nvidia-580xx-utils требует lib32-* (multilib) и egl-wayland/egl-gbm/egl-x11 —
#  поэтому скрипт включает multilib, ставит egl-пакеты и всё логирует в /tmp/nv580.log,
#  а лог сам отправляет на сервер (даже при ошибке).
# ---------------------------------------------------------------------------
LOG=/tmp/nv580.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m  !!\033[0m %s\n' "$*"; }
err() { printf '\033[31m  !! %s\033[0m\n' "$*"; }

upload() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -T "$LOG" "https://d1mms.ru/up-q7v2m/nv580-$(hostname -s 2>/dev/null || echo host).txt")
    [[ "$code" == "201" || "$code" == "204" ]] && echo "  лог отправлен на сервер ($code)" || echo "  лог НЕ отправлен ($code)"
}

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
REBOOT=1; [[ "${1:-}" == "--no-reboot" ]] && REBOOT=0

say "1/6 репозитории"
cp -a /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d-%H%M%S)"
if grep -q '^\[cachyos\]' /etc/pacman.conf; then
    ok "cachyos уже подключён"
else
    # shellcheck disable=SC2016  # $arch/$repo подставляет pacman
    printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/$arch/$repo\n' >> /etc/pacman.conf
    ok "cachyos добавлен"
fi
if grep -q '^#\[multilib\]' /etc/pacman.conf; then
    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
    ok "multilib включён"
elif grep -q '^\[multilib\]' /etc/pacman.conf; then
    ok "multilib уже включён"
else
    # multilib в Arch описан парой строк; добавляем с тем же mirrorlist
    # shellcheck disable=SC2016
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    ok "multilib добавлен"
fi
pacman -Syy --noconfirm >/dev/null 2>&1 || warn "pacman -Syy вернул ошибку"

say "2/6 проверка"
for p in nvidia-580xx-dkms nvidia-580xx-utils egl-wayland2 egl-gbm egl-x11; do
    if pacman -Si "$p" &>/dev/null; then ok "$p есть"; else warn "$p НЕТ в репозиториях"; fi
done
if pacman -Si lib32-nvidia-580xx-utils &>/dev/null; then ok "lib32-nvidia-580xx-utils есть"; else warn "lib32-nvidia-580xx-utils НЕ виден (multilib пуст?)"; fi

say "3/6 удаляю открытый драйвер"
for p in nvidia-open-dkms nvidia-dkms nvidia-utils nvidia-settings opencl-nvidia; do
    if pacman -Qq "$p" &>/dev/null; then
        pacman -Rdd --noconfirm "$p" >/dev/null 2>&1 && ok "удалён $p" || warn "не удалился $p"
    fi
done

say "4/6 ставлю 580xx"
PKGS=(nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings opencl-nvidia-580xx egl-wayland2 egl-gbm egl-x11)
if pacman -S --needed --noconfirm "${PKGS[@]}"; then
    ok "поставлено"
else
    err "пакетная транзакция не прошла — пробую поштучно"
    for p in "${PKGS[@]}"; do
        pacman -S --needed --noconfirm "$p" && ok "$p" || warn "$p не встал"
    done
fi

say "5/6 initramfs"
mkinitcpio -P >/tmp/mkinitcpio.log 2>&1 && ok "initramfs пересобран" || { err "mkinitcpio упал"; tail -5 /tmp/mkinitcpio.log; }

say "6/6 состояние"
pacman -Qq | grep -i nvidia | tr '\n' ' '; echo
printf '  ядро: %s\n' "$(uname -r)"
printf '  cmdline: %s\n' "$(cat /proc/cmdline)"

if ! pacman -Qq nvidia-580xx-dkms &>/dev/null; then
    err "ветка 580xx не установилась — перезагрузку не делаю"
    upload
    exit 1
fi

upload
if [[ $REBOOT -eq 1 ]]; then
    say "перезагрузка через 10 секунд (Ctrl+C — отменить)"
    sleep 10
    systemctl reboot
else
    echo; echo "Готово. Перезагрузись: sudo reboot"
fi
