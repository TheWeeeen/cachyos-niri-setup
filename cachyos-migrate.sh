#!/usr/bin/env bash
# ============================================================================
#  Перенос системы на чистую переустановку CachyOS — в две команды.
#
#  ДО переустановки (в текущей системе):
#      ./cachyos-migrate.sh backup
#
#  ПОСЛЕ переустановки (в свежей системе):
#      ./cachyos-migrate.sh restore
#
#  Флешка определяется по метке «Adata Flash». Если метка другая:
#      USB_LABEL="Ventoy" ./cachyos-migrate.sh backup
#  или указать точку монтирования напрямую:
#      USB=/run/media/user/Adata\ Flash ./cachyos-migrate.sh backup
#
#  Что сохраняет: ключи Secure Boot, список пакетов, ~/.ssh, ~/.config,
#  ~/Documents, ~/Pictures; пишет манифест с разметкой дисков.
#  Всё лежит на флешке и переживает переустановку.
# ============================================================================
set -Eeuo pipefail

USB_LABEL="${USB_LABEL:-Adata Flash}"
SBCTL_DIR="${SBCTL_DIR:-/var/lib/sbctl}"
BACKUP_DIR_NAME="cachyos-migrate"
MODE="${1:-}"

# ---- вывод -----------------------------------------------------------------
c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[34m·\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 && !/^#/ {exit}' "$0"
    exit "${1:-0}"
}

case "$MODE" in
    backup|restore) ;;
    ""|-h|--help|help) usage 0 ;;
    *) c_err "Неизвестный режим: $MODE"; usage 2 ;;
esac

# ---- утилиты ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && die "Запускай от обычного пользователя, не от root."

