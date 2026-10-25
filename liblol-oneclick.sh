#!/bin/bash
# =============================================================================
# liblol-oneclick.sh — 一键构建并打包 liblol 为 Arch Linux 安装包
#
# 流程: 同步上游仓库 -> 解析 spec -> 下载源码(镜像加速+sha256校验) ->
#       模拟 AOSC Autobuild3 环境原生构建 -> makepkg 打包 -> pkg.tar.zst
#
# 用法:
#   ./liblol-oneclick.sh                  # 完整流程
#   ./liblol-oneclick.sh --force          # 忽略"上游无变化"缓存, 强制重建
#   ./liblol-oneclick.sh --no-package     # 只构建, 不打包
#   ./liblol-oneclick.sh --clean          # 打包成功后删除构建目录 bld/ (省磁盘)
#   ./liblol-oneclick.sh --jobs 8         # 并行度 (默认 nproc)
#   ./liblol-oneclick.sh --workdir DIR    # 工作目录 (默认 <脚本目录>/liblol-build)
#   ./liblol-oneclick.sh --help
#
# 可选环境变量:
#   REPO_URL   上游仓库      (默认 https://github.com/AOSC-Dev/liblol.git)
#   GH_PROXY   下载加速前缀  (默认 https://gh-proxy.com)
#   PKGREL     包发布号      (默认 1)
#   PACKAGER  打包者署名     (默认 "liblol-oneclick <noreply@localhost>")
#   JOBS / FORCE=1 / NO_PACKAGE=1 / CLEAN=1 / WORKDIR  (与参数等价)
#
# 产物:
#   $WORKDIR/pkg.tar.zst                                <- 一键包 (本脚本默认输出名)
#   $WORKDIR/pkgbuild/liblol-<ver>-<rel>-<arch>.pkg.tar.zst  <- 规范包名
# 安装:
#   sudo pacman -U pkg.tar.zst
# 日志:
#   $WORKDIR/oneclick.log
#
# 说明: 本机 locale 若为 UTF-8 (如 zh_CN.UTF-8), 上游 ABI 校验的裸 sort/comm
#       会误报"没有被正确排序"; 脚本内部强制 LC_ALL=C (与 AOSC 构建环境一致)。
# =============================================================================
set -euo pipefail

# ------------------------------ 参数解析 ------------------------------
FORCE="${FORCE:-0}"; NO_PACKAGE="${NO_PACKAGE:-0}"; CLEAN="${CLEAN:-0}"
JOBS="${JOBS:-}"; WORKDIR="${WORKDIR:-}"
usage() {
    cat <<'EOF'
liblol-oneclick.sh — 一键构建并打包 liblol 为 Arch Linux 安装包

用法:
  ./liblol-oneclick.sh                  # 完整流程: 同步上游->下载校验->构建->打包
  ./liblol-oneclick.sh --force          # 忽略"上游无变化"缓存, 强制重建
  ./liblol-oneclick.sh --no-package     # 只构建, 不打包
  ./liblol-oneclick.sh --clean          # 打包成功后删除构建目录 bld/ (省磁盘)
  ./liblol-oneclick.sh --jobs 8         # 并行度 (默认 nproc)
  ./liblol-oneclick.sh --workdir DIR    # 工作目录 (默认 <脚本目录>/liblol-build)
  ./liblol-oneclick.sh --help           # 显示本帮助

可选环境变量:
  REPO_URL   上游仓库      (默认 https://github.com/AOSC-Dev/liblol.git)
  GH_PROXY   下载加速前缀  (默认 https://gh-proxy.com)
  PKGREL     包发布号      (默认 1)
  PACKAGER  打包者署名     (默认 "liblol-oneclick <noreply@localhost>")
  JOBS / FORCE=1 / NO_PACKAGE=1 / CLEAN=1 / WORKDIR   (与命令行参数等价)

产物:
  $WORKDIR/pkg.tar.zst                                      一键包
  $WORKDIR/pkgbuild/liblol-<ver>-<rel>-<arch>.pkg.tar.zst  规范包名
安装: sudo pacman -U pkg.tar.zst
日志: $WORKDIR/oneclick.log
EOF
}
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)     FORCE=1 ;;
        --no-package)   NO_PACKAGE=1 ;;
        --clean)        CLEAN=1 ;;
        --jobs)         JOBS="${2:?--jobs 需要参数}"; shift ;;
        --jobs=*)       JOBS="${1#*=}" ;;
        --workdir)      WORKDIR="${2:?--workdir 需要参数}"; shift ;;
        --workdir=*)    WORKDIR="${1#*=}" ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "未知参数: $1 (--help 查看用法)" >&2; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/liblol-build}"
