#!/usr/bin/env bash
# ============================================================================
#  CachyOS: установка системы ОДНОЙ КОМАНДОЙ, без единого вопроса.
#  Написано под конкретную машину: Kingston SSD /dev/sda,
#  sda5 -> / (btrfs), sda6 -> /boot (FAT32). Windows на sda3 не трогается.
#
#  Запуск из live-сессии CachyOS (флешка, UEFI, Secure Boot выключен):
#
#      curl -fsSL https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/install-once.sh | sudo bash
#
#  СКРИПТ УНИЧТОЖАЕТ ДАННЫЕ на /dev/sda5 и /dev/sda6. Больше ничего.
#  Никаких подтверждений и вводов — всё зашито внутри.
#
#  Результат:
#      · root  / пароль: cachyos
#      · dmitry / пароль: dmitry   (группа wheel, sudo без пароля не нужен)
#      · загрузчик systemd-boot, пункт «CachyOS» в меню UEFI
#      · локаль ru_RU.UTF-8, время Europe/Moscow, keymap us
#      · NetworkManager, PipeWire, btrfs-progs, nano, vim, git
#
#  После установки: reboot -> F11 -> «Linux Boot Manager» -> вход как dmitry
#  Пароли сменить: passwd
# ============================================================================
set -Eeuo pipefail

