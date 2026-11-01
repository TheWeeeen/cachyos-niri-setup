#!/usr/bin/env bash
# Диагностика NVIDIA + Wayland. Запуск: curl -sL d1mms.ru/d|sudo bash
# Печатает отчёт и сам загружает его на сервер — присылать ничего не нужно.
set -u
UH="${SUDO_USER:-$USER}"
HOMEDIR=$(getent passwd "$UH" | cut -d: -f6)
REPORT=/tmp/diag-$(date +%s).txt
line() { printf '\n\033[1m%s\033[0m\n' "$*"; }

{
    line "ядро / система"
    uname -r
    grep -E '^PRETTY_NAME' /etc/os-release 2>/dev/null

    line "cmdline"
    cat /proc/cmdline

    line "nvidia-пакеты"
    pacman -Qq 2>/dev/null | grep -i nvidia || echo "нет ни одного nvidia-пакета"

    line "dkms"
    dkms status 2>&1 | head -5 || echo "dkms нет"
    ls /usr/lib/modules/"$(uname -r)"/updates/dkms/ 2>/dev/null | head -5 || echo "модулей dkms для этого ядра нет"

    line "загруженные модули"
    lsmod | grep -i '^nvidia' || echo "nvidia-модули НЕ загружены"

    line "/dev/dri"
    ls -l /dev/dri/ 2>/dev/null

    line "nvidia-smi"
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 | head -3
    else
        echo "nvidia-smi не установлен"
    fi

    line "mkinitcpio"
    grep -E '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null

    line "dmesg (nvidia/drm)"
    dmesg 2>/dev/null | grep -iE 'nvidia|NVRM|drm:' | tail -12 || echo "нет строк"

    line "niri log"
    if [[ -f "$HOMEDIR/niri.log" ]]; then
        tail -12 "$HOMEDIR/niri.log"
    else
        echo "$HOMEDIR/niri.log нет"
    fi

    line "niri процессы"
    pgrep -a niri || echo "niri не запущен"
} 2>&1 | tee "$REPORT"

echo
name="diag-$(hostname -s 2>/dev/null || echo host).txt"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -T "$REPORT" "https://d1mms.ru/up-q7v2m/$name")
if [[ "$code" == "201" || "$code" == "204" ]]; then
    printf '\033[32m  ok\033[0m отчёт отправлен на сервер (%s)\n' "$name"
else
    printf '\033[31m  !! не удалось отправить отчёт (HTTP %s)\033[0m\n' "$code"
    echo "тогда пришли фото экрана"
fi
rm -f "$REPORT"
