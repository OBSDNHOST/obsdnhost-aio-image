FROM debian:trixie-slim

LABEL org.opencontainers.image.title="OBSDNHOST AIO" \
      org.opencontainers.image.description="Node.js, Python, Java and common tools for Discord bot hosting"

ENV DEBIAN_FRONTEND=noninteractive

# Base tools, Python, Java, Go and native libraries bots commonly need
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git openssh-client wget \
      zip unzip tar xz-utils bzip2 jq tree nano \
      iproute2 dnsutils tzdata locales openssl \
      build-essential pkg-config \
      python3 python3-pip python3-venv python3-dev \
      openjdk-21-jre-headless \
      golang-go \
      ffmpeg sqlite3 libsqlite3-dev \
      libssl-dev libffi-dev libopus-dev libsodium-dev \
      libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
      fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS + common tooling
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g npm@latest pnpm yarn typescript tsx pm2 \
    && rm -rf /var/lib/apt/lists/*

# Pterodactyl runs containers as this user
RUN useradd -m -d /home/container -s /bin/bash container

COPY entrypoint.sh /entrypoint.sh
COPY obsdnhost-launcher.sh /usr/local/bin/obsdnhost-launcher
RUN chmod +x /entrypoint.sh /usr/local/bin/obsdnhost-launcher

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD ["/bin/bash", "/entrypoint.sh"]
