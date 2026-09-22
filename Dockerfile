# bazarr-alpine: minimal Bazarr image built on Alpine
#
# Strategy: pure alpine base + system Python + apk-packaged C-extension deps
# (py3-numpy/py3-pillow/py3-webrtcvad/py3-lxml). Apk packages share system
# libs and are smaller than the equivalent musllinux pip wheels (which
# bundle their own copies of every shared lib).
#
# Avoids pulling in a full Ubuntu/S6 stack like linuxserver/bazarr.
ARG BAZARR_VERSION=v1.5.6

# ---- Stage 1: slim static ffmpeg/ffprobe ----------------------------------
# Alpine's `ffmpeg` apk hard-links every video codec lib (x264, x265, aom,
# SVT-AV1, rav1e, dav1d, vpx, vulkan, libplacebo, ...) -- ~150 MB of this
# image. Bazarr only uses ffmpeg/ffprobe for:
#   - ffprobe (via knowit/fese): list audio/subtitle/video streams of a file
#   - fese: extract embedded text subtitles (`-map 0:N -f srt|ass|webvtt`, or
#     `-c:s copy` for ass/srt/webvtt/PGS `sup`)
#   - ffsubsync: decode a reference audio track to mono 16 kHz PCM
#     (`-f s16le -acodec pcm_s16le -af aresample=async=1`), optionally
#     remuxing audio with `-acodec copy` into .mka first
# It never decodes video. So: --disable-everything + only those components.
# Network protocols disabled -- Bazarr hands ffmpeg local file paths only.
FROM alpine:3.21 AS build-ffmpeg
ARG FFMPEG_VERSION=7.1.1
RUN apk add --no-cache build-base nasm pkgconf curl xz zlib-dev zlib-static
WORKDIR /src
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" | tar xJ --strip-components=1
RUN ./configure \
        --prefix=/opt/ffmpeg \
        --pkg-config-flags=--static \
        --extra-ldflags=-static \
        --enable-static --disable-shared \
        --disable-debug --disable-doc --disable-ffplay \
        --disable-autodetect --disable-network \
        --enable-zlib \
        --disable-everything \
        --enable-protocol=file,pipe \
        --enable-demuxer=matroska,mov,avi,mpegts,mpegps,ogg,flv,asf,mp3,aac,ac3,eac3,dts,truehd,flac,wav,srt,ass,webvtt \
        --enable-muxer=s16le,wav,srt,ass,webvtt,sup,matroska,null \
        --enable-decoder=aac,aac_latm,ac3,eac3,dca,truehd,mlp,flac,opus,vorbis,mp3,mp3float,mp2,alac,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_bluray,pcm_dvd,ass,ssa,subrip,srt,webvtt,mov_text,text \
        --enable-encoder=pcm_s16le,subrip,srt,ass,ssa,webvtt \
        --enable-parser=aac,aac_latm,ac3,dca,mlp,flac,mpegaudio,opus,vorbis,h264,hevc,av1,vp9,mpeg4video,mpegvideo \
        --enable-bsf=null \
        --enable-filter=aresample,aformat,anull,null,format \
        --enable-swresample \
 && make -j"$(nproc)" \
 && make install \
 && strip /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe \
 && /opt/ffmpeg/bin/ffmpeg -hide_banner -version | head -1 \
 && ! ldd /opt/ffmpeg/bin/ffmpeg 2>/dev/null | grep -q '=>'

# ---- Stage 2: runtime -------------------------------------------------------
FROM alpine:3.21

ARG BAZARR_VERSION

ENV TZ=UTC \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Runtime deps:
#   - ffmpeg/ffprobe: NOT from apk -- slim static build copied from stage 1
#   - 7zip: archive extraction (Bazarr requires unrar OR unar OR 7zip)
#   - python3 + py3-* C-extension deps (all from apk to share system libs)
#   - tzdata: timezone support
#   - curl/unzip: bootstrap only (purged at end of layer via .build-deps)
#
# NOTE: unrar omitted — not in Alpine main due to licensing. 7zip covers
#       the rar-archive case Bazarr cares about.
RUN apk add --no-cache \
        7zip \
        tzdata \
        ca-certificates \
        python3 \
        py3-lxml \
        py3-numpy \
        py3-pillow \
        su-exec \
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

# Slim static ffmpeg/ffprobe on PATH (bazarr finds binaries via PATH).
COPY --from=build-ffmpeg /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /usr/local/bin/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# NOTE: intentionally stays as root here -- entrypoint.sh drops to
# PUID:PGID (default 1000:1000) via su-exec at container start. See
# https://github.com/chefcai/bazarr-alpine/issues/1
WORKDIR /app

EXPOSE 6767

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "/app/bazarr.py", "--no-update", "--config", "/config"]
