#!/usr/bin/env bash
#
# install-nas-r10.1.sh —— Coopanion 方案 α 的 NAS 端安装器（Debian 13 / OMV 8）第十轮 r10.1
#   （r10 + 挂载实例指纹校验：预检记录一次基线，递归 chown 前重查比对）
#
# 做什么
#   把一份 Coopanion 的 resources/app 装到 /opt/companion/app，在 NAS 上重装依赖
#   （拿到 Linux 原生包），生成 /etc/companion 下的 companion.env 与窗口密钥凭据
#   文件 pet-window.key，安装 check-storage.sh 与 companion.service，然后打印后续手工步骤。
#
# 执行顺序（所有只读预检都在第一次写操作之前）
#   1. 预检（只读）：参数 / 依赖命令 / 发行版 / Node / 源目录 / 挂载与设备（含挂载实例 ID）/
#      home 与 extensions 的真实路径与逃逸 / 已有配置 / 哨兵 / 空间 / 已有安装 /
#      随附文件（check-storage.sh、companion.service）/ 补丁文件（--apply-patch）/
#      安装目标 APP_TARGET 的类型 / systemd 单元目标与 .new 冲突 /
#      服务用户已存在时的权限闸门
#   2. 系统用户（第一次修改；失败时只有这一处已生效）
#   3. 权限闸门（只读）：服务用户对 home 与 extensions 必须 w+x
#   4. 复制程序  5. 重装依赖  6. 窗口密钥补丁
#   7. 环境变量文件  8. check-storage.sh（安装并实跑）与 systemd 单元（同一步）
#
# 明确不做什么（硬约束）
#   - 不格式化任何磁盘、不分区、不建文件系统、不写 /etc/fstab
#   - 不创建数据目录：数据盘上的 home/ 与 extensions/ 必须事先由 OMV 建好
#   - 不删除任何文件（没有任何 rm -rf，rsync 也不带 --delete）
#   - 不覆盖已有的 companion.env / pet-window.key / pet-window.env（旧）/ companion.service
#   - 不 enable、不 start 服务
#   - 不修改 OMV 的 salt / monit / nginx / samba 配置
#
# 升级语义（--force）
#   rsync 是**合并覆盖**，不是干净的全量替换：目标目录里上一次留下的、
#   本次源里已经没有的文件会**继续保留**。这是有意的（脚本不删任何东西）。
#   覆盖前请自行备份；旧文件残留由你判断要不要清理，脚本不会替你决定。
#
# 权限修复（--fix-perms / --fix-perms-recursive）
#   默认只修 home 与 extensions **这两个顶层目录**的属主与权限位（不递归）。
#   数据目录里若已有大量历史文件、且它们属于别的用户，递归 chown 会连它们一起改。
#   因此递归修复必须显式加 --fix-perms-recursive 且同时加 --yes 确认，
#   脚本会打印将被影响的条目数量。
#
# 用法
#   sudo ./install-nas-r10.1.sh \
#        --src /path/to/Coopanion/resources/app \
#        --mountpoint /srv/dev-disk-by-uuid-XXXX \
#        --data-root /srv/dev-disk-by-uuid-XXXX/companion \
#        [--apply-patch] [--force] [--dry-run] [--fix-perms [--fix-perms-recursive --yes]]
#
# 退出码
#   0 成功   1 参数/环境错误   2 前置检查未通过
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 077        # 第六轮提前到最前面：之后创建的密钥/配置文件默认就不会是全员可读

readonly PROG="$(basename -- "$0")"
readonly APP_TARGET="/opt/companion/app"
readonly PATCH_DIR="/opt/companion/patches"
readonly NODE_PREFIX="/opt/node22"
readonly NODE_BIN="$NODE_PREFIX/bin/node"
readonly NPM_BIN="$NODE_PREFIX/bin/npm"
readonly PNPM_BIN="$NODE_PREFIX/bin/pnpm"
readonly PNPM_WANT="11.28.6"
readonly ETC_DIR="/etc/companion"
readonly LIB_DIR="/usr/local/lib/companion"
readonly UNIT_TARGET="/etc/systemd/system/companion.service"
readonly SERVICE_USER="companion"
readonly MIN_FREE_MB=800
readonly SENTINEL_NAME=".companion-volume-id"
readonly INSTALLER_VERSION="r10.1"

SRC=""
MOUNTPOINT=""
DATA_ROOT=""
APPLY_PATCH=0
FORCE=0
DRY_RUN=0
FIX_PERMS=0
FIX_PERMS_RECURSIVE=0
ASSUME_YES=0
ALLOW_UNSUPPORTED_OS=0

# r10.1：第 1 步记录的「数据盘所在挂载实例」的指纹（ID 父ID 设备 文件系统内根 源 类型）。
# 递归 chown 前与它比对：挂载点路径相同、设备号相同，也可能是另一个挂载实例。
MOUNT_IDENT_EXPECT=""

# ---------------------------------------------------------------- 输出 ---
log()  { printf '\033[36m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[install] 注意:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[install] 失败:\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }
die_pre() { printf '\033[31m[install] 前置检查未通过:\033[0m %s\n' "$*" >&2; exit 2; }

on_error() {
  local code=$? ino
  # 只有 systemd 单元验证会产生临时文件。异常中断时也只清「本次执行创建的那一个」：
  # 路径可能已经被别人换成另一个文件，所以先比 inode，对不上就一律不动手。
  if [ -n "${VERIFY_TMP:-}" ] && [ ! -L "${VERIFY_TMP}" ] && [ -f "${VERIFY_TMP}" ]; then
    ino="$(stat -c %i -- "$VERIFY_TMP" 2>/dev/null || true)"
    if [ -n "$ino" ] && [ "$ino" = "${VERIFY_TMP_INO:-}" ]; then
      rm -f -- "$VERIFY_TMP" 2>/dev/null || true
    fi
  fi
  printf '\033[31m[install] 第 %s 行出错（退出码 %s），安装已中止。\033[0m\n' "$1" "$code" >&2
  printf '已做的改动不会被自动回滚；请检查上面的输出后重跑。\n' >&2
}
trap 'on_error $LINENO' ERR
VERIFY_TMP=""      # 临时 unit 文件路径：只有 mktemp 成功之后才会被赋值
VERIFY_TMP_INO=""  # 该文件的 inode：删除前比对，确保只删本次执行创建的那个

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run][计划] %s\n' "$*"
  else
    "$@"
  fi
}

# 写配置文件统一走安全新建（S03）：不跟随符号链接、不覆盖已有文件、走 O_EXCL。
# 三个调用点（companion.env / pet-window.env）都只在「文件不存在」的分支里调用，
# 所以拒绝覆盖不会影响正常流程，只是把「检查与写入之间被换掉」这个窗口堵上。
write_file() { # write_file <path> <content> [描述]
  write_new_file "$1" "$2" "${3:-文件}"
}

# 新建一个文件，绝不覆盖任何已存在的东西（IN-16）。
#   - 写前再查一次：符号链接 / 已存在 / 非普通文件 —— 一律拒绝
#   - 用 `set -C`（noclobber）+ 重定向：内核层面就是 O_EXCL|O_CREAT，
#     即使检查和创建之间路径被人换成符号链接或别的文件，也不会写穿、不会覆盖
#   - 写完回读：类型仍是普通文件、字节数与预期一致
# 为什么不用 `> "$path"`：`>` 会跟随符号链接，也会静默截断已有文件。
write_new_file() { # write_new_file <path> <content> <描述>
  local path="$1" content="$2" what="${3:-文件}"
  local want_bytes got_bytes
  want_bytes="$(printf '%s' "$content" | wc -c | tr -d '[:space:]')"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run][计划] 新建 %s（%s 字节，不覆盖已有文件）\n' "$path" "$want_bytes"
    return 0
  fi

  if [ -L "$path" ]; then
    die "$what $path 是符号链接，拒绝写入（写入会跟随链接覆盖到别处）" 2
  fi
  if [ -e "$path" ]; then
    die "$what $path 已存在，本脚本拒绝覆盖（请先人工处理这个文件）" 2
  fi

  ( set -C; printf '%s' "$content" > "$path" ) \
    || die "无法创建 $what $path（noclobber 拒绝覆盖，或路径在检查之后被替换/不可写）"

  if [ -L "$path" ] || [ ! -f "$path" ]; then
    die "$what $path 写入后不是普通文件（路径在写入期间被替换？）拒绝继续" 2
  fi
  got_bytes="$(wc -c < "$path" | tr -d '[:space:]')"
  [ "$got_bytes" = "$want_bytes" ] \
    || die "$what $path 写入的字节数是 $got_bytes，预期 $want_bytes（写盘异常）"
}

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"
  exit 0
}

# ------------------------------------------------------- 通用检查工具 ---
# 路径是「已存在的符号链接」还是普通目录/文件：用于拒绝逃逸与类型异常
is_symlink() { [ -L "$1" ]; }

# 解析已存在路径的真实位置；失败返回空串（调用方判失败）
resolve_existing() { realpath -e -- "$1" 2>/dev/null || true; }

