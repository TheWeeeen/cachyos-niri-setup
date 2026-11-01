#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  CachyOS: простая установка БЕЗ Calamares.
#
#  Почему без него — по итогам разбора известных багов:
#    1) Calamares навсегда виснет на «Ожидание 1 модуля» — застревает модуль
#       partition (KPMcore/os-prober опрашивает существующие разделы).
#    2) Установка падает в самом конце на «Failed to run chwd» — известный
#       баг CachyOS (конфликт nvidia-пакетов и переезд mesa-подпакетов).
#  Обе поломки находятся в установщике, поэтому здесь его просто нет.
#
#  Диск: /dev/sda. Ставим на sda5 (btrfs, /) и sda6 (FAT32, /boot).
#  Windows на sda3 не трогаем — скрипт сверяет, что там NTFS, иначе выходит.
#
#  Запуск (в live-сессии CachyOS, от root):
#     curl -fsSLO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/install-simple.sh
#     sudo bash install-simple.sh
#
#  Результат: dmitry / dmitry, root / cachyos, systemd-boot, локаль ru,
#  время Москва, NetworkManager. Дальше — reboot и cachyos-niri-setup.sh.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ROOT=/dev/sda5
ESP=/dev/sda6
WIN=/dev/sda3
MNT=/mnt

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. проверки -----------------------------------------------------------
say "1/6 проверки"
command -v pacstrap >/dev/null || die "это не live-ISO CachyOS (нет pacstrap)"
[[ -d /sys/firmware/efi ]]    || die "загрузка не в UEFI"
[[ -b $ROOT && -b $ESP ]]     || die "нет $ROOT или $ESP"
[[ "$(lsblk -no FSTYPE $WIN)" == ntfs* ]] || die "$WIN не NTFS — диск не тот"
ok "UEFI, разделы на месте, Windows на $WIN цел"

# --- 2. освободить и отформатировать ---------------------------------------
say "2/6 разметка"
umount -R $MNT 2>/dev/null || true
# fuser -m по обычному каталогу берёт всю корневую ФС live-системы и убивает
# сессию — поэтому его тут нет вообще, только ленивое размонтирование.
for part in $ROOT $ESP; do
    while read -r tgt; do umount -l -R "$tgt" 2>/dev/null || true; done \
        < <(findmnt -rn -S "$part" -o TARGET)
done
sleep 1
[[ -z "$(findmnt -rn -S $ROOT -o TARGET)" ]] || die "$ROOT занят — перезагрузись и повтори"
mkfs.btrfs -f -L CachyOS $ROOT
mkfs.vfat -F 32 -n CACHYOSBT $ESP
ok "btrfs на $ROOT, FAT32 на $ESP"

# --- 3. смонтировать и поставить базу --------------------------------------
say "3/6 база"
mount $ROOT $MNT
mkdir -p $MNT/boot
mount $ESP $MNT/boot
pacman -Sy --noconfirm --needed archlinux-keyring

KERNEL=linux
if pacman -Ssq '^linux-cachyos$' 2>/dev/null | grep -qx linux-cachyos; then
    KERNEL=linux-cachyos
fi
UCODE=""
if grep -qm1 GenuineIntel /proc/cpuinfo; then UCODE=intel-ucode; fi
if grep -qm1 AuthenticAMD /proc/cpuinfo; then UCODE=amd-ucode; fi

PKGS=(base "$KERNEL" "${KERNEL}-headers" linux-firmware btrfs-progs dosfstools
      efibootmgr networkmanager sudo nano vim git
      pipewire pipewire-pulse wireplumber)
if [[ -n "$UCODE" ]]; then PKGS+=("$UCODE"); fi

pacstrap $MNT "${PKGS[@]}"
genfstab -U $MNT >> $MNT/etc/fstab
ok "ядро $KERNEL ${UCODE:-(без microcode)}"

# --- 4. настройка в chroot -------------------------------------------------
say "4/6 настройка"
arch-chroot $MNT /bin/bash -s -- "$KERNEL" <<'CHROOT'
K=$1
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc || true
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/;s/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=ru_RU.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf
echo cachyos > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 cachyos.localdomain cachyos\n' > /etc/hosts

printf 'root:%s\n' cachyos | chpasswd
useradd -m -G wheel -s /bin/bash dmitry
printf 'dmitry:%s\n' dmitry | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable fstrim.timer

bootctl --esp-path=/boot install || bootctl install
mkdir -p /boot/loader/entries
UUID=$(blkid -s UUID -o value /dev/sda5)
printf 'title CachyOS\nlinux /vmlinuz-%s\ninitrd /initramfs-%s.img\noptions root=UUID=%s rw quiet\n' \
    "$K" "$K" "$UUID" > /boot/loader/entries/cachyos.conf
printf 'default cachyos.conf\ntimeout 5\n' > /boot/loader/loader.conf
mkinitcpio -P
CHROOT
ok "система настроена"

# --- 5. проверка -----------------------------------------------------------
say "5/6 проверка"
[[ -f $MNT/boot/loader/entries/cachyos.conf ]] || die "нет записи загрузки на ESP"
find $MNT/boot -maxdepth 1 -mindepth 1 -printf '%f ' ; echo
ok "systemd-boot и ядро на ESP"

# --- 6. финал --------------------------------------------------------------
say "6/6 готово"
umount -R $MNT
cat <<'EOF'

  reboot -> F11 -> «Linux Boot Manager»
  dmitry / dmitry      root / cachyos      (сменить: passwd)

  рабочий стол:
    curl -fsSLO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/cachyos-niri-setup.sh
    chmod +x cachyos-niri-setup.sh && ./cachyos-niri-setup.sh
EOF
