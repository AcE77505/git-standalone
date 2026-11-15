#!/bin/sh
# ============================================================================
# build.sh - 构建单文件、完全静态的 ARM64 git（面向 Android / 通用 Linux）
#
# 产物：一个自包含的 `git` 可执行文件，在 Android 上开箱即用：
#   * DNS：c-ares 自包含解析 + 公共 DNS 兜底（不依赖 Android 解析器/resolv.conf）
#   * HTTPS 根证书：内嵌进二进制（不依赖 /etc/ssl/certs）
#   * git 子进程（index-pack / upload-pack / receive-pack / remote-http ...）
#     通过 /proc/self/exe 重执行自身（不依赖 PATH 里的系统 git）
#
# 宿主要求（aarch64 Linux）：
#   - musl-gcc        （Debian/Ubuntu: apt install musl-tools）
#   - wget 或 curl、tar、xz、make、gcc
#
# 用法：
#   ./build.sh              # 默认构建（WORKDIR=./work）
#   JOBS=8 ./build.sh       # 指定并行数
#   WORKDIR=/tmp/build ./build.sh
# 产物：$WORKDIR/git
# ============================================================================
set -e

: "${JOBS:=$(nproc)}"
: "${WORKDIR:=./work}"
case "$WORKDIR" in
	/*) ;;
	*) WORKDIR="$PWD/$WORKDIR" ;;
esac
: "${PREFIX:=$WORKDIR/prefix}"
: "${OUT:=$WORKDIR/git}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$WORKDIR/src
mkdir -p "$SRC" "$PREFIX"

# musl 编译需要的内核头文件搜索路径（追加在 musl 头之后，避免污染）
IDIRAFTER="-idirafter /usr/include/aarch64-linux-gnu -idirafter /usr/include -idirafter /usr/include/asm-generic"

# ---- 下载助手：url  sha256  out ----
dl() {
    url=$1; sha=$2; out=$3
    if [ ! -f "$out" ]; then
        echo "==> 下载 $url"
        (wget -q -O "$out" "$url" || curl -fsSL -o "$out" "$url") || { echo "下载失败: $url"; exit 1; }
    fi
    echo "$sha  $out" | sha256sum -c - >/dev/null || { echo "校验失败: $out"; exit 1; }
}

# ============================================================================
# 1. 下载全部源码（版本与校验和来自 SOURCES/README）
# ============================================================================
echo "==================== 1. 下载源码 ===================="
dl https://www.kernel.org/pub/software/scm/git/git-2.43.4.tar.xz \
   6b7aadda1787f0c1eaa257c1df56bb12e43d12bce55cfe7e5ade00228ee3d886 \
   "$SRC/git.tar.xz"
dl https://www.openssl.org/source/openssl-3.0.13.tar.gz \
   88525753f79d3bec27d2fa7c66aa0b92b3aa9498dafd93d7cfa4b3780cdae313 \
   "$SRC/openssl.tar.gz"
dl https://curl.se/download/curl-8.6.0.tar.gz \
   9c6db808160015f30f3c656c0dec125feb9dc00753596bf858a272b5dd8dc398 \
   "$SRC/curl.tar.gz"
dl https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.gz \
   889d16be5abb8d05400b33c25e151638b8d4bac0e2d9c76e9d6923118ae8a34e \
   "$SRC/pcre2.tar.gz"
dl https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz \
   17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c \
   "$SRC/zlib.tar.gz"
dl https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz \
   d4cf38d26e21a56654ffe4acd9cd5481164619626802328506a2869afab29ab3 \
   "$SRC/expat.tar.gz"
dl https://github.com/c-ares/c-ares/releases/download/cares-1_27_0/c-ares-1.27.0.tar.gz \
   0a72be66959955c43e2af2fbd03418e82a2bd5464604ec9a62147e37aceb420b \
   "$SRC/cares.tar.gz"

unpack() { # 压缩包  目录名
    tarball=$1; name=$2
    if [ ! -d "$SRC/$name" ]; then
        mkdir -p "$SRC/$name"
        tar xf "$SRC/$tarball" -C "$SRC/$name" --strip-components=1
    fi
}

# ============================================================================
# 2. 依次静态编译各依赖（全部使用 musl）
# ============================================================================
echo "==================== 2. 编译依赖 ===================="

echo "---- 2.1 zlib ----"
unpack zlib.tar.gz zlib-1.3.1
( cd "$SRC/zlib-1.3.1" && CC=musl-gcc ./configure --prefix="$PREFIX" --static >/dev/null \
  && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "---- 2.2 expat ----"
unpack expat.tar.gz expat-2.6.2
( cd "$SRC/expat-2.6.2" && CC=musl-gcc ./configure --prefix="$PREFIX" --disable-shared --enable-static >/dev/null \
  && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "---- 2.3 openssl ----"
unpack openssl.tar.gz openssl-3.0.13
( cd "$SRC/openssl-3.0.13" \
  && CC=musl-gcc ./config --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
       no-shared no-module no-tests no-legacy -static $IDIRAFTER >/dev/null \
  && make -j"$JOBS" >/dev/null && make install_sw >/dev/null )

echo "---- 2.4 pcre2 ----"
unpack pcre2.tar.gz pcre2-10.43
( cd "$SRC/pcre2-10.43" \
  && CC=musl-gcc ./configure --prefix="$PREFIX" --disable-shared --enable-static \
       --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 CPPFLAGS="$IDIRAFTER" >/dev/null \
  && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "---- 2.5 c-ares（应用 DNS 兜底补丁）----"
unpack cares.tar.gz c-ares-1.27.0
( cd "$SRC/c-ares-1.27.0" && patch -p1 -s < "$SCRIPT_DIR/patches/c-ares-1.27.0-dns.patch" )
( cd "$SRC/c-ares-1.27.0" && patch -p1 -s < "$SCRIPT_DIR/patches/c-ares-1.27.0-android-paths.patch" )
( cd "$SRC/c-ares-1.27.0" \
  && CC=musl-gcc ./configure --prefix="$PREFIX" --disable-shared --enable-static \
       CPPFLAGS="$IDIRAFTER -DCARES_ANDROID" >/dev/null \
  && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "---- 2.6 curl（启用 c-ares）----"
unpack curl.tar.gz curl-8.6.0
( cd "$SRC/curl-8.6.0" \
  && CC=musl-gcc ./configure --prefix="$PREFIX" \
       --disable-shared --enable-static \
       --enable-ares="$PREFIX" --with-ssl="$PREFIX" --with-zlib="$PREFIX" \
       --without-libidn2 --without-librtmp --without-brotli --without-nghttp2 \
       --without-libssh2 --without-gssapi --without-libpsl \
       --disable-ldap --disable-ldaps --disable-manual --disable-dict --disable-telnet \
       --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
       --disable-rtsp --disable-smb \
       --without-ca-bundle --with-ca-path=/system/etc/security/cacerts \
       CPPFLAGS="$IDIRAFTER" LDFLAGS="-static" >/dev/null \
  && make -j"$JOBS" -C lib LDFLAGS="-static" >/dev/null )
cp "$SRC/curl-8.6.0/lib/.libs/libcurl.a" "$PREFIX/lib/"
cp -r "$SRC/curl-8.6.0/include/curl" "$PREFIX/include/"

# 生成 curl-config（git 的 configure 探测 curl 需要）
cat > "$PREFIX/bin/curl-config" <<CFGEOF
#!/bin/sh
prefix="$PREFIX"
case "\$1" in
  --version)      echo "libcurl 8.6.0" ;;
  --vernum)       echo "080600" ;;
  --features)     echo "AsynchDNS HSTS HTTPS-proxy IPv6 Largefile NTLM SSL TLS-SRP UnixSockets alt-svc libz threadsafe" ;;
  --protocols)    echo "FILE FTP FTPS HTTP HTTPS IPFS IPNS MQTT" ;;
  --libs|--static-libs) echo "-L\${prefix}/lib -lcurl -lssl -lcrypto -lz -lcares" ;;
  --cflags)       echo "-DCURL_STATICLIB -I\${prefix}/include" ;;
  *)              echo "unknown option: \$1" >&2; exit 1 ;;
esac
CFGEOF
chmod +x "$PREFIX/bin/curl-config"

# ============================================================================
# 3. 编译单文件 git（应用全部单文件/安卓补丁）
# ============================================================================
echo "==================== 3. 编译 git ===================="
unpack git.tar.xz git-2.43.4
( cd "$SRC/git-2.43.4" && patch -p1 -s < "$SCRIPT_DIR/patches/git-2.43.4-android.patch" )
( cd "$SRC/git-2.43.4" && patch -p1 -s < "$SCRIPT_DIR/patches/git-2.43.4-portable-paths.patch" )
( cd "$SRC/git-2.43.4" \
  && PATH="$PREFIX/bin:$PATH" \
     CC=musl-gcc ./configure \
       --prefix="$PREFIX/git-install" \
       --sysconfdir="$PREFIX/git-install/etc" \
       --with-curl="$PREFIX" --with-expat="$PREFIX" \
       --with-libpcre2="$PREFIX" --with-zlib="$PREFIX" \
       --without-tcltk --without-python \
       CPPFLAGS="-I$PREFIX/include $IDIRAFTER" \
       LDFLAGS="-static -L$PREFIX/lib" \
       LIBS="-lssl -lcrypto -lz -lcares" >/dev/null \
  && PATH="$PREFIX/bin:$PATH" \
     make -j"$JOBS" RUNTIME_PREFIX=YesPlease PROCFS_EXECUTABLE_PATH=/proc/self/exe \
       gitexecdir=libexec/git-core template_dir=templates \
       ETC_GITCONFIG=etc/gitconfig ETC_GITATTRIBUTES=etc/gitattributes \
       NO_PERL=YesPlease NO_GETTEXT=YesPlease NO_PYTHON=YesPlease )

# 复制产物：单文件 git 必须命名为 git（或任何不以 git- 开头的名字）
cp "$SRC/git-2.43.4/git" "$OUT"
chmod +x "$OUT"

echo "====================================================="
echo "构建完成：$OUT"
echo "  $(ls -lh "$OUT" | awk '{print $5}')  完全静态，单文件"
echo "  用法：cp $OUT /你的路径/git && cd /你的路径 && ./git ..."
echo "====================================================="
