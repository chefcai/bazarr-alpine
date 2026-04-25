# bazarr-alpine: minimal Bazarr image built on Alpine
#
# Strategy: pure alpine base + system Python + apk-packaged C-extension deps
# (py3-numpy/py3-pillow/py3-webrtcvad/py3-lxml). Apk packages share system
# libs and are smaller than the equivalent musllinux pip wheels (which
# bundle their own copies of every shared lib).
#
# Avoids pulling in a full Ubuntu/S6 stack like linuxserver/bazarr.
ARG BAZARR_VERSION=v1.5.6

FROM alpine:3.21

ARG BAZARR_VERSION

ENV PUID=13001 \
    PGID=13000 \
    TZ=America/New_York \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Runtime deps:
#   - ffmpeg: subtitle conversion (called by subprocess from bazarr)
#   - 7zip: archive extraction (Bazarr requires unrar OR unar OR 7zip)
#   - python3 + py3-* C-extension deps (all from apk to share system libs)
#   - tzdata: timezone support
#   - curl/unzip: bootstrap only (purged at end of layer via .build-deps)
#
# NOTE: unrar omitted — not in Alpine main due to licensing. 7zip covers
#       the rar-archive case Bazarr cares about.
RUN apk add --no-cache \
        ffmpeg \
        7zip \
        tzdata \
        ca-certificates \
        python3 \
        py3-lxml \
        py3-numpy \
        py3-pillow \
    && apk add --no-cache --virtual .build-deps curl unzip py3-pip \
    && addgroup -g 13000 bazarr \
    && adduser -D -u 13001 -G bazarr bazarr \
    && mkdir -p /app /config /media \
    && curl -fsSL "https://github.com/morpheus65535/bazarr/releases/download/${BAZARR_VERSION}/bazarr.zip" -o /tmp/bazarr.zip \
    && unzip -q /tmp/bazarr.zip -d /app \
    && rm /tmp/bazarr.zip \
    # webrtcvad is the only pip dep we still need — Alpine doesn't package it.
    # The wheel is ~86KB; --break-system-packages installs into the system
    # python's site-packages alongside apk's py3-* packages.
    && pip install --no-cache-dir --no-compile --break-system-packages \
         webrtcvad-wheels \
    # Strip __pycache__ — regenerated at first import, dead weight in image.
    && find /app /usr/lib/python3* -type d -name __pycache__ -prune -exec rm -rf {} + \
    # Strip tests/docs/examples from vendored libs.
    && find /app/libs -type d \( -name tests -o -name test -o -name examples -o -name docs \) -prune -exec rm -rf {} + 2>/dev/null || true \
    # Strip the standalone Python test suite & IDLE — Bazarr never imports them.
    && rm -rf /usr/lib/python3*/test /usr/lib/python3*/idlelib /usr/lib/python3*/turtledemo \
    && chown -R bazarr:bazarr /app /config /media \
    && apk del .build-deps

USER bazarr
WORKDIR /app

EXPOSE 6767

CMD ["python3", "/app/bazarr.py", "--no-update", "--config", "/config"]
