#!/bin/bash
# Set up a fresh machine from Dick's dotfiles repo (private:
# github.com/richardtkemp/dotfiles-ansible). Run it with:
#
#   curl -fsSL https://raw.githubusercontent.com/richardtkemp/cfg_public/main/dotfiles-bootstrap.sh | bash
#
# What it does, skipping any step that is already done:
#   1. macOS: install the Xcode Command Line Tools (git, make).
#   2. Fetch the GitHub CLI (gh) as a plain binary from GitHub's public releases,
#      checksum-verified, into ~/.local/share/dotfiles-bootstrap/bin (no Homebrew yet).
#   3. gh auth login as the personal account (browser code flow), and let git
#      use that login for HTTPS.
#   4. gh repo clone the dotfiles repo into ~/git/dotfiles.
#   5. Install uv, then run `make local`, which asks personal or work if this
#      machine is new, the secrets passphrase and the login password, and does
#      the rest (see README.md in the dotfiles repo).
#
# This file is public: it holds no secrets, and only ever talks to github.com,
# astral.sh (uv) and Apple's software update.
#
# Overrides: DOTFILES_DIR (default ~/git/dotfiles), DOTFILES_REPO
# (richardtkemp/dotfiles-ansible), GITHUB_USER (richardtkemp).

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/git/dotfiles}"
DOTFILES_REPO="${DOTFILES_REPO:-richardtkemp/dotfiles-ansible}"
GITHUB_USER="${GITHUB_USER:-richardtkemp}"
BOOTSTRAP_BIN="$HOME/.local/share/dotfiles-bootstrap/bin"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

install_clt() {
  # macOS ships git/make as stubs until the Command Line Tools are installed.
  if xcode-select -p >/dev/null 2>&1 && [ -x "$(xcode-select -p)/usr/bin/git" ]; then
    return
  fi
  say "Installing the Xcode Command Line Tools (asks for your Mac password)"
  # Headless, the way Homebrew's installer does it: this marker file makes
  # softwareupdate list the CLT package.
  local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
  sudo touch "$marker"
  label=$(softwareupdate -l 2>/dev/null |
    grep -B 1 -E 'Command Line Tools' |
    awk -F'*' '/^ *\*/ {print $2}' |
    sed -e 's/^ *Label: //' -e 's/^ *//' |
    sort -V | tail -n1)
  if [ -n "$label" ]; then
    sudo softwareupdate -i "$label" || true
  fi
  sudo rm -f "$marker"
  if ! xcode-select -p >/dev/null 2>&1; then
    # Fallback: Apple's dialog. Click Install, then this waits for it.
    xcode-select --install || true
    say "Waiting for the Command Line Tools install to finish (click Install in the dialog)"
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  fi
}

install_linux_basics() {
  local missing=()
  for tool in git make curl; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  [ ${#missing[@]} -eq 0 ] && return
  command -v apt-get >/dev/null 2>&1 || die "install ${missing[*]} first"
  say "Installing ${missing[*]} (asks for your password)"
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    return
  fi
  local os arch asset version tag tmp
  case "$(uname -s)" in
    Darwin) os=macOS ;;
    Linux) os=linux ;;
    *) die "unsupported OS $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    *) die "unsupported CPU $(uname -m)" ;;
  esac
  # The latest release, from the redirect of /releases/latest (no API rate limit).
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)
  tag=${tag##*/}
  version=${tag#v}
  [ -n "$version" ] || die "could not find the latest gh release"
  if [ "$os" = macOS ]; then asset="gh_${version}_${os}_${arch}.zip"; else asset="gh_${version}_${os}_${arch}.tar.gz"; fi
  say "Fetching gh $version ($asset)"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$asset" "https://github.com/cli/cli/releases/download/$tag/$asset"
  curl -fsSL -o "$tmp/checksums.txt" "https://github.com/cli/cli/releases/download/$tag/gh_${version}_checksums.txt"
  local want
  want=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/checksums.txt")
  if [ -z "$want" ] || [ "$want" != "$(sha256 "$tmp/$asset")" ]; then die "checksum mismatch for $asset"; fi
  if [ "$os" = macOS ]; then
    (cd "$tmp" && unzip -q "$asset")
  else
    tar -xzf "$tmp/$asset" -C "$tmp"
  fi
  mkdir -p "$BOOTSTRAP_BIN"
  # Kept, not deleted: `gh auth setup-git` records this path as git's HTTPS
  # credential helper. The dotfiles deploy installs gh properly (Homebrew/apt).
  install -m 0755 "$tmp/gh_${version}_${os}_${arch}/bin/gh" "$BOOTSTRAP_BIN/gh"
  rm -rf "$tmp"
}

gh_login() {
  # A token for the personal account, whichever account (if any) is active.
  if gh auth token --hostname github.com --user "$GITHUB_USER" >/dev/null 2>&1; then
    gh auth switch --hostname github.com --user "$GITHUB_USER" >/dev/null 2>&1 || true
  else
    say "Log in to GitHub as $GITHUB_USER (a browser opens; enter the code shown)"
    # admin:public_key lets the deploy add this machine's ssh key to the account.
    gh auth login --hostname github.com --git-protocol https --web --scopes admin:public_key
  fi
  local login
  login=$(gh api user --jq .login)
  [ "$login" = "$GITHUB_USER" ] ||
    die "gh is logged in as $login, not $GITHUB_USER. Run: gh auth login, choosing the $GITHUB_USER account"
  # Let plain git (the deploy's sync and push) use this login over HTTPS.
  gh auth setup-git --hostname github.com
}

clone_repo() {
  if [ -e "$DOTFILES_DIR/.git" ]; then
    say "$DOTFILES_DIR already exists; using it"
    return
  fi
  [ ! -e "$DOTFILES_DIR" ] || [ -z "$(ls -A "$DOTFILES_DIR")" ] ||
    die "$DOTFILES_DIR exists and is not a git checkout; move it aside first"
  say "Cloning $DOTFILES_REPO into $DOTFILES_DIR"
  mkdir -p "$(dirname "$DOTFILES_DIR")"
  gh repo clone "$DOTFILES_REPO" "$DOTFILES_DIR"
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    return
  fi
  say "Installing uv"
  # Leave shell rc files alone: the deploy manages them, and PATH is set below.
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
}

main() {
  [ -t 0 ] || die "needs a terminal for its prompts"
  [ "$(id -u)" -ne 0 ] || die "run as your own user, not root"
  export PATH="$BOOTSTRAP_BIN:$HOME/.local/bin:$PATH"

  case "$(uname -s)" in
    Darwin) install_clt ;;
    Linux) install_linux_basics ;;
  esac
  install_gh
  gh_login
  clone_repo
  install_uv

  say "Deploying (make local)"
  make -C "$DOTFILES_DIR" local
  say "Done. Open a new terminal to pick up the new shell setup."
}

# Run as `curl ... | bash`, bash reads THIS SCRIPT from stdin, so stdin must not
# be redirected script-wide (an `exec </dev/tty` would make bash read the rest
# of the script from the keyboard). Give only main the terminal, then exit
# before bash reads any further.
if [ -t 0 ]; then
  main "$@"
elif (: </dev/tty) 2>/dev/null; then
  main "$@" </dev/tty
else
  die "needs a terminal for its prompts"
fi
exit
