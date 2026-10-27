#!/usr/bin/env bash
# 下载 Linux 6.6 源码作为搜索语料（约 140 MB 压缩包，解压后约 1.5 GB）。
source "$(dirname "$0")/env.sh"

URL="${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel}/v6.x/linux-6.6.tar.xz"
SHA256="d926a06c63dd8ac7df3f86ee1ffc2ce2a3b81a2d168484e76b5b389aba8e56d0"
TARBALL="$WORK_DIR/linux-6.6.tar.xz"

[ -d "$CORPUS" ] && { echo "语料已存在：$CORPUS"; exit 0; }
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "$URL"
echo "$SHA256  $TARBALL" | sha256sum -c -
tar -xf "$TARBALL" -C "$WORK_DIR"
echo "语料就绪：$CORPUS"
