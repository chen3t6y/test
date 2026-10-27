#!/usr/bin/env bash
# ============================================================================
#  setup-v2.sh - v2 桌面环境安装脚本
# ============================================================================
#  依据文档：/home/user/v2-tools-docs/
#    13_base.md      基础工具
#    10_fonts.md     字体（2026-10-27 已核实真实下载地址）
#    01_niri.md      niri（含第五节 AMD 驱动）
#    17_greetd.md    显示管理器
#    03_noctalia.md  桌面壳 v5
#    15_audio.md     音频（pipewire-audio 元包）
#    16_bluetooth.md 蓝牙
#    04~12 *.md      应用层（fish/wezterm/neovim/fcitx5/zotero/tex/tmux）
#
#  目标系统：Ubuntu 26.04 LTS「resolute」 / Debian 13「trixie」，amd64
#  明确不装：waybar（用户用 noctalia。02_waybar.md 跳过）、opencode
#
#  用法：
#    ./setup-v2.sh --help                 看全部阶段与每阶段装什么（分阶段安装就靠它）
#    ./setup-v2.sh --list                 只列阶段名，便于复制
#    ./setup-v2.sh --all                  按顺序全跑，每阶段确认
#    ./setup-v2.sh --only base,niri       只跑指定阶段（逗号分隔，可重复写）
#    ./setup-v2.sh --all --dry-run        只打印命令，不改系统
#    ./setup-v2.sh --all --yes            不逐阶段确认（慎用）
#
#  可组合阶段（详情见 usage()）：base fonts gpu | niri greetd greetd-enable
#  noctalia | fish wezterm tmux neovim | audio bluetooth | fcitx5 zotero tex
#
#  本脚本只装包，不改 ~/.config 里的任何配置，也不自动改时区。
#  写入的系统配置：APT 源、/etc/greetd/config.toml、必要时本地 niri 会话覆盖。
#
#  ★ 必须以普通用户运行，不要 sudo ./setup-v2.sh
#    脚本用 $HOME 装用户级内容（TinyTeX、~/.local/bin/fd），root 下会落进
#    /root 让目标用户拿不到；需要特权的步骤由脚本自己调 sudo。
# ============================================================================

# -E（errtrace）不是可选项：没有它时，函数体最后一条命令失败触发 set -e，
# bash 不执行 ERR trap -- 所有 stage_* 里的失败都会变成「静默 exit 1」，
# 一个字都不打印。实测 bash 5.2.37：`f(){ false; }` 不触发 trap，
# 加 -E 后才触发。
set -eEuo pipefail

readonly SCRIPT_VERSION="2026-10-27"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ---------------------------------------------------------------- 全局状态 --
DRY_RUN=false
ASSUME_YES=false
SKIPPED=()          # 仓库里找不到、被跳过的包
LOG_DIR="${HOME}/.v2-install-logs"
LOG_FILE=""
TMP_DIR=""
DISTRO=""           # ubuntu | debian
CODENAME=""         # resolute | trixie
HOST_ARCH="$(uname -m)"
TARGET_USER=""      # 用户级 systemctl 的目标用户
TARGET_UID=""
CURRENT_STAGE=""    # 出错时报告「卡在哪个阶段」

# -------------------------------------------------------------------- 输出 --
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

_log_raw() {
    [[ -n "$LOG_FILE" ]] && printf '%s\n' "$*" >>"$LOG_FILE"
    printf '%s\n' "$*"
}
log()  { _log_raw "$*"; }
info() { _log_raw "${C_BLU}==>${C_OFF} $*"; }
ok()   { _log_raw "${C_GRN}  ok${C_OFF} $*"; }
warn() { _log_raw "${C_YEL}  !!${C_OFF} $*" >&2; }
err()  { _log_raw "${C_RED}  xx${C_OFF} $*" >&2; }
dim()  { _log_raw "${C_DIM}$*${C_OFF}"; }

hr() { _log_raw "----------------------------------------------------------------"; }
banner() {
    _log_raw ""
    hr
    _log_raw "  $*"
    hr
}

on_error() {
    local rc=$?
    # 先摘掉 trap：on_error 自己也开着 -E，里面任何一条命令非零
    # 都会再次触发 trap，变成死循环刷屏。
    trap - ERR
    local -a _stack=()
    local i
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
        [[ "${FUNCNAME[$i]}" == "main" ]] && break
        _stack=("${FUNCNAME[$i]}" "${_stack[@]}")
    done
    local chain="main"
    for (( i = 0; i < ${#_stack[@]}; i++ )); do
        chain+=" -> ${_stack[$i]}"
    done
    err "Failed: ${FUNCNAME[1]:-main}() line ${BASH_LINENO[0]} (exit ${rc})"
    err "  Call stack: ${chain}"
    [[ -n "$CURRENT_STAGE" ]] && err "  Current stage: ${CURRENT_STAGE}"
    err "  This stage only partially completed; the system may be in an intermediate state."
    [[ -n "$LOG_FILE" ]] && err "Full log: ${LOG_FILE}"
    exit "$rc"
}
trap on_error ERR

# ---------------------------------------------------------------- 执行包装 --
run() {
    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} $*"
        return 0
    fi
    "$@"
}

# 以当前用户身份执行一段 shell 代码。
# 只用于写 /tmp、装 $HOME 下的东西（TinyTeX 等）-- 不要用它写 /etc、
# /usr、/opt，那些地方对普通用户不可写，会 EACCES（见 run_root）。
run_sh() {
    local cmd="$1"
    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} $cmd"
        return 0
    fi
    bash -o pipefail -c "$cmd"
}

# 需要 root 写文件的地方用这个（保持 dry-run 语义）。
# 脚本以普通用户运行（见文件头），所以这里必须显式 sudo。
run_root() {
    local cmd="$1"
    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} sudo $cmd"
        return 0
    fi
    sudo bash -o pipefail -c "$cmd"
}

confirm() {
    local prompt="$1" default="${2:-n}" reply
    $ASSUME_YES && return 0
    # 不能用 [[ -r /dev/tty ]] 判断有没有控制终端：无会话时它照样返回真，
    # 于是 read 失败、reply 为空、取默认值 -- 默认 y 的确认会被当成「是」。
    # 真去打开一次才准确。
    if ! { true >/dev/tty; } 2>/dev/null; then
        # 没有交互终端：dry-run 按「是」继续展示计划，真实运行则拒绝
        if $DRY_RUN; then return 0; fi
        err "No interactive terminal available. Use --yes in non-interactive mode."
        return 1
    fi
    local hint="[y/N]"; [[ "$default" == y ]] && hint="[Y/n]"
    while true; do
        printf '%s %s ' "$prompt" "$hint"
        if ! read -r reply </dev/tty; then
            # EOF / 终端读取失败不能套用默认 y，否则确认可能被意外接受。
            return 1
        fi
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# 高风险确认：绝不能被 --yes 绕过。没有交互终端就一律拒绝。
# 用在「会让机器起不来」的步骤上（启用 greetd）。
hard_confirm() {
    local prompt="$1" reply
    if ! { true >/dev/tty; } 2>/dev/null; then
        err "This step requires manual confirmation in an interactive terminal; --yes is not allowed."
        return 1
    fi
    printf '%s [y/N] ' "$prompt"
    read -r reply </dev/tty || reply=""
    case "$reply" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

# ============================================================================
#  下载重试（墙内环境）
# ============================================================================
#  背景：GitHub / opensuse / fury / tinytex / pkg.noctalia.dev 这些外围站
#  直连不稳，而 Ubuntu 源、Debian 源一般没问题。所以只对下面列出的
#  「外围站」下载做重试，apt 本身不动。
#
#  策略：无限重试 + 指数退避（5 30 60 120 300 300 ...），累计超过
#  NET_GIVEUP_MIN 分钟后询问是否放弃；没有交互终端则直接放弃（不会闷着转到天荒地老）。
#  墙内到 GitHub release 的 CDN 常是「卡住不返回」而不是立刻报错，
#  所以必须配 --connect-timeout + --speed-limit。

NET_GIVEUP_MIN="${NET_GIVEUP_MIN:-15}"
NET_MAX_WAIT="${NET_MAX_WAIT:-300}"

net_is_foreign() {
    case "$1" in
        # githubusercontent.com 已覆盖 objects.githubusercontent.com /
        # raw.githubusercontent.com，不必再单列（shellcheck SC2221/SC2222）。
        *github.com*|*githubusercontent.com*) return 0 ;;
        *download.opensuse.org*)  return 0 ;;
        *apt.fury.io*)            return 0 ;;
        *pkg.noctalia.dev*)       return 0 ;;
        *tinytex.yihui.org*)      return 0 ;;
        *)                        return 1 ;;
    esac
}

# 单次下载的选项。--speed-limit/--speed-time 是防「卡住」的关键。
# 注意：-L 根本不在这里--它必须无条件加，见 net_curl。
_net_opts_curl() {
    if net_is_foreign "$1"; then
        printf '%s' "--connect-timeout 15 --speed-limit 1024 --speed-time 30"
    fi
}
_net_opts_wget() {
    if net_is_foreign "$1"; then
        printf '%s' "--timeout=20 --tries=1"
    fi
}

net_backoff() {
    local n="$1" base=5 wait
    wait=$(( base * (1 << (n - 1)) ))
    (( wait > NET_MAX_WAIT )) && wait=$NET_MAX_WAIT
    printf '%s' "$wait"
}

# net_retry <描述> <命令...>
# 失败后无限重试。累计超时后可确认放弃。dry-run 下只打印。
#
# 不往命令末尾追加任何参数：不同程序对参数位置的要求不同
# （curl 的 URL 之后不能再跟选项），重试就重跑同一条命令。
net_retry() {
    local desc="$1"; shift
    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} $*"
        return 0
    fi

    local tries=0 elapsed=0 wait rc=0 out=""
    while true; do
        tries=$(( tries + 1 ))
        # 取完整输出再判断。原来写 "$@" 2>/dev/null 会把错误信息全扔掉，
        # 于是「权限不够」「参数错」这类重试一百次也没用的失败，看起来
        # 和「网络断了」一模一样，用户只能干等。
        if out="$( "$@" 2>&1 )"; then
            (( tries > 1 )) && ok "    Succeeded on attempt ${tries}"
            return 0
        else
            rc=$?
        fi

        wait="$(net_backoff "$tries")"
        elapsed=$(( elapsed + wait ))
        warn "  ${desc} failed (attempt ${tries}, exit ${rc}); retrying in ${wait}s"
        if [[ -n "$out" ]]; then
            # 只留最后几行，避免刷屏；完整内容本来就在 $out 里，
            # 需要时把 2>&1 的结果整个打到日志更合适，这里保持精简。
            printf '%s\n' "$out" | tail -n 3 | while IFS= read -r l; do
                _log_raw "      ${C_DIM}${l}${C_OFF}"
            done
        fi

        if (( elapsed >= NET_GIVEUP_MIN * 60 )); then
            warn "  Retried ${tries} times; waited about $(( elapsed / 60 )) minutes"
            # 没有交互终端时问不了「还要不要等」，而 confirm 的「否」
            # 在这里等于「继续等」-- 不拦住就是无限重试、无人值守死循环。
            if ! { true >/dev/tty; } 2>/dev/null; then
                warn "  No interactive terminal to confirm whether to keep waiting; giving up on this item"
                return 1
            fi
            if confirm "  Give up on this item (this stage will abort)?" n; then
                return 1
            fi
            elapsed=0   # 用户选了继续等，重新计时
        fi
        sleep "$wait"
    done
}