case "$WORKDIR" in ""|"/") echo "拒绝使用 WORKDIR='$WORKDIR'" >&2; exit 1 ;; esac

REPO_URL="${REPO_URL:-https://github.com/AOSC-Dev/liblol.git}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.com}"
GNU_MIRRORS="${GNU_MIRRORS:-mirrors.aliyun.com mirrors.ustc.edu.cn mirrors.tuna.tsinghua.edu.cn mirrors.nju.edu.cn}"
PKGREL="${PKGREL:-1}"
PACKAGER="${PACKAGER:-liblol-oneclick <noreply@localhost>}"
JOBS="${JOBS:-$(nproc)}"

REPODIR="$WORKDIR/$(basename "$REPO_URL" .git)"
SRCDIR="$WORKDIR/src"
BLDDIR="$WORKDIR/bld"
PKGDIR="$WORKDIR/pkg"
PKGBUILDDIR="$WORKDIR/pkgbuild"
LOG="$WORKDIR/oneclick.log"

mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG") 2>&1

info() { echo "[oneclick $(date +%H:%M:%S)] $*"; }
warn() { echo "[oneclick $(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[oneclick $(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }
phase() { echo; echo "========== [$1/$2] $3 =========="; }

# ------------------------------ 1. 预检 ------------------------------
preflight() {
    local missing="" c
    for c in git curl gcc g++ make patch bsdtar zstd makepkg pacman \
             sha256sum awk sed grep find xargs du df mktemp; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || die "缺少命令:$missing — Arch 请先安装: sudo pacman -S base-devel"
    local avail_kb
    avail_kb=$(df -Pk "$WORKDIR" | awk 'NR==2{print $4}')
    if [ "$avail_kb" -lt 4194304 ]; then
        warn "磁盘可用空间 $((avail_kb/1024))MB (<4GB), glibc 构建可能失败"
    fi
    if [ "$(id -u)" = 0 ]; then
        die "请不要以 root 运行 (makepkg 拒绝 root); 用普通用户执行"
    fi
    info "并行度=$JOBS  工作目录=$WORKDIR  日志=$LOG"
}

# ------------------------------ 2. 同步上游 ------------------------------
sync_repo() {
    if [ -d "$REPODIR/.git" ]; then
        info "更新已有克隆: $REPODIR"
        if git -C "$REPODIR" pull --ff-only --depth 1 >/dev/null 2>&1; then
            info "git pull 成功"
        else
            warn "经 $(git -C "$REPODIR" remote get-url origin 2>/dev/null || echo '?') 更新失败, 改用 GitHub 直连重试"
            git -C "$REPODIR" remote set-url origin "$REPO_URL" >/dev/null 2>&1 || true
            if git -C "$REPODIR" pull --ff-only --depth 1 >/dev/null 2>&1; then
                info "git pull 成功 (直连)"
            else
                warn "更新失败, 继续使用现有检出"
            fi
        fi
    elif [ -e "$REPODIR" ]; then
        die "$REPODIR 已存在但不是 git 仓库 — 请移除该目录或换 --workdir"
    else
        info "经 gh-proxy 克隆 $REPO_URL ..."
        if ! git clone --depth 1 "$GH_PROXY/$REPO_URL" "$REPODIR" >/dev/null 2>&1; then
            warn "gh-proxy 克隆失败, 改用 GitHub 直连"
            git clone --depth 1 "$REPO_URL" "$REPODIR" >/dev/null 2>&1 \
                || die "克隆失败: $REPO_URL"
        fi
        info "克隆完成"
    fi
    HEAD_SHA=$(git -C "$REPODIR" rev-parse HEAD 2>/dev/null || echo unknown)
    info "上游 HEAD = $HEAD_SHA"
}

# ------------------------------ 3. 解析元数据 ------------------------------
parse_meta() {
    local spec="$REPODIR/spec" defines="$REPODIR/autobuild/defines"
    local build="$REPODIR/autobuild/build"
    [ -f "$spec" ]   || die "找不到 $spec"
    [ -f "$defines" ] || die "找不到 $defines"
    [ -f "$build" ]  || die "找不到 $build"

    # spec 是纯变量文件: 子 shell 中 source, 用 printf %q 输出"纯赋值语句"再 eval。
    # (不能用 declare -p — declare 在函数内会创建局部变量, 函数返回即丢失!)
    eval "$( source "$spec" >/dev/null 2>&1
             printf 'VER=%q\n'         "${VER-}"
             printf '__GLIBC_VER=%q\n'  "${__GLIBC_VER-}"
             printf '__LIBXCRYPT_VER=%q\n' "${__LIBXCRYPT_VER-}"
             printf 'SRCS=%q\n'        "${SRCS-}"
             printf 'CHKSUMS=%q\n'     "${CHKSUMS-}" )"
    : "${VER:?spec 缺少 VER}"
    : "${__GLIBC_VER:?spec 缺少 __GLIBC_VER}"
    : "${SRCS:?spec 缺少 SRCS}"
    : "${CHKSUMS:?spec 缺少 CHKSUMS}"

    eval "$( source "$defines" >/dev/null 2>&1
             printf 'PKGNAME=%q\n' "${PKGNAME-}"
             printf 'PKGDES=%q\n'  "${PKGDES-}" )"
    PKGNAME="${PKGNAME:-liblol}"
    PKGDES="${PKGDES:-Old World LoongArch compatibility layer}"

    # 上游 build 脚本内嵌的三元组与前缀
    OWTARGET=$(grep -oE '^OWTARGET="[^"]+"'    "$build" | head -1 | cut -d'"' -f2)
    LOLPREFIX=$(grep -oE '^LOLPREFIX="[^"]+"'  "$build" | head -1 | cut -d'"' -f2)
    OWTARGET="${OWTARGET:-loongarch64-aosc-linux-gnuow}"
    LOLPREFIX="${LOLPREFIX:-/opt/lol}"

    # glibc 依赖下限 (build 脚本 PKGDEP 行中硬编码)
    GLIBC_FLOOR=$(grep -oE 'glibc>=\$\{cur_glibc_epoch\}[0-9]+(\.[0-9]+)*' "$build" \
                  | grep -oE '[0-9]+(\.[0-9]+)*$' | head -1)
    GLIBC_FLOOR="${GLIBC_FLOOR:-2.36}"

    # 本机 makepkg 架构 (Arch loongarch64 移植版为 loong64)
    PKG_ARCH=$(awk -F'"' '/^CARCH=/{print $2}' /etc/makepkg.conf 2>/dev/null || true)
    PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
    PKG_FILE="$PKGBUILDDIR/$PKGNAME-$VER-$PKGREL-$PKG_ARCH.pkg.tar.zst"

    info "包: $PKGNAME $VER-$PKGREL ($PKG_ARCH)"
    info "组件版本: glibc=$__GLIBC_VER  libxcrypt=$__LIBXCRYPT_VER"
    info "三元组: $OWTARGET   前缀: $LOLPREFIX   依赖: glibc>=$GLIBC_FLOOR, glibc<${__GLIBC_VER}.1"
}

