# CachyOS → niri + Noctalia

Два скрипта для чистой установки рабочего стола на CachyOS/Arch: композитор niri,
оболочка Noctalia, файловый менеджер, медиа-набор, драйвер NVIDIA и готовый конфиг.
Плюс помощник для переноса данных на чистую переустановку.

Без дисплей-менеджера: вход через TTY и `niri-session`.

## Скрипты

| Файл | Что делает |
|---|---|
| `cachyos-niri-setup.sh` | ставит систему: niri, Noctalia, пакеты, темы, NVIDIA, конфиг |
| `install-console.sh` | ставит саму систему с консоли, когда графический установщик не работает |
| `cachyos-migrate.sh backup` | сохраняет ключи Secure Boot, список пакетов и данные на флешку |
| `cachyos-migrate.sh restore` | возвращает ключи после переустановки и подписывает загрузчик |

## Требования

- Arch-подобный дистрибутив с pacman: Arch, CachyOS, EndeavourOS, Manjaro, Garuda, Artix
- systemd
- интернет и минимум 4 ГБ свободного места на `/`
- запуск от обычного пользователя (скрипт сам вызывает `sudo`)

На Debian/Ubuntu/Fedora не заработает: `niri` и `noctalia` есть только в репозиториях Arch.

## Установка

```bash
chmod +x cachyos-niri-setup.sh
./cachyos-niri-setup.sh --dry-run    # посмотреть план
./cachyos-niri-setup.sh              # поставить
```

Флаги:

```
--dry-run        только показать команды
--no-nvidia      не трогать драйвер NVIDIA
--autologin      автовход на tty1 и запуск niri
--no-aur         не ставить zen-browser (единственный AUR-пакет)
--rice           скачать обои из Noctara-Dots
--config-only    только конфиги, без установки пакетов
--yes            без вопросов
```

Всё пишется в `~/niri-setup-<дата>.log`. Старый конфиг niri сохраняется рядом как
`config.kdl.bak.<дата>`.

## Установка системы с консоли (если Calamares зависает)

Графический установщик CachyOS иногда висит на «Ожидание модуля» или падает на
`chwd` / `fatlabel`. Тогда систему можно поставить без него, из той же live-сессии:

```bash
curl -fsSLO https://raw.githubusercontent.com/TheWeeeen/cachyos-niri-setup/master/install-console.sh
sudo bash install-console.sh
```

Скрипт спросит корневой раздел (например `/dev/sda5`) и раздел `/boot`
(например `/dev/sda6`), покажет таблицу разделов, потребует ввести `FORMAT`
и дальше сделает всё сам: btrfs + FAT32, `pacstrap`, `chroot`, локаль, время,
пользователь, `systemd-boot` с записью в меню.

Флаги:

```
--root /dev/sdX   корневой раздел
--esp  /dev/sdX   раздел /boot
--user имя        имя пользователя
--hostname имя    имя машины
--dry-run         только показать команды
--yes             без подтверждения FORMAT (осторожно)
```

Разделы с NTFS скрипт форматировать откажется. После установки — `reboot`, в F11
пункт «Linux Boot Manager», вход и уже потом `cachyos-niri-setup.sh`.

## Что ставится

- **Композитор и оболочка:** `niri`, `noctalia`, `xwayland-satellite`, порталы, polkit
- **Звук, сеть, bluetooth:** PipeWire + WirePlumber, `pavucontrol`, NetworkManager, BlueZ, `blueman`, `udiskie`
- **Файлы:** `dolphin`, `ark`, `unrar`, `kio-extras`, превью видео, `7zip`, `zathura`
- **Работа:** `ffmpeg`, `kdenlive`, `obs-studio`, `gimp`, `audacity`, `mpv`, `neovim`, `opencode`
- **Браузеры:** `firefox`, `chromium`, `zen-browser-bin` (AUR)
- **Мелочи:** `obsidian`, `gnome-keyring`, `telegram-desktop`, шрифты Noto + Nerd, kv-тема Qt (Fusion + Breeze Dark)

## Горячие клавиши после установки

```
Mod+Return — терминал        Mod+E — файлы (Dolphin)     Mod+W — Firefox
Mod+B — Zen                  Mod+Space — лаунчер          Mod+S — центр управления
Mod+O — обзор                Mod+V — плавающее окно      Mod+U/I — рабочие столы
Mod+Comma — стопка колонки   Mod+Period — вынуть         Mod+Shift+←/→ — ровно пополам
Alt+Tab — окна с превью      Alt+grave — внутри приложения
Alt+Shift — раскладка        Mod+Shift+E — выход
```

## Перенос на чистую переустановку

```bash
# до переустановки
./cachyos-migrate.sh backup

# после (флешка с бэкапом подключена)
./cachyos-migrate.sh restore
```

Флешка ищется по метке (по умолчанию `Adata Flash`), можно указать вручную:

```bash
USB=/run/media/user/FLASH ./cachyos-migrate.sh backup
USB_LABEL=Ventoy ./cachyos-migrate.sh backup
```

`backup` сохраняет: `/var/lib/sbctl` (ключи Secure Boot), списки пакетов, архив
`~/.ssh ~/.config ~/Documents ~/Pictures ~/Projects`, манифест с разметкой дисков и sha256.

`restore` возвращает ключи, подписывает загрузчик (`sbctl sign-all`) и распаковывает
данные по выбору. Старые файлы не удаляются, а переименовываются в `.bak.<дата>`.

## Важно про Secure Boot

Если Secure Boot включён и подписи сделаны своими ключами (`sbctl`), при переустановке
ключи теряются вместе с разделом. Тогда: выключить Secure Boot в BIOS → установить систему
→ `restore` → включить Secure Boot обратно.

Первый запуск свежей системы ключей не требует — он работает с выключенным Secure Boot.

## Что скрипт не делает

Не создаёт пользователя, не настраивает Steam, не вводит пароли Wi-Fi и не логинит
в аккаунты. После установки остаётся: `nmtui` для сети, `opencode auth login`,
выбор обоев (`noctalia msg wallpaper-next`).

## Проверка

Скрипты проверены `bash -n`, `shellcheck` и прогоном в песочнице с подменёнными
`pacman`, `sudo`, `systemctl`, `paru`, `git` и настоящим KDL-парсером вместо `niri`.
Проверены сценарии: чистая установка, повторный запуск, `--dry-run`, `--config-only`,
`--no-aur`, отсутствие пакета, отсутствие niri, ошибка 404 от зеркала (повтор с `-Syy`).

## Лицензия

MIT