# 把命令拆成「URL 之前」与「URL 之后」两截。
# 返回时设置 _nb（before）、_na（after）、_nurl。
_net_split() {
    _nb=(); _na=(); _nurl=""
    local a hit=false
    for a in "$@"; do
        if ! $hit && [[ "$a" == http* ]]; then
            hit=true; _nurl="$a"; _na+=("$a"); continue
        fi
        if $hit; then _na+=("$a"); else _nb+=("$a"); fi
    done
}

# 带重试的 curl。
#  -L 无条件加：GitHub release 会 302 跳到 CDN，
#     不跟重定向时会「exit 0 + 0 字节文件」，比报错还难查。
#  -f 无条件加：4xx/5xx 当失败，否则会把 HTML 错误页当文件存下。
#  两者都没有时 curl 会“成功”地生成一个空文件，这一点已实测确认。
net_curl() {
    _net_split "$@"
    local -a opts=()
    # shellcheck disable=SC2207
    opts=( $( _net_opts_curl "$_nurl" ) )
    net_retry "curl ${_nurl}" \
        curl -fL --retry 5 --retry-delay 5 --retry-all-errors "${_nb[@]}" "${opts[@]}" "${_na[@]}"
}

# 带重试的 wget（写文件用）
net_wget() {
    _net_split "$@"
    local -a opts=()
    # shellcheck disable=SC2207
    opts=( $( _net_opts_wget "$_nurl" ) )
    net_retry "wget ${_nurl}" \
        wget -q --tries=1 "${_nb[@]}" "${opts[@]}" "${_na[@]}"
}

# 下载到临时文件并校验：非空 + 小块不可能是错误页。
# 用于「下回来还要给别的程序吃」的场合（字体、源码包、脚本）。
net_fetch() {
    local url="$1" out="$2" min="${3:-1024}"
    # dry-run 下不真下，自然没有文件可校验。不提前返回的话，
    # 下面 stat 到 0 字节会误判为失败并把整个阶段搞死。
    if $DRY_RUN; then
        net_curl -o "$out" "$url"
        return 0
    fi
    if ! net_curl -o "$out" "$url"; then
        return 1
    fi
    local sz
    sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
    if (( sz < min )); then
        err "  ${out} is only ${sz} bytes (expected at least ${min}); discarding"
        rm -f "$out"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 环境检测 --
detect_system() {
    [[ -r /etc/os-release ]] || { err "Cannot read /etc/os-release"; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-}"
    CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    case "${DISTRO}:${CODENAME}" in
        ubuntu:resolute) DISTRO=ubuntu ;;
        debian:trixie)   DISTRO=debian ;;
        ubuntu:*|debian:*)
            err "This script supports only Ubuntu 26.04 'resolute' and Debian 13 'trixie'"
            err "Current system: ${PRETTY_NAME:-$DISTRO $CODENAME}"
            err "The documentation is verified for these releases; package names and versions may differ elsewhere."
            exit 1
            ;;
        *)
            err "Unrecognized distribution: ${PRETTY_NAME:-unknown}"
            exit 1
            ;;
    esac

    if [[ "$HOST_ARCH" != "x86_64" ]]; then
        err "This script supports only amd64 (current architecture: ${HOST_ARCH})"
        err "noctalia only publishes amd64 builds; arm64 will fail."
        exit 1
    fi

    TARGET_USER="${SUDO_USER:-$(id -un)}"
    TARGET_UID="$(id -u "$TARGET_USER")"
}

need_sudo() {
    $DRY_RUN && return 0
    if ! command -v sudo >/dev/null 2>&1; then
        err "sudo is unavailable. Running as root is also unsuitable; the script installs user services for \$SUDO_USER."
        exit 1
    fi
    if ! sudo -n true 2>/dev/null; then
        info "sudo access is required; validating credentials"
        sudo -v || { err "sudo validation failed"; exit 1; }
    fi
}

init_log() {
    $DRY_RUN && { LOG_FILE=""; return 0; }
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
    log "Install log: ${LOG_FILE}"
}

# 所有下载与解压产物放在仅当前用户可访问的私有目录中；其中部分文件
# 随后会交给 sudo 使用，不能放在可被其他本地用户替换的固定 /tmp 路径。
init_tmp_dir() {
    if $DRY_RUN; then
        TMP_DIR="/tmp/${SCRIPT_NAME}.<private-temp-dir>"
        return 0
    fi
    TMP_DIR="$(mktemp -d /tmp/setup-v2.XXXXXXXX)"
    trap cleanup_tmp_dir EXIT
    chmod 700 "$TMP_DIR"
}

cleanup_tmp_dir() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR" || warn "Could not clean temporary directory: ${TMP_DIR}"
    fi
    return 0
}

# ---------------------------------------------------------------- apt 封装 --
# 注意：全程 set -o pipefail。凡「生产者 -> 消费者提前退出」的管道都会
# 让生产者收到 SIGPIPE（exit 141），进而被误判为失败。下面两个函数
# 都先取完整输出再解析，不用 `| grep -q` / `| awk '{...; exit}'`。
dpkg_installed() {
    local st
    st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
    [[ "$st" == *"ok installed"* ]]
}

# 在某个命令的输出里找字符串（大小写不敏感）。
# 不能用 `cmd | grep -q`：grep 命中即退出，生产者收 SIGPIPE，
# 在 pipefail 下整条管道返回非 0，连 if 都进不去。
sh_contains() {
    local needle="$1"; shift
    local out
    out="$("$@" 2>/dev/null || true)"
    [[ "$out" == *"${needle}"* || "${out,,}" == *"${needle,,}"* ]]
}

apt_candidate() {
    local out cand
    # LC_ALL=C 是必须的：apt-cache 的输出会被翻译，中文环境下是
    # 「候选： 1.2.14-1」而不是「Candidate: ...」，按 Candidate: 解析会
    # 一律得到空值 -- 于是每个包都被判成「仓库里没有」，required 阶段
    # 立刻中止（本机 LANG=zh_CN.UTF-8 实测）。
    out="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null || true)"
    [[ -z "$out" ]] && return 0
    cand="$(printf '%s\n' "$out" | awk '/^[[:space:]]*Candidate:/{print $2}')"
    printf '%s' "${cand%%$'\n'*}"
}

apt_update() {
    info "apt update"
    run sudo apt-get update -qq
}

