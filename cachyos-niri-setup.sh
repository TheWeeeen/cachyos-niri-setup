#!/usr/bin/env bash
# ============================================================================
#  CachyOS → niri + Noctalia + рабочий набор (без дисплей-менеджера)
#  Всё из репозиториев; AUR нужен только для zen-browser (через paru).
#  Скрипт идемпотентный: можно гонять повторно. Лог: ~/niri-setup-<дата>.log
#
#  Использование:
#     ./cachyos-niri-setup.sh                 # полная установка
#     ./cachyos-niri-setup.sh --dry-run       # показать, что будет сделано
#     ./cachyos-niri-setup.sh --no-nvidia     # не трогать NVIDIA
#     ./cachyos-niri-setup.sh --autologin     # автовход на tty1 + запуск niri
#     ./cachyos-niri-setup.sh --no-aur        # без zen-browser (AUR не трогать)
#     ./cachyos-niri-setup.sh --rice          # + обои из Noctara-Dots
#     ./cachyos-niri-setup.sh --config-only   # только конфиги, без pacman
#     ./cachyos-niri-setup.sh --yes           # без вопросов
# ============================================================================
set -Eeuo pipefail

DRY_RUN=0
NO_NVIDIA=0
AUTOLOGIN=0
CONFIG_ONLY=0
ASSUME_YES=0
NO_AUR=0
RICE=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=1 ;;
        --no-nvidia)   NO_NVIDIA=1 ;;
        --autologin)   AUTOLOGIN=1 ;;
        --config-only) CONFIG_ONLY=1 ;;
        --no-aur)      NO_AUR=1 ;;
        --rice)        RICE=1 ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --help|-h)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg (--help)" >&2; exit 2 ;;
    esac
done

LOG="$HOME/niri-setup-$(date +%Y%m%d-%H%M%S).log"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
NIRI_CFG="$CONFIG_DIR/niri/config.kdl"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d-%H%M%S)"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[34m·\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

if [[ $DRY_RUN -eq 0 ]]; then
    exec > >(tee -a "$LOG") 2>&1
fi

# shellcheck disable=SC2154  # rc выставляется самим trap'ом
trap 'rc=$?; c_err "Упало на строке $LINENO (код $rc). Лог: $LOG"' ERR

# shellcheck disable=SC2317  # вызывается косвенно через run/run_strict
need_sudo() { sudo "$@"; }

# run        — best effort: ошибка не обрывает установку
# run_strict — критично: при ошибке останавливаемся
# в dry-run обе только печатают команду
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        local pretty="$*"
        printf '  [dry-run] %s\n' "${pretty/need_sudo/sudo}"
        return 0
    fi
    "$@" || { c_warn "не выполнено (не критично): $*"; return 0; }
}

run_strict() {
    if [[ $DRY_RUN -eq 1 ]]; then
        local pretty="$*"
        printf '  [dry-run] %s\n' "${pretty/need_sudo/sudo}"
        return 0
    fi
    "$@" || die "Не удалось выполнить: $* (лог: $LOG)"
}

# Обновляет зеркала CachyOS (если есть такой инструмент)
refresh_mirrors() {
    has cachyos-rate-mirrors || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] sudo cachyos-rate-mirrors\n'
        return 0
    fi
    c_info "Перебираю зеркала CachyOS"
    need_sudo cachyos-rate-mirrors >/dev/null 2>&1 \
        || c_warn "cachyos-rate-mirrors не отработал — оставляю текущие зеркала"
}

# Установка с одной повторной попыткой после принудительного обновления индекса.
# Лечит классический 404: в базе старый файл, на зеркале уже новый.
pacman_install_retry() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] sudo pacman %s\n' "$*"
        return 0
    fi
    if need_sudo pacman "$@" --noconfirm; then
        return 0
    fi
    c_warn "pacman вернул ошибку — обновляю зеркала и индекс, пробую ещё раз"
    refresh_mirrors || true
    need_sudo pacman -Syy --noconfirm >/dev/null 2>&1 || true
    need_sudo pacman "$@" --noconfirm \
        || die "Не удалось выполнить: pacman $* (лог: $LOG)
Если в логе 404 на файл пакета — устарел индекс. Помогает:
  sudo cachyos-rate-mirrors && sudo pacman -Syyu"
}

