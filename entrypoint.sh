#!/bin/bash
# Pterodactyl entrypoint for the pnpm image.
#
# Startup order: Git sync -> Node.js -> pnpm -> dependencies -> build -> STARTUP.
# Every step is optional and driven by environment variables (egg variables).
# Steps that depend on the network warn and continue on failure, so a registry
# or Git outage never keeps an already working server from starting.

cd /home/container || exit 1

INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2); exit}')
export INTERNAL_IP

IMAGE_PNPM=/usr/local/bin/pnpm
STARTED_AT=$(date +%s%N)

log() { printf '\033[1;36m[pnpm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pnpm] warning:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[pnpm] error:\033[0m %s\n' "$*"; exit 1; }
is_true() { case "${1,,}" in 1 | true | yes | on) return 0 ;; esac; return 1; }
is_exact_version() { [[ $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Runs the image's pnpm outside the project, so a "packageManager" field in
# the project's package.json cannot redirect the management commands.
pnpm_manage() {
    (cd "$PNPM_HOME" && pnpm_config_manage_package_manager_versions=false exec "$IMAGE_PNPM" "$@")
}

# Runs a command quietly and only shows its output when it fails.
quiet() {
    local output
    if ! output=$("$@" 2>&1); then
        printf '%s\n' "$output"
        return 1
    fi
}

# --- Git ----------------------------------------------------------------------

git_clone() {
    local tmp=.pnpm-image-clone
    local args=(--quiet --no-checkout --filter=blob:none)
    [ -n "$GIT_BRANCH" ] && args+=(--branch "$GIT_BRANCH")

    log "Git: cloning ${GIT_REPO}${GIT_BRANCH:+ (branch ${GIT_BRANCH})}"
    rm -rf "$tmp"
    if ! git clone "${args[@]}" -- "$GIT_REPO" "$tmp"; then
        rm -rf "$tmp"
        warn "Git: clone failed, check the repository URL, branch and credentials"
        return 1
    fi

    # Cloning next to the existing files and moving .git in works in a
    # non-empty directory; reset then writes the tracked files.
    mv "$tmp/.git" .git && rm -rf "$tmp"
    git reset --quiet --hard HEAD || { warn "Git: checkout failed"; return 1; }
    git_submodules
    log "Git: checked out $(git log -1 --format='%h %s')"
}

git_update() {
    local branch before

    git remote set-url origin "$GIT_REPO" 2>/dev/null || git remote add origin "$GIT_REPO"

    branch=${GIT_BRANCH:-$(git symbolic-ref --quiet --short HEAD)}
    if [ -z "$branch" ]; then
        git remote set-head origin --auto >/dev/null 2>&1
        branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)
        branch=${branch#origin/}
    fi
    [ -n "$branch" ] || { warn "Git: cannot determine the branch, set GIT_BRANCH"; return 1; }

    if ! git fetch --quiet --prune origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
        warn "Git: fetching ${branch} failed, keeping the current checkout"
        return 1
    fi

    before=$(git rev-parse --verify --quiet HEAD)
    if [ "$before" = "$(git rev-parse "refs/remotes/origin/${branch}")" ] &&
        [ "$(git symbolic-ref --quiet --short HEAD)" = "$branch" ]; then
        log "Git: ${branch} is up to date ($(git log -1 --format='%h %s'))"
        return 0
    fi

    # The server mirrors the remote branch. Untracked files (.env, configs,
    # node_modules) are kept; edits to tracked files are replaced.
    local dirty
    dirty=$(git status --porcelain --untracked-files=no)
    if [ -n "$dirty" ]; then
        warn "Git: discarding local changes to tracked files:"
        printf '%s\n' "$dirty" | sed 's/^/    /'
    fi

    git checkout --quiet --force -B "$branch" "refs/remotes/origin/${branch}" || { warn "Git: checkout failed"; return 1; }
    git branch --quiet --set-upstream-to="origin/${branch}" >/dev/null 2>&1
    git_submodules
    log "Git: updated ${branch} to $(git log -1 --format='%h %s')"
}

git_submodules() {
    [ -f .gitmodules ] || return 0
    git submodule --quiet sync --recursive
    git submodule --quiet update --init --recursive --force || warn "Git: submodule update failed"
}

git_sync() {
    [ -n "$GIT_REPO" ] || return 0

    # A container killed mid-operation can leave a lock behind; nothing else
    # can be running git at this point.
    rm -f .git/index.lock .git/shallow.lock 2>/dev/null

    if [ ! -e .git ]; then
        git_clone
    elif ! git rev-parse --git-dir >/dev/null 2>&1; then
        warn "Git: .git exists but is not a valid repository, skipping (delete .git to clone again)"
    elif is_true "$AUTO_UPDATE"; then
        git_update
    else
        log "Git: auto update is disabled, keeping the current checkout"
    fi
}

# --- Node.js ------------------------------------------------------------------

# Empty NODE_VERSION uses the Node.js LTS bundled with the image. Anything else
# (22, 20.18.1, lts, latest, ...) is installed by pnpm into $PNPM_HOME, which is
# on the server volume, so each version is downloaded only once.
setup_node() {
    local managed="$PNPM_HOME/bin/node" version=${NODE_VERSION#v}

    # Asking for exactly the bundled version needs no download.
    [ "v${version}" = "$(/usr/local/bin/node -v)" ] && version=

    if [ -z "$version" ]; then
        if [ -e "$managed" ]; then
            log "Node.js: switching back to the bundled version"
            quiet pnpm_manage remove --global node || rm -f "$managed"
        fi
        return 0
    fi

    if is_exact_version "$version" && [ -x "$managed" ] && [ "$("$managed" -v 2>/dev/null)" = "v${version}" ]; then
        return 0
    fi

    if ! quiet pnpm_manage runtime set node "$version" --global; then
        if [ -x "$managed" ]; then
            warn "Node.js: could not install ${version}, keeping $("$managed" -v)"
        else
            warn "Node.js: could not install ${version}, using the bundled version"
        fi
    fi
}

# --- pnpm ---------------------------------------------------------------------

# Empty PNPM_VERSION uses the pnpm bundled with the image, which in turn honours
# the project's "packageManager" field. A set PNPM_VERSION takes precedence over
# both and is installed into $PNPM_HOME.
setup_pnpm() {
    local managed="$PNPM_HOME/bin/pnpm" version=${PNPM_VERSION#v} current

    if [ -z "$version" ]; then
        if [ -e "$managed" ]; then
            log "pnpm: switching back to the bundled version"
            quiet pnpm_manage remove --global @pnpm/exe pnpm ||
                rm -f "$managed" "$PNPM_HOME/bin/pnpx" "$PNPM_HOME/bin/pn" "$PNPM_HOME/bin/pnx"
        fi
        return 0
    fi

    export pnpm_config_manage_package_manager_versions=false
    if is_exact_version "$version" && [ -x "$managed" ]; then
        current=$(cd "$PNPM_HOME" && "$managed" --version 2>/dev/null)
        [ "$current" = "$version" ] && return 0
    fi

    quiet pnpm_manage self-update "$version" || warn "pnpm: could not install ${version}, keeping $(pnpm --version)"
}

# --- Dependencies and build ---------------------------------------------------

install_dependencies() {
    [ -f package.json ] || return 0
    is_true "${INSTALL_DEPS:-1}" || return 0

    is_true "$ALLOW_BUILD_SCRIPTS" && export pnpm_config_dangerously_allow_all_builds=true

    log "Dependencies: pnpm install ${INSTALL_FLAGS}"
    # shellcheck disable=SC2086 # INSTALL_FLAGS is a list of flags
    if ! pnpm install --prefer-offline ${INSTALL_FLAGS} </dev/null; then
        warn "Dependencies: pnpm install failed, starting with the existing node_modules"
        warn "Dependencies: if build scripts were blocked, approve them in pnpm-workspace.yaml (allowBuilds) or enable ALLOW_BUILD_SCRIPTS"
    fi
}

run_build() {
    [ -n "$BUILD_SCRIPT" ] && [ -f package.json ] || return 0
    log "Build: pnpm run ${BUILD_SCRIPT}"
    pnpm run "$BUILD_SCRIPT" </dev/null || fail "Build: '${BUILD_SCRIPT}' failed"
}

# --- Main ---------------------------------------------------------------------

mkdir -p "$PNPM_HOME"

# Wings mounts /tmp as a small tmpfs (100 MB by default), too small for
# downloads such as browsers or large tarballs. Temporary files go to the
# volume instead and are cleared on every start.
if [ -z "$TMPDIR" ]; then
    export TMPDIR=/home/container/.cache/tmp
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR"
fi

git_sync
setup_node
setup_pnpm
install_dependencies
run_build

log "Node.js $(node -v), pnpm $(pnpm --version 2>/dev/null </dev/null), ready in $((($(date +%s%N) - STARTED_AT) / 1000000)) ms"

# Pterodactyl passes the startup command with {{VARIABLE}} placeholders.
STARTUP_COMMAND=$(printf '%s' "${STARTUP:-pnpm start}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
printf ':/home/container$ %s\n' "$STARTUP_COMMAND"

exec /bin/bash -c "$STARTUP_COMMAND"