# apt_install required|optional <包>...
#   required：任何一个包在仓库里找不到 -> 整个阶段中止（不硬装）
#   optional：缺的包跳过并记录，不中断
apt_install() {
    local mode="$1"; shift
    local -a todo=()
    local p cand

    for p in "$@"; do
        if dpkg_installed "$p"; then
            dim "    Installed: ${p}"
            continue
        fi
        cand="$(apt_candidate "$p")"
        if [[ -z "$cand" || "$cand" == "(none)" ]]; then
            SKIPPED+=("$p")
            if $DRY_RUN; then
                # dry-run 下第三方源并未真的加，Candidate 自然为空。
                # 仍然把命令打出来，让用户看到完整计划。
                warn "    dry-run: no candidate available yet (repository not actually added); keeping in plan"
                todo+=("$p")
                continue
            fi
            if [[ "$mode" == "required" ]]; then
                err "    ${p} not found in the repository (Candidate: (none))"
                err "    Installation aborted; later stages will not run (this item is not simply skipped)"
                err "    Check that the repository is enabled, or see the index doc section 4.2 (00_*.md)"
                return 1
            fi
            warn "    Skipping ${p} (not found in repository)"
            continue
        fi
        todo+=("$p")
    done

    if (( ${#todo[@]} == 0 )); then
        dim "    Nothing to install"
        return 0
    fi
    info "apt install --no-install-recommends ${todo[*]}"
    run sudo apt-get install -y --no-install-recommends "${todo[@]}"
}

# 用户级 systemctl（pipewire 是 per-user 服务，不能用 sudo 代替）
as_target_user() {
    if [[ "$EUID" -eq 0 ]]; then
        sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" "$@"
    else
        "$@"
    fi
}

user_systemctl() {
    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} (as ${TARGET_USER}) systemctl --user $*"
        return 0
    fi
    if [[ ! -d "/run/user/${TARGET_UID}" ]]; then
        warn "  /run/user/${TARGET_UID} does not exist; this is not a login session for ${TARGET_USER}"
        warn "  Cannot enable user services here. Log in to niri and run manually:"
        warn "    systemctl --user enable --now pipewire pipewire-pulse wireplumber"
        return 0
    fi
    run as_target_user systemctl --user "$@"
}

# =============================================================== 阶段实现 ===

# ---------------------------------------------------------------- 1. base ---
stage_base() {
    banner "Stage base: Essential tools (13_base.md)"

    apt_update

    info "Required (6 packages)"
    apt_install required \
        ca-certificates curl wget gnupg git unzip

    info "Recommended (5 packages)"
    apt_install optional \
        ripgrep fd-find fzf wl-clipboard bash-completion

    info "Optional (as needed)"
    apt_install optional lazygit keyd
    # ntpsec 不塞进上面那行：它 Provides+Conflicts: time-daemon，装它 apt 会
    # 顺手把 systemd-timesyncd 卸掉（本机实测 dpkg -l 里 timesyncd 变 rc）。
    # 桌面机有 timesyncd 就够，要更精确的同步再由你自己决定。
    if dpkg_installed ntpsec; then
        dim "    ntpsec is installed (it replaces systemd-timesyncd)"
    else
        dim "    Skipping ntpsec: Conflicts: time-daemon; it would remove systemd-timesyncd"
        dim "    For more precise time sync: sudo apt install ntpsec (this removes timesyncd)"
    fi

    # lazygit 兜底：仓库没有就从 GitHub 下（13_base.md section 四）
    if ! dpkg_installed lazygit && ! command -v lazygit >/dev/null 2>&1; then
        info "lazygit is not in the repository; downloading the latest release from GitHub"
        if confirm "  Download lazygit to /usr/local/bin/?" y; then
            if $DRY_RUN; then
                log "  ${C_DIM}[dry-run]${C_OFF} curl api.github.com/repos/jesseduffield/lazygit/releases/latest  -> read the version tag"
                log "  ${C_DIM}[dry-run]${C_OFF} curl -fL .../releases/download/v<ver>/lazygit_<ver>_Linux_x86_64.tar.gz -o ${TMP_DIR}/lazygit.tar.gz"
                log "  ${C_DIM}[dry-run]${C_OFF} tar -C ${TMP_DIR} -xf ${TMP_DIR}/lazygit.tar.gz lazygit"
                log "  ${C_DIM}[dry-run]${C_OFF} sudo install -m755 ${TMP_DIR}/lazygit /usr/local/bin/"
            else
                # 取版本号。GitHub API 匿名限流 60 次/小时，且墙内易断，
                # 所以重试几次，仍失败就改用版本号不用 API 的备用路子。
                local ver=""
                local i
                for i in 1 2 3; do
                    ver="$(curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
                        --retry 3 --retry-delay 5 --retry-all-errors --max-time 40 \
                        https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
                        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1 || true)"
                    [[ -n "$ver" ]] && break
                    (( i < 3 )) && { warn "  Could not get the version (attempt ${i}); retrying in 10s"; sleep 10; }
                done
                if [[ -z "${ver:-}" ]]; then
                    # 不臆造版本号，也不静默跳过
                    err "  Could not get the lazygit version (GitHub API rate limit or network failure)"
                    err "  Install manually: https://github.com/jesseduffield/lazygit/releases/latest"
                    SKIPPED+=("lazygit")
                else
                    if net_fetch \
                         "https://github.com/jesseduffield/lazygit/releases/download/v${ver}/lazygit_${ver}_Linux_x86_64.tar.gz" \
                         "${TMP_DIR}/lazygit.tar.gz" 100000 \
                        && run_sh "tar -C '${TMP_DIR}' -xf '${TMP_DIR}/lazygit.tar.gz' lazygit" \
                        && run sudo install -m755 "${TMP_DIR}/lazygit" /usr/local/bin/ ; then
                        run_sh "rm -f '${TMP_DIR}/lazygit' '${TMP_DIR}/lazygit.tar.gz'"
                        ok "lazygit ${ver} -> /usr/local/bin/lazygit"
                    else
                        err "  lazygit installation failed; skipped (other packages are unaffected)"
                        SKIPPED+=("lazygit")
                    fi
                fi
            fi
        fi
    fi

    info "Time zone (not changed by this script)"
    if ! $DRY_RUN && command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null | sed 's/^/    Current: /' || true
    fi
    dim "    To set Asia/Hong_Kong, run manually: sudo timedatectl set-timezone Asia/Hong_Kong"

    info "keyd (optional; /etc/keyd/default.conf is in your backup)"
    if dpkg_installed keyd; then
        if confirm "  Enable the keyd service? (Required after the initial install)" y; then
            # 只有 enable 不会启动一个从未运行过的单元（try-restart 对
            # inactive 的单元是 no-op），必须 --now。
            run sudo systemctl enable --now keyd
            run sudo systemctl try-restart keyd
            dim "    Deploy the configuration yourself from 07_Archive/backup (this script does not modify configs)"
        fi
    else
        dim "    keyd is not installed; skipping"
    fi
}

# ----------------------------------------------------------------- 2. gpu ---
# 枚举 DRM 卡。card0 不是契约：编号由内核探测顺序决定，多卡、无头独显、
# 显卡坞都会让「/dev/dri/card0 是否存在」与「能不能出画面」脱钩。
# 实测反例：iGPU 接显示器 + RX 7900 XTX 无头时，按 card0 判存活会误报失败。
DRM_CARDS=0
DRM_CONNECTED=0

drm_survey() {
    local c drv out st conn rdev
    DRM_CARDS=0
    DRM_CONNECTED=0

    # 不依赖 nullglob：无匹配时 glob 保持字面量，由 [[ -d ]] 挡掉。
    for c in /sys/class/drm/card[0-9]*; do
        [[ -d "$c" ]] || continue
        # card[0-9]* 也会匹配 card0-eDP-1 这类连接器目录，必须精确过滤。
        [[ "$(basename "$c")" =~ ^card[0-9]+$ ]] || continue
        DRM_CARDS=$((DRM_CARDS + 1))

        drv="$(basename "$(readlink -f "$c/device/driver" 2>/dev/null || true)")"
        [[ -n "$drv" && "$drv" != "." ]] || drv="unknown"

        conn=0
        for out in "$c"-*; do
            [[ -r "$out/status" ]] || continue
            if [[ "$(<"$out/status")" == "connected" ]]; then
                conn=$((conn + 1))
            fi
        done
        DRM_CONNECTED=$((DRM_CONNECTED + conn))

        # 同一 PCI 设备下的 render 节点；niri 的 debug.render-drm-device
        # 要的正是 renderD*，不是 card*。
        rdev=""
        for st in /sys/class/drm/renderD[0-9]*; do
            [[ -d "$st" ]] || continue
            [[ "$(basename "$st")" =~ ^renderD[0-9]+$ ]] || continue
            if [[ "$(readlink -f "$st/device" 2>/dev/null || true)" == \
                  "$(readlink -f "$c/device" 2>/dev/null || true)" ]]; then
                rdev="/dev/dri/$(basename "$st")"
                break
            fi
        done

        dim "$(printf '    %-7s %-9s %-14s %s output(s) connected' \
            "$(basename "$c")" "$drv" "${rdev:-no-render-node}" "$conn")"
    done
}

stage_gpu() {
    banner "Stage gpu: AMD graphics userspace drivers (01_niri.md section 5)"

    apt_update

    info "RX 7900 XTX (gfx1100) uses the in-tree amdgpu kernel driver; no proprietary driver or DKMS needed"
    info "Minimal installs lack userspace graphics libraries; the following two are required"

    apt_install required mesa-vulkan-drivers libgl1-mesa-dri

    info "Verify"
    if $DRY_RUN; then
        dim "    Skipping hardware check (dry-run)"
        return 0
    fi

    drm_survey

    if (( DRM_CARDS == 0 )); then
        err "No card* under /sys/class/drm -- the kernel has no KMS driver bound"
        err "Do not install the desktop: it will start with a blank screen"
        err "Check: lspci -nn | grep -iE 'vga|3d|display'"
        err "Check: lsmod | grep -E '^(amdgpu|i915|xe|radeon)'"
        err "Check: sudo dmesg | grep -iE 'amdgpu|i915|xe|drm' | tail -30"
        return 1
    fi

    if (( DRM_CONNECTED == 0 )); then
        # 无头机器或纯 SSH 装机时的正常状态；不拦截，只是提醒。
        warn "DRM cards found, but no connector reports 'connected'"
        warn "Expected on a headless machine or when installing over SSH;"
        warn "attach a monitor before logging into niri or the output stays blank"
    else
        ok "${DRM_CONNECTED} connected output(s) across ${DRM_CARDS} DRM card(s)"
    fi

    if (( DRM_CARDS > 1 && DRM_CONNECTED > 0 )); then
        dim "    Multiple GPUs: niri renders on the card that has the connected output."
        dim "    To pin it explicitly, use debug { render-drm-device \"/dev/dri/renderD12X\" } in config.kdl"
    fi
}

# ---------------------------------------------------------------- 3. niri ---
stage_niri() {
    banner "Stage niri: Wayland compositor (01_niri.md)"

    case "$DISTRO" in
    ubuntu)
        info "Ubuntu: add PPA ppa:avengemedia/danklinux"
        apt_install required software-properties-common
        run sudo add-apt-repository -y ppa:avengemedia/danklinux
        apt_update
        ;;
    debian)
        info "Debian: add the openSUSE OBS repository (not a PPA)"
        run_root "install -d -m755 /etc/apt/keyrings"
        # 先落到临时文件再 dearmor。直接管道时 gpg 失败会被 pipefail 掩盖，
        # 重试也无法判断到底哪一环断了。
        net_fetch https://download.opensuse.org/repositories/home:/AvengeMedia:/danklinux/Debian_13/Release.key "${TMP_DIR}/danklinux.key" 200
        net_retry "Import danklinux key" \
            sudo gpg --dearmor --yes -o /etc/apt/keyrings/danklinux.gpg "${TMP_DIR}/danklinux.key"
        run_sh "rm -f '${TMP_DIR}/danklinux.key'"
        run_root "chmod 644 /etc/apt/keyrings/danklinux.gpg"
        run_root "printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/danklinux.gpg] https://download.opensuse.org/repositories/home:AvengeMedia:/danklinux/Debian_13/ /' > /etc/apt/sources.list.d/danklinux.list"
        apt_update
        ;;
    esac

    info "Required"
    apt_install required niri

    info "Recommended"
    apt_install optional \
        xwayland-satellite \
        xdg-desktop-portal-gtk \
        xdg-desktop-portal-gnome

    # 通知守护 + polkit 代理：装了 noctalia 时由它接管（01_niri.md section 1.1），
    # 但只跑 --only niri 的话两样都没有 -- 通知不弹、图形提权框不出现。
    if dpkg_installed noctalia || [[ " ${RUN_LIST[*]} " == *" noctalia "* ]]; then
        dim "    noctalia is included in this run; skipping mako-notifier / polkit-kde-agent-1"
    else
        warn "noctalia is not included in this run; no notification daemon or polkit agent will be available"
        if confirm "  Install mako-notifier + polkit-kde-agent-1 as well?" y; then
            apt_install optional mako-notifier polkit-kde-agent-1
        fi
    fi

    info "Optional (keys are bound in the default config)"
    apt_install optional fuzzel swaylock wl-clipboard

    info "Verify"
    if command -v niri >/dev/null 2>&1 && ! $DRY_RUN; then
        niri --version | sed 's/^/    /'
        # 没有配置文件时 niri validate 会报错，这不是安装失败
        if [[ -f "${HOME}/.config/niri/config.kdl" ]]; then
            if niri validate >/dev/null 2>&1; then
                ok "${HOME}/.config/niri/config.kdl syntax is valid"
            else
                warn "niri validate failed; fix the config before starting"
            fi
        else
            dim "    ~/.config/niri/config.kdl not found; skipping validation"
        fi
    fi

    if ! dpkg_installed xwayland-satellite && ! $DRY_RUN; then
        warn "xwayland-satellite is not installed; X11 apps (Steam, some Electron apps) will not start"
        warn "See 01_niri.md section 1.2 for two alternatives"
    fi
}

