# Pterodactyl pnpm

A Pterodactyl image and egg for Node.js applications managed with [pnpm](https://pnpm.io).

```text
ghcr.io/demonmartin/pterodactyl-pnpm:latest
```

- **Any Node.js version.** The current LTS is bundled. Set `NODE_VERSION` to a major (`22`), an exact version (`18.20.8`), `lts` or `latest`, and pnpm installs it once into the server volume. Switching back to a cached version takes well under a second.
- **Any pnpm version.** The standalone pnpm build is bundled. It does not depend on the selected Node.js, so pnpm keeps working with Node.js 18 as well as 26. The project's `packageManager` field is honoured, and `PNPM_VERSION` overrides it.
- **Fast starts.** The pnpm store lives in the server volume on the same filesystem as the project. Packages are hard-linked instead of copied, and a restart with nothing to do takes under 100 ms.
- **Robust Git deployment.** Clones into non-empty directories and mirrors the remote branch on update, even with local edits, diverged history, stale locks or a changed remote URL. Tokens come from a credential helper and are never written to disk. It never prompts for a password, and when Git is unreachable the server still starts with its current code.
- **Always current.** GitHub Actions checks every day for new pnpm and Node.js LTS releases and rebuilds every Monday for Debian security updates. Wings pulls the new image on the next restart.
- **Batteries included.** Build tools for native modules (`build-essential`, `python3`), `git`, `ffmpeg`, `sqlite3`, and the system libraries and fonts for headless and headful Chromium/Chrome and Firefox (Playwright, Puppeteer, Selenium), plus Xvfb. `linux/amd64` and `linux/arm64`.

## Usage

Import [`egg-pnpm.json`](egg-pnpm.json) in the panel (*Admin → Nests → Import Egg*) and create a server with it. Alternatively, use the image in any existing Node.js egg. It behaves like the official yolks images: `/usr/local/bin/node`, `npm` and the `STARTUP` variable all work as usual.

On every start, the image runs these steps in order, each one optional:

1. Clone or update the Git repository
2. Select Node.js and pnpm
3. `pnpm install`
4. The build script
5. The startup command (`pnpm run start` by default)

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `START_SCRIPT` | `start` | `package.json` script that starts the app (`pnpm run <script>`). |
| `NODE_VERSION` | *(bundled LTS)* | `22`, `20.18.1`, `lts`, `latest`, … Ranges update to the newest match on each start. |
| `PNPM_VERSION` | *(bundled / `packageManager`)* | `10`, `9.15.9`, `latest`, … Takes precedence over `packageManager`. |
| `GIT_REPO` | | HTTPS URL to deploy. Empty disables Git. |
| `GIT_BRANCH` | *(default branch)* | Branch to deploy. Changing it switches the checkout. |
| `GIT_USERNAME` / `GIT_TOKEN` | | Credentials for private repositories, sent only to the repository's host. |
| `AUTO_UPDATE` | `0` | Update to the latest commit on every start. |
| `INSTALL_DEPS` | `1` | Run `pnpm install` on every start. |
| `INSTALL_FLAGS` | | Extra flags, e.g. `--prod` or `--frozen-lockfile`. |
| `ALLOW_BUILD_SCRIPTS` | `0` | Allow all dependency build scripts (see below). |
| `BUILD_SCRIPT` | | Script run before starting, e.g. `build`. A failed build stops the start. |

### Git behaviour

- **First start with `GIT_REPO` set:** the repository is cloned into the server directory. Existing files that the repository also contains are replaced, and all other files are kept. To clone again from scratch, delete the `.git` directory.
- **`AUTO_UPDATE=1`:** the server is reset to the remote branch on every start. Edits to tracked files are discarded and listed in the console. Untracked files such as `.env`, configs and `node_modules` are never touched.
- **Unreachable remote** (network, credentials): the console shows a warning and the server starts with the code it already has.

### Dependency build scripts

pnpm blocks dependency install scripts (`postinstall`) by default, and pnpm 11+ fails the install when one is blocked. The preferred fix is to list the trusted packages in `pnpm-workspace.yaml`:

```yaml
allowBuilds:
  esbuild: true
  sqlite3: true
```

Alternatively, set `ALLOW_BUILD_SCRIPTS=1` to allow all of them. A failed install never blocks the start: the server runs with the existing `node_modules` and the console explains what happened.

## What is stored where

Everything persistent lives in the server volume (`/home/container`), so it survives restarts and image updates:

| Path | Contents |
| --- | --- |
| `.local/share/pnpm/store` | pnpm content-addressable store, hard-linked into `node_modules` |
| `.local/share/pnpm/global`, `.local/share/pnpm/bin` | Node.js versions and pnpm versions selected via the variables |
| `.cache/pnpm` | pnpm metadata cache |
| `.cache/ms-playwright`, `.cache/puppeteer` | browsers, if the project downloads them |
| `.cache/tmp` | `TMPDIR`, cleared on each start (Wings' `/tmp` is only 100 MB) |

## Browsers

The image contains the system libraries for Chromium/Chrome and Firefox, but no browser. The project installs its own, which is cached in the volume:

```bash
pnpm exec playwright install chromium firefox
```

- **Puppeteer and Selenium:** pass `--no-sandbox` to Chrome. Containers cannot create the user namespaces that Chrome's sandbox needs. Playwright does this by default.
- **Headful mode:** run the app under Xvfb with a 24-bit screen, e.g. a start script of `xvfb-run -a -s "-screen 0 1920x1080x24" node index.js`. Launch Chromium with `--disable-gpu`, because there is no GPU in the container. Firefox needs no extra flags.
- **WebKit:** needs additional GStreamer libraries that are not included.

## Development

```bash
docker build -t pterodactyl-pnpm:dev .
bash tests/run.sh pterodactyl-pnpm:dev
```

The tests run containers the way Wings does: UID 988, a TTY, a 100 MB tmpfs on `/tmp`, and the server volume at `/home/container`. They cover the variables above, Git edge cases, credentials, signals and offline starts, and with browsers enabled also Playwright and Puppeteer. Set `SKIP_BROWSERS=1` to skip the browser downloads.
