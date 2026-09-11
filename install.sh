#!/usr/bin/env bash
# Installs the factory on an Ubuntu 24.04 box. Run as root from the repo checkout:
#   sudo ./install.sh
# Every step is safe to repeat; re-running is how updates apply. The installer does not
# log accounts in and does not run `tailscale up`; it prints what remains manual at the end.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/etc/factory/factory.env
STATE_DIR=/var/lib/factory

[ "$(id -u)" = 0 ] || { echo "install.sh: run as root (sudo ./install.sh)" >&2; exit 1; }

log() { echo "install: $*"; }

# --- settings -------------------------------------------------------------------------

load_settings() {
  install -d -m 755 /etc/factory
  if [ ! -f "$ENV_FILE" ]; then
    log "creating $ENV_FILE from etc/factory.env.example"
    sed "s|^FACTORY_REPO=.*|FACTORY_REPO=$REPO_DIR|" "$REPO_DIR/etc/factory.env.example" > "$ENV_FILE"
    # a box with the older alerts.env keeps its topic
    if [ -f /etc/factory/alerts.env ]; then
      # shellcheck disable=SC1091
      source /etc/factory/alerts.env
      sed -i "s|^NTFY_TOPIC=.*|NTFY_TOPIC=${NTFY_TOPIC:-}|" "$ENV_FILE"
    fi
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  FACTORY_USER="${FACTORY_USER:-factory}"
  FACTORY_HOME="/home/$FACTORY_USER"
  FACTORY_REPO="${FACTORY_REPO:-$REPO_DIR}"
  FACTORY_TIMEZONE="${FACTORY_TIMEZONE:-}"
  if [ -z "${NTFY_TOPIC:-}" ]; then
    NTFY_TOPIC="factory-$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i "s|^NTFY_TOPIC=.*|NTFY_TOPIC=$NTFY_TOPIC|" "$ENV_FILE"
    GENERATED_TOPIC="$NTFY_TOPIC"
  fi
  grep -q '^FACTORY_REPO=' "$ENV_FILE" || echo "FACTORY_REPO=$FACTORY_REPO" >> "$ENV_FILE"
  USER_PATH="$FACTORY_HOME/.npm-global/bin:$FACTORY_HOME/.local/bin:$FACTORY_HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# --- the shared user ------------------------------------------------------------------

create_user() {
  if ! id "$FACTORY_USER" >/dev/null 2>&1; then
    log "creating user $FACTORY_USER"
    useradd --create-home --shell /bin/bash "$FACTORY_USER"
  fi
  usermod -aG sudo "$FACTORY_USER"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$FACTORY_USER" > "/etc/sudoers.d/$FACTORY_USER"
  chmod 440 "/etc/sudoers.d/$FACTORY_USER"
  # the env file holds the ntfy topic; readable by root and the shared user only
  chown "root:$FACTORY_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  install -d -m 755 "$STATE_DIR"
  [ -s "$STATE_DIR/mode" ] || echo fable > "$STATE_DIR/mode"
}

as_user() { sudo -u "$FACTORY_USER" HOME="$FACTORY_HOME" PATH="$USER_PATH" "$@"; }

# --- system packages ------------------------------------------------------------------

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "apt packages"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates git jq unzip tmux zsh ufw unattended-upgrades >/dev/null

  if ! command -v node >/dev/null 2>&1 || [ "$(node --version | cut -d. -f1)" != "v22" ]; then
    log "node 22 from nodesource"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
    apt-get install -y -qq nodejs >/dev/null
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "docker from get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  usermod -aG docker "$FACTORY_USER"

  if ! command -v tailscale >/dev/null 2>&1; then
    log "tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
}

configure_system() {
  if [ -n "$FACTORY_TIMEZONE" ]; then
    timedatectl set-timezone "$FACTORY_TIMEZONE"
  fi

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Incoming traffic is accepted on the Tailscale interface only. Until Tailscale is up,
  # SSH stays open on every interface so the installer cannot lock the box.
  log "ufw"
  ufw --force default deny incoming >/dev/null
  ufw --force default allow outgoing >/dev/null
  ufw allow in on tailscale0 >/dev/null
  if tailscale ip -4 >/dev/null 2>&1; then
    ufw status | grep -q '^OpenSSH' && ufw --force delete allow OpenSSH >/dev/null
  else
    ufw allow OpenSSH >/dev/null
  fi
  ufw --force enable >/dev/null
}

# --- tools for the shared user --------------------------------------------------------