# --------------------------------------------------------------- 4. greetd --
stage_greetd() {
    banner "Stage greetd: Display manager (17_greetd.md)"

    info "Why this is required: niri starts from a TTY; a crash leaves the user at an unlocked shell"

    if [[ "$DISTRO" == "ubuntu" ]]; then
        if [[ "$(apt_candidate tuigreet)" == "(none)" || -z "$(apt_candidate tuigreet)" ]]; then
            info "tuigreet is in Ubuntu Universe; enabling it"
            run sudo add-apt-repository -y universe
            apt_update
        fi
    fi

    info "Required (2 packages, about 4 MB total)"
    apt_install required greetd tuigreet

    # 不装的东西（17_greetd.md section 十）
    for p in gdm3 sddm lightdm; do
        if dpkg_installed "$p"; then
            warn "${p} is installed. greetd will take over the display-manager.service alias; disable it first:"
            warn "  sudo systemctl disable ${p}"
        fi
    done

    info "Check 1: the user is _greetd, not greeter"
    if $DRY_RUN; then
        dim "    Skipping (packages are not installed in dry-run)"
    elif getent passwd _greetd >/dev/null 2>&1; then
        ok "getent passwd _greetd returned a result"
    else
        err "_greetd user does not exist; the package may not have installed correctly"
        if getent passwd greeter >/dev/null 2>&1; then
            warn "A greeter user exists. The upstream user='greeter' setting is incorrect here; do not change it"
        fi
    fi

    info "Check 2: the session file Exec must be niri-session"
    local desktop_pkg=/usr/share/wayland-sessions/niri.desktop
    local desktop_local=/usr/local/share/wayland-sessions/niri.desktop
    local desktop="$desktop_pkg"
    [[ -f "$desktop_local" ]] && desktop="$desktop_local"
    if [[ -f "$desktop" ]]; then
        local exec_line
        exec_line="$(grep -m1 '^Exec=' "$desktop" || true)"
        if [[ "$exec_line" == "Exec=niri-session" ]]; then
            ok "$exec_line"
        else
            warn "Current value: '${exec_line}'"
            warn "It must be Exec=niri-session. dbus-run-session niri prevents portals from starting and causes snap errors"
            if confirm "  Write the local override file $desktop_local?" n; then
                run_root "install -d -m755 /usr/local/share/wayland-sessions"
                # 用 mv 把目标路径本身移走（即使它是符号链接也不跟随），
                # 再新建普通文件，避免重定向跟随链接覆盖 dpkg 管理的文件。
                run_root "if [ -e '$desktop_local' ] || [ -L '$desktop_local' ]; then mv '$desktop_local' '$desktop_local'.bak.\$(date +%Y%m%d-%H%M%S)-\$\$; fi"
                run_root "printf '%s\n' '[Desktop Entry]' 'Name=Niri' 'Comment=A scrollable-tiling Wayland compositor' 'Exec=niri-session' 'Type=Application' 'DesktopNames=niri' > '$desktop_local'"
                ok "Wrote local override file $desktop_local (the package-managed niri file is unchanged)"
            fi
        fi
    else
        warn "$desktop does not exist; is niri installed?"
    fi

    # ---- config.toml ----
    # 配错的下场先说清楚，别等启用之后才讲（17_greetd.md section 六）。
    warn "A misconfigured config.toml leaves a cursor on boot with no prompt. Note this recovery command first:"
    warn "  In GRUB, press e and append systemd.mask=greetd.service to the kernel command line"

    local conf=/etc/greetd/config.toml
    info "Configure ${conf}"
    local need_write=true
    if [[ -f "$conf" ]]; then
        # 只查「含 tuigreet」不够：vt / user / --cmd 任一处不对照样起不来。
        if grep -q 'tuigreet' "$conf" 2>/dev/null \
            && grep -qE '^[[:space:]]*vt[[:space:]]*=[[:space:]]*7[[:space:]]*$' "$conf" \
            && grep -q '_greetd' "$conf" \
            && grep -q 'niri-session' "$conf"; then
            dim "    Configuration is already correct (tuigreet + vt=7 + _greetd + niri-session); skipping"
            need_write=false
        else
            warn "    ${conf} exists but is incomplete (at least one of vt / user / --cmd is incorrect); rewriting"
        fi
    fi
    if $need_write; then
        log "  Planned contents:"
        log "    [terminal]            vt = 7"
        log "    [default_session]     command = tuigreet --time --remember --remember-session --cmd niri-session"
        log "                          user    = _greetd"
        dim "    Keep vt at 7: greetd.service hardcodes Conflicts=getty@tty7.service"
        if confirm "  Rewrite ${conf}? (The original will be backed up as config.toml.bak.<timestamp>)" y; then
            # 备份失败必须让脚本停下：下一步就是覆盖写，吞掉 cp 的错误
            # 等于「承诺备份但没备份」-- 最坏的一种结果。
            if [[ -f "$conf" ]]; then
                run_root "cp -a $conf ${conf}.bak.\$(date +%Y%m%d-%H%M%S)"
            fi
            run_root "cat > $conf <<'CONFEOF'
[terminal]
vt = 7

[default_session]
command = \"tuigreet --time --remember --remember-session --cmd niri-session\"
user = \"_greetd\"
CONFEOF"
            run_root "chmod 644 $conf"
            $DRY_RUN || ok "Wrote ${conf}"
        fi
    fi

    warn "This stage did not run systemctl enable greetd; do that separately as described below"
}

