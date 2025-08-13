# syntax=docker/dockerfile:1
FROM ubuntu:22.04

SHELL [ "/bin/bash", "-c" ]

ARG BUILD_DATE 
ARG VERSION
ARG DEBIAN_FRONTEND=noninteractive

LABEL build_version="Version: ${VERSION}" \
      build_date="${BUILD_DATE}" \
      maintainer="gelbphoenix"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    CALIBRE_DBPATH=/config \
    UMASK=0002

USER root

# Create the abc user
RUN useradd -u 911 -U -d /config -s /bin/false abc && \
    usermod -G users abc

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential libldap2-dev libsasl2-dev \
      curl python3-dev python3-pip \
      imagemagick ghostscript libldap-2.5-0 \
      libmagic1 libsasl2-2 libxi6 \
      libxslt1.1 python3-venv libxtst6 \
      libxrandr2 libxkbfile1 libxcomposite1 \
      libopengl0 libnss3 libxkbcommon0 \
      libegl1 libxdamage1 libgl1 \
      libglx-mesa0 xz-utils sqlite3 \
      xdg-utils tzdata inotify-tools \
      netcat-openbsd binutils zip

# Install S6-Overlay
RUN export S6_OVERLAY_VERSION=$(curl -s https://api.github.com/repos/just-containers/s6-overlay/releases/latest | awk -F'"' '/tag_name/{print $4;exit}') && \
    curl -Lo /tmp/s6-overlay-$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/aarch64/').tar.xz https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/aarch64/').tar.xz && \
    curl -Lo /tmp/s6-overlay-noarch.tar.xz https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/aarch64/').tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz

ENV S6_STAGE2_HOOK=/docker-mods

# Install Autocaliweb
COPY requirements.txt optional-requirements.txt /app/autocaliweb/

RUN cd /app/autocaliweb && \
    python3 -m venv venv && \
    pip install -U pip wheel && \
    pip install --find-links https://wheel-index.linuxserver.io/ubuntu/ \ 
    -r /app/autocaliweb/requirements.txt \
    -r /app/autocaliweb/optional-requirements.txt 

    
COPY . /app/autocaliweb/

RUN cd /app/autocaliweb/koreader/plugins && \
    PLUGIN_DIGEST=$(find acwsync.koplugin -type f -name "*.lua" -o -name "*.json" | sort | xargs sha256sum | sha256sum | cut -d' ' -f1) && \
    echo "Plugin files digest: $PLUGIN_DIGEST" >> acwsync.koplugin/${PLUGIN_DIGEST}.digest && \
    echo "Build date: ${BUILD_DATE}" >> acwsync.koplugin/${PLUGIN_DIGEST}.digest && \
    echo "Files included:" >> acwsync.koplugin/${PLUGIN_DIGEST}.digest && \
    find acwsync.koplugin -type f -name "*.lua" -o -name "*.json" | sort >> acwsync.koplugin/${PLUGIN_DIGEST}.digest && \
    zip -r koplugin.zip acwsync.koplugin/ && \
    cp /app/autocaliweb/koreader/plugins/koplugin.zip /app/autocaliweb/cps/static
    
RUN cp -r /app/autocaliweb/root/* / && \ 
    rm -R /app/autocaliweb/root/ && \
    /app/autocaliweb/scripts/setup-acw.sh && \
    echo $VERSION >| /app/ACW_RELEASE

# To ensure that docker-mods for calibre-web can be used
RUN ln -s /app/autocaliweb /app/calibre-web

# Install kepubify
RUN export KEPUBIFY_RELEASE=$(curl -s https://api.github.com/repos/pgaskin/kepubify/releases/latest | awk -F'"' '/tag_name/{print $4;exit}') && \
    curl -Lo /usr/bin/kepubify "https://github.com/pgaskin/kepubify/releases/download/${KEPUBIFY_RELEASE}/kepubify-linux-$(uname -m | sed 's/x86_64/64bit/;s/aarch64/arm64/')" && \
    chmod +x /usr/bin/kepubify && \
    echo "$KEPUBIFY_RELEASE" >| /app/KEPUBIFY_RELEASE

# Install Calibre binaries
RUN mkdir -p /app/calibre && \
    CALIBRE_RELEASE=$(curl -s https://api.github.com/repos/kovidgoyal/calibre/releases/latest | awk -F'"' '/tag_name/{print $4;exit}') && \
    CALIBRE_VERSION=${CALIBRE_RELEASE#v} && \
    curl -o /tmp/calibre.txz -L https://download.calibre-ebook.com/${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/').txz && \
    tar xf /tmp/calibre.txz -C /app/calibre && \
    rm /tmp/calibre.txz && \
    /app/calibre/calibre_postinstall && \
    echo "$CALIBRE_RELEASE" >| /app/CALIBRE_RELEASE

# Clean up
RUN apt-get purge -y \
    build-essential libldap2-dev \
    libsasl2-dev python3-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/* \
    /root/.cache

COPY --from=ghcr.io/linuxserver/unrar:latest /usr/bin/unrar-ubuntu /usr/bin/unrar

# ports and volumes
EXPOSE 8083
VOLUME /config
VOLUME /acw-book-ingest
VOLUME /calibre-library

# Healthcheck
HEALTHCHECK --interval=60s --timeout=10s --start-period=5s --retries=2 \
  CMD curl --fail -m 5 http://localhost:8083/login || exit 1

CMD ["/init"]