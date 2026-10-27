# syntax=docker/dockerfile:1

# The bundled Node.js is the current LTS. Any other version is installed at
# runtime by pnpm (NODE_VERSION) and cached in the server volume.
ARG NODE_IMAGE=node:lts-trixie-slim

FROM ${NODE_IMAGE}

# Resolved to an exact version by CI; "latest" works for local builds.
ARG PNPM_VERSION=latest

LABEL org.opencontainers.image.source="https://github.com/DemonMartin/pterodactyl-pnpm"
LABEL org.opencontainers.image.description="Pterodactyl image for Node.js apps managed with pnpm: any Node.js version, any pnpm version, robust Git deployment"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        dnsutils \
        ffmpeg \
        fontconfig \
        git \
        iproute2 \
        iputils-ping \
        jq \
        libnss3 \
        libsqlite3-dev \
        libtool \
        openssh-client \
        procps \
        python3 \
        python3-dev \
        sqlite3 \
        tar \
        tini \
        tzdata \
        unzip \
        xauth \
        xvfb \
        zip \
    && rm -rf /var/lib/apt/lists/*

# System libraries and fonts for headless and headful Chromium/Chrome and
# Firefox, as used by Playwright, Puppeteer and Selenium (the set Playwright
# lists for Debian 13). No browser is installed: projects that need one
# download it themselves, into the server volume.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fonts-freefont-ttf \
        fonts-ipafont-gothic \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-tlwg-loma-otf \
        fonts-wqy-zenhei \
        libasound2t64 \
        libatk-bridge2.0-0t64 \
        libatk1.0-0t64 \
        libatspi2.0-0t64 \
        libcairo-gobject2 \
        libcairo2 \
        libcups2t64 \
        libdbus-1-3 \
        libdbus-glib-1-2 \
        libdrm2 \
        libfontconfig1 \
        libfreetype6 \
        libgbm1 \
        libgdk-pixbuf-2.0-0 \
        libglib2.0-0t64 \
        libgtk-3-0t64 \
        libharfbuzz0b \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libx11-6 \
        libx11-xcb1 \
        libxcb-shm0 \
        libxcb1 \
        libxcomposite1 \
        libxcursor1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxi6 \
        libxkbcommon0 \
        libxrandr2 \
        libxrender1 \
        libxtst6 \
        xfonts-scalable \
    && rm -rf /var/lib/apt/lists/*

# @pnpm/exe is the standalone build: it bundles its own runtime, so pnpm keeps
# working whatever Node.js version the server selects. Corepack is removed so
# nothing can shadow the pnpm binary.
RUN npm install --global --no-fund --no-audit "@pnpm/exe@${PNPM_VERSION}" \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/corepack /usr/local/bin/corepack \
    && pnpm --version

COPY --chmod=644 rootfs/etc/gitconfig /etc/gitconfig
COPY --chmod=755 rootfs/usr/local/bin/ /usr/local/bin/
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Wings runs the container as its own UID (988 by default) with the server
# volume mounted at /home/container, so everything mutable lives there.
RUN useradd --uid 988 --user-group --home-dir /home/container --create-home --shell /bin/bash container \
    && chmod 755 /home/container

USER container
# NODE_VERSION / YARN_VERSION from the node base image are cleared: here
# NODE_VERSION is the server's choice of Node.js (see entrypoint.sh).
ENV NODE_VERSION= \
    YARN_VERSION= \
    USER=container \
    HOME=/home/container \
    PNPM_HOME=/home/container/.local/share/pnpm \
    PATH=/home/container/.local/share/pnpm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    GIT_TERMINAL_PROMPT=0 \
    pnpm_config_confirm_modules_purge=false \
    npm_config_update_notifier=false
WORKDIR /home/container

STOPSIGNAL SIGINT

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
