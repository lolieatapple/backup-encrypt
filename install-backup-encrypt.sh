#!/usr/bin/env bash
#
# 通用加密备份安装脚本 (Ubuntu)
# - 交互式询问: 任务名 / 源目录 / 目标目录 / 加密密码 / UTC 备份时间 / 保留天数
# - 生成独立的备份脚本 + 密码文件 + cron 任务
# - 加密方式: GPG 对称加密 (AES256)
# - 同名任务可重复运行覆盖
#
# 用法:  sudo ./install-backup-encrypt.sh
# 卸载:  sudo ./install-backup-encrypt.sh --uninstall <任务名>

set -euo pipefail

VERSION="0.3.0"
BIN_DIR="/usr/local/bin"
ETC_DIR="/etc/backup-encrypt"
LOG_DIR="/var/log"

# ---------- 输出 ----------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

die() { c_red "ERROR: $*" >&2; exit 1; }

# ---------- 前置检查 ----------
require_root() {
    [[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo $0)"
}

ensure_deps() {
    local missing=()
    command -v gpg >/dev/null 2>&1 || missing+=("gnupg")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v crontab >/dev/null 2>&1 || missing+=("cron")
    if (( ${#missing[@]} > 0 )); then
        c_cyan "检测到缺少依赖: ${missing[*]}"
        read -rp "是否运行 apt-get install 安装? [Y/n] " ans
        ans=${ans:-Y}
        [[ $ans =~ ^[Yy]$ ]] || die "依赖缺失，已中止"
        apt-get update -qq
        apt-get install -y "${missing[@]}"
    fi
}

# 预先确保 ~/.gnupg/gpg-agent.conf 包含 allow-loopback-pinentry。
# 即便不缺也是幂等的；reload 让正在运行的 agent 立刻生效。
ensure_gpg_loopback() {
    local home="${GNUPGHOME:-$HOME/.gnupg}"
    local conf="$home/gpg-agent.conf"
    mkdir -p "$home"
    chmod 700 "$home"
    if [[ ! -f "$conf" ]] || ! grep -qE '^[[:space:]]*allow-loopback-pinentry' "$conf"; then
        printf 'allow-loopback-pinentry\n' >> "$conf"
        c_dim "✓ 已写入 $conf: allow-loopback-pinentry"
    fi
    gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    gpg-connect-agent reloadagent /bye >/dev/null 2>&1 || true
}

# 用真实密码文件做一次最小加密测试，验证 loopback 可用。
gpg_self_test() {
    local pass_file="$1"
    local size err
    size=$(stat -c '%s' "$pass_file")
    c_dim "密码文件 $pass_file: ${size} bytes"
    if (( size == 0 )); then
        die "密码文件为 0 字节，请重新安装并检查输入"
    fi

    if err=$(printf 'probe' \
                | gpg --batch --yes --quiet --no-tty \
                      --pinentry-mode loopback \
                      --symmetric --cipher-algo AES256 \
                      --compress-algo none \
                      --passphrase-file "$pass_file" \
                      --output /dev/null 2>&1); then
        c_green "✓ gpg 加密自检通过"
        return 0
    fi

    c_red "gpg 加密自检失败:"
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    die "gpg 加密失败，安装已中止 (gpg-agent.conf 已含 allow-loopback-pinentry，请检查密码文件内容或 gpg 版本)"
}

# ---------- 交互输入 ----------
prompt_default() {
    local question="$1" default="$2" var
    read -rp "$question [$default]: " var
    printf '%s' "${var:-$default}"
}

## NOTE: 这些 prompt 函数会被 $() 捕获 stdout 作为返回值。
## 任何写到 stdout 的辅助输出都会污染返回值（曾导致密码文件首字节为换行，
## 触发 gpg "Invalid passphrase"）。所有提示和报错必须显式写到 stderr。

prompt_required() {
    local question="$1" var
    while :; do
        read -rp "$question: " var
        [[ -n "$var" ]] && { printf '%s' "$var"; return; }
        c_red "不能为空" >&2
    done
}

# 直接把确认通过的密码写到 out_path（chmod 600）。
# 既避开 $() 捕获污染问题，也不需要 bash 4.3 的 nameref。
prompt_password_to_file() {
    local out_path="$1"
    local p1 p2 dir
    dir=$(dirname "$out_path")
    mkdir -p "$dir"
    chmod 700 "$dir"
    while :; do
        read -rsp "加密密码 (输入时不显示): " p1
        printf '\n' >&2
        [[ -n "$p1" ]] || { c_red "密码不能为空" >&2; continue; }
        [[ ${#p1} -ge 8 ]] || { c_red "密码至少 8 位" >&2; continue; }
        read -rsp "再次输入确认: " p2
        printf '\n' >&2
        if [[ "$p1" == "$p2" ]]; then
            ( umask 077; printf '%s' "$p1" > "$out_path" )
            chmod 600 "$out_path"
            return
        fi
        c_red "两次输入不一致，请重试" >&2
    done
}

prompt_time_utc() {
    local default="$1" raw hh mm
    while :; do
        read -rp "每日备份时间 (UTC, HH:MM) [$default]: " raw
        raw=${raw:-$default}
        if [[ "$raw" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
            hh=$((10#${BASH_REMATCH[1]}))
            mm=$((10#${BASH_REMATCH[2]}))
            if (( hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59 )); then
                printf '%s %s' "$mm" "$hh"
                return
            fi
        fi
        c_red "格式错误，应为 HH:MM (如 10:00)" >&2
    done
}

prompt_int() {
    local question="$1" default="$2" raw
    while :; do
        read -rp "$question [$default]: " raw
        raw=${raw:-$default}
        [[ "$raw" =~ ^[0-9]+$ ]] && { printf '%s' "$raw"; return; }
        c_red "请输入非负整数" >&2
    done
}

prompt_yes() {
    local question="$1" default="${2:-Y}" ans
    read -rp "$question [$default]: " ans
    ans=${ans:-$default}
    [[ $ans =~ ^[Yy]$ ]]
}

# ---------- 卸载 ----------
do_uninstall() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "用法: $0 --uninstall <任务名>"
    local script="${BIN_DIR}/backup-encrypt-${name}.sh"
    local pass="${ETC_DIR}/${name}.pass"

    c_cyan "卸载任务: $name"
    if crontab -l 2>/dev/null | grep -q "# >>> backup-encrypt:${name} >>>"; then
        local cur
        cur=$(crontab -l 2>/dev/null || true)
        printf '%s\n' "$cur" \
            | sed "/# >>> backup-encrypt:${name} >>>/,/# <<< backup-encrypt:${name} <<</d" \
            | crontab -
        c_green "✓ 已移除 cron 任务"
    fi
    [[ -f "$script" ]] && { rm -f "$script"; c_green "✓ 已删除 $script"; }
    [[ -f "$pass" ]]   && { rm -f "$pass";   c_green "✓ 已删除 $pass"; }
    c_green "卸载完成 (备份产物未清理)"
}

# ---------- 写入 cron ----------
update_cron() {
    local name="$1" minute="$2" hour="$3" script_path="$4" log_path="$5"
    local current new_block
    current=$(crontab -l 2>/dev/null || true)
    # 删掉同名旧块
    current=$(printf '%s\n' "$current" \
        | sed "/# >>> backup-encrypt:${name} >>>/,/# <<< backup-encrypt:${name} <<</d")
    new_block=$(cat <<EOF
# >>> backup-encrypt:${name} >>>
CRON_TZ=UTC
${minute} ${hour} * * * ${script_path} >> ${log_path} 2>&1
# <<< backup-encrypt:${name} <<<
EOF
)
    # 末尾去空行后追加
    {
        printf '%s' "$current" | sed '/./,$!d'
        printf '\n%s\n' "$new_block"
    } | crontab -
}

# ---------- 生成备份脚本 ----------
write_backup_script() {
    local script_path="$1" name="$2" src="$3" dest="$4" pass_file="$5" retention="$6"

    cat > "$script_path" <<'SCRIPT_HEAD'
#!/usr/bin/env bash
# Auto-generated by install-backup-encrypt.sh -- DO NOT EDIT BY HAND
set -euo pipefail

SCRIPT_HEAD

    cat >> "$script_path" <<EOF
INSTALLER_VERSION="${VERSION}"
NAME="${name}"
SRC_DIR="${src}"
DEST_DIR="${dest}"
PASS_FILE="${pass_file}"
RETENTION_DAYS=${retention}
EOF

    cat >> "$script_path" <<'SCRIPT_BODY'

log() { printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$NAME" "$*"; }

log "backup-encrypt v${INSTALLER_VERSION} (job=${NAME})"

[[ -d "$SRC_DIR" ]]  || { log "ERROR: source not found: $SRC_DIR"; exit 1; }
[[ -r "$PASS_FILE" ]] || { log "ERROR: passphrase file not readable: $PASS_FILE"; exit 1; }

PERMS=$(stat -c '%a' "$PASS_FILE")
[[ "$PERMS" == "600" || "$PERMS" == "400" ]] \
    || { log "ERROR: passphrase file perms $PERMS too open (need 600/400)"; exit 1; }

mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

TS=$(date -u '+%Y%m%d-%H%M%S')
OUT="${DEST_DIR}/${NAME}-${TS}.tar.gz.gpg"
TMP="${OUT}.partial"

log "start: $SRC_DIR -> $OUT"
trap 'rm -f "$TMP"' ERR

tar -czf - -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" \
    | gpg --batch --yes --quiet --no-tty \
          --pinentry-mode loopback \
          --symmetric --cipher-algo AES256 \
          --compress-algo none \
          --passphrase-file "$PASS_FILE" \
          --output "$TMP"

mv "$TMP" "$OUT"
chmod 600 "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
log "OK: $OUT ($SIZE)"

if (( RETENTION_DAYS > 0 )); then
    DELETED=$(find "$DEST_DIR" -maxdepth 1 -type f -name "${NAME}-*.tar.gz.gpg" \
              -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
    (( DELETED > 0 )) && log "cleaned $DELETED file(s) older than ${RETENTION_DAYS}d"
fi
log "done"
SCRIPT_BODY

    chmod 700 "$script_path"
}

# ---------- 主流程 ----------
main() {
    if [[ "${1:-}" == "--uninstall" ]]; then
        require_root
        do_uninstall "${2:-}"
        exit 0
    fi

    if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
        printf 'backup-encrypt installer v%s\n' "$VERSION"
        exit 0
    fi

    require_root
    ensure_deps
    ensure_gpg_loopback

    c_cyan "================================================"
    c_cyan "  通用加密备份配置向导 (GPG AES256 + tar.gz)"
    c_cyan "  installer v${VERSION}"
    c_cyan "  gpg: $(gpg --version | head -1)"
    c_cyan "================================================"
    echo

    local name src dest retention
    local time_pair minute hour

    name=$(prompt_default "任务名 (用作文件名前缀，仅字母数字横线)" "keystore")
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "任务名只能用字母/数字/下划线/横线"

    while :; do
        src=$(prompt_default "要备份的源目录" "/root/osm/keystore")
        [[ -d "$src" ]] && break
        c_red "目录不存在: $src"
    done

    dest=$(prompt_default "加密压缩包存储目录" "/root/encrypt-backup")
    time_pair=$(prompt_time_utc "10:00")
    minute=${time_pair% *}
    hour=${time_pair#* }
    retention=$(prompt_int "保留天数 (0 表示不清理)" "30")

    local script_path="${BIN_DIR}/backup-encrypt-${name}.sh"
    local pass_file="${ETC_DIR}/${name}.pass"
    local log_path="${LOG_DIR}/backup-encrypt-${name}.log"

    echo
    c_cyan "------ 配置确认 ------"
    printf '  %-14s %s\n' "任务名:"     "$name"
    printf '  %-14s %s\n' "源目录:"     "$src"
    printf '  %-14s %s\n' "目标目录:"   "$dest"
    printf '  %-14s %s\n' "运行时间:"   "每日 UTC $(printf '%02d:%02d' "$hour" "$minute")"
    printf '  %-14s %s\n' "保留天数:"   "$retention"
    printf '  %-14s %s\n' "备份脚本:"   "$script_path"
    printf '  %-14s %s\n' "密码文件:"   "$pass_file"
    printf '  %-14s %s\n' "日志:"       "$log_path"
    echo

    if [[ -f "$script_path" ]] || [[ -f "$pass_file" ]]; then
        c_red "检测到已存在同名任务的文件，将被覆盖"
    fi
    prompt_yes "确认安装?" "Y" || { c_red "已取消"; exit 1; }

    # 输入并直接写入密码文件 (函数内 chmod 600)
    prompt_password_to_file "$pass_file"

    # 用真实密码文件验证 gpg loopback 可用
    gpg_self_test "$pass_file"

    # 生成备份脚本
    write_backup_script "$script_path" "$name" "$src" "$dest" "$pass_file" "$retention"

    # 注册 cron
    update_cron "$name" "$minute" "$hour" "$script_path" "$log_path"

    # 系统时区提示
    local sys_tz
    sys_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    [[ "$sys_tz" != "UTC" && "$sys_tz" != "Etc/UTC" ]] \
        && c_dim "提示: 系统时区为 $sys_tz，cron 块内已声明 CRON_TZ=UTC，按 UTC 时间触发"

    echo
    c_green "✓ 安装完成"
    c_dim "当前 cron 中本任务:"
    crontab -l | sed -n "/# >>> backup-encrypt:${name} >>>/,/# <<< backup-encrypt:${name} <<</p"

    echo
    if prompt_yes "是否立即试跑一次?" "Y"; then
        echo
        "$script_path" 2>&1 | tee -a "$log_path"
        echo
        c_dim "产物列表:"
        ls -lh "$dest" | tail -n +2
    fi

    echo
    c_green "解密恢复命令示例:"
    echo "  gpg --decrypt --batch --passphrase-file ${pass_file} \\"
    echo "      ${dest}/${name}-YYYYMMDD-HHMMSS.tar.gz.gpg | tar -xzf -"
    echo
    c_green "卸载命令: sudo $0 --uninstall ${name}"
}

# 只在被直接执行时跑 main，方便测试脚本 source 同一份函数定义
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
