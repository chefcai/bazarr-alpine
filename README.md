# bazarr-alpine

A footprint-minimized Docker image for [Bazarr](https://github.com/morpheus65535/bazarr),
built on Alpine Linux in GitHub Actions and published to `ghcr.io`.

## Image

```
ghcr.io/chefcai/bazarr-alpine:latest
ghcr.io/chefcai/bazarr-alpine:<bazarr-release>   # e.g., v1.6.0
```

Builds dispatched from a non-`main` branch (`gh workflow run build.yml --ref <branch>`)
publish only `:branch-<branch-name>`; `:latest` and the version tag are published from `main` only.

## How the image is built

1. **`build-ffmpeg` stage** (`alpine:3.21`): static ffmpeg/ffprobe 7.1 built with
   `--disable-everything` plus only what Bazarr uses (table below).
2. **Runtime** (`alpine:3.21`): system `python3` with apk-packaged C extensions
   (`py3-lxml`, `py3-numpy`, `py3-pillow`), `7zip`, `tzdata`, `su-exec`; the
   Bazarr release zip; `webrtcvad-wheels` via pip; `__pycache__`, bundled test
   suites and IDLE stripped. The two static ffmpeg binaries go to `/usr/local/bin`.
3. `entrypoint.sh` remaps the `bazarr` user to `PUID`/`PGID` (default 1000:1000)
   and drops privileges with `su-exec`.

### Slim ffmpeg: what is enabled and why

Alpine's apk `ffmpeg` hard-links every video codec library (x264, x265, aom,
SVT-AV1, rav1e, dav1d, vpx, vulkan, libplacebo, …). Bazarr never decodes video:

| Bazarr feature | ffmpeg components |
|---|---|
| Stream detection (knowit / fese → `ffprobe`) | demuxers matroska, mov, avi, mpegts, mpegps, ogg, flv, asf + common audio; video *parsers* only (h264, hevc, av1, vp9, mpeg4, mpeg2) |
| Embedded subtitle extraction (fese) | decoders/encoders subrip, srt, ass, ssa, webvtt, mov_text, text; muxers srt, ass, webvtt, sup (PGS copy) |
| Subtitle sync (ffsubsync) | audio decoders aac, ac3, eac3, dts, truehd, flac, opus, vorbis, mp3, alac, wma, pcm; `pcm_s16le` encoder; `s16le`/`wav`/`matroska` muxers; `aresample` filter |

Network protocols are disabled (`--disable-network`); Bazarr only passes local
file paths. To add a codec, append it to the relevant `--enable-*` list in the
`build-ffmpeg` stage.

### Size

| Build | On-disk | Compressed |
|---|---:|---:|
| apk `ffmpeg` | 330 MB | 86.5 MB |
| slim static ffmpeg/ffprobe | 222 MB | 69.3 MB |
