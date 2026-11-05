#!/usr/bin/env bash
# Очистка CachyOS/Arch перед установкой другой сборки (HyDE, ML4W и т.п.):
# осиротевшие пакеты, кэш pacman/AUR, старые логи, конфиги панелей с бэкапом.

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help)
            cat <<'EOF'
Использование: ./clean-before-hyprland.sh [--dry-run] [--yes]

  --dry-run   показать, что будет удалено, ничего не трогая
  --yes       не задавать вопросов
EOF
            exit 0
            ;;
        *) echo "Неизвестный флаг: $arg (см. --help)" >&2; exit 2 ;;
    esac
done

command -v pacman >/dev/null || { echo "Это не Arch-подобная система: нет pacman." >&2; exit 1; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local answer
    read -rp "$1 (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

echo "== 1. Осиротевшие пакеты =="
ORPHANS=$(pacman -Qdtq || true)
if [[ -z "$ORPHANS" ]]; then
    echo "Осиротевших пакетов нет."
else
    echo "$ORPHANS"
    # shellcheck disable=SC2086  # список пакетов приходит через пробел из pacman
    if confirm "Удалить их (pacman -Rns)?"; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] sudo pacman -Rns $ORPHANS"
        else
            # shellcheck disable=SC2086
            sudo pacman -Rns $ORPHANS
        fi
    else
        echo "Пропущено."
    fi
fi

echo
echo "== 2. Кэш pacman =="
if command -v paccache >/dev/null; then
    run sudo paccache -r
else
    echo "paccache не установлен (pacman-contrib), пропускаю."
fi

echo
echo "== 3. Кэш AUR-хелпера =="
if command -v yay >/dev/null; then
    run yay -Scc --noconfirm
elif command -v paru >/dev/null; then
    run paru -Scc --noconfirm
else
    echo "Ни yay, ни paru не найдены, пропускаю."
fi

echo
echo "== 4. Логи systemd старше 4 недель =="
run sudo journalctl --vacuum-time=4weeks

echo
echo "== 5. Конфиги старых сборок =="
BACKUP_DIR="$HOME/hyprland-config-backup-$(date +%Y%m%d-%H%M%S)"
CONFIG_DIRS=(hypr waybar wofi swaync mako dunst ags quickshell fuzzel rofi)

EXISTING=()
for dir in "${CONFIG_DIRS[@]}"; do
    [[ -d "$HOME/.config/$dir" ]] && EXISTING+=("$dir")
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
    echo "Старых конфигов панелей в ~/.config нет."
elif confirm "Сделать бэкап в $BACKUP_DIR и удалить: ${EXISTING[*]}?"; then
    run mkdir -p "$BACKUP_DIR"
    for dir in "${EXISTING[@]}"; do
        run cp -r "$HOME/.config/$dir" "$BACKUP_DIR/"
        run rm -rf "$HOME/.config/$dir"
        echo "  -> ~/.config/$dir"
    done
    echo "Бэкап: $BACKUP_DIR"
else
    echo "Пропущено, конфиги на месте."
fi

echo
echo "Готово. Теперь можно ставить новую сборку."
echo "Откатить конфиги: cp -r \"$BACKUP_DIR\"/* ~/.config/"
