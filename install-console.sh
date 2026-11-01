#!/usr/bin/env bash
# ============================================================================
#  Консольная установка CachyOS без графического установщика.
#  Для случаев, когда Calamares висит или падает.
#
#  Запускать из live-сессии CachyOS (флешка), от root.
#
#  Пример:
#     sudo bash install-console.sh
#  или с параметрами:
#     sudo bash install-console.sh --root /dev/sda5 --esp /dev/sda6
#
#  Скрипт ФОРМАТИРУЕТ указанные разделы. Требует ввести слово FORMAT.
# ============================================================================
set -Eeuo pipefail

ROOT_PART="${ROOT_PART:-}"
ESP_PART="${ESP_PART:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-cachyos}"
NEW_USER="${NEW_USER:-}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
MNT=/mnt
ASSUME_YES=0
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)     ROOT_PART="$2"; shift 2 ;;
        --esp)      ESP_PART="$2"; shift 2 ;;
        --user)     NEW_USER="$2"; shift 2 ;;
        --hostname) HOSTNAME_NEW="$2"; shift 2 ;;
        --yes)      ASSUME_YES=1; shift ;;
        --dry-run)  DRY=1; shift ;;
        -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $1"; exit 2 ;;
    esac
done

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[34m·\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

run() { if [[ $DRY -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- проверки
step "Проверка окружения"
[[ $EUID -eq 0 ]] || die "Запускай от root: sudo bash $0"
command -v pacman  &>/dev/null || die "Нет pacman — это не Arch-подобная система"
command -v pacstrap &>/dev/null || die "Нет pacstrap — запусти из live-ISO CachyOS"
command -v arch-chroot &>/dev/null || die "Нет arch-chroot"
[[ -d /sys/firmware/efi ]] || die "Система загружена не в UEFI-режиме"
c_ok "Окружение подходит (UEFI, live-ISO)"

# ---------------------------------------------------------------- разделы
step "Разделы"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | sed 's/^/  /'

if [[ -z "$ROOT_PART" ]]; then
    read -rp "Корневой раздел (будет отформатирован в btrfs), например /dev/sda5: " ROOT_PART
fi
if [[ -z "$ESP_PART" ]]; then
    read -rp "Раздел /boot (FAT32), например /dev/sda6: " ESP_PART
fi

[[ -b "$ROOT_PART" ]] || die "$ROOT_PART не является блочным устройством"
[[ -b "$ESP_PART"  ]] || die "$ESP_PART не является блочным устройством"
[[ "$ROOT_PART" != "$ESP_PART" ]] || die "Корень и /boot не могут быть одним разделом"

# страховка: не даём форматировать раздел с Windows
for p in "$ROOT_PART" "$ESP_PART"; do
    fs=$(lsblk -no FSTYPE "$p" 2>/dev/null || true)
    case "$fs" in
        ntfs|ntfs3|BitLocker) die "$p содержит NTFS/Windows — отказываюсь форматировать" ;;
    esac
done

echo
c_warn "Будут УНИЧТОЖЕНЫ данные на: $ROOT_PART и $ESP_PART"
if [[ $ASSUME_YES -eq 0 && $DRY -eq 0 ]]; then
    read -rp "Введи слово FORMAT для продолжения: " ans
    [[ "$ans" == "FORMAT" ]] || die "Отменено"
fi

# ---------------------------------------------------------------- размонтировать
step "Размонтирование"
run umount -R "$MNT" 2>/dev/null || true
for m in $(findmnt -rn -S "$ROOT_PART" -o TARGET 2>/dev/null || true); do
    run umount -R "$m" 2>/dev/null || true
done
for m in $(findmnt -rn -S "$ESP_PART" -o TARGET 2>/dev/null || true); do
    run umount -R "$m" 2>/dev/null || true
done
c_ok "Размонтировано"

# ---------------------------------------------------------------- форматирование
step "Форматирование"
run mkfs.btrfs -f -L CachyOS "$ROOT_PART"
run mkfs.vfat -F 32 -n CACHYOSBT "$ESP_PART"
c_ok "Файловые системы созданы"

step "Монтирование"
run mount "$ROOT_PART" "$MNT"
run mkdir -p "$MNT/boot"
run mount "$ESP_PART" "$MNT/boot"
c_ok "Смонтировано: $ROOT_PART -> /, $ESP_PART -> /boot"

# ---------------------------------------------------------------- пакеты
step "Установка базовой системы"
run pacman -Sy --noconfirm --needed archlinux-keyring

# ядро CachyOS, если доступно
KERNEL=linux
if pacman -Ssq --freeze linux-cachyos 2>/dev/null | grep -qx linux-cachyos; then
    KERNEL=linux-cachyos
    c_info "Ядро: linux-cachyos"
else
    c_info "Ядро: linux (cachyos-ядро недоступно)"
fi

UCODE=""
if grep -qm1 'GenuineIntel' /proc/cpuinfo; then UCODE=intel-ucode; fi
if grep -qm1 'AuthenticAMD' /proc/cpuinfo; then UCODE=amd-ucode; fi

PKGS=(base base-devel "$KERNEL" "${KERNEL}-headers" linux-firmware btrfs-progs
      networkmanager sudo nano vim git efibootmgr dosfstools
      pipewire pipewire-pulse pipewire-audio wireplumber)
[[ -n "$UCODE" ]] && PKGS+=("$UCODE")

run pacstrap -K "$MNT" "${PKGS[@]}"
c_ok "Базовая система установлена"

step "fstab"
if [[ $DRY -eq 1 ]]; then
    echo "  [dry-run] genfstab -U $MNT >> $MNT/etc/fstab"
else
    genfstab -U "$MNT" >> "$MNT/etc/fstab"
fi
c_ok "fstab создан"

# ---------------------------------------------------------------- chroot
step "Настройка системы"
if [[ -z "$NEW_USER" ]]; then
    read -rp "Имя пользователя: " NEW_USER
fi
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Недопустимое имя пользователя: $NEW_USER"

if [[ $DRY -eq 1 ]]; then
    echo "  [dry-run] arch-chroot $MNT <настройка: локаль, время, hostname, пользователь, systemd-boot>"
else
    arch-chroot "$MNT" /bin/bash -s -- "$HOSTNAME_NEW" "$NEW_USER" "$TIMEZONE" "$KERNEL" <<'CHROOT'
set -Eeuo pipefail
HOSTNAME_NEW="$1"; NEW_USER="$2"; TIMEZONE="$3"; KERNEL="$4"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$HOSTNAME_NEW" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF

echo "root: задай пароль"
passwd root

id "$NEW_USER" &>/dev/null || useradd -m -G wheel -s /bin/bash "$NEW_USER"
echo "$NEW_USER: задай пароль"
passwd "$NEW_USER"

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable fstrim.timer

# --- загрузчик: systemd-boot
bootctl --esp-path=/boot install || bootctl install
mkdir -p /boot/loader/entries
ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")
cat > /boot/loader/entries/cachyos.conf <<ENTRY
title   CachyOS
linux   /vmlinuz-$KERNEL
initrd  /initramfs-$KERNEL.img
options root=UUID=$ROOT_UUID rw quiet splash
ENTRY
cat > /boot/loader/loader.conf <<ENTRY
default  cachyos.conf
timeout  5
console-mode max
ENTRY

mkinitcpio -P
CHROOT
fi
c_ok "Система настроена"

# ---------------------------------------------------------------- проверка
step "Проверка"
if [[ $DRY -eq 0 ]]; then
    if [[ -f "$MNT/boot/loader/entries/cachyos.conf" ]]; then
        c_ok "systemd-boot установлен, запись загрузки создана"
    else
        c_warn "Нет записи загрузки на ESP — проверь /boot/loader/entries"
    fi
    find "$MNT/boot" -maxdepth 1 -mindepth 1 -printf '  %f\n' 2>/dev/null || true
    df -h "$MNT/boot" | tail -1
fi

step "Завершение"
run umount -R "$MNT"
c_ok "Размонтировано"

cat <<EOF

Готово. Дальше:
  1. перезагрузись:  reboot   (флешку можно вынуть)
  2. в F11 выбери пункт «Linux Boot Manager» или «CachyOS»
  3. залогинься как $NEW_USER
  4. поставь рабочий стол:
       curl -LO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/cachyos-niri-setup.sh
       chmod +x cachyos-niri-setup.sh && ./cachyos-niri-setup.sh
EOF