# Ставит только те пакеты, которые реально есть в репозиториях:
# если зеркала отстали, остальное всё равно поставится.
safe_pacman_S() {
    local -a ok=() missing=()
    local p
    for p in "$@"; do
        if [[ $DRY_RUN -eq 0 ]] && ! pacman -Ssq --freeze "$p" 2>/dev/null | grep -qx -- "$p"; then
            missing+=("$p")
        else
            ok+=("$p")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        c_warn "Нет в репозиториях, пропускаю: ${missing[*]}"
    fi
    if [[ ${#ok[@]} -gt 0 ]]; then
        pacman_install_retry -S --needed "${ok[@]}"
    fi
    return 0
}

aur_install() {
    [[ $NO_AUR -eq 1 ]] && return 0
    command -v paru &>/dev/null || { c_warn "paru нет — AUR пропускаю"; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] paru -S --needed --noconfirm %s\n' "$*"
        return 0
    fi
    paru -S --needed --noconfirm "$@" || c_warn "AUR: не удалось поставить $*"
}

niri_validate() {
    # разные версии niri по-разному принимают путь к конфигу
    niri validate -c "$NIRI_CFG" &>/dev/null \
        || niri validate --config "$NIRI_CFG" &>/dev/null \
        || niri validate "$NIRI_CFG" &>/dev/null
}

confirm() {
    [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
    local ans=""
    read -rp "$1 [y/N] " ans </dev/tty || ans=""
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

pkg_installed() { pacman -Qq "$1" &>/dev/null; }
has() { command -v "$1" &>/dev/null; }

# Критичные пакеты: без них сессия не поднимется. Их отсутствие = стоп.
CRITICAL_PKGS=(niri noctalia kitty)

# --------------------------------------------------------------------------
# 0. проверки
# --------------------------------------------------------------------------
step "Проверка окружения"

[[ $EUID -eq 0 ]] && die "Запускай от обычного пользователя, не от root."
command -v pacman &>/dev/null || die "Это не Arch-подобная система (нет pacman)."
command -v sudo &>/dev/null || die "Нужен sudo."
command -v curl &>/dev/null || die "Нужен curl."

# 0.1 какой дистрибутив
DISTRO_ID="неизвестно"
DISTRO_NAME="неизвестно"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-неизвестно}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-неизвестно}}"
fi
c_info "Дистрибутив: $DISTRO_NAME"
case "$DISTRO_ID" in
    arch|cachyos|endeavouros|manjaro|garuda|artix|arcolinux|rebornos|parabola)
        c_ok "Arch-семейство — поддерживается" ;;
    *)
        c_warn "Дистрибутив «$DISTRO_ID» не в списке проверенных"
        c_warn "Продолжаю: скрипт полагается только на pacman и systemd" ;;
esac

# 0.2 systemd (или его аналог)
if ! command -v systemctl &>/dev/null; then
    c_warn "systemctl не найден — службы включать не буду, остальное поставлю"
fi

# 0.3 не занят ли pacman другой операцией
if [[ -e /var/lib/pacman/db.lck ]]; then
    die "pacman заблокирован (/var/lib/pacman/db.lck). Закрой pamac/pacman и повтори."
fi

c_info "Пользователь: $USER, домашний каталог: $HOME"
c_info "Ядро: $(uname -r)"

if [[ $DRY_RUN -eq 0 ]]; then
    sudo -v || die "Нет прав sudo."
fi

# 0.4 сеть: проверяем доступность СВОИХ зеркал, а не только archlinux.org
MIRROR_OK=1
if [[ $DRY_RUN -eq 0 && $CONFIG_ONLY -eq 0 ]]; then
    found=0
    while read -r url; do
        [[ -z "$url" ]] && continue
        found=1
        if curl -sfI --max-time 6 "$url" >/dev/null 2>&1; then
            c_ok "Зеркало доступно: ${url%%/}"
            found=2
            break
        fi
    done < <(grep -hoE 'https?://[^ ]+' /etc/pacman.d/mirrorlist 2>/dev/null | head -5)
    if [[ $found -eq 0 ]]; then
        c_warn "mirrorlist не найден — пропускаю проверку зеркал"
    elif [[ $found -eq 1 ]]; then
        MIRROR_OK=0
        curl -sfI --max-time 8 https://archlinux.org >/dev/null 2>&1 \
            || die "Нет доступа ни к зеркалам, ни к archlinux.org. Проверь сеть."
        c_warn "Зеркала из mirrorlist не отвечают, но интернет есть — продолжаю"
    fi
fi
c_ok "Права и сеть в порядке"

# 0.5 свободное место
if [[ $CONFIG_ONLY -eq 0 ]]; then
    avail_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    avail_h=$(df -Ph / | awk 'NR==2 {print $4}')
    if (( avail_kb < 4*1024*1024 )); then
        die "На / всего $avail_h — нужно минимум 4 ГБ свободного места"
    elif (( avail_kb < 8*1024*1024 )); then
        c_warn "На / $avail_h, рекомендую больше 8 ГБ"
    else
        c_ok "Свободно на /: $avail_h"
    fi
fi