# child 严格位于 parent 之下（都不相等）。组件级比较，不是字符串前缀。
# 现有调用方传的都是 realpath 的结果（没有尾部斜杠）。这里仍做一次最小归一化：
# 两侧一起去掉尾部斜杠（"/" 除外），让 "/data/" 与 "/data" 得到同一个结论。
# 只改比较口径，不改变任何调用方的路径处理。
strict_under() {
  local parent="$1" child="$2"
  while [ ${#parent} -gt 1 ] && [ "${parent%/}" != "$parent" ]; do parent="${parent%/}"; done
  while [ ${#child} -gt 1 ] && [ "${child%/}" != "$child" ]; do child="${child%/}"; done
  [ -z "$parent" ] || [ -z "$child" ] && return 1
  [ "$parent" = "/" ] && [ "$child" != "/" ] && return 0
  [ "$parent" = "$child" ] && return 1
  case "$child/" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

# 拒绝「符号链接 / 目录 / 设备」等异常类型，只接受普通文件
require_regular_file() { # require_regular_file <path> <描述>
  local p="$1" what="$2"
  if is_symlink "$p"; then
    die_pre "$what 是符号链接（$p）。拒绝通过链接把权限修改或写入引到别处，请人工确认为普通文件后重试"
  fi
  if [ -e "$p" ] && [ ! -f "$p" ]; then
    die_pre "$what 存在但不是普通文件（可能是目录或设备）: $p"
  fi
}

# 随附文件（check-storage.sh / companion.service / 补丁）必须：在、是普通文件、能读。
# 这三项都在预检阶段判定，缺一个就在任何写操作之前停下（IN-16）。
require_present_file() { # require_present_file <path> <描述>
  local p="$1" what="$2"
  if is_symlink "$p"; then
    die_pre "$what 是符号链接（$p）。拒绝通过链接读取别处的内容，请放一份真正的普通文件再重试"
  fi
  if [ ! -e "$p" ]; then
    die_pre "$what 不存在: $p。它必须与本脚本放在同一个目录里一起分发"
  fi
  if [ ! -f "$p" ]; then
    die_pre "$what 存在但不是普通文件（可能是目录或设备）: $p"
  fi
  if [ ! -r "$p" ]; then
    die_pre "$what 不可读（检查权限位）: $p"
  fi
}

# 逐级检查路径里每个「已存在」的组件都不是符号链接（S06/S07）。
# 只看已存在的部分：不存在的尾部由创建时的 O_EXCL 与类型检查兜底。
require_no_symlink_components() { # require_no_symlink_components <绝对路径> <描述>
  local what="$2" rest="$1" cur="" comp
  while [ -n "$rest" ]; do
    rest="${rest#/}"
    comp="${rest%%/*}"
    [ -n "$comp" ] || break
    cur="$cur/$comp"
    if [ -L "$cur" ]; then
      die_pre "$what 的路径组件 $cur 是符号链接。关键路径的每一级都必须是真实目录，否则写入会被引到别处"
    fi
    [ -e "$cur" ] || break
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *)   rest="" ;;
    esac
  done
}

# sed 替换串转义（S08）：& \ 与分隔符 | 都必须转义，否则路径里的这些字符会把
# 替换串解释成「匹配内容」或提前结束 s 命令。
sed_repl() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# 扩展 ACL（S04/S05）：命名用户、命名组、mask。空输出 = 只有基础权限位。
# 读不出来一律返回非 0 —— 不允许把「查不到」当成「没有额外 ACL」。
acl_extended() { # acl_extended <file>
  # 成功：stdout 输出扩展 ACE（一行一条）。
  # 失败：把原因打到 **stderr** 并返回 1。
  #   注意不能靠全局变量把错误信息传出去：调用点是 $( ) 命令替换，
  #   子 shell 里的赋值传不回父 shell（第九轮实测踩过，错误信息会变成空串）。
  local f="$1" out rc
  out="$(getfacl -p -c -- "$f" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[install] 失败: getfacl 读取 %s 失败（退出码 %s）: %s\n' "$f" "$rc" "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | awk -F: '
    ($1=="user"  && $2!="") ||
    ($1=="group" && $2!="") ||
    ($1=="mask")             { print }
  '
  return 0
}

# 统计目录下的条目数（R08）：NUL 分隔，文件名里的换行不会被算成两个。
# find 出错必须显式失败，不能把「遍历失败」当成「0 个条目」。
count_entries() { # count_entries <dir>
  local dir="$1" n
  if ! n="$(find "$dir" -mindepth 1 -print0 2>/dev/null | tr -cd '\0' | wc -c)"; then
    die "遍历 $dir 失败（find 出错），无法统计条目数"
  fi
  printf '%s' "$n" | tr -d '[:space:]'
}

# 目录所处的挂载点（findmnt -T 给的是「这个路径实际属于哪个挂载」）。
# 查不到 → 返回非 0，调用方必须失败关闭：问不出来不等于没问题。
mount_target_of() { # mount_target_of <目录>
  local p="$1" t
  t="$(findmnt -rn -T "$p" -o TARGET 2>/dev/null)" || return 1
  [ -n "$t" ] || return 1
  printf '%s\n' "$t"
}

# 路径所处的挂载实例「指纹」：ID 父ID 设备(maj:min) 文件系统内根 源 类型，六项拼成一行。
# 与 mount_target_of 是两个不同的判据：挂载点路径可以相同（整块盘重新挂到同一路径，
# 或同一文件系统上的 bind mount），设备号也可以相同（bind mount 的设备号必然相同）。
#
# 为什么不用「只比 ID」：内核的 mount ID 是复用的。util-linux 2.39.3 实测：
# 卸载一份 tmpfs 后立刻在同一路径重新挂载，拿到的 ID 与卸载前完全相同（442 -> 442）；
# 同一文件系统里的子目录 bind mount，设备号与 ID 都不足以说明问题
# （源目录 442 85 0:87 / none tmpfs，bind 目标 443 85 0:87 /sub none[/sub] tmpfs）。
# 所以这里取六项的组合：任何一项变了就说明挂载关系变了。
# 剩下一种情况仍然看不出：同一块盘被卸载后原样重挂到同一路径 —— 内核给的 ID 可能被复用，
# 六项可能全都相同。但那时磁盘内容与挂载位置本来就没变，递归 chown 触到的还是同一批文件，
# 不构成「改到别的盘」的风险；这一点写在 R10.1 说明的「剩余风险」里，不装作能看出来。
#
# 六项必须齐全：少一项就返回失败，由调用方失败关闭（问不出来不等于没问题）。
mount_ident_of() { # mount_ident_of <路径>
  local p="$1" fp n
  fp="$(findmnt -rn -T "$p" -o ID,PARENT,MAJ:MIN,FSROOT,SOURCE,FSTYPE 2>/dev/null)" || return 1
  [ -n "$fp" ] || return 1
  n="$(printf '%s' "$fp" | awk '{print NF}')" || return 1
  [ "$n" = "6" ] || return 1
  printf '%s\n' "$fp"
}

# <目录> 之下还嵌着哪些挂载点（含同文件系统的 bind mount），空格分隔。
# 只比设备号看不出 bind mount；这个函数用来守住递归 chown 的边界。
nested_mounts_under() { # nested_mounts_under <目录>
  local dir="$1" list t out=""
  list="$(findmnt -rn -o TARGET 2>/dev/null)" || return 1
  [ -n "$list" ] || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if strict_under "$dir" "$t"; then out="$out $t"; fi
  done <<< "$list"
  printf '%s' "${out# }"
}

# 第二种、独立的校验实现（M02）：不解析取值，只按 systemd EnvironmentFile 的
# 硬性规则逐行判定。与 env_parse_strict 走不同代码路径，用来交叉验证
# 「本脚本写出来的文件，systemd 读进去也不会变样」。
verify_env_file_systemd_safe() { # verify_env_file_systemd_safe <file>
  local f="$1" line n=0 bad=""
  [ -f "$f" ] || die "$f 不是普通文件，拒绝做 systemd 兼容性校验"
  if bad="$(LC_ALL=C grep -n '[[:cntrl:]]' "$f" 2>/dev/null)"; then
    die "$f 里有控制字符（systemd EnvironmentFile 会把它们原样带进取值）：$bad"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      *'\') die "$f 第 $n 行以反斜杠结尾（systemd 会当成续行），拒绝继续" ;;
    esac
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) : ;;
      *) die "$f 第 $n 行不是 KEY=VALUE: $line" ;;
    esac
  done < "$f"
}

# R06：用 systemd 自己的解析器验证 unit（语法/指令名/ExecStart 可执行文件）。
# 只有验证通过才允许安装到正式位置。返回 0/1，输出放在 VERIFY_ERROR 里
# （不用 die：调用点要先删掉临时文件再决定怎么退出）。
VERIFY_ERROR=""
verify_unit_file() { # verify_unit_file <file> <描述>
  local f="$1" what="$2" out rc
  VERIFY_ERROR=""
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    VERIFY_ERROR="缺少 systemd-analyze，无法验证 $what 的语法（本脚本不接受未经验证的 unit）"
    return 1
  fi
  out="$(systemd-analyze verify "$f" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    VERIFY_ERROR="$what 未通过 systemd-analyze verify（退出码 $rc）：$out"
    return 1
  fi
  return 0
}

# 删除「本次执行创建的那个」临时 unit 文件。
# 判据是 inode：mktemp 成功后记下 inode，删除前再比一次。路径可能已经被别人
# 换成了另一个文件，inode 对不上就一律不动手（宁可留一个临时文件，也不误删）。
verify_tmp_drop() { # verify_tmp_drop <清理原因，仅用于提示文案>
  local why="${1:-临时 unit 文件}" ino
  if [ -z "${VERIFY_TMP:-}" ]; then
    VERIFY_TMP_INO=""
    return 0
  fi
  ino="$(stat -c %i -- "$VERIFY_TMP" 2>/dev/null || true)"
  if [ -n "$ino" ] && [ "$ino" = "${VERIFY_TMP_INO:-}" ]; then
    if ! rm -f -- "$VERIFY_TMP" 2>/dev/null; then
      warn "$why：临时文件 $VERIFY_TMP 没删掉，请人工删除"
    fi
  else
    warn "$why：临时文件路径 $VERIFY_TMP 已不是本次创建的那个（inode 对不上），按约定不动它"
  fi
  VERIFY_TMP=""
  VERIFY_TMP_INO=""
  return 0
}

# ---------------------------------------------------------------- 参数 ---
# M01：需要取值的选项必须真的有取值。没有这一步时 `--src --force` 会把选项名
# 当成路径，`--src` 放在末尾会让 `shift 2` 直接报错退出（信息还很难懂）。
need_value() { # need_value <选项> <剩余参数个数> <下一个参数>
  local opt="$1" left="$2" nxt="${3:-}"
  [ "$left" -ge 2 ] || die "参数 $opt 缺少取值（后面必须跟一个参数）"
  case "$nxt" in
    ''|--*|-h) die "参数 $opt 缺少取值（下一个是选项 '$nxt'，不是取值）" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)         need_value "$1" "$#" "${2:-}"; SRC="$2"; shift 2 ;;
    --mountpoint)  need_value "$1" "$#" "${2:-}"; MOUNTPOINT="$2"; shift 2 ;;
    --data-root)   need_value "$1" "$#" "${2:-}"; DATA_ROOT="$2"; shift 2 ;;
    --apply-patch) APPLY_PATCH=1; shift ;;
    --force)       FORCE=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --fix-perms)   FIX_PERMS=1; shift ;;
    --fix-perms-recursive) FIX_PERMS=1; FIX_PERMS_RECURSIVE=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    --allow-unsupported-os) ALLOW_UNSUPPORTED_OS=1; shift ;;
    -h|--help)     usage ;;
    *) die "未知参数: $1（用 --help 看用法）" ;;
  esac
done

[ -n "$SRC" ]        || die "缺少 --src（Coopanion 的 resources/app 目录）"
[ -n "$MOUNTPOINT" ] || die "缺少 --mountpoint（OMV 数据盘挂载点）"
[ -n "$DATA_ROOT" ]  || die "缺少 --data-root（通常是 <mountpoint>/companion）"
if [ "$FIX_PERMS_RECURSIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  die "--fix-perms-recursive 会递归修改整棵数据目录的属主，必须同时加 --yes 明确确认"
fi

# ============================================================ 第 1 步 ===
log "第 1 步 / 共 8 步：预检（全部只读，此步失败不会修改任何东西）"

[ "$(id -u)" -eq 0 ] || die "需要 root 运行（sudo）"

# 依赖命令：把脚本实际用到的一次性列全（IN-14：check-storage 里用的是 findmnt/ss，
# 这里连 basename/dirname/find/wc 也一并查，避免跑到一半才发现缺命令）
REQUIRED_CMDS=(rsync install stat df awk sed grep useradd runuser mountpoint findmnt
               ss realpath test chown chmod id date cut cp ls basename dirname find wc
               systemctl hostname getent getfacl systemd-analyze sha256sum tr cmp mktemp)
missing=""
for c in "${REQUIRED_CMDS[@]}"; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
# 每个包提供哪些命令：rsync→rsync；getfacl→acl；systemd-analyze→systemd；
# install/stat/chown/chmod/df/sha256sum/mktemp→coreutils；mountpoint/findmnt/runuser→util-linux；
# ss→iproute2；getent→libc-bin；patch 只有 --apply-patch 用到，单独在下面检查。
[ -z "$missing" ] || die "缺少必需命令:$missing（Debian: apt-get install rsync acl coreutils util-linux iproute2 systemd）"
command -v openssl >/dev/null 2>&1 || die "缺少 openssl（生成窗口密钥用）：apt-get install openssl"
if [ "$APPLY_PATCH" -eq 1 ]; then
  command -v patch >/dev/null 2>&1 || die "缺少 patch 命令（apt-get install patch）"
fi
HAS_GETFACL=0
command -v getfacl >/dev/null 2>&1 && HAS_GETFACL=1

# M08：不符合目标系统时默认拒绝，只有显式 --allow-unsupported-os 才继续。
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
os_ok=0
if [ "$OS_ID" = "debian" ]; then
  case "$OS_VER" in 13*) os_ok=1 ;; esac
fi
if [ "$os_ok" -ne 1 ]; then
  if [ "$ALLOW_UNSUPPORTED_OS" -eq 1 ]; then
    warn "目标系统是 '${OS_ID:-未知} ${OS_VER:-未知}'，不是 Debian 13 (Trixie)；--allow-unsupported-os 已显式放行"
  else
    die_pre "目标系统是 '${OS_ID:-未知} ${OS_VER:-未知}'，本安装器只支持 Debian 13 (Trixie)。确认要在其他系统上继续，请加 --allow-unsupported-os（风险自负）"
  fi
else
  log "发行版：debian $OS_VER"
fi

[ -x "$NODE_BIN" ] || die_pre "找不到 $NODE_BIN。请先把 Node 22 解包到 $NODE_PREFIX（见 migration-plan.md）"
node_ver="$("$NODE_BIN" -v 2>/dev/null || echo unknown)"
node_major="$(printf '%s' "$node_ver" | sed 's/^v//' | cut -d. -f1)"
case "$node_major" in
  ''|*[!0-9]*) die_pre "无法解析 Node 版本: $node_ver" ;;
