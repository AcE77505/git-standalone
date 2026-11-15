# git-standalone

在 **Android / 通用 Linux** 上可直接运行的 **单文件、完全静态** ARM64 git（git 2.43.4）。

一个 `git` 可执行文件，拷到任何目录直接 `./git clone ...` 即可用：
不依赖 Android 的 DNS 解析器、不依赖系统 CA 证书、不依赖 PATH 里的任何 git。

---

## 为什么需要这些修改？

普通的静态 git 在 Android 上会遇到 4 个典型问题（都是因为静态二进制
不能依赖 Android 的私有机制，又缺少 Linux 上常见的文件）：

| # | 报错 | 根因 | 本仓库的修复 |
|---|------|------|--------------|
| 1 | `Could not resolve host: github.com` | 解析器读 `/etc/resolv.conf`，Android 不维护该文件；NSS 模块也无法静态加载 | **c-ares** 自包含 DNS 解析 + 公共 DNS 兜底 |
| 2 | `error setting certificate file: /etc/ssl/certs/ca-certificates.crt` | Android 没有该路径 | **146 个 CA 根证书内嵌进二进制** |
| 3 | `cannot run index-pack: No such file or directory` | git 派生子进程时去 PATH 找 `git`，Android 没有 | 子进程通过 **`/proc/self/exe` 重执行自身** |
| 4 | `unable to find remote helper for 'https'` | 远程助手 `git-remote-http` 是独立文件 | 把 **remote-curl 编译进主 git 内置命令** |

---

## 目录结构

```
git-standalone/
├── build.sh                    # 一键构建脚本（下载→编译→出产物）
├── README.md
├── patches/
│   ├── git-2.43.4-android.patch            # git 的 11 处单文件修改
│   ├── git-2.43.4-portable-paths.patch     # 去除构建机/Linux 固定路径
│   ├── c-ares-1.27.0-dns.patch             # DNS 兜底
│   └── c-ares-1.27.0-android-paths.patch   # 不再读取 /etc/resolv.conf
└── ...
```

---

## 修改说明

### 1. git（patches/git-2.43.4-android.patch，11 个文件）

| 文件 | 修改内容 |
|------|----------|
| `git.c` | 注册 `remote-http/-https/-ftp/-ftps` 为内置命令 |
| `builtin.h` | 声明 `cmd_remote_http()` |
| `builtin/remote-curl.c`（新增） | 复用 remote-curl 实现，编进主 git 当内置助手 |
| `Makefile` | 主 git 链入 remote-curl/http/http-walker，补 `CURL_LIBCURL` |
| `transport-helper.c` | 远程助手改为 exec `/proc/self/exe`（`git_cmd=0`） |
| `setup.c` | 静默模板缺失告警（单文件无模板目录） |
| `http.c` | 新增 `http.dnsServers` 配置→`CURLOPT_DNS_SERVERS`；内嵌 CA→`CURLOPT_CAINFO_BLOB` |
| `git-curl-compat.h` | 新增 `GIT_CURL_HAVE_CURLOPT_CAINFO_BLOB` 版本宏 |
| `cacert.h`（新增，生成） | 内嵌 146 个 CA 根证书 |
| `run-command.c` | git_cmd 子进程（index-pack 等）改 exec `/proc/self/exe` |
| `exec-cmd.c` | `git -c` 重执行也走 `/proc/self/exe` |
| `connect.c` | 本地传输改 git_cmd 派发（修本地 clone/push 的 upload-pack/receive-pack） |

### 2. c-ares（patches/c-ares-1.27.0-dns.patch，1 个文件）

| 文件 | 修改内容 |
|------|----------|
| `src/lib/ares_init.c` | 当 `/etc/resolv.conf` **为空或只有回环地址**时，自动兜底到公共 DNS：`114.114.114.114`、`223.5.5.5`、`119.29.29.29`、`8.8.8.8`、`1.1.1.1`（新增 `ares__servers_only_loopback()` 检测） |

### 3. 便携路径补丁（patches/git-2.43.4-portable-paths.patch、patches/c-ares-1.27.0-android-paths.patch）