need_sudo() { sudo "$@"; }
has() { command -v "$1" &>/dev/null; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

# найти флешку: явная переменная > метка > интерактивный выбор
find_usb() {
    if [[ -n "${USB:-}" ]]; then
        [[ -d "$USB" ]] || die "Каталог USB=$USB не существует"
        printf '%s\n' "$USB"
        return 0
    fi
    local mp
    mp=$(findmnt -no TARGET -S "LABEL=$USB_LABEL" 2>/dev/null | head -1 || true)
    if [[ -z "$mp" ]]; then
        mp=$(findmnt -no TARGET -S "LABEL=$(printf '%s' "$USB_LABEL" | sed 's/ /\\x20/g')" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$mp" && -d "$mp" ]]; then
        printf '%s\n' "$mp"
        return 0
    fi

    c_warn "Флешка с меткой «$USB_LABEL» не смонтирована."
    echo "Доступные съёмные тома:" >&2
    findmnt -rno TARGET,SOURCE,FSTYPE,SIZE -t vfat,exfat,ntfs,ntfs3 2>/dev/null \
        | grep -vE '^/(boot|efi)' | sed 's/^/    /' >&2 || true
    echo >&2
    local ans=""
    read -rp "Введи точку монтирования флешки (пусто = выйти): " ans 2>/dev/null </dev/tty || ans=""
    [[ -z "$ans" ]] && die "Флешка не выбрана"
    [[ -d "$ans" ]] || die "Каталог $ans не существует"
    printf '%s\n' "$ans"
}

dir_size_kb() {
    local p="$1"
    [[ -e "$p" ]] || { echo 0; return 0; }
    du -sk "$p" 2>/dev/null | awk '{print $1}'
}

free_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }

# ============================================================================
#  BACKUP
# ============================================================================
do_backup() {
    step "Перенос: сохранение данных"
    local usb
    usb=$(find_usb)
    usb=$(cd "$usb" && pwd)
    local dest="$usb/$BACKUP_DIR_NAME"
    c_info "Флешка: $usb"
    c_info "Куда пишу: $dest"

    [[ -w "$usb" ]] || die "Нет прав на запись в $usb (exFAT/FAT обычно пишутся, NTFS с гибернацией — нет)"

    local free_before
    free_before=$(free_kb "$usb")
    c_info "Свободно на флешке: $(human $((free_before*1024)))"

    # что собираемся копировать
    local items=()
    for it in .ssh .config Documents Pictures Projects; do
        [[ -e "$HOME/$it" ]] && items+=("$it")
    done
    [[ ${#items[@]} -gt 0 ]] || die "Нечего копировать: в $HOME нет стандартных каталогов"

    local need_kb=0 sz
    for it in "${items[@]}"; do
        sz=$(dir_size_kb "$HOME/$it")
        c_info "  $it — $(human $((sz*1024)))"
        need_kb=$((need_kb + sz))
    done
    # сжатие обычно даёт 2-3x, оставляем запас 30%
    local need_est=$(( need_kb * 7 / 10 ))
    c_info "Нужно примерно: $(human $((need_est*1024))) (со сжатием)"

    if (( need_est > free_before )); then
        c_err "На флешке мало места: свободно $(human $((free_before*1024))), нужно ~$(human $((need_est*1024)))"
        c_warn "Освободи место или исключи крупные каталоги (например, ~/Documents)"
        local ans=""
        read -rp "Продолжить только с .ssh и .config? [y/N] " ans 2>/dev/null </dev/tty || ans=""
        [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Прервано пользователем"
        items=(.ssh .config)
        need_kb=0
        for it in "${items[@]}"; do
            [[ -e "$HOME/$it" ]] && need_kb=$((need_kb + $(dir_size_kb "$HOME/$it")))
        done
        need_est=$(( need_kb * 7 / 10 ))
    fi

    need_sudo -v || die "Нужны права sudo для ключей Secure Boot"

    mkdir -p "$dest"

    # 1. ключи Secure Boot
    step "Ключи Secure Boot"
    if [[ -d "$SBCTL_DIR" ]]; then
        need_sudo rm -rf "$dest/sbctl"
        need_sudo mkdir -p "$dest/sbctl"
        # на exFAT/FAT нельзя сохранить владельца и права — копируем без метаданных,
        # иначе cp сыплет «cannot preserve ownership» на каждый файл
        need_sudo cp -r --no-preserve=mode,ownership "$SBCTL_DIR/." "$dest/sbctl/" 2>/dev/null \
            || c_warn "cp ругнулся (обычное дело для exFAT) — проверяю, что файлы на месте"

        local src_n dst_n
        src_n=$(cd / && find "$SBCTL_DIR" -type f 2>/dev/null | wc -l)
        dst_n=$(cd / && find "$dest/sbctl" -type f 2>/dev/null | wc -l)
        if [[ "$src_n" -gt 0 && "$src_n" -eq "$dst_n" ]]; then
            c_ok "Ключи Secure Boot: $dst_n файлов"
        elif [[ "$dst_n" -gt 0 ]]; then
            c_warn "Ключей скопировалось $dst_n из $src_n — проверь перед переустановкой"
        else
            c_warn "Ключи не скопировались. Если Secure Boot включён — выключи его перед установкой"
        fi
    else
        c_warn "$SBCTL_DIR нет — Secure Boot, похоже, не настроен. Пропускаю."
    fi
    if has sbctl; then
        sbctl status 2>/dev/null > "$dest/sbctl-status.txt" || true
        c_ok "Статус sbctl: $dest/sbctl-status.txt"
    fi

    # 2. список пакетов
    step "Список пакетов"
    if has pacman; then
        pacman -Qqe > "$dest/pkglist-explicit.txt" 2>/dev/null || true
        pacman -Qqm > "$dest/pkglist-aur.txt" 2>/dev/null || true
        pacman -Q  > "$dest/pkglist-all.txt" 2>/dev/null || true
        c_ok "Пакетов: $(wc -l < "$dest/pkglist-explicit.txt" 2>/dev/null || echo 0) явных"
    else
        c_warn "pacman не найден — списки пакетов не сохранены"
    fi

    # 3. архивы данных
    step "Архивирование данных"
    local stamp
    stamp=$(date +%Y%m%d-%H%M)
    local arch="$dest/home-$stamp.tar.gz"
    local tar_opts=(-czf "$arch" -C "$HOME")
    # предупреждения tar (файлы меняются на ходу) не должны валить скрипт
    if tar "${tar_opts[@]}" "${items[@]}" 2>/dev/null; then
        c_ok "Архив: home-$stamp.tar.gz ($(human "$(stat -c%s "$arch")"))"
    else
        c_warn "tar вернул ошибку (файлы менялись во время чтения). Архив сохранён частично."
        c_warn "Проверь его после перезагрузки: tar -tzf $arch > /dev/null"
    fi

    # 4. манифест
    step "Манифест"
    {
        echo "# Бэкап перед переустановкой"
        echo "дата: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "хост: $(hostname)"
        if [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            echo "система: ${PRETTY_NAME:-неизвестно}"
        fi
        echo "ядро: $(uname -r)"
        echo "пользователь: $USER (uid $(id -u))"
        echo "домашний каталог: $HOME"
        echo "архив: home-$stamp.tar.gz"
        echo "каталоги: ${items[*]}"
        echo
        echo "## разметка дисков"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID 2>/dev/null || true
        echo
        echo "## размеры"
        du -sh "$HOME"/* 2>/dev/null | sort -h | tail -20 || true
    } > "$dest/manifest-$stamp.txt"
    c_ok "Манифест: manifest-$stamp.txt"

    # 5. контрольные суммы
    step "Контрольные суммы"
    ( cd "$dest" && sha256sum home-"$stamp".tar.gz > "sha256-$stamp.txt" 2>/dev/null ) \
        && c_ok "sha256-$stamp.txt"

    # 6. скрипт установки — если лежит рядом на флешке, копируем в бэкап
    if [[ -f "$usb/cachyos-niri-setup.sh" ]]; then
        cp -f "$usb/cachyos-niri-setup.sh" "$dest/" 2>/dev/null || true
        c_ok "Скрипт установки тоже сохранён в бэкап"
    fi

    sync
    local free_after
    free_after=$(free_kb "$usb")

    step "Готово"
    cat <<EOF
На флешке: $dest
  · ключи Secure Boot   sbctl/
  · пакеты             pkglist-*.txt
  · архив данных       home-$stamp.tar.gz
  · манифест           manifest-$stamp.txt
  · контрольная сумма  sha256-$stamp.txt

Занято: $(human $(( (free_before-free_after)*1024 )))
Свободно на флешке: $(human $((free_after*1024)))

Дальше:
  1. выключить Secure Boot в BIOS
  2. загрузиться с флешки и переустановить CachyOS (форматировать только / и /boot)
  3. в свежей системе запустить:  ./cachyos-migrate.sh restore
EOF
}

# ============================================================================
#  RESTORE
# ============================================================================
do_restore() {
    step "Перенос: восстановление после переустановки"
    local usb
    usb=$(find_usb)
    usb=$(cd "$usb" && pwd)
    local dest="$usb/$BACKUP_DIR_NAME"
    [[ -d "$dest" ]] || die "На флешке нет $BACKUP_DIR_NAME — сначала сделай backup"

    [[ -d "$HOME/.config" ]] || die "Странное окружение: нет $HOME/.config"
    c_info "Флешка: $usb"

    local manifest
    manifest=$(ls -1t "$dest"/manifest-*.txt 2>/dev/null | head -1 || true)
    if [[ -n "$manifest" ]]; then
        c_info "Бэкап от: $(grep -m1 '^дата:' "$manifest" | cut -d: -f2- | sed 's/^ //')"
        c_info "Пользователь в бэкапе: $(grep -m1 '^пользователь:' "$manifest" | cut -d: -f2- | sed 's/^ //')"
    fi

    need_sudo -v || die "Нужны права sudo"

    # 1. ключи Secure Boot
    step "Ключи Secure Boot"
    if [[ -d "$dest/sbctl" ]]; then
        if ! has sbctl; then
            c_info "Ставлю sbctl"
            need_sudo pacman -S --needed --noconfirm sbctl || c_warn "не удалось поставить sbctl (нет сети?)"
        fi
        need_sudo mkdir -p "$SBCTL_DIR"
        # сохраняем то, что могло появиться на новом месте
        if [[ -n "$(ls -A "$SBCTL_DIR" 2>/dev/null)" ]]; then
            need_sudo cp -a "$SBCTL_DIR" "${SBCTL_DIR}.bak.$(date +%s)"
            c_info "Старые ключи сохранены рядом: ${SBCTL_DIR}.bak.*"
        fi
        need_sudo cp -a "$dest/sbctl/." "$SBCTL_DIR/"
        need_sudo chown -R root:root "$SBCTL_DIR"
        need_sudo find "$SBCTL_DIR" -name '*.key' -exec chmod 600 {} + 2>/dev/null || true
        need_sudo find "$SBCTL_DIR" -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
        c_ok "Ключи восстановлены"

        if has sbctl; then
            need_sudo sbctl sign-all || c_warn "sign-all вернул ошибку — проверь вручную: sudo sbctl verify"
            c_info "Проверка подписей:"
            need_sudo sbctl verify 2>&1 | sed 's/^/    /' | head -12 || true
        fi
    else
        c_warn "Ключей Secure Boot в бэкапе нет — оставь Secure Boot выключенным"
    fi

    # 2. скрипт установки
    step "Скрипт установки"
    if [[ -f "$dest/cachyos-niri-setup.sh" ]]; then
        cp -f "$dest/cachyos-niri-setup.sh" "$HOME/"
        chmod +x "$HOME/cachyos-niri-setup.sh"
        c_ok "Скопирован: ~/cachyos-niri-setup.sh"
    elif [[ -f "$usb/cachyos-niri-setup.sh" ]]; then
        cp -f "$usb/cachyos-niri-setup.sh" "$HOME/"
        chmod +x "$HOME/cachyos-niri-setup.sh"
        c_ok "Скопирован с флешки: ~/cachyos-niri-setup.sh"
    else
        c_warn "Скрипт установки на флешке не найден"
    fi

    # 3. архивы данных — только по запросу
    step "Личные файлы"
    local arch
    arch=$(ls -1t "$dest"/home-*.tar.gz 2>/dev/null | head -1 || true)
    if [[ -z "$arch" ]]; then
        c_warn "Архивов нет"
    else
        c_info "Найден: $(basename "$arch") ($(human "$(stat -c%s "$arch")"))"
        echo "  Что распаковать:"
        echo "    1) только ~/.ssh (безопасно, ничего не затрёт)"
        echo "    2) ~/.ssh и ~/Documents, ~/Pictures, ~/Projects"
        echo "    3) всё, включая ~/.config (затрёт настройки niri/Noctalia!)"
        echo "    4) ничего, распакую сам позже"
        local choice=""
        read -rp "Выбор [1]: " choice 2>/dev/null </dev/tty || choice=""
        choice="${choice:-1}"
        local unpack=()
        case "$choice" in
            1) unpack=(.ssh) ;;
            2) unpack=(.ssh Documents Pictures Projects) ;;
            3) unpack=(.ssh .config Documents Pictures Projects) ;;
            4) unpack=() ;;
            *) c_warn "Не понял выбор, беру вариант 1"; unpack=(.ssh) ;;
        esac
        if [[ ${#unpack[@]} -gt 0 ]]; then
            for it in "${unpack[@]}"; do
                if [[ -e "$HOME/$it" ]]; then
                    mv "$HOME/$it" "$HOME/$it.bak.$(date +%Y%m%d-%H%M%S)"
                    c_info "$it: старое переименовано в $it.bak.*"
                fi
            done
            if tar -xzf "$arch" -C "$HOME" "${unpack[@]}" 2>/dev/null; then
                c_ok "Распаковано: ${unpack[*]}"
            else
                c_warn "tar вернул ошибку при распаковке — проверь ~/$it.* вручную"
            fi
            find "$HOME/.ssh" -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
        else
            c_info "Оставлено на потом: tar -xzf \"$arch\" -C ~"
        fi
    fi

    # 4. что дальше
    step "Готово. Дальше"
    cat <<EOF
  1. включи Secure Boot в BIOS (если выключал) — ключи уже на месте
  2. проверь драйвер:   nvidia-smi
  3. запусти установку:  cd ~ && ./cachyos-niri-setup.sh --dry-run
                         cd ~ && ./cachyos-niri-setup.sh
  4. после установки:    sudo reboot, затем на TTY: niri-session

Списки старых пакетов (пригодятся, чтобы донести недостающее):
  $dest/pkglist-explicit.txt
  $dest/pkglist-aur.txt
EOF
}

case "$MODE" in
    backup)  do_backup ;;
    restore) do_restore ;;
esac
