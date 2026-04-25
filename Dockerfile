# bazarr-alpine: minimal Bazarr image built on Alpine
#
# Strategy: pull the official Bazarr release zip (which ships vendored
# Python deps under libs/) and run it on python:alpine. Avoids pulling
# in a full Ubuntu/S6 stack like linuxserver/bazarr.
ARG BAZARR_VERSION=v1.5.6

FROM python:3.12-alpine

ARG BAZARR_VERSION

ENV PUID=13001 \
    PGID=13000 \
    TZ=America/New_York

# Runtime deps:
#   - ffmpeg: subtitle conversion (optional but commonly used)
#   - tzdata: timezone support
#   - unzip / curl: bootstrap only (removed at end of layer)
# NOTE: unrar omitted — not packaged in Alpine main due to licensing.
#       Bazarr only needs it for .rar-archived subtitle providers.
RUN apk add --no-cache \
        ffmpeg \
        7zip \
        tzdata \
        ca-certificates \
        libxml2 \
        libxslt \
    && apk add --no-cache --virtual .build-deps curl unzip \
    && addgroup -g 13000 bazarr \
    && adduser -D -u 13001 -G bazarr bazarr \
    && mkdir -p /app /config /media \
    && curl -fsSL "https://github.com/morpheus65535/bazarr/releases/download/${BAZARR_VERSION}/bazarr.zip" -o /tmp/bazarr.zip \
    && unzip -q /tmp/bazarr.zip -d /app \
    && rm /tmp/bazarr.zip \
    # bazarr.zip ships pure-Python deps under custom_libs/, but C-extension
    # packages (Pillow, numpy, lxml, webrtcvad, PyNaCl) must be installed
    # for the host architecture/libc. musllinux wheels exist for all of these.
    && pip install --no-cache-dir --root-user-action=ignore \
         Pillow \
         numpy \
         lxml \
         webrtcvad-wheels \
         PyNaCl \
    && chown -R bazarr:bazarr /app /config /media \
    && apk del .build-deps

USER bazarr
WORKDIR /app

EXPOSE 6767

CMD ["python", "/app/bazarr.py", "--no-update", "--config", "/config"]