| 文件 | 修改内容 |
|------|----------|
| `exec-cmd.c` | `RUNTIME_PREFIX` 计算失败时使用可执行文件所在目录，不再回退到构建机路径 |
| `config.c` | `HOME` 缺失或不可写时，全局配置写到 `<git目录>/gitconfig` |
| `run-command.c` / `run-command.h` / `help.c` / `builtin/help.c` | 运行时优先 `/system/bin/sh`，否则回退到编译时的 `SHELL_PATH` |
| `builtin/difftool.c` | `TMPDIR` 未设置且 `/tmp` 不可用时使用 `/data/local/tmp` |
| `ares_private.h`（c-ares） | `CARES_ANDROID` 下不再读取 `/etc/resolv.conf`，改用 `/system/settings/network/resolv.conf`，不存在时走内置公共 DNS 兜底 |
| `build.sh` | `--sysconfdir=etc`、`template_dir=templates`、`NO_PERL`/`NO_GETTEXT`/`NO_PYTHON`、curl `--without-ca-bundle --with-ca-path=/system/etc/security/cacerts`、c-ares `-DCARES_ANDROID` |

资源路径现在都相对可执行文件目录：系统配置为 `<git目录>/etc/gitconfig`，全局配置为 `<git目录>/gitconfig`，`git --exec-path` 为 `<git目录>/libexec/git-core`（单文件不要求该目录存在，内置命令不依赖它）。

仍然保留的 libc/musl 路径都是失败可恢复、不影响 git 核心的：`/etc/passwd`（git 会回退为 `unknown`）、`/etc/services`（只影响命名端口）、`/etc/nsswitch.conf`、`/var/run/nscd`、`/usr/share/zoneinfo`（可用 `TZ=:/system/usr/share/zoneinfo/Asia/Shanghai` 指定 Android 时区文件）。

### 4. 未修改源码、仅改编译参数的依赖
`curl`（`--enable-ares`）、`openssl`（`no-shared no-module no-legacy -static`）、
`zlib`、`expat`、`pcre2` —— 这 5 个都是原版源码，只做 musl 静态编译。

---

## 如何编译

### 前置条件（aarch64 Linux 宿主机）
- `musl-gcc`（Debian/Ubuntu：`apt install musl-tools`）
- `wget` 或 `curl`、`tar`、`xz`、`make`、`gcc`

### 一键构建
```sh
git clone <你的仓库地址>
cd git-standalone
./build.sh                 # 产物在 ./work/git
# 或指定并行数与工作目录
JOBS=8 WORKDIR=/tmp/build ./build.sh
```

脚本会自动：下载全部源码（并校验 SHA256）→ 用 musl 依次静态编译
zlib/expat/openssl/pcre2/c-ares/curl → 打补丁 → 编译单文件 git → 输出 `./work/git`。

### 产物使用
```sh
cp work/git /你的路径/git
cd /你的路径 && ./git clone https://github.com/你的仓库/xxx.git
```
> 注意：单文件必须命名为 `git`（或任何**不以 `git-` 开头**的名字），
> 否则 git 会把文件名当成子命令去派发。

---

## 源码版本与地址

| 组件 | 版本 | 下载地址 |
|------|------|----------|
| git | 2.43.4 | https://www.kernel.org/pub/software/scm/git/git-2.43.4.tar.xz |
| openssl | 3.0.13 | https://www.openssl.org/source/openssl-3.0.13.tar.gz |
| curl | 8.6.0 | https://curl.se/download/curl-8.6.0.tar.gz |
| pcre2 | 10.43 | https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.gz |
| zlib | 1.3.1 | https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz |
| expat | 2.6.2 | https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz |
| c-ares | 1.27.0 | https://github.com/c-ares/c-ares/releases/download/cares-1_27_0/c-ares-1.27.0.tar.gz |

所有 SHA256 校验和已在 `build.sh` 内校验（下载源均来自官方）。

---

## 可选配置

### 自定义 DNS 服务器
万一公共 DNS 在你的网络不可达，可指定：
```sh
./git config --global http.dnsServers "114.114.114.114 223.5.5.5"
./git config --global --unset http.dnsServers   # 清除，回到自动兜底
```

### 自定义 CA 证书（如公司内网）
```sh
./git config --global http.sslcainfo /path/to/your-ca.pem
```

---

## 已知限制 / 说明
- 单文件版**不带模板目录**（`git init` 正常，但无 hooks 示例）和 perl 脚本
  （`git svn` / `git send-email` 等不可用）——这是单文件的取舍。
- `/proc/self/exe` 重执行是 **Linux 专属**机制（Android 内核同样支持）。
- 若目标是 macOS / BSD，需改用 `_NSGetExecutablePath` / `sysctl` 方案。
- 当前为 **arm64** 原生编译；其他架构需相应调整工具链。