# 0.6 скомпилированы ли пакеты под это железо/сборку
if [[ $DRY_RUN -eq 0 && $CONFIG_ONLY -eq 0 ]]; then
    # если зеркала недоступны, локальный индекс может быть устаревшим — не судим строго
    if [[ $MIRROR_OK -eq 0 ]]; then
        c_warn "Индекс репозиториев может быть устаревшим — проверку наличия пакетов пропускаю"
    else
        for cp in "${CRITICAL_PKGS[@]}"; do
            if ! pacman -Ssq --freeze "$cp" 2>/dev/null | grep -qx -- "$cp"; then
                die "Пакет «$cp» не найден в подключённых репозиториях.
Что делать:
  · проверь, что в /etc/pacman.conf есть строка [extra] и она не закомментирована
  · обнови зеркала:  sudo pacman -Sy  (и/или cachyos-rate-mirrors)
  · если система давно не обновлялась:  sudo pacman -Syu
Скрипт остановлен ДО любых изменений в системе."
            fi
        done
        c_ok "Критичные пакеты доступны: ${CRITICAL_PKGS[*]}"
    fi
fi

# 0.7 снапшот btrfs перед изменениями (откат в один пункт загрузчика)
WILL_SNAPSHOT=0
if [[ $DRY_RUN -eq 0 && $CONFIG_ONLY -eq 0 ]]; then
    rootfs=$(findmnt -no FSTYPE / 2>/dev/null || echo "")
    if [[ "$rootfs" == "btrfs" ]] && command -v snapper &>/dev/null; then
        WILL_SNAPSHOT=1
        c_info "Корень на btrfs, snapper есть — сделаю снапшот перед изменениями"
    elif [[ "$rootfs" == "btrfs" ]]; then
        c_warn "Корень на btrfs, но snapper не установлен — автоснапшота не будет"
        c_warn "Для откатов поставь: sudo pacman -S snapper snap-pac"
    else
        c_info "Корень на $rootfs — снапшоты недоступны (откат только через бэкап)"
    fi
fi

HAS_NVIDIA=0
if command -v lspci &>/dev/null && lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi nvidia; then
    HAS_NVIDIA=1
    c_info "NVIDIA: $(lspci | grep -iE 'vga|3d' | grep -i nvidia | head -1 | cut -d: -f3- | sed 's/^ *//')"
fi
[[ $NO_NVIDIA -eq 1 ]] && HAS_NVIDIA=0

# --------------------------------------------------------------------------
# 1. пакеты
# --------------------------------------------------------------------------
if [[ $CONFIG_ONLY -eq 0 ]]; then
    step "Снапшот перед изменениями"
    if [[ $WILL_SNAPSHOT -eq 1 ]]; then
        if run_strict need_sudo snapper -c root create \
                --description "before niri setup $(date +%F-%H%M)" --cleanup-algorithm number; then
            c_ok "Снапшот создан. Откат: sudo snapper -c root list, затем snapper undochange N..0"
        fi
    else
        c_info "Пропущено (не btrfs или нет snapper)"
    fi

    step "Обновление системы"
    pacman_install_retry -Syu
    pacman_install_retry -S --needed base-devel git pciutils

    step "Композитор и оболочка"
    CORE_PKGS=(
        niri noctalia xwayland-satellite
        xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome
        polkit
        pipewire pipewire-pulse pipewire-audio wireplumber pavucontrol
        networkmanager nm-connection-editor bluez bluez-utils blueman
        power-profiles-daemon brightnessctl playerctl libnotify
        wl-clipboard grim slurp swappy
        kitty
        xdg-utils xdg-user-dirs
    )
    safe_pacman_S "${CORE_PKGS[@]}"

    step "Рабочий стол и файлы"
    DESKTOP_PKGS=(
        dolphin ark unrar kio-extras ffmpegthumbs kdegraphics-thumbnailers
        zathura zathura-pdf-poppler
        qt6ct qt5ct
        gvfs gvfs-mtp udiskie
        7zip
        gnome-keyring
        obsidian
        adwaita-icon-theme
        noto-fonts noto-fonts-emoji noto-fonts-cjk ttf-jetbrains-mono-nerd
        gtk3 gtk4 gsettings-desktop-schemas
        qt5-wayland qt6-wayland
        mesa
    )
    safe_pacman_S "${DESKTOP_PKGS[@]}"

    step "Работа и медиа"
    WORK_PKGS=(
        ffmpeg kdenlive obs-studio gimp audacity mpv
        pipewire-jack
        neovim opencode
        firefox chromium telegram-desktop
        fuzzel
    )
    safe_pacman_S "${WORK_PKGS[@]}"

    if [[ $HAS_NVIDIA -eq 1 ]]; then
        c_info "NVIDIA-пакеты"
        safe_pacman_S egl-wayland libva-nvidia-driver nvidia-utils nvidia-settings
        if [[ -r /etc/pacman.conf ]] && grep -q '^\[multilib\]' /etc/pacman.conf; then
            safe_pacman_S lib32-nvidia-utils
        fi
    fi

    # без композитора дальше идти незачем
    if [[ $DRY_RUN -eq 0 ]] && ! command -v niri &>/dev/null; then
        die "niri не установился — прерываю, конфиг не трогаю"
    fi
    c_ok "Основные пакеты установлены"

    step "AUR (zen-browser)"
    safe_pacman_S paru
    aur_install zen-browser-bin
