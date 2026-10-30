# shellcheck shell=bash disable=SC2034
# Shared helpers for the Surface Pro X LineageOS scripts.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_DIR

# shellcheck source=../config.env
. "$KIT_DIR/config.env"

# The device tree reads its kernel and firmware from here (git-ignored).
PREBUILT_DIR="$KIT_DIR/prebuilt"
WORK_DIR="$OUT_DIR/work"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
msg2() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmds() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing commands: ${missing[*]}"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this step needs root, run it with sudo"
}

# fetch URL DEST SHA256
fetch_verified() {
    local url="$1" dest="$2" sum="$3"
    if [ ! -f "$dest" ]; then
        msg2 "downloading $(basename "$dest")"
        curl -fL --retry 3 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    echo "$sum  $dest" | sha256sum -c --quiet - || die "checksum mismatch for $dest"
}

# git_fetch_commit REPO_URL DIR COMMIT: shallow checkout of one commit.
git_fetch_commit() {
    local url="$1" dir="$2" commit="$3"
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$dir" fetch -q --depth 1 origin "$commit"
    fi
    git -C "$dir" checkout -q --force --detach "$commit"
    git -C "$dir" clean -q -fdx
}

# Check out the pinned Fedora kit and load its config.env, which pins the
# kernel commit, the base configs and the firmware commit. Its OUT_DIR and
# helper variables are not used; only the pins are.
load_fedora_kit() {
    FEDORA_KIT_DIR="$WORK_DIR/fedora-kit"
    msg "Fetching the Fedora kit (${FEDORA_KIT_COMMIT:0:12})"
    git_fetch_commit "$FEDORA_KIT_REPO" "$FEDORA_KIT_DIR" "$FEDORA_KIT_COMMIT"
    local saved_out="$OUT_DIR"
    # shellcheck disable=SC1091
    . "$FEDORA_KIT_DIR/config.env"
    OUT_DIR="$saved_out"
    [ -n "${KERNEL_COMMIT:-}" ] || die "the Fedora kit's config.env has no KERNEL_COMMIT"
}
