#!/usr/bin/env bash
# End-to-end tests for the image. Containers are run the way Wings runs them:
# UID 988, TTY with open stdin, a 100 MB tmpfs on /tmp and the server volume
# mounted at /home/container.
#
# Usage: tests/run.sh [image]        (default: pterodactyl-pnpm:dev)
# Set SKIP_BROWSERS=1 to skip the Playwright browser downloads.

set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE=${1:-pterodactyl-pnpm:dev}
PREFIX=pnpm-test-$$
PASSED=0
FAILED=0
OUTPUT=

cleanup() {
    docker ps -aq --filter "name=${PREFIX}" | xargs -r docker rm -f >/dev/null
    docker volume ls -q --filter "name=${PREFIX}" | xargs -r docker volume rm >/dev/null
}
trap cleanup EXIT

# Shared volume for the test Git server, writable by the server UID.
docker run --rm --user root -v "${PREFIX}-git:/git" --entrypoint chown "$IMAGE" 988:988 /git

# Removes carriage returns and ANSI escape sequences from TTY output.
clean() { sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { PASSED=$((PASSED + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
failed() {
    FAILED=$((FAILED + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$*"
    printf '%s\n' "$OUTPUT" | sed 's/^/       | /' | tail -40
}

# assert_output <description> <extended regex>
assert_output() { if grep -Eq -- "$2" <<<"$OUTPUT"; then pass "$1"; else failed "$1"; fi; }
refute_output() { if grep -Eq -- "$2" <<<"$OUTPUT"; then failed "$1"; else pass "$1"; fi; }
assert_status() { if [ "$STATUS" = "$2" ]; then pass "$1"; else OUTPUT="exit status ${STATUS}, expected $2"$'\n'"$OUTPUT"; failed "$1"; fi; }

# server <volume> <startup command> [docker run args...]
# Starts the server like Wings does and waits for it to exit.
server() {
    local volume=${PREFIX}-$1 startup=$2
    shift 2
    local id
    id=$(docker run -d -it --user 988:988 --tmpfs /tmp:rw,exec,size=100m \
        --name "${PREFIX}-$(date +%s%N)" \
        -v "${volume}:/home/container" -v "${PREFIX}-git:/git" \
        -e STARTUP="$startup" "$@" "$IMAGE")
    STATUS=$(timeout 600 docker wait "$id")
    OUTPUT=$(docker logs "$id" 2>&1 | clean)
    docker rm -f "$id" >/dev/null
}

# shell <volume> <script>: runs a script in the volume, bypassing the entrypoint
shell() {
    OUTPUT=$(docker run --rm -i --user 988:988 -v "${PREFIX}-$1:/home/container" -v "${PREFIX}-git:/git" \
        --entrypoint /bin/bash "$IMAGE" -s 2>&1 <<<"$2" | clean)
}

# A Git server for the tests: a bare repository on a shared volume.
git_commit() {
    shell gitwork "
        set -e
        cd /git/work
        git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -am '$1'
        git push -q origin HEAD
    "
}

# -----------------------------------------------------------------------------

section "Image basics"
OUTPUT=$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
    id; node -v; pnpm --version; git --version; tini --version
    command -v corepack || echo "no corepack"
    command -v ffmpeg xvfb-run python3 make g++ ssh
    readlink -f "$(command -v pnpm)"' 2>&1)
assert_output "runs as container (988)" "uid=988\(container\)"
assert_output "bundled Node.js" "^v[0-9]+\."
assert_output "standalone pnpm" "node_modules/@pnpm/exe/pnpm"
assert_output "corepack removed" "no corepack"
assert_output "build and media tools present" "/usr/bin/ffmpeg"
assert_output "xvfb-run present" "/usr/bin/xvfb-run"

section "Plain project (no Git)"
shell plain '
    cat > package.json <<EOF
{"name":"plain","version":"1.0.0","scripts":{"start":"node index.js"},"dependencies":{"is-odd":"3.0.1"}}
EOF
    echo "console.log(\"is-odd(3) =\", require(\"is-odd\")(3), \"pid\", process.pid)" > index.js'
server plain "pnpm start"
assert_status "exits cleanly" 0
assert_output "dependencies installed" "\+ is-odd 3.0.1"
assert_output "app ran" "is-odd\(3\) = true"
assert_output "startup line printed" "^:/home/container\\$ pnpm start"
assert_output "INTERNAL_IP is not reported as empty" "ready in"
shell plain 'ls -a; readlink -f node_modules/is-odd; du -sh .local/share/pnpm/store'
assert_output "store lives in the server volume" "\.local/share/pnpm/store"
server plain "pnpm start"
assert_output "second start is up to date" "Already up to date|Lockfile is up to date|Done in"
assert_output "app ran again" "is-odd\(3\) = true"
ready=$(grep -Eo 'ready in [0-9]+' <<<"$OUTPUT" | grep -Eo '[0-9]+')
if [ "${ready:-99999}" -lt 3000 ]; then pass "up-to-date restart is fast (${ready} ms)"; else failed "up-to-date restart is fast (${ready} ms)"; fi

section "Startup variables"
server plain 'echo "port={{SERVER_PORT}} memory=${SERVER_MEMORY}" && node -e "console.log(process.env.INTERNAL_IP ? \"ip ok\" : \"no ip\")"' \
    -e SERVER_PORT=25565 -e SERVER_MEMORY=512
assert_output "{{VARIABLE}} placeholders are replaced" "port=25565 memory=512"
assert_output "compound commands work" "ip ok"

section "Arbitrary UID without passwd entry"
OUTPUT=$(docker run --rm -t --user 4242:4242 --tmpfs /tmp:size=100m --tmpfs /home/container:uid=4242,gid=4242,exec \
    -e STARTUP='node -e "console.log(\"uid\", process.getuid())"' "$IMAGE" 2>&1 | clean)
assert_output "starts as unknown UID" "uid 4242"

section "Signals"
shell signal '
    echo "{\"name\":\"s\",\"version\":\"1.0.0\",\"scripts\":{\"start\":\"node app.js\"}}" > package.json
    cat > app.js <<EOF
console.log("app started");
process.on("SIGINT", () => { console.log("graceful SIGINT shutdown"); process.exit(0); });
setInterval(() => {}, 1000);
EOF'
id=$(docker run -d -it --user 988:988 --tmpfs /tmp:size=100m -v "${PREFIX}-signal:/home/container" -e STARTUP="pnpm start" --name "${PREFIX}-sig" "$IMAGE")
for _ in $(seq 60); do docker logs "$id" 2>&1 | grep -q "app started" && break; sleep 1; done
start=$(date +%s)
docker stop -t 20 "$id" >/dev/null
STATUS=$(docker wait "$id")
elapsed=$(($(date +%s) - start))
OUTPUT=$(docker logs "$id" 2>&1 | clean)
docker rm -f "$id" >/dev/null
assert_output "app receives SIGINT through pnpm run" "graceful SIGINT shutdown"
if [ "$elapsed" -lt 10 ]; then pass "stops quickly (${elapsed}s)"; else failed "stops quickly (${elapsed}s)"; fi

section "Node.js version selection"
server plain 'node -v' -e NODE_VERSION=20
assert_output "NODE_VERSION=20 installs Node.js 20" "^v20\."
server plain 'node -v' -e NODE_VERSION=20
assert_output "cached on restart" "^v20\."
refute_output "no warnings on restart" "warning"
server plain 'node -v' -e NODE_VERSION=20 --network none
assert_output "offline: keeps the cached version" "^v20\."
assert_output "offline: warns instead of failing" "warning: Node.js: could not install 20, keeping v20"
server plain 'pnpm start' -e NODE_VERSION=18.20.8
assert_output "exact old version (18.20.8)" "Node.js v18\.20\.8"
assert_output "pnpm still works with Node.js 18" "is-odd\(3\) = true"
server plain 'node -v' -e NODE_VERSION=latest
assert_output "NODE_VERSION=latest" "^v2[6-9]\."
server plain 'node -v' -e NODE_VERSION=
BUNDLED=$(docker run --rm --entrypoint node "$IMAGE" -v | clean)
assert_output "empty NODE_VERSION returns to bundled ${BUNDLED}" "^${BUNDLED}$"

section "pnpm version selection"
server plain 'pnpm --version && pnpm start' -e PNPM_VERSION=9.15.9
assert_output "PNPM_VERSION=9.15.9" "^9\.15\.9$"
assert_output "app runs with pnpm 9" "is-odd\(3\) = true"
server plain 'pnpm --version' -e PNPM_VERSION=10
assert_output "PNPM_VERSION=10 (range)" "^10\.[0-9]+\.[0-9]+$"
server plain 'pnpm --version' -e PNPM_VERSION=
IMAGE_PNPM=$(docker run --rm --entrypoint pnpm "$IMAGE" --version | clean)
assert_output "empty PNPM_VERSION returns to bundled ${IMAGE_PNPM}" "^${IMAGE_PNPM}$"

section "packageManager field"
shell pm '
    echo "{\"name\":\"pm\",\"version\":\"1.0.0\",\"packageManager\":\"pnpm@10.34.9\",\"dependencies\":{\"is-odd\":\"3.0.1\"}}" > package.json'
server pm 'pnpm --version'
assert_output "honours packageManager" "^10\.34\.9$"
server pm 'pnpm --version' -e PNPM_VERSION=9.15.9
assert_output "PNPM_VERSION overrides packageManager" "^9\.15\.9$"

section "Build scripts"
shell builds '
    echo "{\"name\":\"b\",\"version\":\"1.0.0\",\"dependencies\":{\"esbuild\":\"0.25.0\"}}" > package.json'
server builds 'node -e "console.log(require(\"esbuild\").transformSync(\"let a: number = 1\", {loader: \"ts\"}).code)"'
assert_output "blocked build scripts produce a hint" "ALLOW_BUILD_SCRIPTS"
server builds 'node -e "console.log(require(\"esbuild\").transformSync(\"let a: number = 1\", {loader: \"ts\"}).code)"' -e ALLOW_BUILD_SCRIPTS=1
assert_output "ALLOW_BUILD_SCRIPTS=1 runs them" "let a = 1;"
refute_output "no install warning" "warning: Dependencies"
shell builds 'rm -rf node_modules; printf "allowBuilds:\n  esbuild: true\n" > pnpm-workspace.yaml'
server builds 'node -e "console.log(require(\"esbuild\").transformSync(\"let a: number = 1\", {loader: \"ts\"}).code)"'
assert_output "project allowBuilds is honoured" "let a = 1;"

section "Build step"
shell buildstep '
    echo "{\"name\":\"bs\",\"version\":\"1.0.0\",\"scripts\":{\"build\":\"echo built > dist.txt\",\"broken\":\"exit 3\"}}" > package.json'
server buildstep 'cat dist.txt' -e BUILD_SCRIPT=build
assert_output "BUILD_SCRIPT runs before startup" "^built$"
server buildstep 'echo should-not-start' -e BUILD_SCRIPT=broken
assert_status "failing build stops the server" 1
refute_output "startup is skipped" "^should-not-start$"

section "Git"
shell gitwork '
    set -e
    git init -q --bare -b main /git/repo.git
    git clone -q /git/repo.git /git/work 2>/dev/null
    cd /git/work
    echo "{\"name\":\"g\",\"version\":\"1.0.0\",\"scripts\":{\"start\":\"node show.js\"}}" > package.json
    echo "console.log(require(\"./version.json\").v)" > show.js
    echo "{\"v\":\"version-1\"}" > version.json
    git add -A
    git -c user.name=test -c user.email=test@example.com commit -qm "v1"
    git push -q origin HEAD:main
    git checkout -qb dev && echo "{\"v\":\"dev-1\"}" > version.json
    git -c user.name=test -c user.email=test@example.com commit -qam "dev"
    git push -q origin dev && git checkout -q main'
GIT=(-e GIT_REPO=file:///git/repo.git)

shell repo 'echo "SECRET=1" > .env; echo "old" > version.json'
server repo 'pnpm start' "${GIT[@]}"
assert_output "clones into a non-empty directory" "Git: checked out .* v1"
assert_output "tracked files replace existing ones" "^version-1$"
shell repo 'cat .env; git status --short --branch'
assert_output "untracked files are kept" "SECRET=1"
assert_output "default branch is tracked" "## main\.\.\.origin/main"

shell gitwork 'cd /git/work && echo "{\"v\":\"version-2\"}" > version.json'
git_commit "v2"
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=0
assert_output "AUTO_UPDATE=0 keeps the checkout" "^version-1$"
shell repo 'echo "{\"v\":\"local edit\"}" > version.json; touch .git/index.lock'
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1
assert_output "AUTO_UPDATE=1 pulls despite local edits and a stale lock" "^version-2$"
assert_output "discarded edits are listed" "M version.json"
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1
assert_output "reports up to date" "Git: main is up to date"

shell repo 'cd /home/container && git -c user.name=x -c user.email=x@x commit -qam "diverged local commit" --allow-empty'
shell gitwork 'cd /git/work && echo "{\"v\":\"version-3\"}" > version.json'
git_commit "v3"
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1
assert_output "recovers from diverged history" "^version-3$"

server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1 -e GIT_BRANCH=dev
assert_output "switches branch via GIT_BRANCH" "^dev-1$"
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1 -e GIT_BRANCH=main
assert_output "switches back" "^version-3$"

shell repo 'chown -R 988 .git 2>/dev/null; git -C /home/container remote set-url origin https://example.invalid/old.git'
server repo 'pnpm start' "${GIT[@]}" -e AUTO_UPDATE=1
assert_output "repairs a changed remote URL" "Git: main is up to date|^version-3$"

server repo 'pnpm start' -e GIT_REPO=file:///git/missing.git -e AUTO_UPDATE=1
assert_status "unreachable remote does not stop the server" 0
assert_output "warns on fetch failure" "warning: Git: fetching"
assert_output "still starts" "^version-3$"

server fresh 'echo started' -e GIT_REPO=https://example.invalid/nope.git
assert_output "failed clone warns" "warning: Git: clone failed"
assert_output "failed clone still starts" "^started$"
shell fresh 'ls -A'
refute_output "failed clone leaves no partial state" "\.git|pnpm-image-clone"

server public 'git log -1 --format=%H && ls' -e GIT_REPO=https://github.com/DemonMartin/pterodactyl-rust.git
assert_output "clones a public GitHub repository" "Dockerfile"

section "Git credentials"
OUTPUT=$(docker run --rm -i --entrypoint /bin/sh -e GIT_REPO=https://github.com/me/private.git -e GIT_USERNAME=me -e GIT_TOKEN=s3cret \
    "$IMAGE" -c 'printf "protocol=https\nhost=github.com\n\n" | git credential fill; echo ---; printf "protocol=https\nhost=evil.example\n\n" | git credential-env get' 2>&1)
assert_output "token is provided for the repository host" "password=s3cret"
assert_output "no token for other hosts" "^---$"
refute_output "token never sent to other hosts" "---.*s3cret"
OUTPUT=$(docker run --rm -i --entrypoint /bin/sh -e GIT_REPO=https://git.example.com:8443/me/x.git -e GIT_TOKEN=t \
    "$IMAGE" -c 'printf "protocol=https\nhost=git.example.com:8443\n\n" | git-credential-env get' 2>&1)
assert_output "hosts with ports, default username" "username=git"
OUTPUT=$(docker run --rm -t --user 988:988 -e GIT_REPO=https://github.com/DemonMartin/this-repo-does-not-exist-123.git \
    -e STARTUP='echo started' "$IMAGE" 2>&1 | clean)
assert_output "private/missing repo never prompts for a password" "^started$"
shell repo 'grep -r s3cret .git || echo "no secrets on disk"'
assert_output "no credentials stored in .git" "no secrets on disk"

section "Disk usage"
shell plain 'du -sh --apparent-size node_modules .local/share/pnpm/store; df /home/container | tail -1'
pass "$(head -2 <<<"$OUTPUT" | tr '\n' ' ')"

if [ "${SKIP_BROWSERS:-0}" != 1 ]; then
    section "Browsers"
    shell browser '
        echo "{\"name\":\"br\",\"version\":\"1.0.0\",\"dependencies\":{\"playwright\":\"latest\",\"puppeteer\":\"latest\"},\"pnpm\":{}}" > package.json
        printf "allowBuilds:\n  puppeteer: true\n" > pnpm-workspace.yaml
        cat > test.js <<EOF
const { chromium, firefox } = require("playwright");
(async () => {
  for (const type of [chromium, firefox]) {
    const headful = process.env.HEADFUL === "1";
    const browser = await type.launch({ headless: !headful, args: headful && type === chromium ? ["--disable-gpu"] : [] });
    const page = await browser.newPage();
    await page.setContent("<h1>Hello 🦖 世界</h1>");
    console.log(type.name(), "ok", await page.textContent("h1"), (await page.screenshot()).length > 1000);
    await browser.close();
  }
  const puppeteer = require("puppeteer");
  const b = await puppeteer.launch({ args: ["--no-sandbox"] });
  const p = await b.newPage();
  await p.setContent("<p>puppeteer</p>");
  console.log("puppeteer ok", await p.\$eval("p", (e) => e.textContent));
  await b.close();
})().catch((e) => { console.error(e); process.exit(1); });
EOF'
    server browser 'pnpm exec playwright install chromium firefox >/dev/null && node test.js'
    assert_output "Playwright Chromium headless" "chromium ok Hello"
    assert_output "Playwright Firefox headless" "firefox ok Hello"
    assert_output "Puppeteer Chrome headless" "puppeteer ok puppeteer"
    server browser 'HEADFUL=1 xvfb-run -a -s "-screen 0 1920x1080x24" node test.js'
    assert_output "headful browsers under Xvfb" "chromium ok Hello.*true"
    assert_output "headful Firefox under Xvfb" "firefox ok Hello"
    shell browser 'du -sh .cache/ms-playwright .cache/puppeteer'
    pass "browsers cached in the volume: $(tr '\n' ' ' <<<"$OUTPUT")"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