fi

# --------------------------------------------------------------------------
# 2. NVIDIA
# --------------------------------------------------------------------------
if [[ $HAS_NVIDIA -eq 1 && $CONFIG_ONLY -eq 0 ]]; then
    step "NVIDIA (проприетарный dkms: Pascal/GTX 10xx не поддерживается nvidia-open)"
    HDR_PKGS=()
    shopt -s nullglob
    for f in /usr/lib/modules/*/pkgbase; do
        kb=$(cat "$f")
        cand="${kb}-headers"
        if [[ $DRY_RUN -eq 1 ]] || pacman -Ssq --freeze "$cand" 2>/dev/null | grep -qx -- "$cand"; then
            HDR_PKGS+=("$cand")
        else
            c_warn "Для ядра $kb нет пакета $cand — модуль dkms может не собраться"
        fi
    done
    shopt -u nullglob
    if [[ ${#HDR_PKGS[@]} -eq 0 ]]; then
        HDR_PKGS=(linux-headers)
    fi
    c_info "Заголовки ядер: ${HDR_PKGS[*]}"
    safe_pacman_S nvidia-dkms mokutil "${HDR_PKGS[@]}"

    # Secure Boot: DKMS подписывает модули ключом MOK, но прошивка должна ему доверять
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        c_warn "Secure Boot включён. Модуль nvidia подписан ключом DKMS (MOK)."
        c_info "После перезагрузки проверь: nvidia-smi"
        c_info "Если драйвер не поднялся — внедрить ключ: sudo mokutil --import /var/lib/dkms/mok.pub"
        c_info "затем перезагрузка и «Enroll MOK» в синем экране."
    fi

    step "Параметр ядра nvidia_drm.modeset=1"
    if grep -q 'nvidia_drm.modeset=1' /proc/cmdline; then
        c_ok "Уже активен"
    elif [[ -f /etc/default/limine ]]; then
        # CachyOS + Limine: параметры задаются в KERNEL_CMDLINE, /etc/kernel/cmdline — лишь фолбэк
        if grep -q 'nvidia_drm.modeset=1' /etc/default/limine; then
            c_ok "Уже прописан в /etc/default/limine"
        elif grep -qE '^KERNEL_CMDLINE\[default\][+]?=' /etc/default/limine; then
            run_strict need_sudo cp -a /etc/default/limine "/etc/default/limine${BACKUP_SUFFIX}"
            if [[ $DRY_RUN -eq 0 ]]; then
                sudo sed -i -E 's/^(KERNEL_CMDLINE\[default\][+]?=")([^"]*)"/\1\2 nvidia_drm.modeset=1"/' /etc/default/limine
                grep -q 'nvidia_drm.modeset=1' /etc/default/limine \
                    || c_warn "не удалось вписать параметр — проверь /etc/default/limine вручную"
            fi
            if command -v limine-mkinitcpio &>/dev/null; then
                run_strict need_sudo limine-mkinitcpio
                c_ok "Параметр добавлен, Limine перегенерирован (limine-mkinitcpio)"
            elif command -v limine-update &>/dev/null; then
                run_strict need_sudo limine-update
                c_ok "Параметр добавлен, Limine перегенерирован (limine-update)"
            else
                c_warn "Параметр добавлен, но Limine не перегенерирован. Выполни: sudo limine-mkinitcpio"
            fi
        else
            c_warn "В /etc/default/limine нет строки KERNEL_CMDLINE[default] — не трогаю."
            c_warn "Добавь параметр вручную в существующую строку KERNEL_CMDLINE, затем: sudo limine-mkinitcpio"
        fi
    elif [[ -f /etc/kernel/cmdline ]]; then
        run_strict need_sudo cp -a /etc/kernel/cmdline "/etc/kernel/cmdline${BACKUP_SUFFIX}"
        if [[ $DRY_RUN -eq 0 ]]; then
            grep -q 'nvidia_drm.modeset=1' /etc/kernel/cmdline \
                || sudo sed -i '1 s/[[:space:]]*$/ nvidia_drm.modeset=1/' /etc/kernel/cmdline
        fi
        if command -v sdboot-manage &>/dev/null; then
            run_strict need_sudo sdboot-manage gen
            c_ok "cmdline обновлён, systemd-boot перегенерирован"
        elif command -v limine-update &>/dev/null; then
            run_strict need_sudo limine-update
            c_ok "cmdline обновлён, Limine перегенерирован"
        else
            c_warn "Загрузчик не перегенерирован. Сделай: sudo sdboot-manage gen"
        fi
    elif [[ -f /etc/default/grub ]]; then
        run_strict need_sudo cp -a /etc/default/grub "/etc/default/grub${BACKUP_SUFFIX}"
        if [[ $DRY_RUN -eq 0 ]]; then
            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia_drm.modeset=1"/' /etc/default/grub
        fi
        run_strict need_sudo grub-mkconfig -o /boot/grub/grub.cfg
        c_ok "GRUB обновлён"
    else
        c_warn "Загрузчик не распознан. Добавь вручную: nvidia_drm.modeset=1"
    fi
fi

# --------------------------------------------------------------------------
# 3. службы
# --------------------------------------------------------------------------
if [[ $CONFIG_ONLY -eq 0 ]]; then
    step "Службы"
    run_strict need_sudo systemctl enable --now NetworkManager
    run need_sudo systemctl enable --now bluetooth.service
    run need_sudo systemctl enable --now power-profiles-daemon
    run systemctl --user enable --now pipewire pipewire-pulse wireplumber
    c_ok "NetworkManager, Bluetooth, power-profiles-daemon, PipeWire"
fi

# --------------------------------------------------------------------------
# 4. дисплей-менеджер: его быть не должно
# --------------------------------------------------------------------------
step "Дисплей-менеджер"
DM_ENABLED=""
for dm in sddm gdm lightdm ly greetd lxdm xdm; do
    if systemctl is-enabled "$dm" &>/dev/null; then
        DM_ENABLED="$dm"
        break
    fi
done
if [[ -n "$DM_ENABLED" ]]; then
    c_warn "Включён $DM_ENABLED — ты просил без логин-менеджера"
    if confirm "Отключить $DM_ENABLED?"; then
        run_strict need_sudo systemctl disable --now "$DM_ENABLED"
        c_ok "$DM_ENABLED отключён, вход через TTY"
    else
        c_info "Оставляю $DM_ENABLED, вход в niri из его меню"
    fi
else
    c_ok "Дисплей-менеджер не включён — вход через TTY"
fi

# --------------------------------------------------------------------------
# 5. тёмные темы Qt/GTK и переменные сессии
# --------------------------------------------------------------------------
step "Темы окружения"
ENV_DIR="$CONFIG_DIR/environment.d"
run mkdir -p "$ENV_DIR" \
    "$CONFIG_DIR/qt6ct/colors" "$CONFIG_DIR/qt5ct/colors" \
    "$CONFIG_DIR/gtk-3.0" "$CONFIG_DIR/gtk-4.0"

write_colors() {
    cat > "$1" <<'COLORS'
[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=-1
IntensityEffect=0

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=30,87,116
BackgroundNormal=41,44,48
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Complementary]
BackgroundAlternate=30,87,116
BackgroundNormal=32,35,38
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Selection]
BackgroundAlternate=61,174,233
BackgroundNormal=61,174,233
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=252,252,252
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Tooltip]
BackgroundAlternate=0,0,0
BackgroundNormal=32,35,38
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:View]
BackgroundAlternate=32,35,38
BackgroundNormal=27,30,32
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Window]
BackgroundAlternate=41,44,48
BackgroundNormal=32,35,38
DecorationFocus=61,174,233
DecorationHover=61,174,233
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=29,153,243
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[General]
ColorScheme=BreezeDark
Name=Breeze Dark
shadeSortColumn=true

[KDE]
contrast=4
COLORS
}

if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$ENV_DIR/80-session.conf" <<'EOF'
QT_QPA_PLATFORMTHEME=qt6ct
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=auto
XDG_CURRENT_DESKTOP=niri
EOF

    if [[ $HAS_NVIDIA -eq 1 ]]; then
        cat > "$ENV_DIR/90-nvidia.conf" <<'EOF'
LIBVA_DRIVER_NAME=nvidia
NVD_BACKEND=direct
__GLX_VENDOR_LIBRARY_NAME=nvidia
GBM_BACKEND=nvidia-drm
XDG_SESSION_TYPE=wayland
EOF
    fi

    cat > "$CONFIG_DIR/qt6ct/qt6ct.conf" <<EOF
[Appearance]
custom_palette=true
color_scheme_path=$CONFIG_DIR/qt6ct/colors/BreezeDark.colors
style=Fusion
icon_theme=Adwaita
EOF

    cat > "$CONFIG_DIR/qt5ct/qt5ct.conf" <<EOF
[Appearance]
custom_palette=true
color_scheme_path=$CONFIG_DIR/qt5ct/colors/BreezeDark.colors
style=Fusion
icon_theme=Adwaita
EOF

    cat > "$CONFIG_DIR/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
EOF

    cat > "$CONFIG_DIR/gtk-4.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
EOF

    write_colors "$CONFIG_DIR/qt6ct/colors/BreezeDark.colors"
    write_colors "$CONFIG_DIR/qt5ct/colors/BreezeDark.colors"
    c_ok "Qt: Fusion + Breeze Dark (Dolphin и др.), GTK: тёмная тема"
else
    echo "  [dry-run] ~/.config/{qt6ct,qt5ct,gtk-3.0,gtk-4.0,environment.d}"
fi

# --------------------------------------------------------------------------
# 6. конфиг niri
# --------------------------------------------------------------------------
step "Конфиг niri"
run mkdir -p "$CONFIG_DIR/niri" "$HOME/Pictures/Screenshots" "$HOME/Pictures/Wallpapers"
run xdg-user-dirs-update --force

if [[ -f "$NIRI_CFG" ]]; then
    run_strict cp -a "$NIRI_CFG" "${NIRI_CFG}${BACKUP_SUFFIX}"
    c_info "Старый конфиг сохранён: ${NIRI_CFG}${BACKUP_SUFFIX}"
fi

write_config() {
    cat > "${NIRI_CFG}.new" <<'KDL'
// niri + Noctalia — сгенерировано cachyos-niri-setup.sh
// Документация: https://niri-wm.github.io/niri/Configuration:-Introduction
// Правки подхватываются на лету, перезапуск не нужен.

input {
    keyboard {
        xkb {
            // раскладки и переключение Alt+Shift
            layout "us,ru"
            options "grp:alt_shift_toggle"
        }
        numlock
    }
    touchpad {
        tap
        natural-scroll
    }
    mouse {
        accel-profile "flat"
    }
}

layout {
    gaps 12
    center-focused-column "on-overflow"
    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }
    default-column-width { proportion 0.5; }
    focus-ring {
        width 2
        active-color "#7aa2f7"
        inactive-color "#414868"
    }
    border {
        off
    }
    shadow {
        on
        softness 30
        spread 5
        offset x=0 y=5
        color "#0007"
    }
}

prefer-no-csd

spawn-at-startup "noctalia"
spawn-at-startup "udiskie"

hotkey-overlay {
    skip-at-startup
}

screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

// Переключатель окон по Alt+Tab с превью
recent-windows {
    previews {
        max-height 480
        max-scale 0.5
    }
    binds {
        Alt+Tab { next-window; }
        Alt+Shift+Tab { previous-window; }
        Alt+grave { next-window filter="app-id"; }
        Alt+Shift+grave { previous-window filter="app-id"; }
    }
}

// --- extras: start
// Блок вырезается автоматически, если твоя версия niri его не понимает.

// скругления окон
window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}

// «Картинка в картинке» из браузера — поверх остальных окон
window-rule {
    match app-id=r#"firefox$|^zen$|^chromium$"# title="^Picture-in-Picture$"
    open-floating true
}

// окно настроек Noctalia — плавающее, фиксированный размер
window-rule {
    match app-id="dev.noctalia.Noctalia"
    open-floating true
    default-column-width { fixed 1080; }
    default-window-height { fixed 920; }
}

// действия уведомлений и активация окон из Noctalia
debug {
    honor-xdg-activation-with-invalid-serial
}

// обои Noctalia в фоне обзора
layer-rule {
    match namespace="^noctalia-backdrop"
    place-within-backdrop true
}

// размытие под панелями, доком и уведомлениями
layer-rule {
    match namespace=r#"^noctalia-(bar-[^"]+|notification|dock|panel|attached-panel|osd)$"#
    background-effect {
        xray false
    }
}

// размытие под переключателем окон
layer-rule {
    match namespace="noctalia-window-switcher"
    background-effect {
        blur true
        xray false
    }
}

// размытие под окнами приложений
window-rule {
    background-effect {
        blur true
        xray false
    }
}

blur {
    passes 2
    offset 3.0
    noise 0.03
    saturation 1.0
}
// --- extras: end

binds {
    // --- система
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+Shift+E { quit; }
    Mod+Escape { spawn-sh "noctalia msg session lock"; }
    Mod+Shift+P { power-off-monitors; }

    // --- запуск
    Mod+Return repeat=false { spawn "kitty"; }
    Mod+E repeat=false { spawn "dolphin"; }
    Mod+W repeat=false { spawn "firefox"; }
    Mod+B repeat=false { spawn "zen-browser"; }
    Mod+Space repeat=false { spawn-sh "noctalia msg panel-toggle launcher"; }
    Mod+S repeat=false { spawn-sh "noctalia msg panel-toggle control-center"; }
    Mod+Shift+Comma repeat=false { spawn-sh "noctalia msg settings-toggle"; }
    Mod+D repeat=false { spawn "fuzzel"; }

    // --- окна
    Mod+Q repeat=false { close-window; }
    Mod+V repeat=false { toggle-window-floating; }
    Mod+Shift+F repeat=false { fullscreen-window; }
    Mod+F repeat=false { maximize-column; }
    Mod+R { switch-preset-column-width; }
    Mod+Shift+R { switch-preset-column-width-back; }
    Mod+O repeat=false { toggle-overview; }

    // --- много окон, одно на экране: стопка в колонке и ровно пополам
    Mod+Comma { consume-window-into-column; }
    Mod+Period { expel-window-from-column; }
    Mod+Shift+Left repeat=false { set-column-width "50%"; }
    Mod+Shift+Right repeat=false { set-column-width "50%"; }

    // --- колонки
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+J { focus-window-down; }
    Mod+K { focus-window-up; }
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Down  { focus-window-down; }
    Mod+Up    { focus-window-up; }
    Mod+Ctrl+H { move-column-left; }
    Mod+Ctrl+L { move-column-right; }
    Mod+Ctrl+J { move-window-down; }
    Mod+Ctrl+K { move-window-up; }
    Mod+Home { focus-column-first; }
    Mod+End  { focus-column-last; }

    // --- рабочие столы
    Mod+U { focus-workspace-down; }
    Mod+I { focus-workspace-up; }
    Mod+Ctrl+U { move-column-to-workspace-down; }
    Mod+Ctrl+I { move-column-to-workspace-up; }
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }

    // --- звук и яркость
    XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "noctalia msg volume-up"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn-sh "noctalia msg volume-down"; }
    XF86AudioMute        allow-when-locked=true { spawn-sh "noctalia msg volume-mute"; }
    XF86MonBrightnessUp   allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }

    // --- скриншоты
    Print repeat=false { screenshot; }
    Ctrl+Print repeat=false { screenshot-screen; }
    Alt+Print repeat=false { screenshot-window; }
    Mod+Shift+S repeat=false { spawn-sh "noctalia msg screenshot-region"; }
    Mod+Alt+W repeat=false { spawn-sh "noctalia msg wallpaper-next"; }
}
KDL
    mv "${NIRI_CFG}.new" "$NIRI_CFG"
}

if [[ $DRY_RUN -eq 0 ]]; then
    write_config
    if command -v niri &>/dev/null; then
        if niri_validate; then
            c_ok "niri validate: конфиг валиден"
        else
            c_warn "niri validate не прошёл — вырезаю блок extras (эффекты и правила)"
            awk '/\/\/ --- extras: start/{skip=1} !skip{print} /\/\/ --- extras: end/{skip=0}' \
                "$NIRI_CFG" > "${NIRI_CFG}.tmp"
            mv "${NIRI_CFG}.tmp" "$NIRI_CFG"
            if niri_validate; then
                c_ok "Базовый конфиг валиден, эффекты отключены"
            else
                die "Конфиг невалиден даже без extras — сессия niri не запустится. Проверь: niri validate -c $NIRI_CFG"
            fi
        fi
    else
        c_warn "niri не найден — валидацию пропускаю"
    fi
fi

# --------------------------------------------------------------------------
# 7. обои из готового риса (--rice)
# --------------------------------------------------------------------------
if [[ $RICE -eq 1 ]]; then
    step "Рис: Noctara-Dots (только обои)"
    RICE_DIR="$HOME/dotfiles-noctara"
    if [[ -d "$RICE_DIR/.git" ]]; then
        run git -C "$RICE_DIR" pull --ff-only
    else
        run git clone --depth=1 https://github.com/deadduck-09/Noctara-Dots "$RICE_DIR"
    fi
    if [[ $DRY_RUN -eq 0 && -d "$RICE_DIR/wallpapers" ]]; then
        found=0
        for f in "$RICE_DIR"/wallpapers/*; do
            [[ -f "$f" ]] || continue
            cp -n "$f" "$HOME/Pictures/Wallpapers/" && found=$((found+1))
        done
        c_ok "Обои в ~/Pictures/Wallpapers (файлов: $found)"
        c_info "Выбери обои в Noctalia: Mod+S -> Обои. Палитра сгенерится из картинки."
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] git clone Noctara-Dots -> ~/dotfiles-noctara, копирование обоев"
    else
        c_warn "В репозитории нет wallpapers/ — пропускаю"
    fi
fi

# --------------------------------------------------------------------------
# 8. автовход (опционально)
# --------------------------------------------------------------------------
if [[ $AUTOLOGIN -eq 1 ]]; then
    step "Автовход на tty1 → niri"
    run_strict need_sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER --noclear %I \$TERM
EOF
    fi
    PROFILE="$HOME/.bash_profile"
    if [[ $DRY_RUN -eq 0 ]]; then
        touch "$PROFILE"
        if ! grep -q 'niri-session' "$PROFILE"; then
            cat >> "$PROFILE" <<'EOF'

# автовход в niri на первой консоли
if [[ -z "${WAYLAND_DISPLAY:-}" && "${XDG_VTNR:-}" == "1" ]]; then
    if command -v niri-session >/dev/null 2>&1; then exec niri-session; else exec niri; fi
fi
EOF
        fi
    fi
    run_strict need_sudo systemctl daemon-reload
    c_ok "Автовход настроен (выйти из сессии — Mod+Shift+E)"
fi

# --------------------------------------------------------------------------
# 9. проверка, классификация и отчёт
# --------------------------------------------------------------------------
step "Проверка"

MISSING_CRITICAL=()
MISSING_OPTIONAL=()
PRESENT=()

check_pkg() {
    local p="$1" critical="$2"
    if pkg_installed "$p"; then
        PRESENT+=("$p $(pacman -Q "$p" 2>/dev/null | awk '{print $2}')")
    elif [[ "$critical" == "critical" ]]; then
        MISSING_CRITICAL+=("$p")
    else
        MISSING_OPTIONAL+=("$p")
    fi
}

for p in "${CRITICAL_PKGS[@]}"; do check_pkg "$p" critical; done
for p in dolphin ark unrar zathura obsidian gnome-keyring firefox chromium zen-browser-bin \
         kitty opencode ffmpeg mpv kdenlive obs-studio gimp audacity 7zip \
         noctalia xwayland-satellite pipewire wireplumber NetworkManager \
         noto-fonts ttf-jetbrains-mono-nerd qt6ct; do
    check_pkg "$p" optional
done

for line in "${PRESENT[@]}"; do c_ok "$line"; done

for b in niri noctalia dolphin kitty opencode ffmpeg zen-browser chromium obsidian zathura; do
    if command -v "$b" &>/dev/null; then
        c_ok "бинарник: $b"
    else
        c_warn "нет в PATH: $b"
    fi
done

CFG_OK=0
if [[ -f "$NIRI_CFG" ]]; then
    c_ok "конфиг: $NIRI_CFG"
    CFG_OK=1
    if [[ $DRY_RUN -eq 0 ]] && command -v niri &>/dev/null && ! niri_validate; then
        c_err "конфиг не проходит niri validate!"
        CFG_OK=0
    fi
else
    c_warn "нет конфига"
fi

NVIDIA_OK=1
if [[ $HAS_NVIDIA -eq 1 && -r /sys/module/nvidia_drm/parameters/modeset ]]; then
    ms=$(cat /sys/module/nvidia_drm/parameters/modeset)
    if [[ "$ms" == "1" ]]; then
        c_ok "nvidia_drm.modeset=1"
    else
        c_warn "nvidia_drm.modeset=$ms — нужен 1: добавь параметр ядра и перезагрузись"
        NVIDIA_OK=0
    fi
elif [[ $HAS_NVIDIA -eq 1 ]]; then
    c_info "Модуль nvidia_drm ещё не загружен — проверь modeset после перезагрузки"
fi

# итог
step "Итог"
if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    c_warn "Пропущено (не критично): ${MISSING_OPTIONAL[*]}"
    c_info "Доставишь позже: sudo pacman -S ${MISSING_OPTIONAL[*]}"
else
    c_ok "Все опциональные пакеты на месте"
fi

EXIT_CODE=0
if [[ ${#MISSING_CRITICAL[@]} -gt 0 ]]; then
    c_err "Отсутствуют критичные пакеты: ${MISSING_CRITICAL[*]}"
    c_err "Сессия niri не запустится. Проверь репозитории и повтори скрипт."
    EXIT_CODE=1
elif [[ $CFG_OK -eq 0 ]]; then
    c_err "Конфиг niri невалиден — сессия не запустится."
    EXIT_CODE=1
else
    c_ok "Критичное на месте"
fi

step "Что сделать руками"
cat <<EOF
  1. sudo reboot
  2. на TTY1 залогинься и запусти:  niri-session
  3. Wi-Fi:  nmtui   (или панель Noctalia)
  4. Обои:   noctalia msg wallpaper-next   (палитра сгенерится из картинки)
  5. opencode:  opencode auth login
  6. Громкость/яркость проверь клавишами Fn
EOF

[[ $NVIDIA_OK -eq 0 ]] && c_warn "После перезагрузки проверь: cat /sys/module/nvidia_drm/parameters/modeset"

step "Горячие клавиши"
cat <<EOF
  Mod+Return — терминал        Mod+E — файлы (Dolphin)     Mod+W — Firefox
  Mod+B — Zen                  Mod+Space — лаунчер          Mod+S — центр управления
  Mod+O — обзор                Mod+V — плавающее окно      Mod+U/I — рабочие столы
  Mod+Shift+Comma — настройки  Alt+Shift — раскладка        Mod+Shift+E — выход
  Alt+Tab — окна с превью      Alt+grave — внутри приложения
  Mod+Comma — в стопку колонки Mod+Period — вынуть
  Mod+Shift+Left / Right — колонка ровно пополам
  Mod+F — развернуть           Mod+Shift+F — фуллскрин      Mod+R — 1/3, 1/2, 2/3
EOF

c_info "Лог: $LOG"
exit $EXIT_CODE
