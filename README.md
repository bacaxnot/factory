# the factory

A multi-account Claude Code box on Ubuntu 24.04. One shared user runs Claude Code inside tmux; [claude-swap](https://pypi.org/project/claude-swap/) rotates between several Claude accounts before any of them hits a usage limit; a health check pushes alerts through [ntfy](https://ntfy.sh); a weekly job keeps the box updated. The box is reachable over Tailscale only.

## What is on the box

| Piece | Where | Role |
| --- | --- | --- |
| `factory` | `/usr/local/bin/factory` | The command line: status, account rotation, updates |
| `factory-alerts` | `/usr/local/bin/factory-alerts` | Health check, run every 5 minutes by `factory-alerts.timer` |
| `cswap-status` | `/usr/local/bin/cswap-status` | One-line account usage for the tmux status bar |
| `cswap-auto.service` | systemd | `cswap auto`, the account rotation, as the shared user |
| `factory-alerts.timer` | systemd | Runs the health check every 5 minutes |
| `factory-update.timer` | systemd | Runs `factory update` every Sunday at 04:00 local time |
| `/etc/factory/factory.env` | settings | ntfy topic, shared user, repo path, timezone |
| `/var/lib/factory/` | state | Rotation mode, alert state, last known Fable usage per account |

The shared user (default `factory`) has passwordless sudo, Docker access, and these tools in its home: bun, Claude Code (native install), uv, claude-swap (`uv tool`), plus node 22, Docker, tmux, git, jq, and unzip system-wide. Its Claude settings select the Fable model and bypass permission prompts. Its work lives under `~/work`.

## Install on a fresh Ubuntu 24.04 box

As a user with sudo on the box:

```bash
sudo apt-get install -y git
sudo mkdir -p /home/factory/work
sudo git clone https://github.com/bacaxnot/factory /home/factory/work/factory
cd /home/factory/work/factory
sudo ./install.sh
```

The installer creates the shared user, installs every tool and package, copies the scripts, units, tmux config and Claude settings into place, and enables the services. It creates `/etc/factory/factory.env` from `etc/factory.env.example` when it is missing, records the repo path there, and generates an ntfy topic when the file has none. The generated topic is printed once; subscribe to it in the ntfy app.

Running the installer again is safe. That is how changes to the repo reach the box.

Two things stay manual, and the installer prints them:

1. **Tailscale.** Run `sudo tailscale up` and open the URL it prints. Until Tailscale is up the firewall keeps SSH open on every interface; the next `sudo ./install.sh` (or `factory update`) closes it, leaving incoming traffic allowed on `tailscale0` only.
2. **Accounts.** Log each Claude account in, then hand it to claude-swap:

   ```bash
   sudo -iu factory
   claude auth login      # prints a URL to open, then asks for the code
   cswap add
   ```

   Repeat for every account. `factory claude account list` shows them.

A repo path other than `/home/factory/work/factory` works the same way; the installer records wherever it runs from. A user other than `factory` comes from `FACTORY_USER` in `/etc/factory/factory.env`; set it before the first run, and clone the repo under that user's home.

## Shell

The shared user's login shell is zsh with oh-my-zsh, the robbyrussell theme, and the git, zsh-autosuggestions and zsh-syntax-highlighting plugins, from `home/zshrc`. The installer owns that file; personal additions go in `~/.zshrc.local`, which it sources. Bash stays installed for scripts.

## Browsers

The installer sets `AGENT_BROWSER_ARGS="--no-sandbox"` for the shared user, which a headless Chromium needs on a VM. The browsers themselves are installed per project: `npm install -g agent-browser` for an agent-driven browser, and `bunx playwright install --with-deps chromium` in a checkout whose tests use Playwright.

## Day to day

Connect over Tailscale, attach to tmux, and work as the shared user:

```bash
ssh factory@<tailscale name>
tmux new -A -s <your name>
claude
```

Each person keeps a tmux session of their own, since two clients on one session see the same windows. The shared session `admin` holds what everyone should be able to watch: long-running loops, scheduled runs, anything a second person may need to inspect. The tmux status bar shows the active account with its 5-hour and Fable usage. Every session on the box shares the active account; claude-swap moves all of them together.

### From your own machine

An SSH host entry and one shell function make the box a single word. In `~/.ssh/config`:

```
Host the-factory
  HostName <tailscale address>
  User factory
  IdentityFile ~/.ssh/<your key>
  IdentitiesOnly yes
```

In `~/.zshrc` or `~/.bashrc`:

```bash
# the factory: no arguments attaches to your own tmux session, named after your user; `factory tmux admin`
# attaches to a shared one; `factory paste [file]` puts an image on the box and its path on your clipboard;
# `factory tunnel [port]` forwards a dev server on the box to localhost; anything else runs as a factory command there
factory() {
  case "${1:-}" in
    "") ssh -t the-factory "tmux new -A -s ${FACTORY_SESSION:-$USER}" ;;
    tmux) ssh -t the-factory "tmux new -A -s ${2:?session name}" ;;
    tunnel) local port="${2:-3000}"; echo "http://localhost:$port -> the factory, Ctrl-C to stop"; ssh -N -L "${port}:localhost:${port}" the-factory ;;
    paste)
      local file="${2:-}" name remote
      name="$(date +%Y%m%d-%H%M%S)"
      if [ -n "$file" ]; then
        [ -f "$file" ] || { echo "no such file: $file" >&2; return 1; }
        name="$name-$(basename "$file")"
      else
        file="$(mktemp -t factory-paste).png"
        pngpaste "$file" 2>/dev/null || { rm -f "$file"; echo "no image on the clipboard (needs pngpaste: brew install pngpaste)" >&2; return 1; }
        name="$name.png"
      fi
      remote=$(ssh the-factory "mkdir -p paste && cat > paste/$name && echo \$HOME/paste/$name" < "$file") || return 1
      [ -n "${2:-}" ] || rm -f "$file"
      printf '%s' "$remote" | pbcopy
      echo "$remote (on your clipboard: Cmd-V it into the session)" ;;
    *) ssh -t the-factory factory "$@" ;;
  esac
}
```

Then `factory` attaches to your own tmux session, named after your user on your machine (set `FACTORY_SESSION` to pick another name), `factory tmux admin` attaches to the shared `admin` session where long-running loops live, `factory status` or `factory claude account list` runs on the box, and `Ctrl-b d` detaches with everything still running. Two people attached to one session see the same windows, so each person keeps a session of their own and shares only `admin`. `factory tunnel` forwards port 3000 so a dev server running on the box opens at `http://localhost:3000` in your browser, with its own `APP_URL` still correct; `factory tunnel 3991` does the same for a worktree's port. Windows ships OpenSSH, so the same host entry works from PowerShell; the function is for bash and zsh.

Claude Code reads the clipboard of the machine it runs on, so an image on your clipboard cannot be pasted into a session directly. `factory paste` copies it to `~/paste/` on the box and puts the file's path on your clipboard; `Cmd-V` in the session pastes the path and Claude reads the image from it. `factory paste shot.png` does the same for a file. The clipboard form needs `pngpaste` (`brew install pngpaste`). The weekly update deletes pastes older than two weeks.

```bash
factory status                         # mode, active account, services, sessions, tailscale address
factory claude account list            # every account with its 5h, weekly and Fable usage
factory claude account switch          # rotate to the account with the most headroom
factory claude account switch 2        # make account 2 active
factory claude account login 2         # re-login account 2 after its token expired
factory claude mode                    # show the rotation mode
factory claude mode any                # rotate on the 5h and weekly windows only
factory claude mode fable              # also rotate on the Fable window; skip accounts whose Fable is spent
factory tmux admin                     # attach to the shared session
factory paste                          # clipboard image -> the box, its path on your clipboard
factory paste shot.png                 # the same for a file
factory tunnel 3000                    # http://localhost:3000 -> the box
factory update                         # run the weekly update now
factory --help
```

### Rotation modes

`cswap auto` watches the active account and switches when a usage window passes 90 percent.

- `fable` (default): the 5-hour, weekly, and Fable weekly windows all count, and rotation never lands on an account whose Fable usage is spent.
- `any`: only the 5-hour and weekly windows count. Use it when working with other models.

A forced `switch <N>` holds until the rotation decides otherwise. In `fable` mode, landing on an account with Fable at 100 percent is undone within a minute; set `mode any` first if that is what you want.

## Alerts

`factory-alerts` runs every 5 minutes and pushes to `https://ntfy.sh/<NTFY_TOPIC>` when:

- `cswap-auto` is down,
- an account's login is broken (its usage status is neither `ok` nor `unavailable`),
- every account is out of Fable usage and the mode is `fable`; the note carries the earliest reset.

A new problem is pushed at once; an unchanged one is repeated every six hours; "all clear" is pushed when the problems are gone. A usage figure that is temporarily unreadable is not an alert; the last known figure stands in for it.

## Update

`factory update` runs every Sunday at 04:00 local time (`factory-update.timer`, `Persistent=true`, so a missed run happens at the next boot). It can also be run by hand at any time. It:

1. pulls the repo checkout named by `FACTORY_REPO`,
2. re-runs `install.sh`,
3. runs `claude update` and `cswap upgrade` as the shared user,
4. verifies that `cswap list --json` reads usage for every account,
5. runs `bun run worktrees:sweep` in every directory under `~/work` whose `package.json` has that script,
6. pushes a note with the Claude Code and claude-swap versions before and after, the account check, and the disk used under `~/work`.

The command exits non-zero when any step fails, and the note lists the failures.

Updating the box by hand comes down to committing to this repo and running `factory update`.

## Settings

`/etc/factory/factory.env`, readable by root and the shared user:

```
NTFY_TOPIC=            # ntfy topic for alerts and update notes; generated when empty
FACTORY_USER=factory   # the shared user
FACTORY_REPO=...       # the checkout `factory update` pulls; recorded by the installer
FACTORY_TIMEZONE=      # for example Europe/Madrid; empty leaves the timezone alone
```

A box that still has the older `/etc/factory/alerts.env` keeps working: the installer seeds `NTFY_TOPIC` from it, and the alerts script reads both files. The old file can be deleted once `factory.env` exists.

## Uninstall

There is no uninstall script. To take the factory off a box:

```bash
sudo systemctl disable --now cswap-auto.service factory-alerts.timer factory-update.timer
sudo rm -f /etc/systemd/system/{cswap-auto,factory-alerts,factory-update}.{service,timer}
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/{factory,factory-alerts,cswap-status}
sudo rm -rf /etc/factory /var/lib/factory
sudo rm -f /etc/sudoers.d/factory
```

The shared user, its home (with the Claude credentials under `~/.claude` and claude-swap's data under `~/.local/share/claude-swap`), and the system packages (Docker, node, Tailscale, ufw) stay; remove them separately if the box is being repurposed. `sudo tailscale logout` detaches the box from the tailnet.

## License

MIT, see `LICENSE`.
