#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  zsh с подсказками как в fish: автоподсказки из истории + подсветка синтаксиса.
#  Запуск:  curl -sL d1mms.ru/z|sudo bash
#  Скрипты (bash script.sh) продолжают работать: меняется только интерактивная оболочка.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m  !!\033[0m %s\n' "$*"; }
err() { printf '\033[31m  !! %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

U="${SUDO_USER:-}"
if [[ -z "$U" || "$U" == "root" ]]; then
    U=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
fi
H=$(getent passwd "$U" | cut -d: -f6)
[[ -d "$H" ]] || { err "нет домашней папки для $U"; exit 1; }

say "1/4 пакеты"
pacman -S --needed --noconfirm zsh zsh-autosuggestions zsh-syntax-highlighting \
    || { err "пакеты не встали"; exit 1; }
ok "zsh и плагины установлены"

say "2/4 конфиг"
AUTO=/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
SYN=/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[[ -r "$AUTO" ]] || warn "не нашёл $AUTO"
[[ -r "$SYN"  ]] || warn "не нашёл $SYN"

ZSHRC="$H/.zshrc"
if [[ -f "$ZSHRC" ]] && grep -q 'hermes-zsh' "$ZSHRC"; then
    ok "$ZSHRC уже настроен"
else
    [[ -f "$ZSHRC" ]] && cp -a "$ZSHRC" "$ZSHRC.bak.$(date +%Y%m%d-%H%M%S)"
    cat >> "$ZSHRC" <<EOF
# hermes-zsh: подсказки как в fish
HISTFILE=~/.zsh_history
HISTSIZE=20000
SAVEHIST=20000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_VERIFY
autoload -Uz compinit && compinit -u

[[ -r $AUTO ]] && source $AUTO
[[ -r $SYN  ]] && source $SYN

# Ctrl+Space — принять подсказку, стрелки вправо — посимвольно
bindkey '^ ' autosuggest-accept
bindkey '^[[C' forward-char

# немного удобств
bindkey '^R' history-incremental-search-backward
alias ls='ls --color=auto'
alias ll='ls -lah'
EOF
    ok "добавлено в $ZSHRC"
fi
chown "$U:$U" "$ZSHRC"

# если настроен автозапуск niri из .bash_profile — то же нужно в .zprofile,
# иначе после смены оболочки сессия перестанет подниматься сама
ZPROFILE="$H/.zprofile"
if grep -q 'hermes-autostart' "$H/.bash_profile" 2>/dev/null; then
    if grep -q 'hermes-autostart' "$ZPROFILE" 2>/dev/null; then
        ok "автозапуск niri уже есть в .zprofile"
    else
        cat >> "$ZPROFILE" <<'EOF'

# hermes-autostart: niri на первой консоли
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$NIRI_SOCKET" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec niri-session  # hermes-autostart
fi
EOF
        ok "автозапуск niri продублирован в .zprofile"
    fi
    chown "$U:$U" "$ZPROFILE"
fi

say "3/4 оболочка по умолчанию"
ZSH_BIN=$(command -v zsh)
usermod -s "$ZSH_BIN" "$U" && ok "для $U назначен $ZSH_BIN" || err "usermod не сработал"

say "4/4 проверка"
printf '  zsh:        %s\n' "$("$ZSH_BIN" --version)"
printf '  плагины:    %s\n' "$(pacman -Qq zsh-autosuggestions zsh-syntax-highlighting 2>/dev/null | tr '\n' ' ')"
printf '  оболочка:   %s\n' "$(getent passwd "$U" | cut -d: -f7)"

cat <<EOF

Готово. Перезайди (или открой новое окно терминала) — подсказки появятся:
  · серый текст справа — история, Enter принимает
  · Ctrl+Space — принять подсказку целиком
  · цветная проверка команды до запуска

Вернуть bash:  chsh -s /bin/bash $U
Прежний .zshrc сохранён как $H/.zshrc.bak.<дата>
EOF
