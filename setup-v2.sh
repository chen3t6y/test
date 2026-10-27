#!/usr/bin/env bash
# ============================================================================
#  setup-v2.sh — v2 桌面环境安装脚本
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
# bash 不执行 ERR trap —— 所有 stage_* 里的失败都会变成「静默 exit 1」，
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
        chain+=" → ${_stack[$i]}"
    done
    err "失败：${FUNCNAME[1]:-main}() 第 ${BASH_LINENO[0]} 行（exit ${rc}）"
    err "  调用链：${chain}"
    [[ -n "$CURRENT_STAGE" ]] && err "  当前阶段：${CURRENT_STAGE}"
    err "  该阶段的命令只执行了一部分，系统可能处于中间状态。"
    [[ -n "$LOG_FILE" ]] && err "完整日志：${LOG_FILE}"
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
# 只用于写 /tmp、装 $HOME 下的东西（TinyTeX 等）—— 不要用它写 /etc、
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
    # 于是 read 失败、reply 为空、取默认值 —— 默认 y 的确认会被当成「是」。
    # 真去打开一次才准确。
    if ! { true >/dev/tty; } 2>/dev/null; then
        # 没有交互终端：dry-run 按「是」继续展示计划，真实运行则拒绝
        if $DRY_RUN; then return 0; fi
        err "没有可用的交互终端。非交互场景请加 --yes"
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
        err "这一步必须在交互终端里手动确认，不允许用 --yes 跳过"
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
# 注意：-L 根本不在这里——它必须无条件加，见 net_curl。
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
            (( tries > 1 )) && ok "    第 ${tries} 次尝试成功"
            return 0
        else
            rc=$?
        fi

        wait="$(net_backoff "$tries")"
        elapsed=$(( elapsed + wait ))
        warn "  ${desc} 失败（第 ${tries} 次，exit ${rc}），${wait} 秒后重试"
        if [[ -n "$out" ]]; then
            # 只留最后几行，避免刷屏；完整内容本来就在 $out 里，
            # 需要时把 2>&1 的结果整个打到日志更合适，这里保持精简。
            printf '%s\n' "$out" | tail -n 3 | while IFS= read -r l; do
                _log_raw "      ${C_DIM}${l}${C_OFF}"
            done
        fi

        if (( elapsed >= NET_GIVEUP_MIN * 60 )); then
            warn "  已重试 ${tries} 次，累计等待约 $(( elapsed / 60 )) 分钟"
            # 没有交互终端时问不了「还要不要等」，而 confirm 的「否」
            # 在这里等于「继续等」—— 不拦住就是无限重试、无人值守死循环。
            if ! { true >/dev/tty; } 2>/dev/null; then
                warn "  没有交互终端，无法确认是否继续等待 —— 放弃这一项"
                return 1
            fi
            if confirm "  放弃这一项（本阶段随之中止）？" n; then
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
        err "  ${out} 只有 ${sz} 字节（预期至少 ${min}），丢弃"
        rm -f "$out"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 环境检测 --
detect_system() {
    [[ -r /etc/os-release ]] || { err "读不到 /etc/os-release"; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-}"
    CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    case "${DISTRO}:${CODENAME}" in
        ubuntu:resolute) DISTRO=ubuntu ;;
        debian:trixie)   DISTRO=debian ;;
        ubuntu:*|debian:*)
            err "本脚本只覆盖 Ubuntu 26.04「resolute」与 Debian 13「trixie」"
            err "当前是 ${PRETTY_NAME:-$DISTRO $CODENAME}"
            err "文档是照这两个版本核实的，别的版本包名与版本号都对不上。"
            exit 1
            ;;
        *)
            err "不认识的发行版：${PRETTY_NAME:-unknown}"
            exit 1
            ;;
    esac

    if [[ "$HOST_ARCH" != "x86_64" ]]; then
        err "本脚本只覆盖 amd64（当前 ${HOST_ARCH}）"
        err "noctalia 只发布 amd64 构建，arm64 会失败。"
        exit 1
    fi

    TARGET_USER="${SUDO_USER:-$(id -un)}"
    TARGET_UID="$(id -u "$TARGET_USER")"
}

need_sudo() {
    $DRY_RUN && return 0
    if ! command -v sudo >/dev/null 2>&1; then
        err "没有 sudo。用 root 直接跑也不合适——脚本会以 \$SUDO_USER 装用户服务。"
        exit 1
    fi
    if ! sudo -n true 2>/dev/null; then
        info "需要 sudo 权限，先验证一次口令"
        sudo -v || { err "sudo 验证失败"; exit 1; }
    fi
}

init_log() {
    $DRY_RUN && { LOG_FILE=""; return 0; }
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"
    log "安装日志：${LOG_FILE}"
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
        rm -rf -- "$TMP_DIR" || warn "无法清理临时目录：${TMP_DIR}"
    fi
    return 0
}