esac
# M09：不是「>= 22 就都行」。运行期固定用 $NODE_BIN（/opt/node22），
# 主版本必须是 22，否则装到一半才发现 ABI/内置模块差异。
[ "$node_major" -eq 22 ] || die_pre "Node 主版本是 $node_major（$node_ver），本部署固定使用 $NODE_PREFIX（22.x）。请换成 Node 22"
log "Node: $node_ver"

[ -f "$SRC/core/boot.ts" ]            || die_pre "$SRC/core/boot.ts 不存在——--src 要指向 Coopanion 的 resources/app"
[ -d "$SRC/build/cortico/src/core" ]  || die_pre "$SRC/build/cortico/src/core 不存在（框架源码缺失）"
[ -f "$SRC/package.json" ]            || die_pre "$SRC/package.json 不存在"
# R10：没有锁文件就不装依赖 —— 装出来的依赖树无法复现，也无法核对版本。
[ -f "$SRC/pnpm-lock.yaml" ]          || die_pre "$SRC/pnpm-lock.yaml 不存在。没有锁文件时装出来的依赖树不可复现，本脚本拒绝继续"
# M10：安装源里的关键文件必须是普通文件，不能是通过链接指向别处的替身。
for f in "$SRC/core/boot.ts" "$SRC/package.json" "$SRC/pnpm-lock.yaml"; do
  if [ -L "$f" ]; then
    die_pre "安装源里的 $f 是符号链接。请用真实的普通文件（链接可能指向与锁文件不同版本的源码）"
  fi
done
# S06 补：目录同样会被 -d 顺着符号链接跟过去。框架源码目录若不查，
# rsync 复制进来的是「链接指向的那棵树」，装完后框架根可能落在安装源之外。
# 只查目录本身与它到安装源之间的关键父目录；项目内部普通文件的符号链接不动
# （rsync 仍是合并覆盖，没有 --delete，也没有 --no-links）。
SRC_ABS="$(realpath -m -- "$SRC" 2>/dev/null)" || die_pre "无法规范化 --src 的路径: $SRC"
[ -n "$SRC_ABS" ] || die_pre "无法规范化 --src 的路径: $SRC"
for p in "$SRC_ABS" "$SRC_ABS/build" "$SRC_ABS/build/cortico" \
         "$SRC_ABS/build/cortico/src" "$SRC_ABS/build/cortico/src/core"; do
  if [ -L "$p" ]; then
    die_pre "安装源里的目录 $p 是符号链接。框架源码目录必须是真实目录（链接会把复制进来的树指向源目录之外）"
  fi
  [ -d "$p" ] || die_pre "安装源里的目录 $p 不是目录（或不存在）"
done
# 双重保险：解析链接之后的真实路径仍必须落在安装源之内
SRC_REAL="$(resolve_existing "$SRC_ABS")"
CORE_REAL="$(resolve_existing "$SRC_ABS/build/cortico/src/core")"
[ -n "$SRC_REAL" ]  || die_pre "无法解析安装源的真实路径: $SRC_ABS"
[ -n "$CORE_REAL" ] || die_pre "无法解析框架源码目录的真实路径: $SRC_ABS/build/cortico/src/core"
strict_under "$SRC_REAL" "$CORE_REAL" \
  || die_pre "框架源码目录的真实路径 $CORE_REAL 不在安装源 $SRC_REAL 之内（路径被链接或挂载改道）"

# ---- 挂载：存在、真的是挂载点、与 / 不同设备 -------------------------------
mountpoint -q -- "$MOUNTPOINT" || die_pre "挂载点 $MOUNTPOINT 未挂载。请先在 OMV 里挂载数据盘，再重跑本脚本"

MOUNT_N="$(realpath -m -- "$MOUNTPOINT")" || die_pre "无法规范化 --mountpoint"
DATA_N="$(realpath -m -- "$DATA_ROOT")"   || die_pre "无法规范化 --data-root"

[ "$MOUNT_N" = "/" ] && die_pre "--mountpoint 不能是 /"
[ "$MOUNT_N" = "$DATA_N" ] && die_pre "--data-root 不能等于 --mountpoint：数据根必须是挂载点下的独立子目录"
strict_under "$MOUNT_N" "$DATA_N" || die_pre "--data-root（$DATA_N）不是 --mountpoint（$MOUNT_N）的严格子目录（注意 /data2 不算 /data 的子目录）"

dev_mount="$(stat -c %d -- "$MOUNT_N" 2>/dev/null)" || die_pre "无法读取 $MOUNT_N 的设备号"
dev_data="$(stat -c %d -- "$DATA_N"  2>/dev/null)" || die_pre "无法读取 $DATA_N 的设备号"
dev_root="$(stat -c %d -- / 2>/dev/null)"          || die_pre "无法读取 / 的设备号"

[ "$dev_mount" = "$dev_root" ] && die_pre "$MOUNT_N 与 / 同设备——不是真正独立的挂载点"
[ "$dev_data" = "$dev_mount" ] || die_pre "数据根 $DATA_N（设备 $dev_data）与挂载点 $MOUNT_N（设备 $dev_mount）不在同一个文件系统上（嵌套挂载？）"