# ------------------------------ 4. 状态检查 + 下载 ------------------------------
check_state_and_download() {
    SPEC_HASH=$(sha256sum "$REPODIR/spec" | cut -d' ' -f1)
    AUTOBUILD_HASH=$( cd "$REPODIR/autobuild" && \
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum \
        | sha256sum | cut -d' ' -f1 )
    local state_file="$WORKDIR/.oneclick-state"

    if [ "$FORCE" != 1 ] && [ -f "$state_file" ] && [ -f "$PKG_FILE" ]; then
        if grep -qx "HEAD=$HEAD_SHA"     "$state_file" && \
           grep -qx "SPEC=$SPEC_HASH"    "$state_file" && \
           grep -qx "AUTOBUILD=$AUTOBUILD_HASH" "$state_file"; then
            info "上游无变化 (HEAD/Spec/autobuild 与上次构建一致) 且包已存在 — 跳过构建"
            cp -f "$PKG_FILE" "$WORKDIR/pkg.tar.zst"
            info "使用现有包: $WORKDIR/pkg.tar.zst  (--force 可强制重建)"
            exit 0
        fi
    fi
    info "需要构建 (首次运行 / 上游有更新 / --force)"

    # SRCS / CHKSUMS -> 数组, 逐一下载校验
    local -a src_arr=() chk_arr=()
    local s
    for s in $SRCS; do src_arr+=("$s"); done
    read -ra chk_arr <<< "$CHKSUMS"
    [ "${#src_arr[@]}" -eq "${#chk_arr[@]}" ] \
        || die "SRCS(${#src_arr[@]}) 与 CHKSUMS(${#chk_arr[@]}) 数量不一致"

    mkdir -p "$SRCDIR"
    local i=0 e name url want
    while [ "$i" -lt "${#src_arr[@]}" ]; do
        s="${src_arr[$i]}"
        case "$s" in
            file::*) ;;
            *) die "不支持的源类型 (仅处理 file::): $s" ;;
        esac
        e="${s#file::}"
        name="${e%%::*}"; name="${name#rename=}"
        url="${e#*::}"
        want="${chk_arr[$i]#sha256::}"
        fetch_source "$name" "$url" "$want"
        i=$((i+1))
    done
}