install_user_tools() {
  install -d -o "$FACTORY_USER" -g "$FACTORY_USER" "$FACTORY_HOME/.npm-global/bin" "$FACTORY_HOME/.local/bin" "$FACTORY_HOME/.claude" "$FACTORY_HOME/work"

  if [ ! -x "$FACTORY_HOME/.bun/bin/bun" ]; then
    log "bun"
    as_user bash -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null
  fi
  if [ ! -x "$FACTORY_HOME/.local/bin/claude" ]; then
    log "Claude Code"
    as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null
  fi
  if [ ! -x "$FACTORY_HOME/.local/bin/uv" ]; then
    log "uv"
    as_user bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null
  fi
  if [ ! -x "$FACTORY_HOME/.local/bin/cswap" ]; then
    log "claude-swap"
    as_user "$FACTORY_HOME/.local/bin/uv" tool install claude-swap >/dev/null
  fi

  # the rotation's model axis follows the mode file; `factory claude mode` changes both
  if [ "$(cat "$STATE_DIR/mode")" = any ]; then
    as_user "$FACTORY_HOME/.local/bin/cswap" config unset autoswitch.model >/dev/null 2>&1 || true
  else
    as_user "$FACTORY_HOME/.local/bin/cswap" config set autoswitch.model Fable >/dev/null
  fi

  local path_line='export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"'
  # a headless Chromium on a VM needs the sandbox off; agent-browser reads its launch flags here
  local browser_line='export AGENT_BROWSER_ARGS="--no-sandbox"'
  local rc line
  for rc in "$FACTORY_HOME/.profile" "$FACTORY_HOME/.bashrc"; do
    touch "$rc"
    for line in "$path_line" "$browser_line"; do
      grep -qxF "$line" "$rc" || printf '\n%s\n' "$line" >> "$rc"
    done
    chown "$FACTORY_USER:$FACTORY_USER" "$rc"
  done
}

install_shell() {
  log "zsh, oh-my-zsh and its plugins"
  local omz="$FACTORY_HOME/.oh-my-zsh"
  if [ ! -d "$omz" ]; then
    as_user git clone -q --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$omz"
  fi
  local plugin
  for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
    if [ ! -d "$omz/custom/plugins/$plugin" ]; then
      as_user git clone -q --depth 1 "https://github.com/zsh-users/$plugin.git" "$omz/custom/plugins/$plugin"
    fi
  done
  install -o "$FACTORY_USER" -g "$FACTORY_USER" -m 644 "$REPO_DIR/home/zshrc" "$FACTORY_HOME/.zshrc"
  install -o "$FACTORY_USER" -g "$FACTORY_USER" -m 644 "$REPO_DIR/home/zshenv" "$FACTORY_HOME/.zshenv"
  if [ "$(getent passwd "$FACTORY_USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    chsh -s "$(command -v zsh)" "$FACTORY_USER"
  fi
}

install_home_files() {
  log "tmux and Claude settings"
  install -o "$FACTORY_USER" -g "$FACTORY_USER" -m 644 "$REPO_DIR/home/tmux.conf" "$FACTORY_HOME/.tmux.conf"
  install -o "$FACTORY_USER" -g "$FACTORY_USER" -m 644 "$REPO_DIR/home/claude-settings.json" "$FACTORY_HOME/.claude/settings.json"

  # Claude Code skips its first-run questions when onboarding is marked complete
  local state="$FACTORY_HOME/.claude.json" tmp
  [ -s "$state" ] || echo '{}' > "$state"
  tmp=$(mktemp)
  jq '.hasCompletedOnboarding = true' "$state" > "$tmp"
  install -o "$FACTORY_USER" -g "$FACTORY_USER" -m 600 "$tmp" "$state"
  rm -f "$tmp"
}

# --- scripts and services -------------------------------------------------------------

install_scripts() {
  log "scripts to /usr/local/bin"
  install -m 755 "$REPO_DIR/bin/factory" "$REPO_DIR/bin/factory-alerts" "$REPO_DIR/bin/cswap-status" /usr/local/bin/
}

install_services() {
  log "systemd units"
  local unit
  for unit in "$REPO_DIR"/systemd/*; do
    sed -e "s|@USER@|$FACTORY_USER|g" -e "s|@HOME@|$FACTORY_HOME|g" "$unit" > "/etc/systemd/system/$(basename "$unit")"
  done
  systemctl daemon-reload
  systemctl enable --now cswap-auto.service factory-alerts.timer factory-update.timer >/dev/null
  systemctl restart cswap-auto.service
}

# --- what remains manual --------------------------------------------------------------

print_remaining() {
  echo
  echo "The factory is installed for user $FACTORY_USER."
  if [ -n "${GENERATED_TOPIC:-}" ]; then
    echo
    echo "ntfy topic (generated, kept in $ENV_FILE): $GENERATED_TOPIC"
    echo "Subscribe to https://ntfy.sh/$GENERATED_TOPIC to receive alerts."
  fi
  echo
  echo "Left to do by hand:"
  if ! tailscale ip -4 >/dev/null 2>&1; then
    echo "  - tailscale up          (prints a URL to open; SSH stays open on every interface until then)"
  fi
  echo "  - add each Claude account, as $FACTORY_USER:"
  echo "      sudo -iu $FACTORY_USER"
  echo "      claude auth login && cswap add"
  echo "  - run the installer again once Tailscale is up, to close SSH on the public interfaces"
}

main() {
  load_settings
  create_user
  install_packages
  configure_system
  install_user_tools
  install_shell
  install_home_files
  install_scripts
  install_services
  print_remaining
}

main "$@"