# ---- зашитые параметры (менять тут, если что) -------------------------------
ROOT_PART=/dev/sda5
ESP_PART=/dev/sda6
WIN_PART=/dev/sda3
HOSTNAME_NEW=cachyos
NEW_USER=dmitry
ROOT_PASS=cachyos
USER_PASS=dmitry
TIMEZONE=Europe/Moscow
MNT=/mnt
# ----------------------------------------------------------------------------

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[34m·\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

# ---- автоматический root ----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

step "Проверка окружения"
command -v pacman     &>/dev/null || die "Нет pacman — это не Arch-подобная система"
command -v pacstrap   &>/dev/null || die "Нет pacstrap — запусти из live-ISO CachyOS"
command -v arch-chroot &>/dev/null || die "Нет arch-chroot — запусти из live-ISO CachyOS"
[[ -d /sys/firmware/efi ]] || die "Загружено не в UEFI — включи UEFI в BIOS"
[[ -b "$ROOT_PART" ]] || die "Нет $ROOT_PART"
[[ -b "$ESP_PART"  ]] || die "Нет $ESP_PART"
c_ok "Окружение подходит"

step "Проверка, что это тот самый диск"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | sed 's/^/  /'
if [[ -b "$WIN_PART" ]]; then
    winfs=$(lsblk -no FSTYPE "$WIN_PART" 2>/dev/null || true)
    [[ "$winfs" == ntfs* ]] || die "$WIN_PART не NTFS — диск не тот, останавливаюсь"
    c_ok "Windows-раздел на месте ($WIN_PART, $winfs) — его не трогаем"
else
    c_warn "$WIN_PART не найден — разметка не совпадает с ожидаемой, продолжаю только с $ROOT_PART и $ESP_PART"
fi

step "Размонтирование"
umount -R "$MNT" 2>/dev/null || true
fuser -km "$MNT" 2>/dev/null || true
for p in "$ROOT_PART" "$ESP_PART"; do
    for m in $(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true); do
        umount -l -R "$m" 2>/dev/null || true
    done
done
sleep 1
left=$( { findmnt -rn -S "$ROOT_PART" -o TARGET 2>/dev/null
          findmnt -rn -S "$ESP_PART"  -o TARGET 2>/dev/null; } | tr '\n' ' ' | sed 's/ *$//' )
[[ -z "$left" ]] || die "Раздел занят: $left — перезагрузись и запусти снова"
c_ok "Разделы свободны"

step "Форматирование"
mkfs.btrfs -f -L CachyOS "$ROOT_PART"
mkfs.vfat -F 32 -n CACHYOSBT "$ESP_PART"
c_ok "btrfs на $ROOT_PART, FAT32 на $ESP_PART"

step "Монтирование"
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot"
mount "$ESP_PART" "$MNT/boot"
c_ok "Смонтировано"

step "Пакеты"
pacman -Sy --noconfirm --needed archlinux-keyring

KERNEL=linux
if pacman -Ssq '^linux-cachyos$' 2>/dev/null | grep -qx linux-cachyos; then
    KERNEL=linux-cachyos
fi
c_info "Ядро: $KERNEL"

UCODE=""
if grep -qm1 'GenuineIntel' /proc/cpuinfo; then UCODE=intel-ucode; fi
if grep -qm1 'AuthenticAMD' /proc/cpuinfo; then UCODE=amd-ucode; fi

PKGS=(base base-devel "$KERNEL" "${KERNEL}-headers" linux-firmware btrfs-progs
      networkmanager sudo nano vim git efibootmgr dosfstools
      pipewire pipewire-pulse pipewire-audio wireplumber)
if [[ -n "$UCODE" ]]; then PKGS+=("$UCODE"); fi

pacstrap "$MNT" "${PKGS[@]}"
c_ok "Базовая система установлена"

step "fstab"
genfstab -U "$MNT" >> "$MNT/etc/fstab"
c_ok "fstab создан"

step "Настройка системы"
arch-chroot "$MNT" /bin/bash -s -- "$HOSTNAME_NEW" "$NEW_USER" "$TIMEZONE" "$KERNEL" \
                 "$ROOT_PASS" "$USER_PASS" <<'CHROOT'
set -Eeuo pipefail
HOSTNAME_NEW="$1"; NEW_USER="$2"; TIMEZONE="$3"; KERNEL="$4"
ROOT_PASS="$5"; USER_PASS="$6"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$HOSTNAME_NEW" > /etc/hostname
printf '127.0.0.1   localhost\n::1         localhost\n127.0.1.1   %s.localdomain %s\n' \
    "$HOSTNAME_NEW" "$HOSTNAME_NEW" > /etc/hosts

printf 'root:%s\n' "$ROOT_PASS" | chpasswd
id "$NEW_USER" &>/dev/null || useradd -m -G wheel -s /bin/bash "$NEW_USER"
printf '%s:%s\n' "$NEW_USER" "$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable fstrim.timer

bootctl --esp-path=/boot install || bootctl install
mkdir -p /boot/loader/entries
ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")
printf 'title   CachyOS\nlinux   /vmlinuz-%s\ninitrd  /initramfs-%s.img\noptions root=UUID=%s rw quiet\n' \
    "$KERNEL" "$KERNEL" "$ROOT_UUID" > /boot/loader/entries/cachyos.conf
printf 'default  cachyos.conf\ntimeout  5\nconsole-mode max\n' > /boot/loader/loader.conf

mkinitcpio -P
CHROOT
c_ok "Система настроена"

step "Проверка"
if [[ -f "$MNT/boot/loader/entries/cachyos.conf" ]]; then
    c_ok "Запись загрузки на месте"
else
    c_warn "Нет /boot/loader/entries/cachyos.conf — проверь ESP вручную"
fi
find "$MNT/boot" -maxdepth 1 -mindepth 1 -printf '  %f\n' 2>/dev/null || true

step "Завершение"
umount -R "$MNT"
c_ok "Размонтировано"

cat <<EOF

============================================================
ГОТОВО.

  reboot  ->  F11  ->  «Linux Boot Manager» / «CachyOS»

  пользователь: $NEW_USER        пароль: $USER_PASS
  root:                          пароль: $ROOT_PASS

  сменить пароли:  passwd   и   sudo passwd root

  рабочий стол (niri + Noctalia), уже в системе-онлайн:
     curl -fsSLO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/cachyos-niri-setup.sh
     chmod +x cachyos-niri-setup.sh && ./cachyos-niri-setup.sh
============================================================
EOF