case "$DATA_N" in
  /opt/companion|/opt/companion/*) die_pre "DATA_ROOT 不能是程序目录或其子目录" ;;
esac

# ---- 数据目录：必须已存在、真实路径必须仍在数据根内（防逃逸） --------------
[ -d "$DATA_N" ] || die_pre "数据根目录不存在: $DATA_N"

HOME_EXPECT="$DATA_N/home"
EXT_EXPECT="$DATA_N/extensions"
[ -d "$HOME_EXPECT" ] || die_pre "$HOME_EXPECT 不存在。请先按 storage-design.md 在数据盘上建好目录，本脚本不会代建"
[ -d "$EXT_EXPECT" ]  || die_pre "$EXT_EXPECT 不存在（同上）"

HOME_REAL="$(resolve_existing "$HOME_EXPECT")"
EXT_REAL="$(resolve_existing "$EXT_EXPECT")"
DATA_REAL="$(resolve_existing "$DATA_N")"
[ -n "$DATA_REAL" ] || die_pre "无法解析数据根的真实路径: $DATA_N"
[ -n "$HOME_REAL" ] || die_pre "无法解析 $HOME_EXPECT 的真实路径（符号链接成环？）"
[ -n "$EXT_REAL" ]  || die_pre "无法解析 $EXT_EXPECT 的真实路径（符号链接成环？）"

strict_under "$DATA_REAL" "$HOME_REAL" \
  || die_pre "$HOME_EXPECT 的真实路径是 $HOME_REAL，不在数据根 $DATA_REAL 之内（符号链接逃逸）"
strict_under "$DATA_REAL" "$EXT_REAL" \
  || die_pre "$EXT_EXPECT 的真实路径是 $EXT_REAL，不在数据根 $DATA_REAL 之内（符号链接逃逸）"
[ "$HOME_REAL" = "$EXT_REAL" ] && die_pre "home 与 extensions 指向同一个目录（$HOME_REAL）"
log "数据目录真实路径校验通过：$HOME_REAL / $EXT_REAL"

# R07：home/extensions 必须在**同一个文件系统**上，且就是数据根那块盘。
# 只比数据根与挂载点是不够的：OMV 里把某个子目录单独挂载/bind mount 很常见，
# 那样 Core 写进去的东西就落到了别的盘上，而所有检查都会通过。
# 设备号只挡「另一个文件系统」；**同一个文件系统上的 bind mount 设备号完全相同**，
# 所以还要问挂载表：这两个目录所处的挂载点必须就是数据根所处的那个挂载点。
DATA_MT="$(mount_target_of "$DATA_N")" \
  || die_pre "findmnt 问不出数据根 $DATA_N 所处的挂载点：无法确认 home/extensions 有没有被单独挂载。拒绝在无法判断的情况下继续"
for d in "$HOME_REAL" "$EXT_REAL"; do
  dev_d="$(stat -c %d -- "$d" 2>/dev/null)" || die_pre "无法读取 $d 的设备号"
  if [ "$dev_d" != "$dev_data" ]; then
    die_pre "$d 与数据根 $DATA_N 不在同一个文件系统上（设备 $dev_d vs $dev_data）：home/extensions 被单独挂载或 bind mount 了？请先人工确认数据去哪块盘"
  fi
  d_mt="$(mount_target_of "$d")" \
    || die_pre "findmnt 问不出 $d 所处的挂载点：无法确认它有没有被单独挂载或 bind mount。拒绝在无法判断的情况下继续"
  if [ "$d_mt" != "$DATA_MT" ]; then
    die_pre "$d 的挂载点是 $d_mt，而数据根 $DATA_N 的挂载点是 $DATA_MT：它被单独挂载或 bind mount 了（同一文件系统上的 bind mount 设备号相同，stat 看不出来）。请先人工确认数据去哪块盘"
  fi
  n_mt="$(nested_mounts_under "$d")" \
    || die_pre "findmnt 列不出挂载表：无法确认 $d 之下没有嵌套挂载。拒绝在无法判断的情况下继续"
  if [ -n "$n_mt" ]; then
    die_pre "$d 之下还挂着 $n_mt：写进这些子目录的数据不在数据根那块盘上，请先人工处理"
  fi
done

# ---- 挂载实例指纹基线（r10.1）---------------------------------------------
# 上面两条判据（挂载点路径、设备号）可能一起失效：第 1 步之后有人把整块数据盘重新挂到
# 同一个路径上，home/extensions 正好也落在新挂载之下 —— 挂载点还是那个字符串，
# 设备号还可能是同一个文件系统，mount_target_of 与 stat 都会给出「一切照旧」。
# 这里记下六项组合指纹的基线，递归 chown 前重查比对。
MOUNT_IDENT_EXPECT="$(mount_ident_of "$MOUNT_N")" \
  || die_pre "findmnt 问不出挂载点 $MOUNT_N 的挂载实例指纹（ID/父ID/设备/根/源/类型）：无法确认数据盘是哪一个挂载实例。拒绝在无法判断的情况下继续"
for p in "$DATA_N" "$HOME_REAL" "$EXT_REAL"; do
  fp_p="$(mount_ident_of "$p")" \
    || die_pre "findmnt 问不出 $p 的挂载实例指纹：无法确认它与挂载点 $MOUNT_N 属于同一个挂载实例。拒绝在无法判断的情况下继续"
  if [ "$fp_p" != "$MOUNT_IDENT_EXPECT" ]; then
    die_pre "$p 的挂载实例指纹是「$fp_p」，而挂载点 $MOUNT_N 是「$MOUNT_IDENT_EXPECT」：它们不属于同一个挂载实例（被单独挂载或 bind mount 了）"
  fi
done
log "挂载实例校验通过：$MOUNT_N / $DATA_N / home / extensions 同属挂载实例「$MOUNT_IDENT_EXPECT」（ID 父ID 设备 根 源 类型）"

# S06/S07：关键路径逐级查符号链接。只查最终路径挡不住「父目录被换成链接」。
require_no_symlink_components "$MOUNT_N"             "挂载点"
require_no_symlink_components "$DATA_N"              "数据根"
require_no_symlink_components "$HOME_REAL"           "home"
require_no_symlink_components "$EXT_REAL"            "extensions"
require_no_symlink_components "/opt"                 "/opt"
require_no_symlink_components "/opt/companion"       "/opt/companion"
require_no_symlink_components "$APP_TARGET"          "安装目标"
require_no_symlink_components "$ETC_DIR"             "配置目录"
require_no_symlink_components "$LIB_DIR"             "辅助脚本目录"

# 后续所有写操作都用解析后的真实路径，避免「检查 A、写 B」
HOME_EXPECT="$HOME_REAL"
EXT_EXPECT="$EXT_REAL"

# ---- EnvironmentFile 严格解析 ---------------------------------------------
# 支持的取值格式（systemd EnvironmentFile 的可判定子集）：
#   - 空行、以 # 开头的整行注释（不支持行内注释）
#   - KEY=VALUE，KEY 只含 [A-Za-z0-9_]，不以数字开头（不允许 export 前缀、不允许空格）
#   - VALUE 若整体被一对 " 或 ' 包住则剥掉引号
#   - **不做变量展开、不做命令替换、不做反斜杠转义**
# 一律拒绝并报错的写法：export 前缀、行内注释、续行、单边引号、
#   引号只包住一部分（a"b"）、值中间出现反斜杠。
# 重复键一律报错：systemd 会让后者覆盖前者，本脚本拒绝这种静默差异。
declare -A ENV_VALS=()
declare -A ENV_LINES=()
ENV_ERROR=""

env_parse_strict() { # env_parse_strict <file> <必需键>...
  local file="$1"; shift
  local -a want=("$@")
  local line key val lineno=0 k inner

  ENV_ERROR=""
  ENV_VALS=()
  ENV_LINES=()

  if [ ! -r "$file" ]; then
    ENV_ERROR="无法读取 $file"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) : ;;
      *) ENV_ERROR="$file:$lineno 不是 KEY=VALUE 形式: $line"; return 1 ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      ''|*[!A-Za-z0-9_]*) ENV_ERROR="$file:$lineno 变量名非法（只允许 [A-Za-z0-9_]，不支持 export/空格）: '$key'"; return 1 ;;
      [0-9]*)             ENV_ERROR="$file:$lineno 变量名以数字开头: '$key'"; return 1 ;;
    esac

    # 引号：必须整体成对；不允许半包、不允许值里出现裸反斜杠
    case "$val" in
      \"*)
        case "$val" in
          *\") : ;;
          *) ENV_ERROR="$file:$lineno 双引号未闭合: $key=..."; return 1 ;;
        esac
        inner="${val#\"}"; inner="${inner%\"}"
        case "$inner" in
          *\"*) ENV_ERROR="$file:$lineno 值内部出现裸双引号（不支持转义）: $key"; return 1 ;;
          *\\*) ENV_ERROR="$file:$lineno 值里含反斜杠（本脚本不支持转义，请改写）: $key"; return 1 ;;
        esac
        val="$inner"
        ;;
      \'*)
        case "$val" in
          *\') : ;;
          *) ENV_ERROR="$file:$lineno 单引号未闭合: $key=..."; return 1 ;;
        esac
        inner="${val#\'}"; inner="${inner%\'}"
        case "$inner" in
          *\'*) ENV_ERROR="$file:$lineno 值内部出现裸单引号: $key"; return 1 ;;
        esac
        val="$inner"
        ;;
      *\"*|*\'*)
        ENV_ERROR="$file:$lineno 引号必须整体包住取值（不支持 a\"b\" 这种半包写法）: $key"
        return 1
        ;;
      *\\*)
        # 裸值里的反斜杠：systemd EnvironmentFile 会把它当转义符，本脚本按字面保留，
        # 两边解析结果会不一致，所以一律拒绝而不是猜测。
        ENV_ERROR="$file:$lineno 值里含反斜杠（本脚本不支持转义，请改写；systemd 会把它当转义符）: $key"
        return 1
        ;;
    esac

    if [ -n "${ENV_LINES[$key]:-}" ]; then
      ENV_ERROR="$file:$lineno 变量 $key 重复出现（第 ${ENV_LINES[$key]} 行已有）。本脚本不接受重复赋值，请人工去重"
      return 1
    fi
    ENV_LINES[$key]="$lineno"
    ENV_VALS[$key]="$val"
  done < "$file"

  for k in "${want[@]}"; do
    if [ -z "${ENV_LINES[$k]:-}" ]; then
      ENV_ERROR="$file 缺少必需变量 $k（当前文件里的键：$(printf '%s ' "${!ENV_LINES[@]}")）"
      return 1
    fi
    if [ -z "${ENV_VALS[$k]}" ]; then
      ENV_ERROR="$file 的 $k 是空值（第 ${ENV_LINES[$k]} 行）"
      return 1
    fi
  done

  return 0
}

# ---- 已有 companion.env：类型 + 全字段回读校验 ------------------------------
COMPANION_ENV="$ETC_DIR/companion.env"
if [ -e "$COMPANION_ENV" ] || [ -L "$COMPANION_ENV" ]; then
  require_regular_file "$COMPANION_ENV" "companion.env"

  env_parse_strict "$COMPANION_ENV" \
    CORTICO_COMPANION_ROOT CORTICO_HOME CORTICO_EXTENSIONS_DIR \
    COMPANION_DATA_ROOT COMPANION_MOUNTPOINT NODE_ENV \
    || die_pre "$ENV_ERROR"

  old_cmp="${ENV_VALS[CORTICO_COMPANION_ROOT]}"
  old_home="${ENV_VALS[CORTICO_HOME]}"
  old_ext="${ENV_VALS[CORTICO_EXTENSIONS_DIR]}"
  old_root="${ENV_VALS[COMPANION_DATA_ROOT]}"
  old_mnt="${ENV_VALS[COMPANION_MOUNTPOINT]}"
  old_node="${ENV_VALS[NODE_ENV]}"

  for kv in "CORTICO_COMPANION_ROOT=$old_cmp" "CORTICO_HOME=$old_home" \
            "CORTICO_EXTENSIONS_DIR=$old_ext" "COMPANION_DATA_ROOT=$old_root" \
            "COMPANION_MOUNTPOINT=$old_mnt"; do
    case "${kv#*=}" in
      /*) : ;;
      *) die_pre "$COMPANION_ENV 的 ${kv%%=*} 不是绝对路径: '${kv#*=}'" ;;
    esac
  done

  old_cmp_n="$(realpath -m -- "$old_cmp")"   || die_pre "无法规范化 $COMPANION_ENV 里的 CORTICO_COMPANION_ROOT"
  old_home_n="$(realpath -m -- "$old_home")" || die_pre "无法规范化 $COMPANION_ENV 里的 CORTICO_HOME"
  old_ext_n="$(realpath -m -- "$old_ext")"   || die_pre "无法规范化 $COMPANION_ENV 里的 CORTICO_EXTENSIONS_DIR"
  old_root_n="$(realpath -m -- "$old_root")" || die_pre "无法规范化 $COMPANION_ENV 里的 COMPANION_DATA_ROOT"
  old_mnt_n="$(realpath -m -- "$old_mnt")"   || die_pre "无法规范化 $COMPANION_ENV 里的 COMPANION_MOUNTPOINT"
  CMP_EXPECT="$(realpath -m -- "$APP_TARGET/build/cortico")" || die_pre "无法规范化安装目标 $APP_TARGET/build/cortico"

  problems=""
  [ "$old_cmp_n"  = "$CMP_EXPECT"  ] || problems="$problems"$'\n'"  CORTICO_COMPANION_ROOT：文件里是 $old_cmp_n，本次安装目标是 $CMP_EXPECT"
  [ "$old_home_n" = "$HOME_EXPECT" ] || problems="$problems"$'\n'"  CORTICO_HOME：文件里是 $old_home_n，本次是 $HOME_EXPECT"
  [ "$old_ext_n"  = "$EXT_EXPECT"  ] || problems="$problems"$'\n'"  CORTICO_EXTENSIONS_DIR：文件里是 $old_ext_n，本次是 $EXT_EXPECT"
  [ "$old_root_n" = "$DATA_N"      ] || problems="$problems"$'\n'"  COMPANION_DATA_ROOT：文件里是 $old_root_n，本次是 $DATA_N"
  [ "$old_mnt_n"  = "$MOUNT_N"     ] || problems="$problems"$'\n'"  COMPANION_MOUNTPOINT：文件里是 $old_mnt_n，本次是 $MOUNT_N"
  if [ "$old_node" != "production" ]; then
    problems="$problems"$'\n'"  NODE_ENV：文件里是 '$old_node'，本部署要求 production"
  fi

  if [ -n "$problems" ]; then
    printf '\033[31m[install] 前置检查未通过:\033[0m %s 已存在，且与本次参数不一致：%s\n' "$COMPANION_ENV" "$problems" >&2
    printf '  请人工确认哪个是对的：改这份文件（推荐），或者用与之匹配的参数重跑。\n' >&2
    printf '  本脚本不会自动改写它，也不会在这里猜你的意图。\n' >&2
    exit 2
  fi
  log "$COMPANION_ENV 已存在：6 个键齐全、无重复、取值与本次参数一致，保留不动"
fi

# ---- 窗口密钥：systemd 凭据文件（S01）-------------------------------------
# r9 起密钥不再放在 EnvironmentFile 里，而是单独一个文件：
#   /etc/companion/pet-window.key   0400 root:root   单行 32 位小写十六进制
# 由 systemd 的 LoadCredential= 在启动时读进内存，服务进程通过
# $CREDENTIALS_DIRECTORY/pet-window-key 读取。这样磁盘上就没有 companion
# 用户可读的密钥副本（旧方案 pet-window.env 是 0640 root:companion）。
#
# 兼容旧安装：pet-window.env 还在时把里面的密钥迁过来，不重新生成——
# 重新生成会让 Windows 侧那份 key 立刻失效。
WINDOW_ENV="$ETC_DIR/pet-window.env"
WINDOW_KEY_FILE="$ETC_DIR/pet-window.key"
WINDOW_KEY=""
WINDOW_KEY_NEW=0
WINDOW_LEGACY_KEY=""

if [ -e "$WINDOW_ENV" ] || [ -L "$WINDOW_ENV" ]; then
  require_regular_file "$WINDOW_ENV" "pet-window.env（旧格式）"
  env_parse_strict "$WINDOW_ENV" CORTICO_PET_WINDOW_KEY || die_pre "$ENV_ERROR"
  WINDOW_LEGACY_KEY="${ENV_VALS[CORTICO_PET_WINDOW_KEY]}"
  case "$WINDOW_LEGACY_KEY" in
    *[!0-9a-f]*) die_pre "$WINDOW_ENV 里的 CORTICO_PET_WINDOW_KEY 含非小写十六进制字符（长度 ${#WINDOW_LEGACY_KEY}）" ;;
  esac
  [ "${#WINDOW_LEGACY_KEY}" -eq 32 ] || die_pre "$WINDOW_ENV 里的 CORTICO_PET_WINDOW_KEY 长度是 ${#WINDOW_LEGACY_KEY}，要求 32"
  log "发现旧格式 $WINDOW_ENV：键恰好一次、32 位小写十六进制（将迁移到 $WINDOW_KEY_FILE，内容不改写）"
fi

if [ -e "$WINDOW_KEY_FILE" ] || [ -L "$WINDOW_KEY_FILE" ]; then
  require_regular_file "$WINDOW_KEY_FILE" "pet-window.key"
  WINDOW_KEY="$(cat -- "$WINDOW_KEY_FILE" 2>/dev/null || true)"
  case "$WINDOW_KEY" in
    *[!0-9a-f]*) die_pre "$WINDOW_KEY_FILE 的内容不是纯 32 位小写十六进制（实际长度 ${#WINDOW_KEY}）：不接受夹带换行/空格/其他字符的密钥文件" ;;
  esac
  [ "${#WINDOW_KEY}" -eq 32 ] || die_pre "$WINDOW_KEY_FILE 的长度是 ${#WINDOW_KEY}，要求恰好 32 位小写十六进制（单行、无换行）"
  if [ -n "$WINDOW_LEGACY_KEY" ] && [ "$WINDOW_LEGACY_KEY" != "$WINDOW_KEY" ]; then
    die_pre "两份密钥不一致：$WINDOW_ENV 与 $WINDOW_KEY_FILE。拒绝猜测 Windows 侧在用哪一个，请人工统一后重跑"
  fi
  log "已有 $WINDOW_KEY_FILE：32 位小写十六进制（内容不改写）"
fi

# ---- 哨兵：类型检查（创建/修复留到预检通过之后） ---------------------------
SENTINEL="$DATA_N/$SENTINEL_NAME"
if [ -L "$SENTINEL" ]; then
  die_pre "$SENTINEL 是符号链接。拒绝通过链接写入别处，请人工删除该链接后重试"
fi
if [ -e "$SENTINEL" ] && [ ! -f "$SENTINEL" ]; then
  die_pre "$SENTINEL 存在但不是普通文件（可能是目录或设备）"
fi

# ---- 空间、已有安装 -------------------------------------------------------
avail_mb="$(df -Pm "$MOUNT_N" | awk 'NR==2 {print $4}')"
[ "${avail_mb:-0}" -ge "$MIN_FREE_MB" ] || die_pre "$MOUNT_N 剩余空间 ${avail_mb}MB，少于 ${MIN_FREE_MB}MB"

# 安装目标 APP_TARGET：只允许「不存在」或「目录」。
# 先判链接再判类型：`[ -f ]` / `[ -d ]` 都会跟随符号链接，一个指向 /etc 的链接
# 会被当成普通目录放过去，所以链接必须单独拦。
if [ -L "$APP_TARGET" ]; then
  die_pre "$APP_TARGET 是符号链接——拒绝在一个链接上安装（请人工确认它指向哪里）"
fi
if [ -e "$APP_TARGET" ] && [ ! -d "$APP_TARGET" ]; then
  die_pre "$APP_TARGET 存在但不是目录（普通文件/设备/FIFO/socket 都不接受）。请人工确认后移走它"
fi
if [ -d "$APP_TARGET" ] && [ -n "$(ls -A "$APP_TARGET" 2>/dev/null || true)" ]; then
  if [ "$FORCE" -eq 1 ]; then
    warn "$APP_TARGET 已存在，--force：将**合并覆盖**同名文件；源里已不存在的旧文件会保留（不删任何东西）"
  else
    die_pre "$APP_TARGET 已存在且非空。这是升级场景：请先备份，再用 --force 重跑（脚本不会删任何文件）"
  fi
fi

# ---- 随附文件：check-storage.sh / companion.service -------------------------
# 这两个文件原来在第 8 步才检查；那时系统用户、程序、配置都已经改完。
# 现在提前到预检：缺文件时一个字节都还没写（IN-16）。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)" \
  || die_pre "无法解析脚本所在目录（\$0=$0）"
CHK_SRC="$SCRIPT_DIR/check-storage.sh"
UNIT_SRC="$SCRIPT_DIR/companion.service"
require_present_file "$CHK_SRC"  "check-storage.sh"
require_present_file "$UNIT_SRC" "companion.service"

# ---- 补丁文件：仅 --apply-patch --------------------------------------------
# 允许两个来源（只读检查，不复制、不改动任何东西）：
#   1. $PATCH_DIR/0001-window-key-from-env.diff（安装目录下的既有副本）
#   2. 与本脚本同目录的 0001-window-key-from-env.diff（分发目录里的原件）
# 原来只认第 1 种，而且直到第 6 步才检查——那时已经建了用户、复制了程序。
# 补丁按顺序打：0001 让 windowKey 可来自环境变量，0002 再让它优先读 systemd 凭据。
PATCH_NAMES=("0001-window-key-from-env.diff" "0002-window-key-from-credential.diff")
PATCH_SRC_LIST=()
if [ "$APPLY_PATCH" -eq 1 ]; then
  for pname in "${PATCH_NAMES[@]}"; do
    found=""
    for cand in "$PATCH_DIR/$pname" "$SCRIPT_DIR/$pname"; do
      if [ -e "$cand" ] || [ -L "$cand" ]; then
        require_present_file "$cand" "补丁文件 $pname"
        found="$cand"
        break
      fi
    done
    [ -n "$found" ] \
      || die_pre "--apply-patch 需要 $pname，但在 $PATCH_DIR/ 与 $SCRIPT_DIR/ 都没有找到。请把补丁一起拷到脚本同目录后重跑"
    PATCH_SRC_LIST+=("$found")
    log "补丁文件：$found"
  done
fi

# ---- systemd 单元：目标类型 + .new 冲突 ------------------------------------
# 单元文件永远不覆盖已有的那份（保留原设计）：已存在时只写 .new 供人工 diff。
# 但 .new 也不能覆盖别人已经放好的：它的存在本身就是「有人还没处理完」的信号。
if [ -L "$UNIT_TARGET" ]; then
  die_pre "$UNIT_TARGET 是符号链接。拒绝通过链接写入/替换别处，请人工确认为普通文件后重试"
fi
if [ -e "$UNIT_TARGET" ] && [ ! -f "$UNIT_TARGET" ]; then
  die_pre "$UNIT_TARGET 存在但不是普通文件（可能是目录或设备）"
fi
UNIT_NEW="${UNIT_TARGET}.new"
if [ -f "$UNIT_TARGET" ]; then
  if [ -L "$UNIT_NEW" ]; then
    die_pre "$UNIT_NEW 是符号链接——拒绝写入（会跟随链接覆盖到别处），请人工删除该链接"
  fi
  if [ -e "$UNIT_NEW" ]; then
    die_pre "$UNIT_NEW 已存在。本脚本不覆盖已有的 .new（可能是上一轮留下待比对的版本），请先人工 diff 并处理掉它"
  fi
fi

# ---- 已有服务用户：属性必须符合预期（R11/R13）-----------------------------
# 用户名存在 ≠ 这个用户就是我们要的：UID 落在普通用户区间、home 在别处、
# shell 是 /bin/bash，都会让后面的 chown 与 systemd 行为跟预期不一样。
# 本脚本不删除、不重建已有用户，只做只读核对并在不符合时停下。
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  pw_line="$(getent passwd "$SERVICE_USER" 2>/dev/null || true)"
  [ -n "$pw_line" ] || die_pre "用户 $SERVICE_USER 存在，但 getent passwd 读不到属性，无法确认它是否符合预期"
  u_uid="$(printf '%s' "$pw_line" | cut -d: -f3)"
  u_gid="$(printf '%s' "$pw_line" | cut -d: -f4)"
  u_home="$(printf '%s' "$pw_line" | cut -d: -f6)"
  u_shell="$(printf '%s' "$pw_line" | cut -d: -f7)"
  case "$u_uid" in ''|*[!0-9]*) die_pre "无法解析 $SERVICE_USER 的 UID: '$u_uid'" ;; esac
  if [ "$u_uid" -ge 1000 ]; then
    warn "$SERVICE_USER 的 UID 是 $u_uid（普通用户区间，不是 useradd --system 的 100-999）。若这是有意建的专用账户可继续，但请确认它没有别的登录用途"
  fi
  [ "$u_home" = "/var/lib/$SERVICE_USER" ] \
    || die_pre "$SERVICE_USER 的 home 是 $u_home，预期 /var/lib/$SERVICE_USER。请人工确认，本脚本不会改已有用户"
  case "$u_shell" in
    */nologin|*/false) : ;;
    *) die_pre "$SERVICE_USER 的 shell 是 $u_shell，预期 nologin/false。请人工确认，本脚本不会改已有用户" ;;
  esac
  # 后面所有属主写法都是 $SERVICE_USER:$SERVICE_USER，install -g 也是这个组：
  # 组不存在、或主组不是同名组，都会让第 4/7/8 步在**已经复制了程序之后**才失败。
  # 所以这里必须拒绝，不能只给警告（拒绝发生在第一次写操作之前）。
  g_name="$(getent group "$u_gid" 2>/dev/null | cut -d: -f1 || true)"
  if [ -z "$g_name" ]; then
    die_pre "$SERVICE_USER 的主组 GID 是 $u_gid，但 /etc/group 里没有这个 GID。后续 chown $SERVICE_USER:$SERVICE_USER 无法解析，拒绝继续"
  fi
  getent group "$SERVICE_USER" >/dev/null 2>&1 \
    || die_pre "组 '$SERVICE_USER' 不存在。后续 install -g $SERVICE_USER 与 chown $SERVICE_USER:$SERVICE_USER 都依赖这个组，请先 groupadd --system $SERVICE_USER 后重跑"
  if [ "$g_name" != "$SERVICE_USER" ]; then
    die_pre "已有用户 $SERVICE_USER 的主组是 '$g_name'（GID $u_gid），不是同名组 '$SERVICE_USER'。本脚本后面的 install -g 与 chown 固定写成 $SERVICE_USER:$SERVICE_USER，在这个账户结构下会把属组写错或直接失败。请人工处理（例如 usermod -g $SERVICE_USER $SERVICE_USER），本脚本不会改已有用户的 UID/主组/shell"
  fi
  log "已有服务用户 $SERVICE_USER：UID $u_uid、home $u_home、shell $u_shell，符合预期"