# 下载单个源码: 多镜像候选 + sha256 校验, 任一候选校验通过即采用
fetch_source() {
    local name="$1" url="$2" want="$3"
    local dest="$SRCDIR/$name"

    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
        info "[$name] 使用已缓存文件 (sha256 校验通过)"
        return 0
    fi

    local base stem pkg c
    base="${url%%\?*}"; base="${base##*/}"        # glibc-2.44.tar.xz
    stem="$base"
    case "$stem" in
        *.tar.xz)  stem="${stem%.tar.xz}" ;;
        *.tar.gz)  stem="${stem%.tar.gz}" ;;
        *.tar.bz2) stem="${stem%.tar.bz2}" ;;
        *.tar.zst) stem="${stem%.tar.zst}" ;;
    esac
    pkg="$stem"
    [ "$stem" != "$base" ] && pkg="${stem%-*}"    # glibc-2.44 -> glibc

    local -a cands=()
    # GitHub 资源优先走 gh-proxy 加速
    case "$url" in *github.com*) cands+=("$GH_PROXY/$url") ;; esac
    # GNU 上游 tarball 走国内镜像 (与 AOSC repack 通常字节一致; 不一致则由 sha256 拦截)
    if [ "$stem" != "$base" ]; then
        for m in $GNU_MIRRORS; do cands+=("https://$m/gnu/$pkg/$base"); done
    fi
    cands+=("$url")

    info "[$name] 开始下载 (期望 sha256=${want:0:16}...)"
    for c in "${cands[@]}"; do
        info "[$name] 尝试: $c"
        if curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 2 \
                --speed-limit 1024 --speed-time 60 -o "$dest.tmp" "$c" 2>/dev/null; then
            if [ "$(sha256sum "$dest.tmp" | cut -d' ' -f1)" = "$want" ]; then
                mv -f "$dest.tmp" "$dest"
                info "[$name] 下载并校验通过 ($(du -h "$dest" | cut -f1))"
                return 0
            fi
            warn "[$name] 校验失败 (镜像内容与 spec 不一致), 尝试下一个源"
            rm -f "$dest.tmp"
        else
            rm -f "$dest.tmp"
        fi
    done
    die "[$name] 所有镜像均下载失败: $url"
}

