#!/usr/bin/env bash
# Pomelo client-driver CLI installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/PomeloProductions/deploy/v1/install.sh | sh
#   # or, with options:
#   bash install.sh [--to <dir>] [--ref <git-ref>] [--force]
#
# v1 installs the bash CLI directly from raw.githubusercontent.com. A future
# release will swap the source to GitHub Releases binaries; the install
# entrypoint (this script's URL) stays stable across that change.

set -euo pipefail

REPO="PomeloProductions/deploy"
REF="${POMELO_INSTALL_REF:-main}"
SRC_PATH="cli/pomelo-deploy.sh"
INSTALL_DIR=""
FORCE="false"

log()  { printf '%s\n' "$*" >&2; }
die()  { log "error: $*"; exit 1; }
info() { log "==> $*"; }

usage() {
    cat <<'EOF'
install.sh — install the `pomelo` CLI

OPTIONS
    --to <dir>     Install directory (default: /usr/local/bin, falling back to
                   ~/.local/bin when /usr/local/bin is not writable)
    --ref <ref>    Git ref to install from (branch, tag, or commit). Default: main
    --force        Overwrite an existing `pomelo` binary
    -h, --help     Show this help

ENVIRONMENT
    POMELO_INSTALL_REF   Same as --ref
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)    INSTALL_DIR="${2:?--to requires a value}"; shift 2 ;;
        --ref)   REF="${2:?--ref requires a value}"; shift 2 ;;
        --force) FORCE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

# Pick an install dir we can actually write to.
choose_install_dir() {
    if [[ -n "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        return
    fi

    if [[ -w /usr/local/bin ]]; then
        INSTALL_DIR="/usr/local/bin"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        # Passwordless sudo available — use the system path.
        INSTALL_DIR="/usr/local/bin"
        SUDO="sudo"
    else
        INSTALL_DIR="$HOME/.local/bin"
        mkdir -p "$INSTALL_DIR"
        log "note: installing to $INSTALL_DIR (add it to PATH if it isn't already)"
    fi
}

SUDO=""
choose_install_dir

cli_path="$INSTALL_DIR/pomelo-deploy.sh"
wrapper_path="$INSTALL_DIR/pomelo"

# Safety: refuse to clobber an existing binary unless --force.
if [[ -e "$wrapper_path" || -e "$cli_path" ]] && [[ "$FORCE" != "true" ]]; then
    die "$wrapper_path already exists — re-run with --force to overwrite"
fi

# Sanity-check runtime deps now, not at first run.
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || log "warning: '$cmd' not on PATH; pomelo will fail until it's installed"
done

src_url="https://raw.githubusercontent.com/$REPO/$REF/$SRC_PATH"
sums_url="https://raw.githubusercontent.com/$REPO/$REF/cli/pomelo-deploy.sh.sha256"

tmp_cli="$(mktemp -t pomelo-deploy.XXXXXX)"
trap 'rm -f "$tmp_cli" "$tmp_cli.sums" "$tmp_cli.wrapper"' EXIT

info "downloading $src_url"
curl -fsSL --output "$tmp_cli" "$src_url"

# Optional checksum verification: if a sidecar .sha256 file exists in the repo
# we verify against it. Missing file is non-fatal so install works on refs that
# don't ship checksums yet.
if curl -fsSL --output "$tmp_cli.sums" "$sums_url" 2>/dev/null; then
    info "verifying sha256"
    expected="$(awk 'NR==1 {print $1}' "$tmp_cli.sums")"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$tmp_cli" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$tmp_cli" | awk '{print $1}')"
    fi
    [[ "$expected" == "$actual" ]] || die "checksum mismatch (expected $expected, got $actual)"
fi

chmod +x "$tmp_cli"

# Build the `pomelo` wrapper script. Keeping it as a thin wrapper means the
# `pomelo deploy …` invocation in CI examples stays stable when the bash CLI
# is eventually replaced by a Go binary.
cat > "$tmp_cli.wrapper" <<EOF
#!/usr/bin/env bash
exec "$cli_path" "\$@"
EOF
chmod +x "$tmp_cli.wrapper"

info "installing to $INSTALL_DIR"
${SUDO:+$SUDO} install -m 0755 "$tmp_cli"        "$cli_path"
${SUDO:+$SUDO} install -m 0755 "$tmp_cli.wrapper" "$wrapper_path"

info "installed: $wrapper_path"
"$wrapper_path" --version || true