fi

log "预检通过：尚未做任何修改"

# ============================================================ 第 2 步 ===
log "第 2 步 / 共 8 步：系统用户 $SERVICE_USER（本步起开始修改系统）"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  log "用户已存在，跳过"
else
  # --user-group：明确要求同时创建同名组，后面一律用 $SERVICE_USER:$SERVICE_USER
  run useradd --system --user-group --create-home --home-dir "/var/lib/$SERVICE_USER" \
      --shell /usr/sbin/nologin --comment "Coopanion Core" "$SERVICE_USER"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 计划创建系统用户 $SERVICE_USER（含同名组）"
  else
    log "已创建系统用户 $SERVICE_USER（如需回滚：userdel $SERVICE_USER）"
    getent group "$SERVICE_USER" >/dev/null 2>&1 \
      || die "用户 $SERVICE_USER 已创建，但没有同名组。后续 install -g / chown 都写成 $SERVICE_USER:$SERVICE_USER，依赖这个组；请执行 groupadd --system $SERVICE_USER 后重跑"
  fi
fi
run install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "/var/lib/$SERVICE_USER"

# ============================================================ 第 3 步 ===
# 权限闸门：仍然发生在「复制程序、写入配置」之前。
# 到这一步为止只可能有系统用户被创建。
log "第 3 步 / 共 8 步：数据目录权限闸门"
need_perm_fix=0
# 权限结论必须分态，不能都报成「已通过」：
#   ok          = 刚才真的用 runuser 测过，通过
#   fixed       = 真的改了，改完又用 runuser 测过，通过
#   planned-fix = 现在不通过，dry-run 只打印了修复计划，一条都没执行
#   skipped     = 连测都没测（dry-run 且服务用户还不存在）
PERM_STATE="skipped"
if [ "$DRY_RUN" -eq 1 ] && ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  # R01/R02：dry-run 下服务用户通常还不存在，runuser 必然失败。
  # 那是「没法验证」，不是「权限不对」：不能据此报权限失败，也不能声称验证过。
  warn "[dry-run] 服务用户 $SERVICE_USER 尚不存在：跳过真实权限验证（模拟环境里没有可代表真实结果的检查）"
else
  runuser -u "$SERVICE_USER" -- test -wx "$HOME_EXPECT" 2>/dev/null || need_perm_fix=1
  runuser -u "$SERVICE_USER" -- test -wx "$EXT_EXPECT" 2>/dev/null || need_perm_fix=1
  if [ "$need_perm_fix" -eq 0 ]; then
    PERM_STATE="ok"
  fi
fi

