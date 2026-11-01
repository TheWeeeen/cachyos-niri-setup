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

say "1/6 зеркала cachyos"
cp -a /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d-%H%M%S)"

# mirror.cachyos.org у части провайдеров отваливается по таймауту. Проверяем
# кандидатов и оставляем в pacman.conf только те, что реально отвечают.
# shellcheck disable=SC2206  # $arch/$repo — литералы для pacman
# одинарные кавычки обязательны: $arch/$repo подставляет pacman, а не bash
MIRRORS=(
    'https://mirror.yandex.ru/cachyos/repo/$arch/$repo'
    'https://cdn77.cachyos.org/repo/$arch/$repo'
    'https://mirror.cachyos.org/repo/$arch/$repo'
    'https://archlinux.gay/cachy/repo/$arch/$repo'
)
GOOD=()
for m in "${MIRRORS[@]}"; do
    probe=${m//\$arch\/$repo/x86_64/cachyos}
    if curl -fsS -m 6 -o /dev/null "$probe/cachyos.db"; then
        GOOD+=("$m"); ok "отвечает: $m"
    else
        warn "не отвечает: $m"
    fi
done
if [[ ${#GOOD[@]} -eq 0 ]]; then
    GOOD=("${MIRRORS[@]}")
    warn "ни одно зеркало не ответило быстро — оставляю все подряд"
fi

# переписываем секцию [cachyos] целиком
awk '/^\[cachyos\]/{skip=1; next} skip && /^\[/{skip=0} !skip' /etc/pacman.conf > /etc/pacman.conf.new
mv /etc/pacman.conf.new /etc/pacman.conf
{
    echo
    echo "[cachyos]"
    for m in "${GOOD[@]}"; do echo "Server = $m"; done
} >> /etc/pacman.conf
ok "в pacman.conf прописано зеркал: ${#GOOD[@]}"
# multilib обязателен (lib32-* в зависимостях 580xx). В mirrorlist CachyOS он
# обычно не прописан, поэтому задаём серверы явно, а старую секцию вырезаем.
awk '/^\[multilib\]/{skip=1; next} skip && /^\[/{skip=0} !skip' /etc/pacman.conf > /etc/pacman.conf.new
mv /etc/pacman.conf.new /etc/pacman.conf
{
    echo
    echo "[multilib]"
    echo 'Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch'
    echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch'
} >> /etc/pacman.conf
ok "multilib настроен на рабочие зеркала"
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