# ------------------------------ 5. 构建环境 ------------------------------
setup_env() {
    # autobuild 树复制进 SRCDIR (上游脚本从 $SRCDIR/autobuild 打补丁/读文件)
    rm -rf "$SRCDIR/autobuild"
    mkdir -p "$SRCDIR/autobuild"
    cp -a "$REPODIR/autobuild/." "$SRCDIR/autobuild/"

    # 同架构"交叉"三元组: loongarch64-aosc-linux-gnuow-* -> 原生工具链
    rm -rf "$WORKDIR/toolchain-bin"
    mkdir -p "$WORKDIR/toolchain-bin"
    local t
    for t in gcc g++ cc c++ ar as ld ld.bfd ld.gold nm objcopy objdump \
             ranlib readelf strip gcc-ar gcc-nm gcc-ranlib; do
        [ -e "/usr/bin/$t" ] && ln -sf "/usr/bin/$t" "$WORKDIR/toolchain-bin/$OWTARGET-$t"
    done
    info "工具链 shim: $OWTARGET-* -> 原生 ($(ls "$WORKDIR/toolchain-bin" | wc -l) 个)"

    # config.sub 接受性预检
    local cs=/usr/share/autoconf/build-aux/config.sub
    if [ -x "$cs" ]; then
        "$cs" "$OWTARGET" >/dev/null 2>&1 \
            || die "config.sub 拒绝三元组 $OWTARGET — 请检查 autobuild/build 的 OWTARGET"
        info "config.sub 接受三元组 $OWTARGET"
    fi
}

# ------------------------------ 6. 构建 ------------------------------
run_build() {
    rm -rf "$BLDDIR" "$PKGDIR"
    mkdir -p "$BLDDIR" "$PKGDIR"

    # ---- 模拟 AOSC Autobuild3 环境 ----
    export SRCDIR BLDDIR PKGDIR
    export PKGVER="$VER"
    export PKGREL="$PKGREL"
    export __GLIBC_VER __LIBXCRYPT_VER
    export PATH="$WORKDIR/toolchain-bin:$PATH"
    export MAKEFLAGS="-j$JOBS"
    export CPPFLAGS=""
    export LC_ALL=C            # AOSC 构建环境为 C locale (否则 ABI 校验误失败)
    export TERM="${TERM:-xterm}"

    abinfo() { echo "[liblol $(date +%H:%M:%S)] $*"; }
    abdie()  { echo "[liblol $(date +%H:%M:%S)] FATAL: $*" >&2; exit 1; }

    # Arch 无 dpkg: 用 pacman 读取版本 (仅用于记录依赖区间)
    dpkg-query() {
        case "$*" in
            *glibc*)     pacman -Q glibc     2>/dev/null | awk '{print $2}' ;;
            *libxcrypt*) pacman -Q libxcrypt 2>/dev/null | awk '{print $2}' ;;
        esac
    }
    PKGDEP=""   # Debian 语义, 仅信息记录
    PKGBREAK=""

    abinfo "SRCDIR=$SRCDIR  BLDDIR=$BLDDIR  PKGDIR=$PKGDIR  JOBS=$JOBS"
    info "开始执行上游 autobuild/build (glibc 全量编译约 10-20 分钟) ..."
    source "$SRCDIR/autobuild/build"
    abinfo "构建完成 — 暂存树 $PKGDIR ($(du -sh "$PKGDIR" | cut -f1))"

    # 快速自检: 暂存树必须有 loader 与 libc
    [ -f "$PKGDIR$LOLPREFIX/support/lib/$OWTARGET/ld.so.1" ] \
        || die "构建产物缺失: $LOLPREFIX/support/lib/$OWTARGET/ld.so.1"
    [ -f "$PKGDIR$LOLPREFIX/support/lib/$OWTARGET/libc.so.6" ] \
        || die "构建产物缺失: $LOLPREFIX/support/lib/$OWTARGET/libc.so.6"
}