if [ "$need_perm_fix" -eq 1 ]; then
  if [ "$FIX_PERMS" -eq 1 ]; then
    if [ "$FIX_PERMS_RECURSIVE" -eq 1 ]; then
      n_home="$(count_entries "$HOME_EXPECT")"
      n_ext="$(count_entries "$EXT_EXPECT")"
      warn "--fix-perms-recursive：将递归修改 $HOME_EXPECT（$n_home 个条目）与 $EXT_EXPECT（$n_ext 个条目）的属主"
      warn "  这些条目里若有别的服务/用户的数据，属主会被一并改掉。"
      # 递归 chown 会顺着整棵树改下去：动手前把挂载关系**重新问一遍**。
      # 不能沿用第 1 步缓存的 DATA_MT：从预检到这里可能已经有人往数据目录上挂了东西。
      # 尤其要防「bind mount 到 home/ 或 extensions/ **自身**」——那种情况下设备号相同，
      # nested_mounts_under 也看不见（它用 strict_under，明确排除了目录本身），
      # 只有问一次 mount_target_of 才能发现目录自己的挂载点变了。
      # 检查用的就是后面 chown -R 实际操作的这两个路径，不换成别的等价值。
      cur_data_mt="$(mount_target_of "$DATA_N")" \
        || die "findmnt 问不出数据根 $DATA_N 当前的挂载点：无法确认挂载关系，拒绝递归修改属主"
      for d in "$HOME_EXPECT" "$EXT_EXPECT"; do
        cur_d_mt="$(mount_target_of "$d")" \
          || die "findmnt 问不出 $d 当前的挂载点：无法确认它有没有被单独挂载，拒绝递归修改属主"
        if [ "$cur_d_mt" != "$cur_data_mt" ]; then
          die "拒绝递归修改 $d 的属主：它当前的挂载点是 $cur_d_mt，而数据根 $DATA_N 当前是 $cur_data_mt（第 1 步预检之后挂载关系变了；目录自身被 bind mount 到别处也算）"
        fi
        v_nm="$(nested_mounts_under "$d")" \
          || die "findmnt 列不出挂载表：无法确认 $d 之下没有嵌套挂载，拒绝递归修改属主"
        [ -z "$v_nm" ] \
          || die "拒绝递归修改 $d 的属主：它之下还挂着 $v_nm，递归会改到那块盘上的内容。请先人工处理这些挂载"
      done
      # 挂载实例指纹复查（r10.1）：挂载点路径与设备号都相同、但整个数据盘被换成另一个
      # 挂载实例（例如换个文件系统重挂到同一路径，或同盘不同子目录的 bind mount）时，
      # 上面两条判据都看不出来 —— 组合指纹（ID/父ID/设备/根/源/类型）会变。
      # 四条路径都必须仍然是第 1 步记下的那个实例：挂载点本身、数据根、以及 chown -R 的两个目标。
      [ -n "$MOUNT_IDENT_EXPECT" ] \
        || die "内部状态错误：第 1 步没有记录挂载实例指纹，拒绝递归修改属主（无法确认挂载关系）"
      for p in "$MOUNT_N" "$DATA_N" "$HOME_EXPECT" "$EXT_EXPECT"; do
        cur_fp="$(mount_ident_of "$p")" \
          || die "findmnt 问不出 $p 当前的挂载实例指纹：无法确认挂载关系，拒绝递归修改属主"
        if [ "$cur_fp" != "$MOUNT_IDENT_EXPECT" ]; then
          die "拒绝递归修改属主：$p 当前的挂载实例指纹是「$cur_fp」，而第 1 步预检时是「$MOUNT_IDENT_EXPECT」（第 1 步预检之后挂载关系变了：数据盘被重新挂到同一路径、或被换成了另一个挂载实例）"
        fi
      done
      run chown -R "$SERVICE_USER:$SERVICE_USER" "$HOME_EXPECT" "$EXT_EXPECT"
    else
      warn "数据目录对 $SERVICE_USER 不是 w+x。--fix-perms：只改这两个顶层目录的属主与权限位（不递归、不触碰内容）"
      run chown "$SERVICE_USER:$SERVICE_USER" "$HOME_EXPECT" "$EXT_EXPECT"
    fi
    run chmod 0750 "$HOME_EXPECT" "$EXT_EXPECT"
    if [ "$DRY_RUN" -eq 0 ]; then
      for d in "$HOME_EXPECT" "$EXT_EXPECT"; do
        runuser -u "$SERVICE_USER" -- test -w "$d" || die "chown/chmod 之后 $d 仍不可写（检查是否只读挂载或 ACL 覆盖）"
        runuser -u "$SERVICE_USER" -- test -x "$d" || die "chown/chmod 之后 $d 仍不可穿越（检查 ACL）"
      done
      PERM_STATE="fixed"
      log "权限已修正并复检：$(stat -c '%U:%G %a' -- "$HOME_EXPECT") / $(stat -c '%U:%G %a' -- "$EXT_EXPECT")"
    else
      PERM_STATE="planned-fix"
      log "[dry-run][计划] 权限修正后复检（未执行）"
    fi
  else
    {
      printf '\033[31m[install] 前置检查未通过:\033[0m 数据目录对 %s 不是「可写 + 可穿越（w+x）」\n' "$SERVICE_USER"
      printf '  %s  → %s\n' "$HOME_EXPECT" "$(stat -c '%U:%G %a' -- "$HOME_EXPECT" 2>/dev/null || echo '?')"
      printf '  %s  → %s\n' "$EXT_EXPECT"  "$(stat -c '%U:%G %a' -- "$EXT_EXPECT" 2>/dev/null || echo '?')"
      printf '\n'
      printf '  已做的修改：只有系统用户 %s（新建时）。程序未复制、配置未写入、目录权限未改。\n' "$SERVICE_USER"
      printf '  如需回滚：userdel %s\n\n' "$SERVICE_USER"
      printf '  OMV 共享文件夹默认是 root:users 0775，服务用户不在 users 组里就写不进去。\n'
      printf '  两种做法（都不要用 777）：\n'
      printf '    推荐（专用用户独占，只改顶层两项）：\n'
      printf '      chown %s:%s %s %s\n' "$SERVICE_USER" "$SERVICE_USER" "$HOME_EXPECT" "$EXT_EXPECT"
      printf '      chmod 0750 %s %s\n' "$HOME_EXPECT" "$EXT_EXPECT"
      printf '    或者（保留 users 组可写）：把 %s 加入 users 组，目录保持 2775 root:users\n' "$SERVICE_USER"
      printf '      usermod -aG users %s && chmod 2775 %s %s\n' "$SERVICE_USER" "$HOME_EXPECT" "$EXT_EXPECT"
      printf '\n  也可以重跑并加 --fix-perms（只改顶层）。\n'
      printf '  若数据目录里已有历史文件需要一并改属主，加 --fix-perms-recursive --yes（会递归修改，风险见文档）。\n'
      printf '  注意：home/ 与 extensions/ 不要再挂到 SMB 共享里，OMV 的 ACL 递归会改属主。\n'
    } >&2
    exit 2
  fi
fi
case "$PERM_STATE" in
  ok)
    log "数据目录对 $SERVICE_USER 可写且可穿越（w+x）—— 本次用 runuser 实测通过" ;;
  fixed)
    log "数据目录权限已修正，并用 runuser 实测通过（w+x）" ;;
  planned-fix)
    warn "[dry-run] 数据目录当前**不满足** w+x；本次只打印了 chown/chmod 计划，一条都没执行。修复之后能不能用：未验证"
    log "[dry-run] 数据目录权限：计划修复（结果未验证）" ;;
  skipped)
    log "[dry-run] 数据目录权限：跳过真实权限验证（结果未验证）" ;;
  *)
    log "数据目录权限：未验证" ;;
esac

# ============================================================ 第 4 步 ===
log "第 4 步 / 共 8 步：复制程序到 $APP_TARGET"
run install -d -m 0755 -o root -g root /opt/companion "$APP_TARGET" "$PATCH_DIR"

# 不带 node_modules（要在本机重装）、不带 Windows 专用目录、不带日志。
# 注意：没有 --delete —— 目标是合并覆盖，旧文件会保留。
run rsync -a --info=stats1 \
    --exclude 'node_modules/' \
    --exclude 'mingit/' \
    --exclude 'docs/' \
    --exclude '.git/' \
    --exclude '*.log' \
    --exclude 'build/home/' \
    "$SRC/" "$APP_TARGET/"

# ============================================================ 第 5 步 ===
log "第 5 步 / 共 8 步：在 NAS 上安装依赖（Linux 原生包）"
if [ -x "$PNPM_BIN" ] && [ "$("$PNPM_BIN" --version 2>/dev/null || true)" = "$PNPM_WANT" ]; then
  log "pnpm $PNPM_WANT 已就绪"
else
  [ -x "$NPM_BIN" ] || die "找不到 $NPM_BIN（Node 22 的 tarball 里应自带 npm）"
  log "用 npm 安装 pnpm@$PNPM_WANT 到 $NODE_PREFIX"
  run "$NPM_BIN" install -g --prefix "$NODE_PREFIX" "pnpm@$PNPM_WANT"
fi

# --prod：app/package.json 里没有 devDependencies，tsx 也在 dependencies 中，
#         所以装完仍然可以 `node --import tsx core/boot.ts`。
# R10：--frozen-lockfile —— 锁文件与 package.json 不一致时直接失败，
# 而不是静默改锁文件装出一棵和锁文件不一样的树。
run "$PNPM_BIN" install --prod --frozen-lockfile --dir "$APP_TARGET"

LOCK_SHA=""
if [ "$DRY_RUN" -eq 0 ]; then
  [ -f "$APP_TARGET/pnpm-lock.yaml" ] \
    || die "依赖装完后 $APP_TARGET/pnpm-lock.yaml 不见了，无法核对锁文件"
  LOCK_SHA="$(sha256sum "$APP_TARGET/pnpm-lock.yaml" | cut -d' ' -f1)"
  [ -n "$LOCK_SHA" ] || die "读不到 $APP_TARGET/pnpm-lock.yaml 的 sha256"
  log "依赖安装完成，锁文件 sha256：$LOCK_SHA"
fi

if [ -f "$APP_TARGET/pnpm-lock.yaml" ] && [ ! -f "$PATCH_DIR/pnpm-lock.initial.yaml" ]; then
  run cp -n "$APP_TARGET/pnpm-lock.yaml" "$PATCH_DIR/pnpm-lock.initial.yaml"
  log "已保存依赖基线: $PATCH_DIR/pnpm-lock.initial.yaml"
fi

run chown -R root:root "$APP_TARGET"
run chmod -R go-w "$APP_TARGET"