# ---------------------------------------------------------------- apt 封装 --
# 注意：全程 set -o pipefail。凡「生产者 → 消费者提前退出」的管道都会
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
    # 一律得到空值 —— 于是每个包都被判成「仓库里没有」，required 阶段
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
#   required：任何一个包在仓库里找不到 → 整个阶段中止（不硬装）
#   optional：缺的包跳过并记录，不中断
apt_install() {
    local mode="$1"; shift
    local -a todo=()
    local p cand

    for p in "$@"; do
        if dpkg_installed "$p"; then
            dim "    已装：${p}"
            continue
        fi
        cand="$(apt_candidate "$p")"
        if [[ -z "$cand" || "$cand" == "(none)" ]]; then
            SKIPPED+=("$p")
            if $DRY_RUN; then
                # dry-run 下第三方源并未真的加，Candidate 自然为空。
                # 仍然把命令打出来，让用户看到完整计划。
                warn "    dry-run：仓库暂无可选版本（源未实际添加），仍列入计划"
                todo+=("$p")
                continue
            fi
            if [[ "$mode" == "required" ]]; then
                err "    仓库里没有 ${p}（Candidate: (none)）"
                err "    安装中止 —— 后面的阶段也不会继续（不是只跳过这一项）"
                err "    先确认源已启用，或查 00_索引.md §4.2"
                return 1
            fi
            warn "    跳过 ${p}（仓库里没有）"
            continue
        fi
        todo+=("$p")
    done

    if (( ${#todo[@]} == 0 )); then
        dim "    无需安装"
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
        warn "  /run/user/${TARGET_UID} 不存在 —— 当前不是 ${TARGET_USER} 的登录会话"
        warn "  用户服务无法在此启用。请登录 niri 后手动执行："
        warn "    systemctl --user enable --now pipewire pipewire-pulse wireplumber"
        return 0
    fi
    run as_target_user systemctl --user "$@"
}

# =============================================================== 阶段实现 ===

# ---------------------------------------------------------------- 1. base ---
stage_base() {
    banner "阶段 base · 基础工具（13_base.md）"

    apt_update

    info "必要（6 个）"
    apt_install required \
        ca-certificates curl wget gnupg git unzip

    info "推荐（5 个）"
    apt_install optional \
        ripgrep fd-find fzf wl-clipboard bash-completion

    info "可选（按需）"
    apt_install optional lazygit keyd
    # ntpsec 不塞进上面那行：它 Provides+Conflicts: time-daemon，装它 apt 会
    # 顺手把 systemd-timesyncd 卸掉（本机实测 dpkg -l 里 timesyncd 变 rc）。
    # 桌面机有 timesyncd 就够，要更精确的同步再由你自己决定。
    if dpkg_installed ntpsec; then
        dim "    ntpsec 已装（它顶替了 systemd-timesyncd）"
    else
        dim "    ntpsec 不装：Conflicts: time-daemon，会移除 systemd-timesyncd"
        dim "    确实需要更精确的同步：sudo apt install ntpsec（先接受会移除 timesyncd）"
    fi

    # lazygit 兜底：仓库没有就从 GitHub 下（13_base.md §四）
    if ! dpkg_installed lazygit && ! command -v lazygit >/dev/null 2>&1; then
        info "lazygit 不在仓库，改从 GitHub 下最新版"
        if confirm "  下载 lazygit 到 /usr/local/bin/ ?" y; then
            if $DRY_RUN; then
                log "  ${C_DIM}[dry-run]${C_OFF} curl api.github.com/repos/jesseduffield/lazygit/releases/latest  → 取版本号"
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
                    (( i < 3 )) && { warn "  取版本号失败（第 ${i} 次），10 秒后重试"; sleep 10; }
                done
                if [[ -z "${ver:-}" ]]; then
                    # 不臆造版本号，也不静默跳过
                    err "  取不到懒吉特版本号（可能 GitHub API 限流或断网）"
                    err "  手动装：https://github.com/jesseduffield/lazygit/releases/latest"
                    SKIPPED+=("lazygit")
                else
                    if net_fetch \
                         "https://github.com/jesseduffield/lazygit/releases/download/v${ver}/lazygit_${ver}_Linux_x86_64.tar.gz" \
                         "${TMP_DIR}/lazygit.tar.gz" 100000 \
                        && run_sh "tar -C '${TMP_DIR}' -xf '${TMP_DIR}/lazygit.tar.gz' lazygit" \
                        && run sudo install -m755 "${TMP_DIR}/lazygit" /usr/local/bin/ ; then
                        run_sh "rm -f '${TMP_DIR}/lazygit' '${TMP_DIR}/lazygit.tar.gz'"
                        ok "lazygit ${ver} → /usr/local/bin/lazygit"
                    else
                        err "  lazygit 安装失败，已跳过（不影响其他包）"
                        SKIPPED+=("lazygit")
                    fi
                fi
            fi
        fi
    fi

    info "时区（本脚本不自动修改）"
    if ! $DRY_RUN && command -v timedatectl >/dev/null 2>&1; then
        timedatectl show -p Timezone --value 2>/dev/null | sed 's/^/    当前：/' || true
    fi
    dim "    如需设置为 Asia/Hong_Kong，请手动执行：sudo timedatectl set-timezone Asia/Hong_Kong"

    info "keyd（可选，你 backup 里有 /etc/keyd/default.conf）"
    if dpkg_installed keyd; then
        if confirm "  启用 keyd 服务？（首次装完必须启用才生效）" y; then
            # 只有 enable 不会启动一个从未运行过的单元（try-restart 对
            # inactive 的单元是 no-op），必须 --now。
            run sudo systemctl enable --now keyd
            run sudo systemctl try-restart keyd
            dim "    配置文件需你自己从 07_Archive/backup 部署（本脚本不碰配置）"
        fi
    else
        dim "    未装 keyd，跳过"
    fi
}

# ----------------------------------------------------------------- 2. gpu ---
stage_gpu() {
    banner "阶段 gpu · AMD 显卡用户态驱动（01_niri.md §五）"

    apt_update

    info "RX 7900 XTX（gfx1100）走内核 in-tree amdgpu，不需要闭源驱动 / DKMS"
    info "但最小安装不带用户态图形库 —— 以下两个是必要"

    apt_install required mesa-vulkan-drivers libgl1-mesa-dri

    info "验证"
    if $DRY_RUN; then
        dim "    跳过硬件检查（dry-run）"
    elif [[ -e /dev/dri/card0 ]]; then
        ok "/dev/dri/card0 存在"
        ls -l /dev/dri/ | sed 's/^/    /'
    else
        err "/dev/dri/card0 不存在 —— 不要往下装桌面，起了也是黑屏"
        err "查：lsmod | grep amdgpu ; dmesg | grep -i amdgpu"
        return 1
    fi
}

# ---------------------------------------------------------------- 3. niri ---
stage_niri() {
    banner "阶段 niri · Wayland 合成器（01_niri.md）"

    case "$DISTRO" in
    ubuntu)
        info "Ubuntu：加 PPA ppa:avengemedia/danklinux"
        apt_install required software-properties-common
        run sudo add-apt-repository -y ppa:avengemedia/danklinux
        apt_update
        ;;
    debian)
        info "Debian：加 openSUSE OBS 源（不是 PPA）"
        run_root "install -d -m755 /etc/apt/keyrings"
        # 先落到临时文件再 dearmor。直接管道时 gpg 失败会被 pipefail 掩盖，
        # 重试也无法判断到底哪一环断了。
        net_fetch https://download.opensuse.org/repositories/home:/AvengeMedia:/danklinux/Debian_13/Release.key "${TMP_DIR}/danklinux.key" 200
        net_retry "导入 danklinux 密钥" \
            sudo gpg --dearmor --yes -o /etc/apt/keyrings/danklinux.gpg "${TMP_DIR}/danklinux.key"
        run_sh "rm -f '${TMP_DIR}/danklinux.key'"
        run_root "chmod 644 /etc/apt/keyrings/danklinux.gpg"
        run_root "printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/danklinux.gpg] https://download.opensuse.org/repositories/home:AvengeMedia:/danklinux/Debian_13/ /' > /etc/apt/sources.list.d/danklinux.list"
        apt_update
        ;;
    esac

    info "必要"
    apt_install required niri

    info "推荐"
    apt_install optional \
        xwayland-satellite \
        xdg-desktop-portal-gtk \
        xdg-desktop-portal-gnome

    # 通知守护 + polkit 代理：装了 noctalia 时由它接管（01_niri.md §1.1），
    # 但只跑 --only niri 的话两样都没有 —— 通知不弹、图形提权框不出现。
    if dpkg_installed noctalia || [[ " ${RUN_LIST[*]} " == *" noctalia "* ]]; then
        dim "    本轮有 noctalia → 跳过 mako-notifier / polkit-kde-agent-1"
    else
        warn "本轮不含 noctalia：没有通知守护和 polkit 代理"
        if confirm "  补装 mako-notifier + polkit-kde-agent-1？" y; then
            apt_install optional mako-notifier polkit-kde-agent-1
        fi
    fi

    info "可选（默认 config 里绑了键）"
    apt_install optional fuzzel swaylock wl-clipboard

    info "验证"
    if command -v niri >/dev/null 2>&1 && ! $DRY_RUN; then
        niri --version | sed 's/^/    /'
        # 没有配置文件时 niri validate 会报错，这不是安装失败
        if [[ -f "${HOME}/.config/niri/config.kdl" ]]; then
            if niri validate >/dev/null 2>&1; then
                ok "${HOME}/.config/niri/config.kdl 语法通过"
            else
                warn "niri validate 报错 —— 先修配置再启动"
            fi
        else
            dim "    未找到 ~/.config/niri/config.kdl，跳过 validate"
        fi
    fi

    if ! dpkg_installed xwayland-satellite && ! $DRY_RUN; then
        warn "xwayland-satellite 未装上 → X11 程序（Steam、部分 Electron）开不了"
        warn "两条出路见 01_niri.md §1.2"
    fi
}

# --------------------------------------------------------------- 4. greetd --
stage_greetd() {
    banner "阶段 greetd · 显示管理器（17_greetd.md）"

    info "为什么必须装：niri 从 TTY 起，崩溃后会把用户丢到未锁定的 shell"

    if [[ "$DISTRO" == "ubuntu" ]]; then
        if [[ "$(apt_candidate tuigreet)" == "(none)" || -z "$(apt_candidate tuigreet)" ]]; then
            info "tuigreet 在 Ubuntu universe，启用它"
            run sudo add-apt-repository -y universe
            apt_update
        fi
    fi

    info "必要（2 个，合计约 4 MB）"
    apt_install required greetd tuigreet

    # 不装的东西（17_greetd.md §十）
    for p in gdm3 sddm lightdm; do
        if dpkg_installed "$p"; then
            warn "检测到已装 ${p}。greetd 会抢 display-manager.service 别名，建议先禁用："
            warn "  sudo systemctl disable ${p}"
        fi
    done

    info "验证一：用户是 _greetd，不是 greeter"
    if $DRY_RUN; then
        dim "    跳过（dry-run 下包尚未安装）"
    elif getent passwd _greetd >/dev/null 2>&1; then
        ok "getent passwd _greetd 有输出"
    else
        err "_greetd 用户不存在 —— 包可能没装好"
        if getent passwd greeter >/dev/null 2>&1; then
            warn "存在 greeter 用户。upstream 文档的 user=「greeter」在这里是错的，别改"
        fi
    fi

    info "验证二：会话文件 Exec 必须是 niri-session"
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
            warn "当前是「${exec_line}」"
            warn "必须是 Exec=niri-session。dbus-run-session niri 会让 portal 起不来、snap 报错"
            if confirm "  在本地写入覆盖文件 $desktop_local ?" n; then
                run_root "install -d -m755 /usr/local/share/wayland-sessions"
                # 用 mv 把目标路径本身移走（即使它是符号链接也不跟随），
                # 再新建普通文件，避免重定向跟随链接覆盖 dpkg 管理的文件。
                run_root "if [ -e '$desktop_local' ] || [ -L '$desktop_local' ]; then mv '$desktop_local' '$desktop_local'.bak.\$(date +%Y%m%d-%H%M%S)-\$\$; fi"
                run_root "printf '%s\n' '[Desktop Entry]' 'Name=Niri' 'Comment=A scrollable-tiling Wayland compositor' 'Exec=niri-session' 'Type=Application' 'DesktopNames=niri' > '$desktop_local'"
                ok "已写入本地覆盖文件 $desktop_local（不会修改 niri 包管理的文件）"
            fi
        fi
    else
        warn "$desktop 不存在 —— niri 装了吗？"
    fi

    # ---- config.toml ----
    # 配错的下场先说清楚，别等启用之后才讲（17_greetd.md §六）。
    warn "配错 config.toml 的表现是「开机一个光标、没有任何提示」，先抄下救援命令："
    warn "  GRUB 按 e，在内核命令行末尾加 systemd.mask=greetd.service"

    local conf=/etc/greetd/config.toml
    info "配置 ${conf}"
    local need_write=true
    if [[ -f "$conf" ]]; then
        # 只查「含 tuigreet」不够：vt / user / --cmd 任一处不对照样起不来。
        if grep -q 'tuigreet' "$conf" 2>/dev/null \
            && grep -qE '^[[:space:]]*vt[[:space:]]*=[[:space:]]*7[[:space:]]*$' "$conf" \
            && grep -q '_greetd' "$conf" \
            && grep -q 'niri-session' "$conf"; then
            dim "    已是正确配置（tuigreet + vt=7 + _greetd + niri-session），跳过"
            need_write=false
        else
            warn "    ${conf} 已存在但内容不完整（vt / user / --cmd 至少一处不对），将重写"
        fi
    fi
    if $need_write; then
        log "  计划写入："
        log "    [terminal]            vt = 7"
        log "    [default_session]     command = tuigreet --time --remember --remember-session --cmd niri-session"
        log "                          user    = _greetd"
        dim "    vt 保持 7：greetd.service 写死 Conflicts=getty@tty7.service"
        if confirm "  改写 ${conf}？（原文件备份为 config.toml.bak.<时间戳>）" y; then
            # 备份失败必须让脚本停下：下一步就是覆盖写，吞掉 cp 的错误
            # 等于「承诺备份但没备份」—— 最坏的一种结果。
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
            $DRY_RUN || ok "已写入 ${conf}"
        fi
    fi

    warn "本阶段【没有】执行 systemctl enable greetd —— 这一步单独做，见下方说明"
}

# 单独阶段：启用 greetd（有锁死风险，所以拆出来）
stage_greetd_enable() {
    banner "阶段 greetd-enable · 启用显示管理器（有锁死风险）"

    log "配置写错时，greetd 会重启 5 次（StartLimitBurst=5）然后彻底放弃，"
    log "屏幕上一个光标、没有任何提示。看着像死机。"
    log ""
    log "救回来的办法（先把这行抄到纸上）："
    log "  在 GRUB 按 e 改内核命令行，加："
    log "    systemd.mask=greetd.service"
    log "  起来后改好配置，再 sudo systemctl unmask greetd"
    log ""

    if $DRY_RUN; then
        dim "    dry-run：跳过人工确认，只列出启用前会做的检查"
    else
        if ! hard_confirm "先切到 tty2 手动试一次 greeter 了吗？（sudo -u _greetd tuigreet --time --cmd echo TEST_OK）"; then
            warn "建议先在 tty2 试通再启用。本阶段中止。"
            return 0
        fi
        if ! hard_confirm "确认启用 greetd（会接管 display-manager.service，未经测试不要按 y）？"; then
            warn "已取消。未做任何更改。"
            return 0
        fi
    fi

    # 启用前把「能不能起来」的前置条件全查一遍。原来只查 dpkg_installed，
    # 而 greetd 包自带一个 agreety 默认会话 —— 配置没配对就 enable，
    # 结果是把 agreety 设成 display-manager，开机直接进不去。
    local conf=/etc/greetd/config.toml
    if ! $DRY_RUN; then
        local -a bad=()
        dpkg_installed greetd || bad+=("greetd 未安装（先跑：${SCRIPT_NAME} --only greetd）")
        getent passwd _greetd >/dev/null 2>&1 || bad+=("用户 _greetd 不存在")
        if [[ -f "$conf" ]] && grep -q '_greetd' "$conf" && grep -q 'niri-session' "$conf"; then
            :
        else
            bad+=("${conf} 缺失，或不含 _greetd / niri-session")
        fi
        local desktop_effective=/usr/local/share/wayland-sessions/niri.desktop
        [[ -f "$desktop_effective" ]] || desktop_effective=/usr/share/wayland-sessions/niri.desktop
        if [[ -f "$desktop_effective" ]] \
            && ! grep -qx 'Exec=niri-session' "$desktop_effective"; then
            bad+=("niri.desktop 的 Exec 不是 niri-session")
        fi
        if (( ${#bad[@]} > 0 )); then
            err "  启用前检查未通过，不启用（否则大概率到不了图形界面）："
            printf '      - %s\n' "${bad[@]}" >&2
            return 1
        fi
        ok "启用前检查通过"
    fi

    run sudo systemctl enable greetd
    $DRY_RUN || ok "已启用。重启后进 tuigreet 登录界面"
    dim "  未重启前随时可撤：sudo systemctl disable greetd"
}

# ------------------------------------------------------------- 5. noctalia --
stage_noctalia() {
    banner "阶段 noctalia · 桌面壳 v5（03_noctalia.md）"

    local suite=""
    case "${DISTRO}:${CODENAME}" in
        ubuntu:resolute) suite=resolute ;;
        debian:trixie)   suite=trixie ;;
    esac
    if [[ -z "$suite" ]]; then
        err "noctalia 只发布 trixie / resolute 构建，当前 ${DISTRO} ${CODENAME} 无构建"
        return 1
    fi

    info "1/3 签名密钥"
    if [[ -f /usr/share/keyrings/nickh-archive-keyring.gpg ]]; then
        dim "    已存在，跳过"
    else
        net_fetch https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb "${TMP_DIR}/nickh-archive-keyring.deb" 1000
        run sudo dpkg -i "${TMP_DIR}/nickh-archive-keyring.deb"
        run_sh "rm -f '${TMP_DIR}/nickh-archive-keyring.deb'"
    fi

    info "2/3 加源 noctalia-${suite}.sources"
    local src=/etc/apt/sources.list.d/noctalia-${suite}.sources
    # 清理不匹配的源要无条件做：放在「目标源不存在」的分支里，
    # 两份 suite 就会共存，apt 拉到哪份构建看运气（03_noctalia.md §1.2）。
    for old in /etc/apt/sources.list.d/noctalia-*.sources; do
        [[ -e "$old" && "$old" != "$src" ]] || continue
        warn "  发现不匹配的源 ${old}，移除（03_noctalia.md §1.2）"
        run sudo rm -f "$old"
    done
    if [[ -f "$src" ]]; then
        dim "    ${src} 已存在"
    else
        net_fetch "https://pkg.noctalia.dev/deb/noctalia-${suite}.sources" "${TMP_DIR}/noctalia-${suite}.sources" 50
        run sudo install -m644 "${TMP_DIR}/noctalia-${suite}.sources" "$src"
        run_sh "rm -f '${TMP_DIR}/noctalia-${suite}.sources'"
    fi
    apt_update

    info "3/3 安装"
    apt_install required noctalia

    info "可选（默认不装）"
    dim "    noctalia-greeter          仅要图形登录界面时（会拉图形栈）"
    dim "    umbriel + xdg-desktop-portal-umbriel   功能定位仍未核实，默认不装"
    dim "    已用 greetd 的话，17_greetd.md §九 建议先跑通 tuigreet 再说"

    log ""
    log "  安装后还需你自己做的两件事（本脚本不改你的配置）："
    log "    1. ~/.config/niri/config.kdl 末尾加：spawn-at-startup \"noctalia\""
    log "    2. 若之前装了 waybar：pkill waybar，并删掉 spawn-at-startup \"waybar\" 那一行"
}

# ---------------------------------------------------------------- 6. audio --
stage_audio() {
    banner "阶段 audio · PipeWire（15_audio.md）"

    info "核心：用 pipewire-audio 元包，不要手拼四个包"
    dim "    旧配方漏了 libspa-0.2-bluetooth → 蓝牙耳机配对成功但没声音"

    # pulseaudio 与 pipewire-audio 冲突（Conflicts + Replaces），会被移除
    if dpkg_installed pulseaudio; then
        warn "检测到已装 pulseaudio。pipewire-audio 与它 Conflicts，apt 会把它移除。"
        warn "两者同抢 ALSA 设备控制权（/etc/alsa/conf.d/99-pulse.conf 会排在后面夺权）。"
        if ! confirm "  继续（移除 pulseaudio）？" y; then
            warn "  已取消本阶段"
            return 0
        fi
    fi

    apt_update

    info "必要 + 两个必须显式补的 Recommends"
    apt_install required pipewire-audio alsa-ucm-conf
    apt_install optional rtkit

    info "可选"
    dim "    pulseaudio-utils   提供 pactl（pipewire-pulse 不自带）—— 要跑验证命令就得装"
    dim "    pavucontrol        图形混音器"
    dim "    playerctl          媒体键控制"
    if confirm "  装 pulseaudio-utils（为了 pactl 验证）？" y; then
        apt_install optional pulseaudio-utils
    fi
    # 下面验证要跑 aplay -l，而 aplay 来自 alsa-utils —— 不装就是给用户
    # 一条跑不起来的空指令（原脚本确实这样）。
    dim "    alsa-utils         提供 aplay / alsamixer（验证那行 aplay -l 需要）"
    apt_install optional alsa-utils

    info "启用用户服务"
    user_systemctl enable --now pipewire pipewire-pulse wireplumber

    info "验证"
    if $DRY_RUN; then
        dim "    跳过（dry-run 下包尚未安装）"
    else
        local missing=()
        dpkg_installed alsa-ucm-conf || missing+=("alsa-ucm-conf")
        dpkg_installed rtkit        || missing+=("rtkit")
        if (( ${#missing[@]} > 0 )); then
            warn "缺 ${missing[*]} —— --no-install-recommends 的代价，见 15_audio.md 第一节"
        fi
        if [[ -d /usr/share/alsa/ucm2 ]] && [[ -z "$(ls -A /usr/share/alsa/ucm2 2>/dev/null)" ]]; then
            err "/usr/share/alsa/ucm2/ 为空 → 声卡命名错乱、HDMI/模拟口全变 default"
            err "确认 alsa-ucm-conf 装上了没有"
        fi
    fi

    if ! $DRY_RUN; then
        log "  下面几条要登录 niri 会话后才有意义："
        log "    wpctl status"
        log "    LANG=C pactl info | grep '^Server Name'   # 期望 PulseAudio (on PipeWire 1.x.x)"
        log "    aplay -l                                  # 内核认到声卡没有"
    fi
}

# ------------------------------------------------------------ 7. bluetooth --
stage_bluetooth() {
    banner "阶段 bluetooth · 蓝牙键盘（16_bluetooth.md）"

    info "蓝牙键盘不需要 blueman。bluez 的 bluetoothctl 配对一次即可"

    apt_update

    info "必要"
    apt_install required bluez
    # rfkill 在 Debian 是独立包（不在 util-linux 里）。没有它就没法解除软阻塞，
    # 蓝牙适配器会一直处于 Soft blocked，scan 扫不到任何设备。
    apt_install optional rfkill

    info "启用服务"
    run sudo systemctl enable --now bluetooth

    info "解除软阻塞"
    if $DRY_RUN; then
        run_root "rfkill unblock bluetooth"
    elif ! run_root "rfkill unblock bluetooth"; then
        warn "  rfkill 没成功（可能没装 rfkill，或被硬开关挡住）"
        warn "  蓝牙扫不到设备时手动确认：sudo rfkill list; sudo rfkill unblock bluetooth"
    fi

    dim "    bluez-firmware / firmware-iwlwifi 视芯片而定，本脚本不装"

    log ""
    log "  配对三步不可省（缺 trust 则开机不自动重连 —— 最常见的坑）："
    log "    bluetoothctl"
    log "      power on → agent KeyboardDisplay → default-agent → scan on"
    log "      pair XX:XX:XX:XX:XX:XX      # 键盘上会显示 6 位数字，按完回车"
    log "      trust XX:XX:XX:XX:XX:XX"
    log "      connect XX:XX:XX:XX:XX:XX"
    log "    pair 卡住不出数字键：先 remove 再重新 pair，多半是上次配对残留"
    log ""
    log "  键盘不主动回连时，两种办法（本脚本都不碰配置）："
    log "    A. 在 niri config.kdl 里补一条："
    log "       spawn-at-startup \"sh\" \"-c\" \"sleep 5; bluetoothctl connect XX:XX:XX:XX:XX:XX\""
    log "    B. /etc/bluetooth/main.conf 的 [Policy] 段里设 AutoEnable=true"
    log "       （bluez 默认可能因 rfkill 启动时处于软阻塞而不自动上电）"
    log ""
    log "  要显示电量才需要 Experimental = true（Debian Wiki 提醒可能影响输入设备）"
}

# --------------------------------------------------------------- 2. fonts ---
stage_fonts() {
    banner "阶段 fonts · 字体（10_fonts.md）"

    info "只要 3 个字体文件，不装整套 nerd-fonts（几十个字体、几百 MB）"

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
        dim "    ${nf_file} 已存在，跳过"
    else
        info "下载 Nerd 版 JetBrains Mono（${nf_ver}，约 7 MB）"
        dim "    用 .tar.xz 不用 .zip：内容一样，127.8 MB → 6.9 MB"
        # xz-utils 是解 .tar.xz 的前置（13_base.md 没有这个包）
        apt_install optional xz-utils
        if net_fetch "${nf_url}" "${TMP_DIR}/JBM.tar.xz" 100000 && \
           run_sh "tar -C '${TMP_DIR}' -xJf '${TMP_DIR}/JBM.tar.xz' '${nf_file}'" && \
           run_root "install -d -m755 /usr/local/share/fonts" && \
           run sudo install -m644 "${TMP_DIR}/${nf_file}" /usr/local/share/fonts/ ; then
            ok "${nf_file} → /usr/local/share/fonts/"
        else
            warn "  Nerd 字体安装失败。手动试："
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
        warn "  没有中文字体。两个选择（见 10_fonts.md §4.3）："
        warn "    A. sudo apt install fonts-lxgw-wenkai            （原版字重，约 60 MB）"
        warn "    B. 下 Screen 版（字重较粗，26.4 MB）："
        warn "       curl -fL -O https://github.com/lxgw/LxgwWenKai-Screen/releases/download/v1.530/LXGWWenKaiMonoGBScreen.ttf"
        if confirm "  现装仓库版的 fonts-lxgw-wenkai（选项 A）？" y; then
            apt_install optional fonts-lxgw-wenkai
        fi
    fi

    info "验证"
    if ! $DRY_RUN; then
        if sh_contains 'JetBrainsMono Nerd Font' fc-list; then
            ok "JetBrainsMono Nerd Font 已识别"
        else
            warn "未识别到 JetBrainsMono Nerd Font —— 图标会变成方块"
        fi
        if sh_contains 'LXGW WenKai Mono' fc-list; then
            ok "LXGW WenKai Mono 已识别"
        else
            warn "未识别到 LXGW WenKai Mono"
        fi
    fi
}

# ---------------------------------------------------------------- 8. fish ---
stage_fish() {
    banner "阶段 fish · 交互式 shell（04_fish.md）"

    info "两个发行版的官方仓库都已是 fish 4.x —— 不加任何第三方源"
    dim "    Ubuntu 26.04: 4.2.1-3.2    Debian 13: 4.0.2-1"
    dim "    OBS shells:fish 现供 4.9.x（比 trixie 主仓库新，加源只会升级）；"
    dim "    脚本按文档只吃主仓库，想要新版自己加源即可"

    apt_update
    apt_install required fish

    info "插件依赖（fzf.fish 用）"
    apt_install optional fzf fd-find

    # Debian/Ubuntu 把 fd 装成 fdfind，而 fzf.fish 找的是 fd
    if ! $DRY_RUN && dpkg_installed fd-find && command -v fdfind >/dev/null 2>&1; then
        if [[ ! -e "${HOME}/.local/bin/fd" ]]; then
            if confirm "  建软链 ~/.local/bin/fd → fdfind？（fzf.fish 需要）" y; then
                mkdir -p "${HOME}/.local/bin"
                ln -sf "$(command -v fdfind)" "${HOME}/.local/bin/fd"
                ok "已建 ${HOME}/.local/bin/fd"
                dim "    确认 ~/.local/bin 在 PATH 里"
            fi
        else
            dim "    ~/.local/bin/fd 已存在"
        fi
    fi

    info "验证"
    if command -v fish >/dev/null 2>&1 && ! $DRY_RUN; then
        fish --version | sed 's/^/    /'
    fi

    warn "不要执行 chsh -s fish —— 登录 shell 改成 fish 会导致桌面无法登录"
    dim "    有些启动脚本用 bash 语法。保持 bash，用时手动 exec fish"

    log ""
    log "  装插件（本脚本不碰配置，需你自己跑）："
    log "    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source"
    log "    fisher install jorgebucaran/fisher"
    log "    fisher install PatrickF1/fzf.fish"
    dim "    提示符二选一：有自定义 fish_prompt.fish 就别装 starship 插件，会互相覆盖"
}

# -------------------------------------------------------------- 9. wezterm ---
stage_wezterm() {
    banner "阶段 wezterm · 终端（05_wezterm.md）"

    # wezterm 与 wezterm-nightly 冲突，只能装一个
    if ! $DRY_RUN && dpkg_installed wezterm-nightly && ! dpkg_installed wezterm; then
        warn "已装 wezterm-nightly。两者不能共存，本阶段不装稳定版。"
        warn "  要换稳定版：sudo apt remove wezterm-nightly，再跑本阶段"
        return 0
    fi

    info "1/2 加 WezTerm 官方 APT 源（apt.fury.io）"
    if [[ -f /usr/share/keyrings/wezterm-fury.gpg ]]; then
        dim "    密钥已存在"
    else
        net_fetch https://apt.fury.io/wez/gpg.key "${TMP_DIR}/wezterm-fury.key" 200
        net_retry "导入 wezterm 密钥" \
            sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg "${TMP_DIR}/wezterm-fury.key"
        run_sh "rm -f '${TMP_DIR}/wezterm-fury.key'"
    fi
    if [[ -f /etc/apt/sources.list.d/wezterm.list ]]; then
        dim "    源文件已存在"
    else
        run_root "printf '%s\n' 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' > /etc/apt/sources.list.d/wezterm.list"
    fi
    # _apt 用户要能读这个密钥，否则 apt update 报 NO_PUBKEY / 权限错。
    run_root "chmod 644 /usr/share/keyrings/wezterm-fury.gpg"
    apt_update

    info "2/2 安装稳定版（不是 nightly：nightly 会带未测回归）"
    apt_install required wezterm

    info "验证"
    if command -v wezterm >/dev/null 2>&1 && ! $DRY_RUN; then
        wezterm --version | sed 's/^/    /'
    fi

    dim "    配置：把 07_Archive/backup 里的 wezterm.lua 放到 ~/.config/wezterm/（本脚本不碰）"
}

# -------------------------------------------------------------- 10. neovim ---
stage_neovim() {
    banner "阶段 neovim · 编辑器（06_neovim.md）"

    apt_update

    local use_tarball=false
    if [[ "$DISTRO" == "ubuntu" ]]; then
        dim "    Ubuntu 26.04 仓库是 0.11.6-1 ≥ LazyVim 要求的 0.11.2，用 apt 就够"
        apt_install required neovim
    else
        dim "    Debian 13 仓库只到 0.10.4-8 < 0.11.2，差一个大版本 —— 走官方 tarball"
        use_tarball=true
    fi

    if $use_tarball; then
        if ! $DRY_RUN && dpkg_installed neovim; then
            warn "已装仓库版 neovim（0.10.4，跑不了 LazyVim）"
            warn "  tarball 版会装到 /opt/nvim，软链 /usr/local/bin/nvim 优先级高于 /usr/bin/nvim"
            if ! confirm "  继续安装 tarball 版？" y; then
                return 0
            fi
        fi
        info "从官方 release 取最新 tarball"
        dim "    安装到 /opt/nvim，软链 /usr/local/bin/nvim"
        net_fetch \
            https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
            "${TMP_DIR}/nvim.tar.gz" 1000000
        run_sh "rm -rf '${TMP_DIR}/nvim-linux-x86_64' && tar -C '${TMP_DIR}' -xzf '${TMP_DIR}/nvim.tar.gz'"
        if ! $DRY_RUN && [[ ! -x "${TMP_DIR}/nvim-linux-x86_64/bin/nvim" ]]; then
            err "解压结果中没有可执行的 nvim；保留现有 /opt/nvim 未作改动"
            return 1
        fi
        run_root "set -e; stage=/opt/.nvim-new-${TARGET_UID}; backup=/opt/nvim.backup.\$(date +%Y%m%d-%H%M%S)-\$\$; rm -rf \"\$stage\"; cp -a '${TMP_DIR}/nvim-linux-x86_64' \"\$stage\"; chown -R root:root \"\$stage\"; if [ -e /opt/nvim ] || [ -L /opt/nvim ]; then mv /opt/nvim \"\$backup\"; had_old=true; else had_old=false; fi; if mv \"\$stage\" /opt/nvim; then if \$had_old; then printf 'Previous Neovim preserved at %s\\n' \"\$backup\"; fi; else rc=\$?; if \$had_old; then mv \"\$backup\" /opt/nvim || printf 'Rollback failed; previous Neovim remains at %s\\n' \"\$backup\" >&2; fi; exit \$rc; fi"
        run_root "ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim"
        run_sh "rm -f '${TMP_DIR}/nvim.tar.gz'"
        $DRY_RUN || ok "已装到 /opt/nvim"
    fi

    info "可选：markdown 图片内联显示（LazyVim 的 magick）"
    dim "    imagemagick + libmagickwand-dev + luarocks，只有要内联图片才需要"
    if confirm "  装这三个？（不装则图片显示成链接文本）" n; then
        apt_install optional imagemagick libmagickwand-dev luarocks
        log "  之后以 ${TARGET_USER} 身份跑（必须带 --local，否则装到 /usr/local 需 root）："
        log "    luarocks --local install magick"
    fi

    info "验证"
    if ! $DRY_RUN; then
        if command -v nvim >/dev/null 2>&1; then
            local nv; nv="$(command -v nvim)"
            dim "    路径：${nv}"
            nvim --version 2>/dev/null | head -1 | sed 's/^/    /'
            # LazyVim 硬要求 LuaJIT
            if sh_contains luajit nvim --version; then
                ok "满足 LazyVim 的 LuaJIT 要求"
            else
                warn "凭版本输出看不出 LuaJIT，LazyVim 要求 LuaJIT 构建"
            fi
            if [[ "$nv" == /usr/bin/nvim ]]; then
                warn "  正在用 /usr/bin/nvim。若装了 tarball，检查 PATH 顺序"
            fi
        else
            warn "找不到 nvim"
        fi
    fi
}

# -------------------------------------------------------------- 11. fcitx5 ---
stage_fcitx5() {
    banner "阶段 fcitx5 · 中文输入法（07_fcitx5.md）"

    info "核心：Wayland 下不要设 GTK_IM_MODULE，只要 XMODIFIERS + QT_IM_MODULE"

    apt_update

    info "必要"
    apt_install required fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk4 fcitx5-frontend-qt6

    info "推荐：图形配置界面"
    apt_install optional fcitx5-config-qt

    dim "    fcitx5-chinese-addons 已含拼音引擎，不要另装 fcitx5-pinyin"
    dim "    fcitx5-frontend-gtk3 / fcitx5-frontend-qt5 只在有老版程序时才装"

    log ""
    log "  还需在 ~/.config/niri/config.kdl 加（本脚本不碰配置）："
    log "    spawn-at-startup \"fcitx5\" \"-d\""
    log "    environment {"
    log "        XMODIFIERS \"@im=fcitx\""
    log "        QT_IM_MODULE \"fcitx\""
    log "    }"
    warn "    绝对不要加 GTK_IM_MODULE —— 会让候选框闪烁或位置错乱"
    dim "    GTK3/4 改用 ~/.config/gtk-{3,4}.0/settings.ini 里的 gtk-im-module=fcitx"

    log ""
    log "  验证（进 niri 会话后）："
    log "    pgrep -a fcitx5"
    log "    fcitx5-diagnose | head -40    # GTK_IM_MODULE 应为空，QT_IM_MODULE 应为 fcitx"
}

# --------------------------------------------------------------- 12. zotero ---
stage_zotero() {
    banner "阶段 zotero · 文献管理（08_zotero.md）"

    info "用 zotero-deb —— Zotero 官方文档唯一背书的第三方源"

    if [[ -f /etc/apt/sources.list.d/zotero.list ]] || [[ -f /etc/apt/sources.list.d/zotero.sources ]]; then
        dim "    源文件已存在，跳过加源"
        apt_update
    else
        # 官方给的是一条 curl | sudo bash。管道执行远程脚本无法审查，
        # 所以先落到本地、把开头打出来、确认后再跑。
        info "下载 zotero-deb 的 install.sh 供你检查（不直接管道执行）"
        net_fetch https://raw.githubusercontent.com/retorquere/zotero-pkg/master/install.sh "${TMP_DIR}/zotero-install.sh" 500
        if ! $DRY_RUN; then
            log "  ---- install.sh 前 20 行 ----"
            head -20 "${TMP_DIR}/zotero-install.sh" | sed 's/^/    /'
            log "  ---- 共 $(wc -l <"${TMP_DIR}/zotero-install.sh") 行，完整文件 ${TMP_DIR}/zotero-install.sh ----"
        fi
        if ! confirm "  这个脚本会写 /etc/apt/sources.list.d/ 并加签名密钥。执行它？" y; then
            warn "已跳过加源。可自己看过 ${TMP_DIR}/zotero-install.sh 再决定（脚本结束时会清理）"
            return 0
        fi
        run sudo bash "${TMP_DIR}/zotero-install.sh"
        apt_update
    fi

    apt_install required zotero

    info "验证"
    if command -v zotero >/dev/null 2>&1 && ! $DRY_RUN; then
        zotero --version 2>/dev/null | sed 's/^/    /' || true
    fi

    log ""
    log "  首次使用后两件事："
    log "    1. Better BibTeX 插件没有 CLI 装法，从 releases 下 .xpi 手动装："
    log "       https://github.com/retorquere/zotero-better-bibtex/releases"
    log "    2. 若之前装过 tarball 版，删残留：rm -f ~/.local/share/applications/zotero.desktop"
}

# ---------------------------------------------------------------- 13. tex ---
stage_tex() {
    banner "阶段 tex · TinyTeX + zathura（11_tex.md）"

    apt_update

    info "必要：TinyTeX 安装脚本的前置"
    apt_install required perl xz-utils

    info "编译调用链 + PDF 预览"
    dim "    latexmk 的 Depends 是 texlive-latex-base —— 装它会连带拉进一整套"
    dim "    texlive 和 /usr/bin/pdflatex，和 TinyTeX 的 PATH 打架（11_tex.md §4.1）"
    if confirm "  仍要 apt 装 latexmk（会带 texlive-latex-base）？" y; then
        apt_install optional latexmk
    else
        dim "    跳过。TinyTeX 里也能装：tlmgr install latexmk"
    fi
    apt_install required zathura zathura-pdf-poppler

    # 安装脚本里有 rm -rf $TEXDIR，重跑会清空已装宏包
    if [[ -d "${HOME}/.TinyTeX" ]]; then
        warn "${HOME}/.TinyTeX 已存在。安装脚本里有 rm -rf \$TEXDIR，重跑会清空已装宏包。"
        warn "  升级请用：tlmgr update --self --all"
        return 0
    fi

    info "装 TinyTeX（用户级，不需要 root，约 50–70 MB）"
    dim "    目录 ${HOME}/.TinyTeX，软链 ~/bin 或 ~/.local/bin"
    if ! confirm "  现在装 TinyTeX？" y; then
        dim "    跳过。手动：wget -qO- https://tinytex.yihui.org/install-bin-unix.sh | sh"
        return 0
    fi
    # 官方脚本是「下载后直接 sh」。管道形式无法判断是网络断还是脚本报错，
    # 所以先下载到本地，校验非空再执行。
    local tt="${TMP_DIR}/tinytex-install.sh"
    # dry-run 下 net_fetch 不会真的产生文件，紧接着的 grep 必然失败，
    # 于是误报「下载失败」—— 校验要跳过（否则 dry-run 会自己吓自己）。
    if net_fetch https://tinytex.yihui.org/install-bin-unix.sh "$tt" 500 \
        && { $DRY_RUN || grep -q 'TinyTeX' "$tt" 2>/dev/null; }; then
        run_sh "sh '$tt'"
        run_sh "rm -f '$tt'"
    else
        err "  TinyTeX 安装脚本下载失败或内容不对，跳过"
        warn "    手动：wget -qO- https://tinytex.yihui.org/install-bin-unix.sh | sh"
        SKIPPED+=("tinytex")
    fi

    info "装中文宏包（--no-doc 省空间）"
    dim "    ctex setspace environ trimspaces zhnumber fancyhdr ms"
    if ! $DRY_RUN; then
        local tlmgr="${HOME}/.TinyTeX/bin/x86_64-linux/tlmgr"
        if [[ -x "$tlmgr" ]]; then
            run "$tlmgr" install --no-doc ctex setspace environ trimspaces zhnumber fancyhdr ms || \
                warn "  tlmgr 出错。手动：tlmgr install --no-doc ctex setspace environ trimspaces zhnumber fancyhdr ms"
        else
            warn "  没找到 ${tlmgr}，跳过宏包"
        fi
    fi

    info "验证"
    if ! $DRY_RUN; then
        # 只跑 command -v 会被 apt 装的 texlive 骗过去：装过 latexmk 之后
        # /usr/bin/pdflatex 一定在，看着「通过」，实际用的不是 TinyTeX。
        local ttbin="${HOME}/.TinyTeX/bin/x86_64-linux"
        local c p
        for c in pdflatex xelatex tlmgr; do
            p="$(command -v "$c" 2>/dev/null || true)"
            if [[ -z "$p" ]]; then
                warn "  ${c} 不在 PATH —— 把 ${ttbin} 加进 PATH，或跑 tlmgr path add"
            elif [[ "$p" == /usr/bin/* ]]; then
                warn "  ${c} → ${p}：这是 apt 装的 texlive，不是 TinyTeX"
                warn "    想用 TinyTeX：export PATH=\"${ttbin}:\$PATH\""
            else
                dim "    ${c}: ${p}"
            fi
        done
        if [[ ! -x "${ttbin}/pdflatex" ]]; then
            warn "  ${ttbin}/pdflatex 不存在 —— TinyTeX 可能没装成"
        fi
    fi

    dim "    与系统 texlive 冲突时才需要 texlive-local.deb，见 11_tex.md 第四节第一小节"
}

# --------------------------------------------------------------- 14. tmux ---
stage_tmux() {
    banner "阶段 tmux · 终端复用器（12_tmux.md）"

    info "一个包就够，不需要任何第三方源"
    apt_update
    apt_install required tmux

    info "验证"
    if command -v tmux >/dev/null 2>&1 && ! $DRY_RUN; then
        tmux -V | sed 's/^/    /'
    fi

    log ""
    log "  配置（gpakosz/.tmux）本脚本不碰，需你自己跑："
    log "    git clone --single-branch https://github.com/gpakosz/.tmux.git ~/.tmux"
    log "    ln -s .tmux/.tmux.conf ~/.tmux.conf"
    log "    cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local"
    warn "    建软链前先判悬空软链："
    warn "      if [ ! -e ~/.tmux.conf ] && [ ! -L ~/.tmux.conf ]; then ln -s ...; fi"
    dim "    -e 对悬空软链返回假，只用 -e 会让 ln 报 File exists 并中止脚本"
}

# ================================================================ 阶段注册 ==
STAGE_ORDER=(
    base fonts gpu niri greetd noctalia
    fish wezterm neovim
    audio bluetooth
    fcitx5 zotero tex tmux
)
declare -A STAGE_DESC=(
    [base]="基础工具：curl/git/gnupg/ripgrep/fzf + 时区"
    [gpu]="AMD 用户态驱动：mesa-vulkan-drivers + libgl1-mesa-dri"
    [niri]="niri：加源（PPA 或 OBS）+ 主体 + portal"
    [greetd]="显示管理器：greetd + tuigreet + 写 config.toml（不启用）"
    [greetd-enable]="启用 greetd（有锁死风险，需单独确认）"
    [noctalia]="桌面壳 v5：密钥 + 源 + noctalia"
    [audio]="PipeWire：pipewire-audio 元包 + alsa-ucm-conf + rtkit"
    [bluetooth]="蓝牙：bluez + 服务 + 配对指引"
    [fish]="fish shell + fzf/fd-find + fdfind 软链"
    [wezterm]="WezTerm：fury 官方源 + 稳定版"
    [neovim]="Neovim：Ubuntu 用 apt，Debian 13 必须用官方 tarball"
    [fcitx5]="中文输入法：fcitx5 + chinese-addons + gtk4/qt6 frontend"
    [zotero]="Zotero：zotero-deb 源（先审查 install.sh）"
    [tex]="TinyTeX + latexmk + zathura + 中文宏包"
    [tmux]="tmux（只装包，配置你手动克隆）"
    [fonts]="字体：Nerd JetBrains Mono v3.5.1 + 中文字体（二选一）"
)

# 帮助用的元数据：分组 / 装什么 / 文档 / 前置 / 风险标记。
# STAGE_DESC 保持一句话（阶段确认提示直接用它），细节放 STAGE_PKGS。
STAGE_GROUPS=(
    "系统层:base fonts gpu"
    "桌面环境:niri greetd greetd-enable noctalia"
    "终端与编辑器:fish wezterm tmux neovim"
    "硬件:audio bluetooth"
    "应用:fcitx5 zotero tex"
)
declare -A STAGE_PKGS=(
    [base]="ca-certificates curl wget gnupg git unzip|ripgrep fd-find fzf wl-clipboard bash-completion|按需：lazygit（仓库无此包则从 GitHub 取二进制）、keyd"
    [fonts]="fontconfig unzip + JetBrainsMono Nerd Font v3.5.1（只取 3 个文件）|中文字体二选一：fonts-lxgw-wenkai 或手动放 LXGWWenKaiMonoGBScreen.ttf"
    [gpu]="mesa-vulkan-drivers libgl1-mesa-dri|RX 7900 XTX 走内核 in-tree amdgpu，不需要闭源驱动 / DKMS"
    [niri]="niri + portal / xwayland 依赖|推荐：mako-notifier polkit-kde-agent-1|绑定键可选：fuzzel swaylock wl-clipboard"
    [greetd]="greetd tuigreet|写 /etc/greetd/config.toml（tuigreet + vt=7 + _greetd + niri-session）|不执行 systemctl enable"
    [greetd-enable]="systemctl enable --now greetd|配错会「一个光标、无提示」，启用前先看 17_greetd.md §六"
    [noctalia]="签名密钥 + pkg.noctalia.dev 源 + noctalia|默认不装：noctalia-greeter（会拉图形栈）、umbriel"
    [audio]="pipewire-audio alsa-ucm-conf rtkit|可选：pulseaudio-utils（提供 pactl）、pavucontrol、playerctl、alsa-utils"
    [bluetooth]="bluez（+ rfkill）|不用 blueman；配对后必须 trust 才能开机自动重连"
    [fish]="fish 4.x（官方仓库，无第三方源）|fzf fd-find + ~/.local/bin/fd 软链；fisher 插件你自己装"
    [wezterm]="apt.fury.io 官方源 + wezterm 稳定版（不是 nightly）"
    [tmux]="tmux（单个包，无第三方源）|配置文件你自己克隆，脚本不碰 ~/.config"
    [neovim]="Ubuntu：apt neovim|Debian 13：官方 tarball 解到用户目录|可选：imagemagick libmagickwand-dev luarocks（markdown 内联图片）"
    [fcitx5]="fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk4 fcitx5-frontend-qt6|可选：fcitx5-config-qt（图形配置）"
    [zotero]="zotero-deb 源（先下载 install.sh 供你审查）+ zotero"
    [tex]="perl xz-utils + zathura zathura-pdf-poppler|TinyTeX 装到 \$HOME（约 50–70 MB）+ latexmk + 中文宏包"
)
declare -A STAGE_DOC=(
    [base]="13_base.md"        [fonts]="10_fonts.md"     [gpu]="01_niri.md §五"
    [niri]="01_niri.md"        [greetd]="17_greetd.md"   [greetd-enable]="17_greetd.md §六"
    [noctalia]="03_noctalia.md" [fish]="04_fish.md"      [wezterm]="05_wezterm.md"
    [tmux]="12_tmux.md"        [neovim]="06_neovim.md"   [fcitx5]="07_fcitx5.md"
    [zotero]="08_zotero.md"    [tex]="11_tex.md"         [audio]="15_audio.md"
    [bluetooth]="16_bluetooth.md"
)
declare -A STAGE_NEEDS=(
    [niri]="建议先 base"
    [greetd]="先 niri（读 niri-session 会话文件）"
    [greetd-enable]="先 greetd 且已核对 config.toml"
    [noctalia]="先 niri"
    [fcitx5]="建议先 fonts"
    [wezterm]="需 base 里的 curl/gnupg"
    [zotero]="需 base 里的 curl/gnupg"
    [audio]="无"
    [tex]="无（TinyTeX 用户级安装）"
)
declare -A STAGE_TAG=(
    [greetd-enable]="高风险"
    [zotero]="要审查脚本"
)

# 单个阶段的帮助条目：一句话 + 装什么 + 文档/前置
_usage_stage() {
    local s="$1" line="" meta=""
    printf '  %-16s %s\n' "$s" "${STAGE_DESC[$s]:-}"
    local IFS='|'
    local first=true
    for line in ${STAGE_PKGS[$s]:-}; do
        if $first; then
            printf '  %-16s   · 装：%s\n' "" "$line"
            first=false
        else
            printf '  %-16s         %s\n' "" "$line"
        fi
    done
    unset IFS
    [[ -n "${STAGE_DOC[$s]:-}"   ]] && meta+="文档 ${STAGE_DOC[$s]}"
    [[ -n "${STAGE_NEEDS[$s]:-}" ]] && meta+="   前置 ${STAGE_NEEDS[$s]}"
    [[ -n "${STAGE_TAG[$s]:-}"   ]] && meta+="   [${STAGE_TAG[$s]}]"
    [[ -n "$meta" ]] && printf '  %-16s   · %s\n' "" "${meta#  }"
    return 0
}

usage() {
    local group name s
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — v2 桌面环境安装（系统层）

用法：
  ${SCRIPT_NAME} --help                     本说明（含每个阶段装了哪些包）
  ${SCRIPT_NAME} --list                     只列阶段名（紧凑，便于复制）
  ${SCRIPT_NAME} --all                      按内置顺序跑全部阶段（不含 greetd-enable）
  ${SCRIPT_NAME} --only base,niri,fonts     只跑指定阶段（逗号分隔）
  ${SCRIPT_NAME} --only=base,niri           同上，等号写法也行
  ${SCRIPT_NAME} --all --dry-run            只打印命令，不改系统
  ${SCRIPT_NAME} --all --yes                不逐阶段确认（greetd-enable 仍会问）

选项：
  --all             全部阶段（不含 greetd-enable）
  --only LIST       逗号分隔，可重复写（--only a --only b）
  --list            紧凑列出阶段名 + 一句话说明
  --dry-run         只打印命令，不写系统
  --yes, -y         不逐阶段确认
  -h, --help        本说明

阶段（${#STAGE_ORDER[@]} 个可组合模块 + 1 个高风险开关）：
  分组只是为了好读；实际执行顺序 = 你在 --only 里给的顺序，--all 用内置顺序。
EOF
    for group in "${STAGE_GROUPS[@]}"; do
        name="${group%%:*}"
        printf '\n  ── %s %s\n' "$name" "────────────────────────────────────────────"
        for s in ${group#*:}; do
            _usage_stage "$s"
        done
    done
    cat <<EOF

常用组合：
  先要一个能登录的桌面
      ${SCRIPT_NAME} --only base,gpu,niri,greetd,noctalia
  再加终端 / 编辑器
      ${SCRIPT_NAME} --only fish,wezterm,tmux,neovim
  中文显示与输入
      ${SCRIPT_NAME} --only fonts,fcitx5
  写论文
      ${SCRIPT_NAME} --only tex,zotero
  声音与蓝牙键盘
      ${SCRIPT_NAME} --only audio,bluetooth
  全都要（greetd 只配置，不启用）
      ${SCRIPT_NAME} --all

顺序与依赖（脚本不会替你排）：
  · base 最先：加第三方源要 curl / gnupg。
  · niri 先于 greetd 和 noctalia：后两者要读 niri-session 会话文件。
  · fonts 建议在 fcitx5 之前：先有中文字体，输入法才有字可显示。
  · greetd-enable 单独跑：唯一会 systemctl enable 的步骤，配错会卡在光标界面。

重复执行与失败：
  · 阶段可以单独重跑：已装的包 apt 会跳过。
  · 配置只在缺失或内容不对时询问后改写，改写前自动备份（.bak.<时间戳>）。
  · 任一阶段失败会打印失败行号与当前阶段并退出，不会闷着往下走。
  · 仓库里找不到的包（Candidate: (none)）不硬装，最后汇总在「已跳过」里。

网络（墙内环境）：
  外围站（GitHub / openSUSE OBS / fury / pkg.noctalia.dev / tinytex）失败会退避重试
  5 30 60 120 300 秒（上限 300）；累计等满 15 分钟问一次是否放弃这一项。
  想改阈值：NET_GIVEUP_MIN=30 ${SCRIPT_NAME} --all
  apt 源不走重试（Debian / Ubuntu 源一般不堵）。

注意：
  · 必须以普通用户运行，不要 sudo ./${SCRIPT_NAME}（用户级内容会落进 /root）。
  · 不改 ~/.config、不自动改时区。系统写入仅：APT 源、/etc/greetd/config.toml、
    必要时的 niri 本地会话覆盖文件。
  · 明确不装 waybar（你用 noctalia，两者不能同时装）、不装 opencode（09_opencode.md 自理）。
EOF
}

# --list：只要名字，方便复制进 --only
list_stages() {
    local s
    printf '%s %s — 可组合阶段（%d 个 + greetd-enable）：\n\n' \
        "$SCRIPT_NAME" "$SCRIPT_VERSION" "${#STAGE_ORDER[@]}"
    for s in "${STAGE_ORDER[@]}"; do
        printf '  %-16s %s\n' "$s" "${STAGE_DESC[$s]:-}"
    done
    printf '  %-16s %s\n' "greetd-enable" "${STAGE_DESC[greetd-enable]:-}"
    printf '\n安装示例：%s --only base,niri,fonts\n' "$SCRIPT_NAME"
    printf '看每阶段装什么：%s --help\n' "$SCRIPT_NAME"
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
                    err "--only 需要一个参数，例如 --only base,niri"
                    exit 1
                fi
                saw_only=true
                IFS=',' read -r -a _tmp <<<"$1"; selected+=("${_tmp[@]}") ;;
            --only=*)
                if [[ -z "${1#*=}" ]]; then
                    err "--only= 后面不能为空，例如 --only=base,niri"
                    exit 1
                fi
                saw_only=true
                IFS=',' read -r -a _tmp <<<"${1#*=}"; selected+=("${_tmp[@]}") ;;
            --list)     list_stages; exit 0 ;;
            --dry-run)  DRY_RUN=true ;;
            --yes|-y)   ASSUME_YES=true ;;
            -h|--help)  usage; exit 0 ;;
            *)          err "不认识的参数：$1"; usage; exit 1 ;;
        esac
        shift
    done

    if $want_all && $saw_only; then
        err "--all 与 --only 不能同时使用；请只指定其中一种"
        exit 1
    fi

    if $want_all; then
        RUN_LIST=("${STAGE_ORDER[@]}")
    elif ((${#selected[@]})); then
        RUN_LIST=("${selected[@]}")
    else
        err "没指定阶段。用 --all 或 --only"; usage; exit 1
    fi

    local s
    for s in "${RUN_LIST[@]}"; do
        if [[ -z "${STAGE_DESC[$s]:-}" ]]; then
            err "未知阶段：$s"; usage; exit 1
        fi
    done
}

# ==================================================================== main ==
main() {
    parse_args "$@"

    if [[ "$EUID" -eq 0 ]]; then
        err "不要用 root 运行本脚本（包括 sudo ./${SCRIPT_NAME}）。"
        err "脚本用 \$HOME 装 TinyTeX、建 ~/.local/bin/fd 软链；root 下这些会落进"
        err "/root，目标用户拿不到。请用普通用户运行，需要特权的步骤脚本自己 sudo。"
        exit 1
    fi

    detect_system
    need_sudo
    init_log
    init_tmp_dir

    banner "v2 桌面环境安装 ${SCRIPT_VERSION}"
    log "  发行版    ${DISTRO} / ${CODENAME}"
    log "  架构      ${HOST_ARCH}"
    log "  目标用户  ${TARGET_USER} (uid ${TARGET_UID})"
    log "  阶段      ${RUN_LIST[*]}"
    log "  桌面壳    noctalia（不装 waybar）"
    $DRY_RUN && warn "  DRY-RUN：只打印命令，不改系统"

    local s
    for s in "${RUN_LIST[@]}"; do
        if ! $ASSUME_YES && [[ "$s" != "greetd-enable" ]]; then
            if ! confirm "执行阶段 ${s}（${STAGE_DESC[$s]}）？" y; then
                warn "跳过 ${s}"
                continue
            fi
        fi
        CURRENT_STAGE="$s"
        "stage_${s//-/_}"
    done

    banner "完成"
    if ((${#SKIPPED[@]})); then
        if $DRY_RUN; then
            dim "  dry-run：以下包因源未实际添加而无法确认（真实运行时会重新检查）："
        else
            warn "以下包在仓库里找不到，已被跳过："
        fi
        printf '    %s\n' "${SKIPPED[@]}" | sort -u >&2 || true
    fi
    log "  下一步："
    log "    1. sudo systemctl enable greetd   （或 ${SCRIPT_NAME} --only greetd-enable）"
    log "       启用前务必读 17_greetd.md §六"
    log "    2. 往 ~/.config/niri/config.kdl 加 spawn-at-startup \"noctalia\""
    log "    3. 重启，从 tuigreet 登录，再跑音频 / 蓝牙验证"
    [[ -n "$LOG_FILE" ]] && log "  日志：${LOG_FILE}"
    return 0
}

main "$@"