# 单独阶段：启用 greetd（有锁死风险，所以拆出来）
stage_greetd_enable() {
    banner "Stage greetd-enable: Enable the display manager (lockout risk)"

    log "With an invalid config, greetd retries 5 times (StartLimitBurst=5) and then gives up;"
    log "the screen shows a cursor with no prompt. It looks like a freeze."
    log ""
    log "Recovery procedure (write this down first):"
    log "  In GRUB, press e to edit the kernel command line and add:"
    log "    systemd.mask=greetd.service"
    log "  After booting, fix the config, then run sudo systemctl unmask greetd"
    log ""

    if $DRY_RUN; then
        dim "    dry-run: skipping manual confirmation; listing pre-enable checks only"
    else
        if ! hard_confirm "Have you tested the greeter manually on tty2? (sudo -u _greetd tuigreet --time --cmd echo TEST_OK)"; then
            warn "Test it on tty2 before enabling. Aborting this stage."
            return 0
        fi
        if ! hard_confirm "Enable greetd? (It takes over display-manager.service; do not confirm unless tested.)"; then
            warn "Cancelled. No changes were made."
            return 0
        fi
    fi

    # 启用前把「能不能起来」的前置条件全查一遍。原来只查 dpkg_installed，
    # 而 greetd 包自带一个 agreety 默认会话 -- 配置没配对就 enable，
    # 结果是把 agreety 设成 display-manager，开机直接进不去。
    local conf=/etc/greetd/config.toml
    if ! $DRY_RUN; then
        local -a bad=()
        dpkg_installed greetd || bad+=("greetd is not installed (run first: ${SCRIPT_NAME} --only greetd)")
        getent passwd _greetd >/dev/null 2>&1 || bad+=("user _greetd does not exist")
        if [[ -f "$conf" ]] && grep -q '_greetd' "$conf" && grep -q 'niri-session' "$conf"; then
            :
        else
            bad+=("${conf} is missing or does not contain _greetd / niri-session")
        fi
        local desktop_effective=/usr/local/share/wayland-sessions/niri.desktop
        [[ -f "$desktop_effective" ]] || desktop_effective=/usr/share/wayland-sessions/niri.desktop
        if [[ -f "$desktop_effective" ]] \
            && ! grep -qx 'Exec=niri-session' "$desktop_effective"; then
            bad+=("niri.desktop Exec is not niri-session")
        fi
        if (( ${#bad[@]} > 0 )); then
            err "  Pre-enable checks failed; not enabling (the graphical session would likely be unreachable):"
            printf '      - %s\n' "${bad[@]}" >&2
            return 1
        fi
        ok "Pre-enable checks passed"
    fi

    run sudo systemctl enable greetd
    $DRY_RUN || ok "Enabled. Reboot to reach the tuigreet login screen"
    dim "  Reversible until you reboot: sudo systemctl disable greetd"
}

# ------------------------------------------------------------- 5. noctalia --
stage_noctalia() {
    banner "Stage noctalia: Desktop shell v5 (03_noctalia.md)"

    local suite=""
    case "${DISTRO}:${CODENAME}" in
        ubuntu:resolute) suite=resolute ;;
        debian:trixie)   suite=trixie ;;
    esac
    if [[ -z "$suite" ]]; then
        err "noctalia only ships trixie / resolute builds; there is none for ${DISTRO} ${CODENAME}"
        return 1
    fi

    info "1/3 Signing key"
    if [[ -f /usr/share/keyrings/nickh-archive-keyring.gpg ]]; then
        dim "    Already exists; skipping"
    else
        net_fetch https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb "${TMP_DIR}/nickh-archive-keyring.deb" 1000
        run sudo dpkg -i "${TMP_DIR}/nickh-archive-keyring.deb"
        run_sh "rm -f '${TMP_DIR}/nickh-archive-keyring.deb'"
    fi

    info "2/3 Add repository noctalia-${suite}.sources"
    local src=/etc/apt/sources.list.d/noctalia-${suite}.sources
    # 清理不匹配的源要无条件做：放在「目标源不存在」的分支里，
    # 两份 suite 就会共存，apt 拉到哪份构建看运气（03_noctalia.md section 1.2）。
    for old in /etc/apt/sources.list.d/noctalia-*.sources; do
        [[ -e "$old" && "$old" != "$src" ]] || continue
        warn "  Found mismatched repository ${old}; removing it (03_noctalia.md section 1.2)"
        run sudo rm -f "$old"
    done
    if [[ -f "$src" ]]; then
        dim "    ${src} already exists"
    else
        net_fetch "https://pkg.noctalia.dev/deb/noctalia-${suite}.sources" "${TMP_DIR}/noctalia-${suite}.sources" 50
        run sudo install -m644 "${TMP_DIR}/noctalia-${suite}.sources" "$src"
        run_sh "rm -f '${TMP_DIR}/noctalia-${suite}.sources'"
    fi
    apt_update

    info "3/3 Install"
    apt_install required noctalia

    info "Optional (not installed by default)"
    dim "    noctalia-greeter          only for a graphical login screen (pulls the graphics stack)"
    dim "    umbriel + xdg-desktop-portal-umbriel   purpose still unverified; not installed by default"
    dim "    If using greetd, 17_greetd.md section 9 recommends getting tuigreet working first"

    log ""
    log "  Two things left for you after install (this script does not touch your configs):"
    log "    1. Append to ~/.config/niri/config.kdl: spawn-at-startup \"noctalia\""
    log "    2. If waybar was installed: run pkill waybar and remove the spawn-at-startup \"waybar\" line"
}

# ---------------------------------------------------------------- 6. audio --
stage_audio() {
    banner "Stage audio: PipeWire (15_audio.md)"

    info "Key point: use the pipewire-audio metapackage; do not assemble four packages manually"
    dim "    The old package list omitted libspa-0.2-bluetooth; Bluetooth headsets paired but had no audio"

    # pulseaudio 与 pipewire-audio 冲突（Conflicts + Replaces），会被移除
    if dpkg_installed pulseaudio; then
        warn "pulseaudio is installed. pipewire-audio Conflicts with it, so apt will remove it."
        warn "Both fight over ALSA device control (/etc/alsa/conf.d/99-pulse.conf sorts later and takes over)."
        if ! confirm "  Continue (remove pulseaudio)?" y; then
            warn "  Stage cancelled"
            return 0
        fi
    fi

    apt_update

    info "Required + two Recommends that must be requested explicitly"
    apt_install required pipewire-audio alsa-ucm-conf
    apt_install optional rtkit

    info "Optional"
    dim "    pulseaudio-utils   provides pactl (pipewire-pulse does not ship it) -- needed for the checks"
    dim "    pavucontrol        graphical mixer"
    dim "    playerctl          media key control"
    if confirm "  Install pulseaudio-utils (for the pactl check)?" y; then
        apt_install optional pulseaudio-utils
    fi
    # 下面验证要跑 aplay -l，而 aplay 来自 alsa-utils -- 不装就是给用户
    # 一条跑不起来的空指令（原脚本确实这样）。
    dim "    alsa-utils         provides aplay / alsamixer (needed by the aplay -l check)"
    apt_install optional alsa-utils

    info "Enable user services"
    user_systemctl enable --now pipewire pipewire-pulse wireplumber

    info "Verify"
    if $DRY_RUN; then
        dim "    Skipping (packages are not installed in dry-run)"
    else
        local missing=()
        dpkg_installed alsa-ucm-conf || missing+=("alsa-ucm-conf")
        dpkg_installed rtkit        || missing+=("rtkit")
        if (( ${#missing[@]} > 0 )); then
            warn "Missing ${missing[*]}; this is the cost of --no-install-recommends. See 15_audio.md section 1"
        fi
        if [[ -d /usr/share/alsa/ucm2 ]] && [[ -z "$(ls -A /usr/share/alsa/ucm2 2>/dev/null)" ]]; then
            err "/usr/share/alsa/ucm2/ is empty -> wrong card names; HDMI/analog all become default"
            err "Check whether alsa-ucm-conf is installed"
        fi
    fi

    if ! $DRY_RUN; then
        log "  The following commands are meaningful only after logging in to a niri session:"
        log "    wpctl status"
        log "    LANG=C pactl info | grep '^Server Name'   # expect PulseAudio (on PipeWire 1.x.x)"
        log "    aplay -l                                  # does the kernel see the sound card?"
    fi
}

# ------------------------------------------------------------ 7. bluetooth --
stage_bluetooth() {
    banner "Stage bluetooth: Bluetooth keyboard (16_bluetooth.md)"

    info "Bluetooth keyboards do not need blueman. Pair once with bluez's bluetoothctl"

    apt_update

    info "Required"
    apt_install required bluez
    # rfkill 在 Debian 是独立包（不在 util-linux 里）。没有它就没法解除软阻塞，
    # 蓝牙适配器会一直处于 Soft blocked，scan 扫不到任何设备。
    apt_install optional rfkill

    info "Enable service"
    run sudo systemctl enable --now bluetooth

    info "Lift the soft block"
    if $DRY_RUN; then
        run_root "rfkill unblock bluetooth"
    elif ! run_root "rfkill unblock bluetooth"; then
        warn "  rfkill failed (rfkill may not be installed, or a hardware switch may be blocking it)"
        warn "  If the device is not found, check: sudo rfkill list; sudo rfkill unblock bluetooth"
    fi

    dim "    bluez-firmware / firmware-iwlwifi depend on the chipset; not installed by this script"

    log ""
    log "  All three pairing steps matter (without trust it will not reconnect on boot -- the classic trap):"
    log "    bluetoothctl"
    log "      power on -> agent KeyboardDisplay -> default-agent -> scan on"
    log "      pair XX:XX:XX:XX:XX:XX      # the keyboard shows 6 digits; type them and press Enter"
    log "      trust XX:XX:XX:XX:XX:XX"
    log "      connect XX:XX:XX:XX:XX:XX"
    log "    pair hangs with no digits: remove first, then pair again; usually leftover pairing state"
    log ""
    log "  If the keyboard does not reconnect on its own, two options (this script touches neither):"
    log "    A. Add this line to niri config.kdl:"
    log "       spawn-at-startup \"sh\" \"-c\" \"sleep 5; bluetoothctl connect XX:XX:XX:XX:XX:XX\""
    log "    B. Set AutoEnable=true in the [Policy] section of /etc/bluetooth/main.conf"
    log "       (bluez may not power on automatically if rfkill is soft-blocked at startup)"
    log ""
    log "  Set Experimental = true only to show battery levels (Debian Wiki warns this may affect input devices)"
}

# --------------------------------------------------------------- 2. fonts ---
stage_fonts() {
    banner "Stage fonts: Fonts (10_fonts.md)"

    info "Only 3 font files; the full nerd-fonts set is dozens of fonts and hundreds of MB"

    apt_update
    apt_install required fontconfig unzip

    # 中文字体：Debian 13 的 fonts-lxgw-wenkai 1.511 有 LXGWWenKaiMono-Regular.ttf，
    # 但它不是「Screen」字重。后者只在 lxgw/LxgwWenKai-Screen 的 release 里。
    apt_install optional fonts-lxgw-wenkai

    # ---------------------------------------------------------------
    # 以下网址已联网核实（2026-10-27）：
    #  · nerd-fonts v3.5.1（2026-08-21），JetBrainsMono.tar.xz 6.9 MB
    #    包内扁平结构，JetBrainsMonoNerdFontMono-Regular.ttf 在根目录
    #  · 官方仓库的 fonts-jetbrains-mono 无 Nerd 图标字形，必须从 GitHub 取
    # ---------------------------------------------------------------
    local nf_ver="v3.5.1"
    local nf_file="JetBrainsMonoNerdFontMono-Regular.ttf"
    local nf_url="https://github.com/ryanoasis/nerd-fonts/releases/download/${nf_ver}/JetBrainsMono.tar.xz"

    if $DRY_RUN; then
        log "  ${C_DIM}[dry-run]${C_OFF} curl -fL --retry 3 -o ${TMP_DIR}/JBM.tar.xz ${nf_url}"
        log "  ${C_DIM}[dry-run]${C_OFF} tar -C ${TMP_DIR} -xJf ${TMP_DIR}/JBM.tar.xz ${nf_file}"
        log "  ${C_DIM}[dry-run]${C_OFF} sudo install -d -m755 /usr/local/share/fonts"
        log "  ${C_DIM}[dry-run]${C_OFF} sudo install -m644 ${TMP_DIR}/${nf_file} /usr/local/share/fonts/"
        log "  ${C_DIM}[dry-run]${C_OFF} sudo fc-cache -f"
    elif [[ -f "/usr/local/share/fonts/${nf_file}" ]]; then
        dim "    ${nf_file} already exists; skipping"
    else
        info "Downloading Nerd JetBrains Mono (${nf_ver}, about 7 MB)"
        dim "    Use .tar.xz instead of .zip: same contents, 127.8 MB -> 6.9 MB"
        # xz-utils 是解 .tar.xz 的前置（13_base.md 没有这个包）
        apt_install optional xz-utils
        if net_fetch "${nf_url}" "${TMP_DIR}/JBM.tar.xz" 100000 && \
           run_sh "tar -C '${TMP_DIR}' -xJf '${TMP_DIR}/JBM.tar.xz' '${nf_file}'" && \
           run_root "install -d -m755 /usr/local/share/fonts" && \
           run sudo install -m644 "${TMP_DIR}/${nf_file}" /usr/local/share/fonts/ ; then
            ok "${nf_file} -> /usr/local/share/fonts/"
        else
            warn "  Nerd font install failed. Try manually:"
            warn "    curl -fL -o /tmp/JBM.tar.xz ${nf_url}"
            warn "    tar -C /tmp -xJf /tmp/JBM.tar.xz ${nf_file}"
            warn "    sudo install -m644 /tmp/${nf_file} /usr/local/share/fonts/"
        fi
        run_sh "rm -f '${TMP_DIR}/JBM.tar.xz' '${TMP_DIR}/${nf_file}'"
        # 系统级字体缓存要 root 才写得了（/var/cache/fontconfig）。
        run_root "fc-cache -f"
    fi

    # ---------------------------------------------------------------
    # 中文：两选一。Screen 版字重较粗（Medium 冒充 Regular），
    # 高分屏不觉得偏细的话仓库版就够，不必多拉 26 MB。
    # ---------------------------------------------------------------
    if ! $DRY_RUN && ! dpkg_installed fonts-lxgw-wenkai && ! sh_contains 'LXGW WenKai Mono' fc-list; then
        warn "  No CJK fonts found. Two options (see 10_fonts.md section 4.3):"
        warn "    A. sudo apt install fonts-lxgw-wenkai            (original weight, about 60 MB)"
        warn "    B. Download the Screen build (heavier weight, 26.4 MB):"
        warn "       curl -fL -O https://github.com/lxgw/LxgwWenKai-Screen/releases/download/v1.530/LXGWWenKaiMonoGBScreen.ttf"
        if confirm "  Install the repository build of fonts-lxgw-wenkai (option A)?" y; then
            apt_install optional fonts-lxgw-wenkai
        fi
    fi

    info "Verify"
    if ! $DRY_RUN; then
        if sh_contains 'JetBrainsMono Nerd Font' fc-list; then
            ok "JetBrainsMono Nerd Font detected"
        else
            warn "JetBrainsMono Nerd Font not detected -- icons will render as boxes"
        fi
        if sh_contains 'LXGW WenKai Mono' fc-list; then
            ok "LXGW WenKai Mono detected"
        else
            warn "LXGW WenKai Mono not detected"
        fi
    fi
}

# ---------------------------------------------------------------- 8. fish ---
stage_fish() {
    banner "Stage fish: Interactive shell (04_fish.md)"

    info "Both distributions provide fish 4.x in their official repositories; no third-party repository needed"
    dim "    Ubuntu 26.04: 4.2.1-3.2    Debian 13: 4.0.2-1"
    dim "    The OBS repo shells:fish currently ships 4.9.x (newer than trixie main; adding it only upgrades);"
    dim "    the script follows the docs and uses main only; add the repo yourself for a newer build"

    apt_update
    apt_install required fish

    info "Plugin dependency (used by fzf.fish)"
    apt_install optional fzf fd-find

    # Debian/Ubuntu 把 fd 装成 fdfind，而 fzf.fish 找的是 fd
    if ! $DRY_RUN && dpkg_installed fd-find && command -v fdfind >/dev/null 2>&1; then
        if [[ ! -e "${HOME}/.local/bin/fd" ]]; then
            if confirm "  Create the ~/.local/bin/fd -> fdfind symlink? (fzf.fish needs it)" y; then
                mkdir -p "${HOME}/.local/bin"
                ln -sf "$(command -v fdfind)" "${HOME}/.local/bin/fd"
                ok "Created ${HOME}/.local/bin/fd"
                dim "    Make sure ~/.local/bin is in PATH"
            fi
        else
            dim "    ~/.local/bin/fd already exists"
        fi
    fi

    info "Verify"
    if command -v fish >/dev/null 2>&1 && ! $DRY_RUN; then
        fish --version | sed 's/^/    /'
    fi

    warn "Do not run chsh -s fish -- a fish login shell will break desktop login"
    dim "    Some startup scripts use bash syntax. Keep bash and run exec fish manually when needed"

    log ""
    log "  Install plugins (this script does not touch configs; run these yourself):"
    log "    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source"
    log "    fisher install jorgebucaran/fisher"
    log "    fisher install PatrickF1/fzf.fish"
    dim "    Choose one prompt: do not install the starship plugin if you have a custom fish_prompt.fish; they conflict"
}

# -------------------------------------------------------------- 9. wezterm ---
stage_wezterm() {
    banner "Stage wezterm: Terminal (05_wezterm.md)"

    # wezterm 与 wezterm-nightly 冲突，只能装一个
    if ! $DRY_RUN && dpkg_installed wezterm-nightly && ! dpkg_installed wezterm; then
        warn "wezterm-nightly is installed. They cannot coexist; this stage will not install the stable version."
        warn "  To switch to stable: sudo apt remove wezterm-nightly, then run this stage again"
        return 0
    fi

    info "1/2 Add the official WezTerm APT repository (apt.fury.io)"
    if [[ -f /usr/share/keyrings/wezterm-fury.gpg ]]; then
        dim "    Key already exists"
    else
        net_fetch https://apt.fury.io/wez/gpg.key "${TMP_DIR}/wezterm-fury.key" 200
        net_retry "Import the WezTerm key" \
            sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg "${TMP_DIR}/wezterm-fury.key"
        run_sh "rm -f '${TMP_DIR}/wezterm-fury.key'"
    fi
    if [[ -f /etc/apt/sources.list.d/wezterm.list ]]; then
        dim "    Repository file already exists"
    else
        run_root "printf '%s\n' 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' > /etc/apt/sources.list.d/wezterm.list"
    fi
    # _apt 用户要能读这个密钥，否则 apt update 报 NO_PUBKEY / 权限错。
    run_root "chmod 644 /usr/share/keyrings/wezterm-fury.gpg"
    apt_update

    info "2/2 Install the stable release (not nightly: nightly carries untested regressions)"
    apt_install required wezterm

    info "Verify"
    if command -v wezterm >/dev/null 2>&1 && ! $DRY_RUN; then
        wezterm --version | sed 's/^/    /'
    fi

    dim "    Config: copy wezterm.lua from 07_Archive/backup to ~/.config/wezterm/ (this script does not touch it)"
}

# -------------------------------------------------------------- 10. neovim ---
stage_neovim() {
    banner "Stage neovim: Editor (06_neovim.md)"

    apt_update

    local use_tarball=false
    if [[ "$DISTRO" == "ubuntu" ]]; then
        dim "    Ubuntu 26.04 provides 0.11.6-1 >= LazyVim's 0.11.2 requirement; apt is sufficient"
        apt_install required neovim
    else
        dim "    Debian 13 only provides 0.10.4-8 < 0.11.2, one major version behind; use the official tarball"
        use_tarball=true
    fi

    if $use_tarball; then
        if ! $DRY_RUN && dpkg_installed neovim; then
            warn "Repository neovim (0.10.4) is installed and cannot run LazyVim"
            warn "  The tarball installs to /opt/nvim; /usr/local/bin/nvim takes precedence over /usr/bin/nvim"
            if ! confirm "  Continue with the tarball install?" y; then
                return 0
            fi
        fi
        info "Fetching the latest tarball from the official release"
        dim "    Installs to /opt/nvim, symlink at /usr/local/bin/nvim"
        net_fetch \
            https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
            "${TMP_DIR}/nvim.tar.gz" 1000000
        run_sh "rm -rf '${TMP_DIR}/nvim-linux-x86_64' && tar -C '${TMP_DIR}' -xzf '${TMP_DIR}/nvim.tar.gz'"
        if ! $DRY_RUN && [[ ! -x "${TMP_DIR}/nvim-linux-x86_64/bin/nvim" ]]; then
            err "No executable nvim found in the extracted files; existing /opt/nvim was left unchanged"
            return 1
        fi
        run_root "set -e; stage=/opt/.nvim-new-${TARGET_UID}; backup=/opt/nvim.backup.\$(date +%Y%m%d-%H%M%S)-\$\$; rm -rf \"\$stage\"; cp -a '${TMP_DIR}/nvim-linux-x86_64' \"\$stage\"; chown -R root:root \"\$stage\"; if [ -e /opt/nvim ] || [ -L /opt/nvim ]; then mv /opt/nvim \"\$backup\"; had_old=true; else had_old=false; fi; if mv \"\$stage\" /opt/nvim; then if \$had_old; then printf 'Previous Neovim preserved at %s\\n' \"\$backup\"; fi; else rc=\$?; if \$had_old; then mv \"\$backup\" /opt/nvim || printf 'Rollback failed; previous Neovim remains at %s\\n' \"\$backup\" >&2; fi; exit \$rc; fi"
        run_root "ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim"
        run_sh "rm -f '${TMP_DIR}/nvim.tar.gz'"
        $DRY_RUN || ok "Installed to /opt/nvim"
    fi

    info "Optional: inline images in markdown (LazyVim's magick)"
    dim "    imagemagick + libmagickwand-dev + luarocks are needed only for inline images"
    if confirm "  Install these three? (without them images show as link text)" n; then
        apt_install optional imagemagick libmagickwand-dev luarocks
        log "  Then run as ${TARGET_USER} (include --local or it installs to /usr/local and requires root):"
        log "    luarocks --local install magick"
    fi

    info "Verify"
    if ! $DRY_RUN; then
        if command -v nvim >/dev/null 2>&1; then
            local nv; nv="$(command -v nvim)"
            dim "    Path: ${nv}"
            nvim --version 2>/dev/null | head -1 | sed 's/^/    /'
            # LazyVim 硬要求 LuaJIT
            if sh_contains luajit nvim --version; then
                ok "Meets LazyVim's LuaJIT requirement"
            else
                warn "Version output alone does not prove LuaJIT; LazyVim requires a LuaJIT build"
            fi
            if [[ "$nv" == /usr/bin/nvim ]]; then
                warn "  Using /usr/bin/nvim. If the tarball is installed, check the PATH order"
            fi
        else
            warn "nvim not found"
        fi
    fi
}

# -------------------------------------------------------------- 11. fcitx5 ---
stage_fcitx5() {
    banner "Stage fcitx5: CJK input method (07_fcitx5.md)"

    info "Key point: do not set GTK_IM_MODULE under Wayland; only XMODIFIERS + QT_IM_MODULE"

    apt_update

    info "Required"
    apt_install required fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk4 fcitx5-frontend-qt6

    info "Recommended: graphical configuration tool"
    apt_install optional fcitx5-config-qt

    dim "    fcitx5-chinese-addons includes the Pinyin engine; do not install fcitx5-pinyin separately"
    dim "    Install fcitx5-frontend-gtk3 / fcitx5-frontend-qt5 only for legacy applications"

    log ""
    log "  Also add this to ~/.config/niri/config.kdl (this script does not touch it):"
    log "    spawn-at-startup \"fcitx5\" \"-d\""
    log "    environment {"
    log "        XMODIFIERS \"@im=fcitx\""
    log "        QT_IM_MODULE \"fcitx\""
    log "    }"
    warn "    Never add GTK_IM_MODULE -- it makes the candidate window flicker or misplace itself"
    dim "    For GTK3/4, use gtk-im-module=fcitx in ~/.config/gtk-{3,4}.0/settings.ini"

    log ""
    log "  Verify (inside a niri session):"
    log "    pgrep -a fcitx5"
    log "    fcitx5-diagnose | head -40    # GTK_IM_MODULE should be empty; QT_IM_MODULE should be fcitx"
}

# --------------------------------------------------------------- 12. zotero ---
stage_zotero() {
    banner "Stage zotero: Reference manager (08_zotero.md)"

    info "Use zotero-deb, the only third-party repository endorsed by Zotero's official documentation"

    if [[ -f /etc/apt/sources.list.d/zotero.list ]] || [[ -f /etc/apt/sources.list.d/zotero.sources ]]; then
        dim "    Repository file already exists; skipping"
        apt_update
    else
        # 官方给的是一条 curl | sudo bash。管道执行远程脚本无法审查，
        # 所以先落到本地、把开头打出来、确认后再跑。
        info "Downloading zotero-deb's install.sh for your review (not piping it to a shell)"
        net_fetch https://raw.githubusercontent.com/retorquere/zotero-pkg/master/install.sh "${TMP_DIR}/zotero-install.sh" 500
        if ! $DRY_RUN; then
            log "  ---- first 20 lines of install.sh ----"
            head -20 "${TMP_DIR}/zotero-install.sh" | sed 's/^/    /'
            log "  ---- $(wc -l <"${TMP_DIR}/zotero-install.sh") lines total; full file ${TMP_DIR}/zotero-install.sh ----"
        fi
        if ! confirm "  This script writes /etc/apt/sources.list.d/ and adds a signing key. Run it?" y; then
            warn "Repository setup skipped. Review ${TMP_DIR}/zotero-install.sh yourself before deciding (it is removed when the script exits)"
            return 0
        fi
        run sudo bash "${TMP_DIR}/zotero-install.sh"
        apt_update
    fi

    apt_install required zotero

    info "Verify"
    if command -v zotero >/dev/null 2>&1 && ! $DRY_RUN; then
        zotero --version 2>/dev/null | sed 's/^/    /' || true
    fi

    log ""
    log "  After first launch, do these two things:"
    log "    1. Better BibTeX has no CLI installation method; download the .xpi from releases and install manually:"
    log "       https://github.com/retorquere/zotero-better-bibtex/releases"
    log "    2. If a tarball build was installed before, clean up: rm -f ~/.local/share/applications/zotero.desktop"
}

# ---------------------------------------------------------------- 13. tex ---
stage_tex() {
    banner "Stage tex: TinyTeX + zathura (11_tex.md)"

    apt_update

    info "Required: prerequisites for the TinyTeX installer"
    apt_install required perl xz-utils

    info "Compilation toolchain + PDF preview"
    dim "    latexmk depends on texlive-latex-base; installing it pulls in the entire TeX Live suite"
    dim "    texlive and /usr/bin/pdflatex conflict with TinyTeX's PATH (11_tex.md section 4.1)"
    if confirm "  Install latexmk via apt anyway (it pulls in texlive-latex-base)?" y; then
        apt_install optional latexmk
    else
        dim "    Skipped. TinyTeX can install it too: tlmgr install latexmk"
    fi
    apt_install required zathura zathura-pdf-poppler

    # 安装脚本里有 rm -rf $TEXDIR，重跑会清空已装宏包
    if [[ -d "${HOME}/.TinyTeX" ]]; then
        warn "${HOME}/.TinyTeX already exists. Its installer runs rm -rf \$TEXDIR; rerunning it removes installed packages."
        warn "  To update, run: tlmgr update --self --all"
        return 0
    fi

    info "Install TinyTeX (per-user, no root required, about 50-70 MB)"
    dim "    Directory ${HOME}/.TinyTeX, symlinked into ~/bin or ~/.local/bin"
    if ! confirm "  Install TinyTeX now?" y; then
        dim "    Skipped. Manual: wget -qO- https://tinytex.yihui.org/install-bin-unix.sh | sh"
        return 0
    fi
    # 官方脚本是「下载后直接 sh」。管道形式无法判断是网络断还是脚本报错，
    # 所以先下载到本地，校验非空再执行。
    local tt="${TMP_DIR}/tinytex-install.sh"
    # dry-run 下 net_fetch 不会真的产生文件，紧接着的 grep 必然失败，
    # 于是误报「下载失败」-- 校验要跳过（否则 dry-run 会自己吓自己）。
    if net_fetch https://tinytex.yihui.org/install-bin-unix.sh "$tt" 500 \
        && { $DRY_RUN || grep -q 'TinyTeX' "$tt" 2>/dev/null; }; then
        run_sh "sh '$tt'"
        run_sh "rm -f '$tt'"
    else
        err "  TinyTeX installer download failed or looks wrong; skipping"
        warn "    Manual: wget -qO- https://tinytex.yihui.org/install-bin-unix.sh | sh"
        SKIPPED+=("tinytex")
    fi

    info "Install CJK LaTeX packages (--no-doc saves space)"
    dim "    ctex setspace environ trimspaces zhnumber fancyhdr ms"
    if ! $DRY_RUN; then
        local tlmgr="${HOME}/.TinyTeX/bin/x86_64-linux/tlmgr"
        if [[ -x "$tlmgr" ]]; then
            run "$tlmgr" install --no-doc ctex setspace environ trimspaces zhnumber fancyhdr ms || \
                warn "  tlmgr failed. Manual: tlmgr install --no-doc ctex setspace environ trimspaces zhnumber fancyhdr ms"
        else
            warn "  ${tlmgr} not found; skipping packages"
        fi
    fi

    info "Verify"
    if ! $DRY_RUN; then
        # 只跑 command -v 会被 apt 装的 texlive 骗过去：装过 latexmk 之后
        # /usr/bin/pdflatex 一定在，看着「通过」，实际用的不是 TinyTeX。
        local ttbin="${HOME}/.TinyTeX/bin/x86_64-linux"
        local c p
        for c in pdflatex xelatex tlmgr; do
            p="$(command -v "$c" 2>/dev/null || true)"
            if [[ -z "$p" ]]; then
                warn "  ${c} not in PATH -- add ${ttbin} to PATH, or run tlmgr path add"
            elif [[ "$p" == /usr/bin/* ]]; then
                warn "  ${c} -> ${p}: this is the apt-installed texlive, not TinyTeX"
                warn "    To use TinyTeX: export PATH=\"${ttbin}:\$PATH\""
            else
                dim "    ${c}: ${p}"
            fi
        done
        if [[ ! -x "${ttbin}/pdflatex" ]]; then
            warn "  ${ttbin}/pdflatex does not exist -- the TinyTeX install may have failed"
        fi
    fi

    dim "    Use texlive-local.deb only if it conflicts with system texlive; see 11_tex.md section 4.1"
}

# --------------------------------------------------------------- 14. tmux ---
stage_tmux() {
    banner "Stage tmux: Terminal multiplexer (12_tmux.md)"

    info "One package is enough; no third-party repository needed"
    apt_update
    apt_install required tmux

    info "Verify"
    if command -v tmux >/dev/null 2>&1 && ! $DRY_RUN; then
        tmux -V | sed 's/^/    /'
    fi

    log ""
    log "  Config (gpakosz/.tmux) is not touched by this script; run these yourself:"
    log "    git clone --single-branch https://github.com/gpakosz/.tmux.git ~/.tmux"
    log "    ln -s .tmux/.tmux.conf ~/.tmux.conf"
    log "    cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local"
    warn "    Check for a dangling symlink before linking:"
    warn "      if [ ! -e ~/.tmux.conf ] && [ ! -L ~/.tmux.conf ]; then ln -s ...; fi"
    dim "    -e returns false for dangling symlinks; using only -e makes ln report File exists and abort the script"
}

# ================================================================ 阶段注册 ==
STAGE_ORDER=(
    base fonts gpu niri greetd noctalia
    fish wezterm neovim
    audio bluetooth
    fcitx5 zotero tex tmux
)
declare -A STAGE_DESC=(
    [base]="Essential tools: curl/git/gnupg/ripgrep/fzf + time zone"
    [gpu]="AMD userspace drivers: mesa-vulkan-drivers + libgl1-mesa-dri"
    [niri]="niri: add repository (PPA or OBS) + compositor + portals"
    [greetd]="Display manager: greetd + tuigreet + write config.toml (not enabled)"
    [greetd-enable]="Enable greetd (lockout risk, separate confirmation)"
    [noctalia]="Desktop shell v5: signing key + repository + noctalia"
    [audio]="PipeWire: pipewire-audio metapackage + alsa-ucm-conf + rtkit"
    [bluetooth]="Bluetooth: bluez + service + pairing guide"
    [fish]="fish shell + fzf/fd-find + fdfind symlink"
    [wezterm]="WezTerm: official fury repository + stable release"
    [neovim]="Neovim: apt on Ubuntu, official tarball on Debian 13"
    [fcitx5]="CJK input: fcitx5 + chinese-addons + gtk4/qt6 frontend"
    [zotero]="Zotero: zotero-deb repository (review install.sh first)"
    [tex]="TinyTeX + latexmk + zathura + CJK packages"
    [tmux]="tmux (package only; you clone the config)"
    [fonts]="Fonts: Nerd JetBrains Mono v3.5.1 + CJK font (choose one)"
)

# Help metadata: group / packages / doc / prerequisites / risk tag.
# STAGE_DESC stays one line (the per-stage confirmation prompt uses it); details go in STAGE_PKGS.
STAGE_GROUPS=(
    "System:base fonts gpu"
    "Desktop:niri greetd greetd-enable noctalia"
    "Terminal & editors:fish wezterm tmux neovim"
    "Hardware:audio bluetooth"
    "Applications:fcitx5 zotero tex"
)
declare -A STAGE_PKGS=(
    [base]="ca-certificates curl wget gnupg git unzip|ripgrep fd-find fzf wl-clipboard bash-completion|optional: lazygit (binary from GitHub when absent from the repo), keyd"
    [fonts]="fontconfig unzip + JetBrainsMono Nerd Font v3.5.1 (3 files only)|CJK font, choose one: fonts-lxgw-wenkai, or drop LXGWWenKaiMonoGBScreen.ttf manually"
    [gpu]="mesa-vulkan-drivers libgl1-mesa-dri|RX 7900 XTX uses the in-tree amdgpu driver; no proprietary driver or DKMS"
    [niri]="niri + portal / xwayland dependencies|recommended: mako-notifier polkit-kde-agent-1|optional key bindings: fuzzel swaylock wl-clipboard"
    [greetd]="greetd tuigreet|writes /etc/greetd/config.toml (tuigreet + vt=7 + _greetd + niri-session)|does not run systemctl enable"
    [greetd-enable]="systemctl enable --now greetd|a bad config leaves a bare cursor with no prompt; read 17_greetd.md section 6 first"
    [noctalia]="signing key + pkg.noctalia.dev repository + noctalia|not installed: noctalia-greeter (pulls the graphics stack), umbriel"
    [audio]="pipewire-audio alsa-ucm-conf rtkit|optional: pulseaudio-utils (provides pactl), pavucontrol, playerctl, alsa-utils"
    [bluetooth]="bluez (+ rfkill)|no blueman; trust the device after pairing or it will not reconnect on boot"
    [fish]="fish 4.x (official repositories, no third-party repo)|fzf fd-find + ~/.local/bin/fd symlink; install fisher plugins yourself"
    [wezterm]="apt.fury.io official repository + wezterm stable (not nightly)"
    [tmux]="tmux (single package, no third-party repository)|clone the config yourself; this script does not touch ~/.config"
    [neovim]="Ubuntu: apt neovim|Debian 13: official tarball into the user directory|optional: imagemagick libmagickwand-dev luarocks (inline images in markdown)"
    [fcitx5]="fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk4 fcitx5-frontend-qt6|optional: fcitx5-config-qt (GUI configuration)"
    [zotero]="zotero-deb repository (install.sh is downloaded for your review) + zotero"
    [tex]="perl xz-utils + zathura zathura-pdf-poppler|TinyTeX into \$HOME (about 50-70 MB) + latexmk + CJK packages"
)
declare -A STAGE_DOC=(
    [base]="13_base.md"        [fonts]="10_fonts.md"     [gpu]="01_niri.md section 5"
    [niri]="01_niri.md"        [greetd]="17_greetd.md"   [greetd-enable]="17_greetd.md section 6"
    [noctalia]="03_noctalia.md" [fish]="04_fish.md"      [wezterm]="05_wezterm.md"
    [tmux]="12_tmux.md"        [neovim]="06_neovim.md"   [fcitx5]="07_fcitx5.md"
    [zotero]="08_zotero.md"    [tex]="11_tex.md"         [audio]="15_audio.md"
    [bluetooth]="16_bluetooth.md"
)
declare -A STAGE_NEEDS=(
    [niri]="base first"
    [greetd]="niri first (reads the niri-session desktop file)"
    [greetd-enable]="greetd first, config.toml verified"
    [noctalia]="niri first"
    [fcitx5]="fonts first"
    [wezterm]="curl/gnupg from base"
    [zotero]="curl/gnupg from base"
    [tex]="no prerequisites (per-user install)"
)
declare -A STAGE_TAG=(
    [greetd-enable]="high risk"
    [zotero]="review script"
)

# One help entry per stage: one-line summary + what it installs + docs/prerequisites
_usage_stage() {
    local s="$1" line="" meta=""
    printf '  %-16s %s\n' "$s" "${STAGE_DESC[$s]:-}"
    local IFS='|'
    local first=true
    for line in ${STAGE_PKGS[$s]:-}; do
        if $first; then
            printf '  %-16s   - install: %s\n' "" "$line"
            first=false
        else
            printf '  %-16s              %s\n' "" "$line"
        fi
    done
    unset IFS
    [[ -n "${STAGE_DOC[$s]:-}"   ]] && meta+="docs ${STAGE_DOC[$s]}"
    [[ -n "${STAGE_NEEDS[$s]:-}" ]] && meta+="   needs ${STAGE_NEEDS[$s]}"
    [[ -n "${STAGE_TAG[$s]:-}"   ]] && meta+="   [${STAGE_TAG[$s]}]"
    [[ -n "$meta" ]] && printf '  %-16s   - %s\n' "" "${meta#  }"
    return 0
}

usage() {
    local group name s
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} - v2 desktop environment installer (system layer)

Usage:
  ${SCRIPT_NAME} --help                     this text (what each stage installs)
  ${SCRIPT_NAME} --list                     stage names only (compact, easy to copy)
  ${SCRIPT_NAME} --all                      run every stage in build order (no greetd-enable)
  ${SCRIPT_NAME} --only base,niri,fonts     run only the given stages (comma separated)
  ${SCRIPT_NAME} --only=base,niri           same, equals form
  ${SCRIPT_NAME} --all --dry-run            print commands only, change nothing
  ${SCRIPT_NAME} --all --yes                no per-stage confirmation (greetd-enable still asks)

Options:
  --all             all stages (excludes greetd-enable)
  --only LIST       comma separated, may be repeated (--only a --only b)
  --list            compact list of stage names with one-line descriptions
  --dry-run         print commands only; do not touch the system
  --yes, -y         no per-stage confirmation
  -h, --help        this text

Stages (${#STAGE_ORDER[@]} combinable modules + 1 high-risk switch):
  Grouping is for reading only; execution order is the order you pass to --only
  (--all uses the built-in order).
EOF
    for group in "${STAGE_GROUPS[@]}"; do
        name="${group%%:*}"
        printf '\n  -- %s %s\n' "$name" "----------------------------------------------"
        for s in ${group#*:}; do
            _usage_stage "$s"
        done
    done
    cat <<EOF

Common combinations:
  A desktop you can log in to
      ${SCRIPT_NAME} --only base,gpu,niri,greetd,noctalia
  Add terminal and editor
      ${SCRIPT_NAME} --only fish,wezterm,tmux,neovim
  CJK display and input
      ${SCRIPT_NAME} --only fonts,fcitx5
  Writing papers
      ${SCRIPT_NAME} --only tex,zotero
  Audio and a Bluetooth keyboard
      ${SCRIPT_NAME} --only audio,bluetooth
  Everything (greetd is configured, not enabled)
      ${SCRIPT_NAME} --all

Order and dependencies (the script does not reorder for you):
  - base first: adding third-party repositories needs curl / gnupg.
  - niri before greetd and noctalia: both read the niri-session desktop file.
  - fonts before fcitx5: the input method needs a CJK font to render candidates.
  - greetd-enable stands alone: the only systemctl enable step; a bad config
    leaves you at a bare cursor.

Re-running and failures:
  - Stages can be re-run individually: apt skips packages already installed.
  - Configs are rewritten only when missing or incorrect, after a confirmation,
    and are backed up first (.bak.<timestamp>).
  - A failing stage prints the line number and stage name, then exits; it does
    not silently continue.
  - Packages missing from every repository (Candidate: (none)) are not forced
    in; they are summarized under "skipped" at the end.

Network (behind the GFW):
  Third-party hosts (GitHub / openSUSE OBS / fury / pkg.noctalia.dev / tinytex)
  retry with backoff 5 30 60 120 300 s (capped at 300). After 15 minutes of
  cumulative waiting you are asked once whether to give up on that item.
  Change the threshold: NET_GIVEUP_MIN=30 ${SCRIPT_NAME} --all
  apt repositories are not retried (Debian / Ubuntu mirrors are usually fine).

Notes:
  - Run as a normal user, never sudo ./${SCRIPT_NAME} (user-level content would land in /root).
  - Does not modify ~/.config and does not change the time zone. System writes are
    limited to: APT repository files, /etc/greetd/config.toml, and, if needed, the
    local niri session override file.
  - Deliberately does not install waybar (you use noctalia; the two conflict) or
    opencode (see 09_opencode.md).
EOF
}

# --list: names only, ready to paste into --only
list_stages() {
    local s
    printf '%s %s - combinable stages (%d + greetd-enable):\n\n' \
        "$SCRIPT_NAME" "$SCRIPT_VERSION" "${#STAGE_ORDER[@]}"
    for s in "${STAGE_ORDER[@]}"; do
        printf '  %-16s %s\n' "$s" "${STAGE_DESC[$s]:-}"
    done
    printf '  %-16s %s\n' "greetd-enable" "${STAGE_DESC[greetd-enable]:-}"
    printf '\nInstall example: %s --only base,niri,fonts\n' "$SCRIPT_NAME"
    printf 'See what each stage installs: %s --help\n' "$SCRIPT_NAME"
}

parse_args() {
    local selected=()
    local want_all=false
    local saw_only=false

    (($# == 0)) && { usage; exit 0; }

    while (($#)); do
        case "$1" in
            --all)      want_all=true ;;
            --only)
                shift
                if (($# == 0)) || [[ -z "${1:-}" ]]; then
                    err "--only requires an argument, e.g. --only base,niri"
                    exit 1
                fi
                saw_only=true
                IFS=',' read -r -a _tmp <<<"$1"; selected+=("${_tmp[@]}") ;;
            --only=*)
                if [[ -z "${1#*=}" ]]; then
                    err "--only= must not be empty, e.g. --only=base,niri"
                    exit 1
                fi
                saw_only=true
                IFS=',' read -r -a _tmp <<<"${1#*=}"; selected+=("${_tmp[@]}") ;;
            --list)     list_stages; exit 0 ;;
            --dry-run)  DRY_RUN=true ;;
            --yes|-y)   ASSUME_YES=true ;;
            -h|--help)  usage; exit 0 ;;
            *)          err "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done

    if $want_all && $saw_only; then
        err "--all and --only are mutually exclusive; use only one of them"
        exit 1
    fi

    if $want_all; then
        RUN_LIST=("${STAGE_ORDER[@]}")
    elif ((${#selected[@]})); then
        RUN_LIST=("${selected[@]}")
    else
        err "No stages selected. Use --all or --only"; usage; exit 1
    fi

    local s
    for s in "${RUN_LIST[@]}"; do
        if [[ -z "${STAGE_DESC[$s]:-}" ]]; then
            err "Unknown stage: $s"; usage; exit 1
        fi
    done
}

# ==================================================================== main ==
main() {
    parse_args "$@"

    if [[ "$EUID" -eq 0 ]]; then
        err "Do not run this script as root (including sudo ./${SCRIPT_NAME})."
        err "It installs TinyTeX under \$HOME and creates the ~/.local/bin/fd symlink; as root"
        err "these land in /root and the target user cannot use them. Run it as a normal user."
        err "Steps that need privileges call sudo themselves."
        exit 1
    fi

    detect_system
    need_sudo
    init_log
    init_tmp_dir

    banner "v2 desktop environment install ${SCRIPT_VERSION}"
    log "  Distro      ${DISTRO} / ${CODENAME}"
    log "  Arch        ${HOST_ARCH}"
    log "  Target user ${TARGET_USER} (uid ${TARGET_UID})"
    log "  Stages      ${RUN_LIST[*]}"
    log "  Desktop     noctalia (waybar not installed)"
    $DRY_RUN && warn "  DRY-RUN: printing commands only, no changes"

    local s
    for s in "${RUN_LIST[@]}"; do
        if ! $ASSUME_YES && [[ "$s" != "greetd-enable" ]]; then
            if ! confirm "Run stage ${s} (${STAGE_DESC[$s]})?" y; then
                warn "Skipping ${s}"
                continue
            fi
        fi
        CURRENT_STAGE="$s"
        "stage_${s//-/_}"
    done

    banner "Done"
    if ((${#SKIPPED[@]})); then
        if $DRY_RUN; then
            dim "  dry-run: these packages cannot be confirmed until the repository is really added (rechecked on a real run):"
        else
            warn "These packages were not found in any repository and were skipped:"
        fi
        printf '    %s\n' "${SKIPPED[@]}" | sort -u >&2 || true
    fi
    log "  Next steps:"
    log "    1. sudo systemctl enable greetd   (or ${SCRIPT_NAME} --only greetd-enable)"
    log "       Read 17_greetd.md section 6 before enabling"
    log "    2. Add spawn-at-startup \"noctalia\" to ~/.config/niri/config.kdl"
    log "    3. Reboot, log in via tuigreet, then verify audio / Bluetooth"
    [[ -n "$LOG_FILE" ]] && log "  Log: ${LOG_FILE}"
    return 0
}

main "$@"