# ============================================================ 第 6 步 ===
log "第 6 步 / 共 8 步：窗口密钥补丁"
WORLD_PKG="$APP_TARGET/node_modules/cortico-world-desktop-pet"
if [ ! -d "$WORLD_PKG" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "[dry-run] 依赖尚未安装，跳过世界包检查"
  else
    die "依赖里没有 cortico-world-desktop-pet —— 第 5 步可能没装成功，请检查 pnpm 输出"
  fi
fi
# R05：判据是「目标行确实被改成了目标写法」，不是「文件里出现过这个字符串」。
WORLD_SRC="$WORLD_PKG/src/server.ts"

# 补丁 1 的判据：windowKey 不再是「每进程随机」，而是从外部取值。
# 0002 会把 0001 那行换成调 resolveWindowKey()，所以两种写法都算已到位——
# 否则「先打 1 再打 2」之后回查 1 会误报失败。
patched_env() { # patched_env <server.ts>
  local f="$1"
  [ -f "$f" ] || return 1
  if grep -q 'private readonly windowKey = randomUUID();' "$f" 2>/dev/null; then return 1; fi
  grep -q 'private readonly windowKey = (process.env.CORTICO_PET_WINDOW_KEY' "$f" 2>/dev/null && return 0
  patched_cred "$f"
}
# 补丁 2 的判据：凭据解析函数已存在、且 windowKey 调它（0002）
patched_cred() { # patched_cred <server.ts>
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q 'function resolveWindowKey' "$f" 2>/dev/null || return 1
  grep -q 'private readonly windowKey = resolveWindowKey();' "$f" 2>/dev/null || return 1
  return 0
}

apply_one_patch() { # apply_one_patch <patch file> <描述>
  local pf="$1" what="$2" rej_list
  # R03：先干跑。不匹配就一个字节都不改，避免留下半个补丁。
  if ! patch -p1 --dry-run -d "$WORLD_PKG" < "$pf" >/dev/null 2>&1; then
    die "$what 与当前源码不匹配（patch --dry-run 失败）。源码可能已升级，本步未改动任何文件"
  fi
  # --backup：改之前留一份 <file>.pre-patch，失败时能原样退回去。
  if ! patch -p1 --backup --suffix=.pre-patch -d "$WORLD_PKG" < "$pf"; then
    rej_list="$(find "$WORLD_PKG" -name '*.rej' -print 2>/dev/null | tr '\n' ' ')"
    die "应用$what失败，可能留下部分改动。rej 文件：${rej_list:-无}。恢复：在 $WORLD_PKG 下用 *.pre-patch 覆盖回原文件并删除 *.rej 后重跑"
  fi
  log "$what 已应用（备份后缀 .pre-patch）"
}

if [ "$APPLY_PATCH" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
  # R02：dry-run 下依赖通常还没装，这里没有可验证的对象——明说跳过，不假装验过。
  warn "[dry-run] 依赖尚未安装：跳过补丁干跑与实际应用（本项未验证）"
elif [ "$APPLY_PATCH" -eq 1 ]; then
  [ -d "$WORLD_PKG" ] || die "依赖里没有 cortico-world-desktop-pet —— 第 5 步可能没装成功，请检查 pnpm 输出"
  [ -f "$WORLD_SRC" ] || die "找不到 $WORLD_SRC，无法判断补丁该不该打"
  [ -r "${PATCH_SRC_LIST[0]}" ] || die "补丁文件 ${PATCH_SRC_LIST[0]} 在预检之后消失了，拒绝在状态不明时继续"
  [ -r "${PATCH_SRC_LIST[1]}" ] || die "补丁文件 ${PATCH_SRC_LIST[1]} 在预检之后消失了，拒绝在状态不明时继续"
  if patched_env "$WORLD_SRC"; then
    log "补丁 1 已在位（windowKey 已读环境变量），跳过"
  else
    apply_one_patch "${PATCH_SRC_LIST[0]}" "补丁 1（windowKey 读环境变量）"
  fi
  if patched_cred "$WORLD_SRC"; then
    log "补丁 2 已在位（windowKey 优先读 systemd 凭据），跳过"
  else
    apply_one_patch "${PATCH_SRC_LIST[1]}" "补丁 2（windowKey 优先读 systemd 凭据）"
  fi
  # R04：应用之后再验一次结构，别只信 patch 的退出码。
  patched_env  "$WORLD_SRC" || die "补丁 1 应用后结构判据不成立——拒绝把它当成已修好。请检查 $WORLD_SRC"
  patched_cred "$WORLD_SRC" || die "补丁 2 应用后结构判据不成立——拒绝把它当成已修好。请检查 $WORLD_SRC"
  log "两个补丁均已应用并通过结构判据"
else
  if [ -d "$WORLD_PKG" ] && patched_cred "$WORLD_SRC"; then
    log "补丁已在位（windowKey 优先读 systemd 凭据），跳过"
  else
    warn "未应用补丁（远程窗口将无法通过 key 校验）。加上 --apply-patch 可立即应用"
  fi
fi

# ============================================================ 第 7 步 ===
log "第 7 步 / 共 8 步：环境变量文件"
run install -d -m 0755 -o root -g root "$ETC_DIR"

if [ -e "$COMPANION_ENV" ] || [ -L "$COMPANION_ENV" ]; then
  warn "$COMPANION_ENV 已存在且已通过一致性校验，保留不动"
else
  write_file "$COMPANION_ENV" "# Coopanion Core 环境（由 install-nas.sh 生成，可手工修改）
# 注意：改这里的路径之后，必须让本脚本用相同参数重跑一遍，否则它会在预检时停下。
# 六个键都是必需的，且每个只能出现一次（check-storage.sh 与 systemd 都按这套读）。
# 框架源码位置：Core 会去 \$CORTICO_COMPANION_ROOT/src/core 找入口
CORTICO_COMPANION_ROOT=$APP_TARGET/build/cortico
# 用户数据根（HDD）：Core 的 seed() 会在这里建 companion/
CORTICO_HOME=$HOME_EXPECT
# World / Provider 扩展目录（HDD）
CORTICO_EXTENSIONS_DIR=$EXT_EXPECT
# 数据根与挂载点：给 check-storage.sh 做归属与挂载校验用，Core 本身不读
COMPANION_DATA_ROOT=$DATA_N
COMPANION_MOUNTPOINT=$MOUNT_N
NODE_ENV=production
"
  run chmod 0644 "$COMPANION_ENV"
  run chown root:root "$COMPANION_ENV"
  if [ "$DRY_RUN" -eq 0 ]; then
    # 写盘后用同一套严格解析器**全字段**回读：写进去的必须与预期逐项相同
    env_parse_strict "$COMPANION_ENV" \
      CORTICO_COMPANION_ROOT CORTICO_HOME CORTICO_EXTENSIONS_DIR \
      COMPANION_DATA_ROOT COMPANION_MOUNTPOINT NODE_ENV \
      || die "刚写入的 $COMPANION_ENV 解析失败: $ENV_ERROR"
    [ "${ENV_VALS[CORTICO_COMPANION_ROOT]}"  = "$APP_TARGET/build/cortico" ] || die "回读：CORTICO_COMPANION_ROOT 与预期不一致"
    [ "${ENV_VALS[CORTICO_HOME]}"            = "$HOME_EXPECT" ] || die "回读：CORTICO_HOME 与预期不一致"
    [ "${ENV_VALS[CORTICO_EXTENSIONS_DIR]}"  = "$EXT_EXPECT" ]  || die "回读：CORTICO_EXTENSIONS_DIR 与预期不一致"
    [ "${ENV_VALS[COMPANION_DATA_ROOT]}"     = "$DATA_N" ]      || die "回读：COMPANION_DATA_ROOT 与预期不一致"
    [ "${ENV_VALS[COMPANION_MOUNTPOINT]}"    = "$MOUNT_N" ]     || die "回读：COMPANION_MOUNTPOINT 与预期不一致"
    [ "${ENV_VALS[NODE_ENV]}"                = "production" ]   || die "回读：NODE_ENV 与预期不一致"
    # M02：再用一份独立实现（不复用 env_parse_strict）核对 systemd 侧规则。
    verify_env_file_systemd_safe "$COMPANION_ENV"
    log "已写入并回读确认 $COMPANION_ENV（6 个键，无重复，取值全部匹配；systemd 兼容性校验通过）"
  fi
fi

# ---- 窗口密钥文件：0400 root:root，由 systemd LoadCredential 提供给服务 ----
if [ -e "$WINDOW_KEY_FILE" ] || [ -L "$WINDOW_KEY_FILE" ]; then
  cur_meta="$(stat -c '%a %U:%G' -- "$WINDOW_KEY_FILE" 2>/dev/null || true)"
  # S04：getfacl 缺失或执行失败 = 失败关闭。绝不能把「查不到」当成「没有额外 ACL」。
  extra_acl="$(acl_extended "$WINDOW_KEY_FILE")" \
    || die_pre "getfacl 读不到 $WINDOW_KEY_FILE 的 ACL（原因见上一行），拒绝把「查不到」当成「没有额外 ACL」"
  extra_acl="$(printf '%s' "$extra_acl" | tr '\n' ' ')"
  acl_gone=0
  if [ -z "$(printf '%s' "$extra_acl" | tr -d '[:space:]')" ]; then acl_gone=1; fi
  if [ "$cur_meta" = "400 root:root" ] && [ "$acl_gone" -eq 1 ]; then
    log "$WINDOW_KEY_FILE 已存在：0400 root:root、无扩展 ACL，保留不动"
  else
    warn "$WINDOW_KEY_FILE 元数据是 '$cur_meta'，扩展 ACL: '${extra_acl:-无}'（期望 '400 root:root' 且没有扩展 ACE）"
    if [ "$acl_gone" -ne 1 ]; then
      warn "  存在扩展 ACL（命名用户/命名组/mask），本脚本不自动删除（可能是有意授权的）。请人工复核："
      warn "    getfacl -p -- $WINDOW_KEY_FILE"
      warn "  在扩展 ACL 清掉之前，0400 并不能保证只有 root 能读这个文件。"
    fi
    run chown root:root "$WINDOW_KEY_FILE"
    run chmod 0400 "$WINDOW_KEY_FILE"
    if [ "$DRY_RUN" -eq 0 ]; then
      new_meta="$(stat -c '%a %U:%G' -- "$WINDOW_KEY_FILE")"
      [ "$new_meta" = "400 root:root" ] \
        || die "修正后 $WINDOW_KEY_FILE 的元数据仍是 '$new_meta'（期望 '400 root:root'）——可能有 ACL 覆盖或文件系统不支持"
      new_acl="$(acl_extended "$WINDOW_KEY_FILE")" \
        || die "getfacl 读不到 $WINDOW_KEY_FILE 的 ACL（原因见上一行），无法证明 ACL 已清干净"
      [ -z "$(printf '%s' "$new_acl" | tr -d '[:space:]')" ] \
        || die "修正后 $WINDOW_KEY_FILE 仍有扩展 ACL：$(printf '%s' "$new_acl" | tr '\n' ' ')。0400 不足以证明只有 root 可读，请人工处理"
      log "元数据已修正并回读确认：$new_meta（无扩展 ACL）"
    fi
  fi
else
  if [ -n "${WINDOW_LEGACY_KEY:-}" ]; then
    WINDOW_KEY="$WINDOW_LEGACY_KEY"
    log "复用旧 $WINDOW_ENV 里的密钥（不重新生成，Windows 侧那份 key 继续有效）"
  else
    WINDOW_KEY="$(openssl rand -hex 16)"
    WINDOW_KEY_NEW=1
  fi
  write_new_file "$WINDOW_KEY_FILE" "$WINDOW_KEY
" "窗口密钥文件"
  run chmod 0400 "$WINDOW_KEY_FILE"
  run chown root:root "$WINDOW_KEY_FILE"
  if [ "$DRY_RUN" -eq 0 ]; then
    readback="$(cat -- "$WINDOW_KEY_FILE" 2>/dev/null || true)"
    [ "$readback" = "$WINDOW_KEY" ] || die "刚写入的 $WINDOW_KEY_FILE 内容与内存中的不一致（写盘异常）"
    new_meta="$(stat -c '%a %U:%G' -- "$WINDOW_KEY_FILE")"
    [ "$new_meta" = "400 root:root" ] \
      || die "新生成的 $WINDOW_KEY_FILE 元数据是 '$new_meta'（期望 '400 root:root'）"
    new_acl="$(acl_extended "$WINDOW_KEY_FILE")" \
      || die "getfacl 读不到 $WINDOW_KEY_FILE 的 ACL（原因见上一行），无法证明 ACL 已清干净"
    [ -z "$(printf '%s' "$new_acl" | tr -d '[:space:]')" ] \
      || die "新生成的 $WINDOW_KEY_FILE 带扩展 ACL：$(printf '%s' "$new_acl" | tr '\n' ' ')。父目录的默认 ACL 可能被继承了，请人工处理"
    log "已写入窗口密钥文件，回读确认：32 位十六进制、元数据 $new_meta、无扩展 ACL"
  fi
fi

# 旧文件里是同一把密钥，迁移完仍以 0640 可读：降权，别留个旁路。
if [ -e "$WINDOW_ENV" ] && [ "$DRY_RUN" -eq 0 ]; then
  run chown root:root "$WINDOW_ENV"
  run chmod 0600 "$WINDOW_ENV"
  warn "旧文件 $WINDOW_ENV 仍在（已降权为 0600 root:root）。确认服务按新方式正常启动后，可人工删除"
fi

# ============================================================ 第 8 步 ===
log "第 8 步 / 共 8 步：安装 check-storage.sh 与 systemd 单元"
run install -d -m 0755 -o root -g root "$LIB_DIR"
# 预检已确认过；这里再查一次：中间隔着建用户、整树复制、依赖安装
[ -f "$CHK_SRC" ] || die "check-storage.sh 在预检之后消失了: $CHK_SRC"
# R15：新版本先过语法检查，再保护已有版本（有变化就先备份，不直接盖掉）。
bash -n "$CHK_SRC" || die "$CHK_SRC 语法检查未通过（bash -n），拒绝安装到 $LIB_DIR"
CHK_DST="$LIB_DIR/check-storage.sh"
if [ -f "$CHK_DST" ] && ! cmp -s "$CHK_SRC" "$CHK_DST"; then
  chk_bak="$CHK_DST.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  run cp -p "$CHK_DST" "$chk_bak"
  warn "已备份旧的 check-storage.sh 到 $chk_bak（确认无问题后可自行删除）"
fi
run install -m 0755 -o root -g root "$CHK_SRC" "$CHK_DST"

if [ "$DRY_RUN" -eq 0 ]; then
  log "预检：以 $SERVICE_USER 身份执行 check-storage.sh"
  if ! runuser -u "$SERVICE_USER" -- env \
        CORTICO_HOME="$HOME_EXPECT" \
        CORTICO_EXTENSIONS_DIR="$EXT_EXPECT" \
        COMPANION_DATA_ROOT="$DATA_N" \
        COMPANION_MOUNTPOINT="$MOUNT_N" \
        "$LIB_DIR/check-storage.sh"; then
    die "预检未通过（见上面 [storage] 输出）。此时程序与配置已就位，服务单元尚未安装" 2
  fi
fi

[ -f "$UNIT_SRC" ] || die "companion.service 在预检之后消失了: $UNIT_SRC"

# S08：路径里的 & \ | 先转义，否则会被 sed 当成替换串的特殊语法。
unit_rendered="$(sed -e "s|@MOUNTPOINT@|$(sed_repl "$MOUNT_N")|g" \
                      -e "s|@DATA_ROOT@|$(sed_repl "$DATA_N")|g" "$UNIT_SRC")"

# R06：先写到临时文件，让 systemd 自己的解析器验一遍；通过之后才允许落到正式位置。
#
# 文件名必须以 .service 结尾：systemd-analyze verify 按单元文件路径解析，
# 没有合法单元后缀时它会把参数当成「单元名」，根本不去读文件内容。
#
# 用 mktemp 创建，而不是 `set -C` + 用 $$ 拼出的固定文件名：
#   - mktemp 用 O_EXCL 原子创建，永远不会复用或覆盖已经存在的文件；
#   - 创建失败时不需要也不允许做任何 rm —— 那种情况下文件本来就不存在，
#     删只会误伤别人已经放在那儿的文件（这正是上一版 `set -C` + 无条件 rm 的缺陷）；
#   - 生成的文件权限按 0600 处理，unit 内容（含数据路径与服务用户名）不对外可读；
#   - 名字里的 XXXXXXXX 是随机的，两个并发实例不会撞名。
# `--suffix=.service` 是 GNU coreutils mktemp 的老选项（Debian 13 的 coreutils 9.x
# 支持；8.x 起就有），语义是把后缀追加在模板末尾的 X 串之后，最终文件名仍以 .service 结尾。
if [ "$DRY_RUN" -eq 0 ]; then
  unit_tmp="$(mktemp --suffix=.service "$ETC_DIR/.companion-service-verify.XXXXXXXX" 2>/dev/null)" \
    || { VERIFY_TMP=""; VERIFY_TMP_INO=""; \
         die "无法在 $ETC_DIR 下创建临时 unit 文件（目录不存在或不可写）。本次没有创建、也没有删除任何已有文件"; }
  if [ -z "$unit_tmp" ] || [ -L "$unit_tmp" ] || [ ! -f "$unit_tmp" ]; then
    VERIFY_TMP=""; VERIFY_TMP_INO=""
    die "mktemp 返回的路径不是普通文件（'$unit_tmp'，可能是符号链接或目录）。本次没有删除任何已有文件"
  fi
  # 只有走到这里，才确认「这个文件是本次执行创建的」；之后所有清理都以它为前提。
  VERIFY_TMP="$unit_tmp"
  VERIFY_TMP_INO="$(stat -c %i -- "$unit_tmp" 2>/dev/null || true)"
  if [ -z "$VERIFY_TMP_INO" ]; then
    VERIFY_TMP=""; VERIFY_TMP_INO=""
    die "无法读取临时 unit 文件 $unit_tmp 的 inode：不能保证只清理本次创建的文件，拒绝继续"
  fi
  # mktemp 通常已经是 0600；这里显式再设一次，不依赖 umask 或文件系统的默认权限。
  chmod 0600 -- "$unit_tmp" 2>/dev/null || true

  if ! printf '%s\n' "$unit_rendered" > "$unit_tmp"; then
    verify_tmp_drop "写入失败"
    die "无法写入临时 unit 文件 $unit_tmp（写入阶段失败）"
  fi
  if ! verify_unit_file "$unit_tmp" "生成的 systemd 单元"; then
    verify_tmp_drop "验证失败"
    die "$VERIFY_ERROR"
  fi
  verify_tmp_drop "验证通过"
  log "生成的 systemd 单元通过 systemd-analyze verify（临时文件已删除）"
else
  log "[dry-run] 跳过 systemd-analyze verify（未生成真实文件，结果未验证）"
fi

if [ -f "$UNIT_TARGET" ]; then
  warn "$UNIT_TARGET 已存在，未覆盖。新版本写到 $UNIT_NEW，请自行 diff 后决定是否替换"
  # write_new_file：符号链接/已存在/非普通文件一律拒绝，创建走 O_EXCL，
  # 因此既不会覆盖上一轮留下的 .new，也不会顺着链接写到别处（IN-16）
  write_new_file "$UNIT_NEW" "$unit_rendered" "服务单元新版本"
  run chmod 0644 "$UNIT_NEW"
  run chown root:root "$UNIT_NEW"
  UNIT_INSTALLED=0
else
  write_new_file "$UNIT_TARGET" "$unit_rendered" "服务单元"
  run chmod 0644 "$UNIT_TARGET"
  run chown root:root "$UNIT_TARGET"
  UNIT_INSTALLED=1
fi

if [ "$UNIT_INSTALLED" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  systemctl daemon-reload
fi

# ---------------------------------------------------------------- 收尾 ---
# 哨兵放到最后：只有前面全部成功才留下「这块盘已被初始化」的标记
#
# 写入前再查一次类型（IN-15）：预检（第 1 步）到这一步之间隔了很多分钟和多次写操作，
# 路径可能被换掉。set -C（noclobber）只防「覆盖已有文件」，不防「路径变成符号链接后写穿」。
if [ -L "$SENTINEL" ] || { [ -e "$SENTINEL" ] && [ ! -f "$SENTINEL" ]; }; then
  die "哨兵路径 $SENTINEL 在写入前变成了符号链接或非普通文件（预检之后被替换？），拒绝写入"
fi
if [ ! -f "$SENTINEL" ]; then
  warn "数据盘哨兵缺失，将创建 $SENTINEL（只是初始化标记，不是磁盘身份证明）"
  if [ "$DRY_RUN" -eq 0 ]; then
    ( set -C; printf 'companion-data %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(hostname -f 2>/dev/null || hostname)" ) > "$SENTINEL" \
      || die "无法创建哨兵 $SENTINEL（noclobber 拒绝覆盖，或路径被替换）"
    chmod 0644 "$SENTINEL"
    log "已创建哨兵: $SENTINEL"
  else
    printf '[dry-run][计划] 创建哨兵 %s\n' "$SENTINEL"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run 结束，未做任何改动（上面的 [计划] 步骤都未执行）"
  exit 0
fi

# ---- 安装记录（M05/M06/M07）----------------------------------------------
# 只记事实，不记任何密钥。重复安装时覆盖（原子替换），不追加。
if [ "$DRY_RUN" -eq 0 ]; then
  # 只认顶层 "version": "x.y.z"；用 sed 而不是按引号切字段——切字段容易把 name 当成 version
pkg_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/package.json" 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$pkg_ver" ] || pkg_ver="unknown"
  pnpm_ver="$("$PNPM_BIN" --version 2>/dev/null || echo unknown)"
  if [ "$UNIT_INSTALLED" -eq 1 ]; then unit_state="installed"; else unit_state="kept-existing-wrote-.new"; fi
  if [ -d "$WORLD_PKG" ] && patched_cred "$WORLD_SRC"; then
    patch_state="applied"
  elif [ "${APPLY_PATCH:-0}" -eq 1 ]; then
    patch_state="requested-but-missing"
  else
    patch_state="not-applied"
  fi
  record_tmp="$ETC_DIR/.install-record.$$"
  ( set -C; printf '%s\n' \
      "installer_version=$INSTALLER_VERSION" \
      "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "os=${OS_ID:-unknown} ${OS_VER:-unknown}" \
      "node=$node_ver" \
      "pnpm=$pnpm_ver" \
      "source=$SRC" \
      "app_version=${pkg_ver:-unknown}" \
      "lock_sha256=${LOCK_SHA:-unknown}" \
      "patch=$patch_state" \
      "unit=$unit_state" \
      > "$record_tmp" ) || die "无法写安装记录 $record_tmp"
  chmod 0644 "$record_tmp"
  chown root:root "$record_tmp"
  mv -f "$record_tmp" "$ETC_DIR/install-record.txt"
  log "安装记录已写入 $ETC_DIR/install-record.txt"
fi

cat <<EOF

================ 安装完成，尚未启动 ================

程序目录     : $APP_TARGET
数据根       : $DATA_N
CORTICO_HOME : $HOME_EXPECT
扩展目录     : $EXT_EXPECT
挂载点       : $MOUNT_N
环境变量     : $COMPANION_ENV   （0644 root:root）
窗口密钥     : $WINDOW_KEY_FILE   （0400 root:root，systemd LoadCredential 提供）
服务单元     : $UNIT_TARGET

数据目录属主权限（服务用户必须可写）：
  $(stat -c '%U:%G %a' -- "$HOME_EXPECT")  $HOME_EXPECT
  $(stat -c '%U:%G %a' -- "$EXT_EXPECT")  $EXT_EXPECT

升级提示：本次是**合并覆盖**，源里已不存在的旧文件仍留在 $APP_TARGET，脚本不会删。

下一步（按顺序手工执行）：

 1. 确认数据盘哨兵（缺失时已创建；换盘或重建文件系统后需要重做）：
      sudo /usr/local/lib/companion/check-storage.sh --init-sentinel

 2. 再跑一次预检，确认全部通过：
      sudo -u $SERVICE_USER /usr/local/lib/companion/check-storage.sh

 3. 启用并启动：
      sudo systemctl enable --now companion
      systemctl status companion --no-pager
      journalctl -u companion -f

 4. 把窗口密钥拷到 Windows（人工，不走网络）：
      sudo cat $WINDOW_KEY_FILE
    → Windows: %LOCALAPPDATA%\\Coopanion\\pet-window.key（单行，无换行）

 5. Windows 侧先建 SSH 隧道，再运行 start-pet.cmd

关于 OMV 共享文件夹权限（不要用 777）：
  OMV 建出来的共享文件夹默认是 root:users 0775。$SERVICE_USER 不在 users 组里，
  默认写不进去，所以本脚本要么在权限闸门处停下，要么用 --fix-perms 改成：
      chown $SERVICE_USER:$SERVICE_USER <home> <extensions> && chmod 0750 <home> <extensions>
  （--fix-perms 只改这两个顶层目录；要连历史文件一起改属主才用 --fix-perms-recursive --yes）
  如果还想让 users 组能读，用 2775 root:users 并把 $SERVICE_USER 加进 users 组。
  另外：home/ 与 extensions/ 不建议再挂成 SMB 共享——OMV 的 ACL 递归会改属主。

注意：
 - 本脚本没有格式化任何磁盘、没有改 /etc/fstab、没有动 OMV 配置。
 - 若 $APP_TARGET 归 root 所有导致 tsx 启动报权限错误，
   执行：sudo chown -R root:$SERVICE_USER $APP_TARGET && sudo chmod -R g+w $APP_TARGET
EOF

# S02：只有在**本次新生成**时才把密钥打印这一次。
# 沿用已有密钥时一个字都不输出 —— 重复安装不该把老密钥再打进终端/日志。
if [ "${WINDOW_KEY_NEW:-0}" -eq 1 ]; then
  printf '\n窗口密钥（本次新生成，只显示这一次，请立即抄走）：\n  %s\n' "$WINDOW_KEY"
else
  printf '\n窗口密钥：已存在，本次未输出（避免把旧密钥写进日志）。需要时人工查看：\n  sudo cat %s\n' "$WINDOW_KEY_FILE"
fi

exit 0