# ------------------------------ 7. 打包 ------------------------------
do_package() {
    rm -rf "$PKGBUILDDIR"
    mkdir -p "$PKGBUILDDIR"

    # license 探测
    local lic="custom"
    if [ -f "$REPODIR/LICENSE" ]; then
        if grep -q "Version 3" "$REPODIR/LICENSE"; then lic="GPL-3.0-only"
        elif grep -q "Version 2" "$REPODIR/LICENSE"; then lic="GPL-2.0-only"
        fi
    fi

    {
        echo "# 由 liblol-oneclick.sh 自动生成 — $(date -R)"
        echo "pkgname=$PKGNAME"
        echo "pkgver=$VER"
        echo "pkgrel=$PKGREL"
        printf 'pkgdesc=%q\n' "$PKGDES"
        echo "arch=('$PKG_ARCH')"
        echo "url=${REPO_URL%.git}"
        echo "license=('$lic')"
        echo "# 依赖区间镜像 autobuild/build 内 PKGDEP 的计算结果"
        echo "depends=('glibc>=$GLIBC_FLOOR' 'glibc<${__GLIBC_VER}.1')"
        echo "provides=('$PKGNAME')"
        echo "options=('!strip' 'staticlibs' '!lto' '!debug')"
        echo "source=()"
        echo "package() {"
        echo "    cp -a \"$PKGDIR/.\" \"\$pkgdir/\""
        echo "    # ABBS 的 overrides/ 树 (上游框架负责安装, 此处手动补上)"
        echo "    if [ -d \"$REPODIR/autobuild/overrides\" ]; then"
        echo "        cp -a \"$REPODIR/autobuild/overrides/.\" \"\$pkgdir/\""
        echo "    fi"
        echo "    install -Dm644 \"$REPODIR/LICENSE\" \"\$pkgdir/usr/share/licenses/$PKGNAME/LICENSE\" || true"
        echo "}"
    } > "$PKGBUILDDIR/PKGBUILD"
    info "已生成 PKGBUILD: $PKGBUILDDIR/PKGBUILD"

    ( cd "$PKGBUILDDIR" && LC_ALL=C PACKAGER="$PACKAGER" makepkg --nocheck -f )
    [ -f "$PKG_FILE" ] || die "makepkg 未生成预期的包: $PKG_FILE"
    cp -f "$PKG_FILE" "$WORKDIR/pkg.tar.zst"
    info "打包完成:"
    info "  $PKG_FILE"
    info "  $WORKDIR/pkg.tar.zst"
}

# ------------------------------ 8. 验证与总结 ------------------------------
verify_and_summarize() {
    info "pacman 元数据:"
    pacman -Qip "$WORKDIR/pkg.tar.zst" 2>/dev/null | sed 's/^/    /'

    # 冒烟测试: 解包直接运行包内旧世界 loader
    local tmpv loader
    tmpv=$(mktemp -d)
    bsdtar -xf "$WORKDIR/pkg.tar.zst" -C "$tmpv"
    loader="$tmpv$LOLPREFIX/support/lib/$OWTARGET/ld.so.1"
    if [ -x "$loader" ]; then
        info "冒烟测试 (包内 loader): $("$loader" --version 2>&1 | head -1)"
    else
        warn "包内未找到可执行 loader: $loader"
    fi
    rm -rf "$tmpv"

    cat <<SUMMARY

------------------------------------------------------------
  构建打包完成 ✔
  安装包 : $WORKDIR/pkg.tar.zst
  大小   : $(du -h "$WORKDIR/pkg.tar.zst" | cut -f1)
  sha256 : $(sha256sum "$WORKDIR/pkg.tar.zst" | cut -d' ' -f1)
  安装   : sudo pacman -U $WORKDIR/pkg.tar.zst
  卸载   : sudo pacman -R $PKGNAME
  注意   : 运行旧世界程序还需 la_ow_syscall 内核模块
          (dkms + linux-headers, 见 INSTALL-arch.md 第 4 节)
------------------------------------------------------------
SUMMARY
}

write_state() {
    [ "$NO_PACKAGE" = 1 ] && return 0
    printf 'HEAD=%s\nSPEC=%s\nAUTOBUILD=%s\nPKG=%s\nDATE=%s\n' \
        "$HEAD_SHA" "$SPEC_HASH" "$AUTOBUILD_HASH" "$PKG_FILE" "$(date -R)" \
        > "$WORKDIR/.oneclick-state"
}

# ------------------------------ main ------------------------------
phase 1 8 "环境预检";                  preflight
phase 2 8 "同步上游仓库";              sync_repo
phase 3 8 "解析 spec / defines";       parse_meta
phase 4 8 "检查变更 / 下载源码";       check_state_and_download
phase 5 8 "配置构建环境";              setup_env
phase 6 8 "构建 liblol";               run_build
if [ "$NO_PACKAGE" = 1 ]; then
    info "按 --no-package 参数跳过打包"
else
    phase 7 8 "打包 Arch 安装包";       do_package
    phase 8 8 "验证与总结";             verify_and_summarize
fi
write_state
if [ "$CLEAN" = 1 ]; then
    rm -rf "$BLDDIR"
    info "--clean: 已删除 $BLDDIR"
fi
info "全部完成 ✔  日志: $LOG"
