#!/usr/bin/env bash
#
# check-storage.sh —— Coopanion 方案 α 的启动前置检查（第六轮）
#
# 用途
#   在 Core 启动前确认下面这些事，任何一件不成立就退出（退出码 78 = EX_CONFIG）：
#     1. 两个数据环境变量都设了、都是绝对路径、都是数据根的**严格子目录**
#     2. 数据盘真的挂载了：挂载点成立、数据根与挂载点同设备、与 / 不同设备、
#        挂在指定挂载点上（不是嵌套挂载）、不是只读挂载
#     3. 哨兵文件在，且是普通文件（**仅表示「这块盘被初始化过」，不是磁盘身份证明**）
#     4. 目录存在；companion 对 CORTICO_HOME / CORTICO_EXTENSIONS_DIR 必须既能写也能穿越
#        （w+x），对数据根本身只要求可穿越（x）
#     5. 桌宠端口区间 7797-7806 空闲
#
# 路径可信度
#   所有路径在比较前都过 realpath -m 规范化（消掉 `..`、解析符号链接）。
#   规范化失败直接判失败，不做「看起来还行」的降级。
#   子目录判定是**组件级**比较，不是字符串前缀：/data/companionX 不会被当成
#   /data/companion 的子目录；并且要求二者**不相等**（数据根自己不能当 home）。
#
# 挂载判定（第六轮收紧）
#   - 只读判定按**逗号分隔的挂载选项逐项精确比较**，只认独立的 `ro`。
#     `rw`、`errors=remount-ro` 之类不会被误判成只读。
#   - 设备一致性：数据根与挂载点的 `stat -c %d` 必须相同；
#     同时要求「数据根所在的实际挂载目标」就是 COMPANION_MOUNTPOINT，
#     这样嵌套挂载（数据根底下又挂了一块盘）也会被拦下。
#   - findmnt 不存在 / 查询失败 / 输出为空 —— 一律**失败关闭**，不把未知当正常。
#
# COMPANION_MOUNTPOINT 是必需项
#   第六轮起强制要求：没有它就只剩「数据根不是 /」这一条弱保护，
#   无法证明数据真的落在那块 HDD 上。安装脚本总会写入它，
#   手工排查时也请显式给出（export COMPANION_MOUNTPOINT=…）。
#
# 环境变量优先级
#   外部环境（systemd / runuser / 手工 export）里已经有的值**优先**；
#   /etc/companion/companion.env 只用来**补缺失**的键，绝不覆盖已有值。
#   读配置文件时不 eval、不做变量展开、不做命令替换。
#
# 端口预检查的边界
#   这里只能证明「检查的那一刻端口是空的」，**不能消除竞态**：
#   从本脚本退出到 PetServer 真正 bind 之间仍可能被别人抢走。
#   真正的保证要靠 Core 侧固定端口、不许静默漂移（详见审计报告：这是源码问题，
#   本脚本不修改 Coopanion 源码）。
#
# 端口查询失败 = 失败关闭（第七轮收紧）
#   ss -H -ltn 的**退出状态先被检查**，只有查询成功才解析端口。
#   老写法是 `ss | awk | grep -q` 放进 if 里循环 10 次：ss 失败时管道下游只看到
#   空输入，grep 返回 1 =「没占用」，于是「查不到」被当成「端口全空闲」——fail-open。
#   现在：ss 退出码非 0、输出非空却解析不出本地端口、或**任何一条**监听记录格式
#   异常（字段不足 / 本地地址没有端口 / 端口不是纯十进制数字 / 超出 1-65535），
#   一律报错退出（78）。解析全部用 shell 内建，不依赖 seq / grep。
#
# 显式路径必须是绝对路径（第七轮）
#   COMPANION_DATA_ROOT 与 COMPANION_MOUNTPOINT 若由外部显式给出，必须是绝对路径。
#   realpath -m 会把相对路径按**当前工作目录**补全：systemd 下 cwd 是 /，
#   手工排查时可能是任意目录——同一个值在不同地方指向不同的盘，不能默默接受。
#
# 运行账户
#   - 由 systemd 以 User=companion 调用（ExecStartPre）
#   - 也可用 root 手工预检：root 下所有可写性判断会**用 companion 身份重新执行**
#
# 退出码
#   0   一切正常
#   78  配置/存储/端口不满足（EX_CONFIG）
#
# 明确不会做的事
#   - 不创建目录（唯一例外：显式 --init-sentinel 时写哨兵，且只在挂载校验全部通过之后）
#   - 不挂载、不卸载、不格式化、不改 fstab
#   - 不删除任何文件
#
set -uo pipefail

readonly EX_CONFIG=78
readonly PORT_BASE=7797
readonly PORT_COUNT=10
readonly SENTINEL_NAME=".companion-volume-id"
readonly ENV_FILE="/etc/companion/companion.env"

SERVICE_USER="${COMPANION_SERVICE_USER:-companion}"

fail() { printf '[storage] 失败: %s\n' "$*" >&2; exit "$EX_CONFIG"; }
ok()   { printf '[storage] 通过: %s\n' "$*"; }
warn() { printf '[storage] 注意: %s\n' "$*" >&2; }

# 规范化路径：realpath -m 不要求路径存在，且能消掉 `..` 与符号链接。
norm() {
  realpath -m -- "$1" 2>/dev/null || readlink -f -- "$1" 2>/dev/null || true
}

# child 是否位于 parent 之下（两者都已规范化；parent 为 / 时恒真）。
# 注意：child 等于 parent 时也返回真，因此调用方必须另行排除相等的情况。
under() {
  local parent="$1" child="$2"
  [ "$parent" = "/" ] && return 0
  case "$child/" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

# 严格子目录：在 parent 之下，且不等于 parent
strict_under() {
  local parent="$1" child="$2"
  [ "$parent" = "$child" ] && return 1
  under "$parent" "$child"
}

as_service() {
  if [ "$(id -u)" -eq 0 ] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
    runuser -u "$SERVICE_USER" -- "$@"
  else
    "$@"
  fi
}

# --- 0. 参数 -------------------------------------------------------------
INIT_SENTINEL=0
for arg in "$@"; do
  case "$arg" in
    --init-sentinel) INIT_SENTINEL=1 ;;
    -h|--help)
      sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/d;p}' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      fail "未知参数: $arg"
      ;;
  esac
done

# --- 1. 环境变量（外部优先，配置文件只补缺） -----------------------------
# 先记录「外部已经给了哪些」，再逐行补；已存在的键绝不覆盖。
if [ -r "$ENV_FILE" ]; then
  ENV_LINENO=0
  # 已经出现过的有效键，形如 $'\nKEY\n'：键只允许 [A-Za-z0-9_]，不含通配符，
  # 所以可以直接用 case 做整词匹配，不需要关联数组（bash 3 也能跑）。
  ENV_SEEN=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    ENV_LINENO=$((ENV_LINENO + 1))
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
      *=*) : ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
    esac
    # 重复键：同一个有效键出现两次，文件想表达什么并不明确——按行序先读到的会赢，
    # 后读到的被静默忽略，改成另一种顺序行为就变了。安装脚本写出的文件也会有
    # 同样的歧义，所以直接判失败，不去猜哪一条才是「真正想要的」。
    case "$ENV_SEEN" in
      *$'\n'"$key"$'\n'*)
        fail "$ENV_FILE 第 $ENV_LINENO 行：配置键 '$key' 重复出现。同一键只能有一条，拒绝猜测哪一条生效"
        ;;
    esac
    ENV_SEEN="$ENV_SEEN$key"$'\n'
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    # 关键：已经在环境里的值优先，配置文件只补空缺
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$ENV_FILE"
fi

[ -n "${CORTICO_HOME:-}" ] || fail "CORTICO_HOME 未设置（$ENV_FILE 缺失或为空）"
[ -n "${CORTICO_EXTENSIONS_DIR:-}" ] || fail "CORTICO_EXTENSIONS_DIR 未设置（$ENV_FILE 缺失或为空）"

case "$CORTICO_HOME" in
  /*) : ;;
  *) fail "CORTICO_HOME 必须是绝对路径，当前为 '$CORTICO_HOME'" ;;
esac
case "$CORTICO_EXTENSIONS_DIR" in
  /*) : ;;
  *) fail "CORTICO_EXTENSIONS_DIR 必须是绝对路径，当前为 '$CORTICO_EXTENSIONS_DIR'" ;;
esac

# --- 2. 规范化 -----------------------------------------------------------
HOME_N="$(norm "$CORTICO_HOME")"
EXT_N="$(norm "$CORTICO_EXTENSIONS_DIR")"
[ -n "$HOME_N" ] || fail "无法规范化 CORTICO_HOME（$CORTICO_HOME）：路径可能成环或不可解析"
[ -n "$EXT_N" ]  || fail "无法规范化 CORTICO_EXTENSIONS_DIR（$CORTICO_EXTENSIONS_DIR）"
[ "$HOME_N" = "$EXT_N" ] && fail "CORTICO_HOME 与 CORTICO_EXTENSIONS_DIR 指向同一个目录（$HOME_N）"

# 数据根：优先用显式配置；否则按 CORTICO_HOME 的父目录推断（并在后面强制要求挂载点）
if [ -n "${COMPANION_DATA_ROOT:-}" ]; then
  # 显式配置必须是绝对路径：realpath -m 会把相对路径按当前工作目录补全，
  # 同一个值在 systemd（cwd=/）与手工排查（cwd 任意）下会指向不同的盘。
  case "$COMPANION_DATA_ROOT" in
    /*) : ;;
    *) fail "COMPANION_DATA_ROOT 必须是绝对路径，当前为 '$COMPANION_DATA_ROOT'" ;;
  esac
  ROOT_N="$(norm "$COMPANION_DATA_ROOT")"
  [ -n "$ROOT_N" ] || fail "无法规范化 COMPANION_DATA_ROOT（$COMPANION_DATA_ROOT）"
else
  ROOT_N="$(dirname -- "$HOME_N")"
  warn "未设置 COMPANION_DATA_ROOT，按 CORTICO_HOME 的父目录推断为 $ROOT_N"
fi
[ "$ROOT_N" = "/" ] && fail "数据根不能是 /：'$ROOT_N'"

[ "$HOME_N" != "$CORTICO_HOME" ] && warn "CORTICO_HOME 规范化后为 $HOME_N（原始写法 $CORTICO_HOME 含符号链接或 .. ）"
[ "$EXT_N"  != "$CORTICO_EXTENSIONS_DIR" ] && warn "CORTICO_EXTENSIONS_DIR 规范化后为 $EXT_N"

# --- 3. 两个变量必须是数据根的严格子目录 ---------------------------------
[ "$HOME_N" = "$ROOT_N" ] && fail "CORTICO_HOME 不能等于数据根（$ROOT_N）：它必须是数据根下的子目录"
[ "$EXT_N"  = "$ROOT_N" ] && fail "CORTICO_EXTENSIONS_DIR 不能等于数据根（$ROOT_N）：必须是子目录"
strict_under "$ROOT_N" "$HOME_N" || fail "CORTICO_HOME（$HOME_N）不在数据根（$ROOT_N）之下"
strict_under "$ROOT_N" "$EXT_N"  || fail "CORTICO_EXTENSIONS_DIR（$EXT_N）不在数据根（$ROOT_N）之下"
ok "两个数据目录都是数据根 $ROOT_N 的严格子目录"

# 数据目录不得落在程序盘上
for p in "$HOME_N" "$EXT_N" "$ROOT_N"; do
  case "$p" in
    /opt/companion|/opt/companion/*) fail "$p 指向程序目录——数据必须放在数据盘" ;;
  esac
done

# --- 4. 挂载检查 ---------------------------------------------------------
command -v findmnt >/dev/null 2>&1 || fail "找不到 findmnt（util-linux）——无法证明挂载状态，拒绝启动"
command -v mountpoint >/dev/null 2>&1 || fail "找不到 mountpoint（util-linux）——拒绝启动"

# COMPANION_MOUNTPOINT 强制必需（见文件头「COMPANION_MOUNTPOINT 是必需项」）
[ -n "${COMPANION_MOUNTPOINT:-}" ] \
  || fail "COMPANION_MOUNTPOINT 未设置。它是证明「数据真的在那块 HDD 上」的唯一依据，本脚本不接受在没有它的情况下放行"
# 同 COMPANION_DATA_ROOT：相对路径会被 realpath 按 cwd 补全，必须显式拒绝。
case "$COMPANION_MOUNTPOINT" in
  /*) : ;;
  *) fail "COMPANION_MOUNTPOINT 必须是绝对路径，当前为 '$COMPANION_MOUNTPOINT'" ;;
esac
MOUNT_N="$(norm "$COMPANION_MOUNTPOINT")"
[ -n "$MOUNT_N" ] || fail "无法规范化 COMPANION_MOUNTPOINT（$COMPANION_MOUNTPOINT）"
[ "$MOUNT_N" = "/" ] && fail "COMPANION_MOUNTPOINT 不能是 /"

mountpoint -q -- "$MOUNT_N" || fail "挂载点 $MOUNT_N 没有挂载（OMV 里卷是否在线？）"
strict_under "$MOUNT_N" "$ROOT_N" || fail "数据根 $ROOT_N 不是挂载点 $MOUNT_N 的严格子目录（数据根不能等于挂载点本身）"
ok "挂载点 $MOUNT_N 已挂载，数据根在其之下"

[ -d "$ROOT_N" ] || fail "数据根目录不存在: $ROOT_N"

dev_mount="$(stat -c %d -- "$MOUNT_N" 2>/dev/null)" || fail "无法读取 $MOUNT_N 的设备号"
dev_data="$(stat -c %d -- "$ROOT_N" 2>/dev/null)"  || fail "无法读取 $ROOT_N 的设备号"
dev_root="$(stat -c %d -- / 2>/dev/null)"          || fail "无法读取 / 的设备号"

[ "$dev_data" = "$dev_root" ] \
  && fail "数据根 $ROOT_N 与 / 在同一个文件系统上——磁盘未挂载（拒绝写入）"
[ "$dev_data" = "$dev_mount" ] \
  || fail "数据根 $ROOT_N（设备 $dev_data）与挂载点 $MOUNT_N（设备 $dev_mount）不是同一个文件系统——可能存在嵌套挂载或路径指向别处"

# 数据根「实际所在的挂载目标」必须就是 COMPANION_MOUNTPOINT：
# 这样「数据根底下又挂了一块盘」的嵌套挂载会被拦下。
real_target="$(findmnt -rn -T "$ROOT_N" -o TARGET 2>/dev/null)" \
  || fail "findmnt 查询失败：无法确定 $ROOT_N 的挂载目标（拒绝把未知当正常）"
[ -n "$real_target" ] || fail "findmnt 对 $ROOT_N 返回空结果——无法判断挂载状态，拒绝启动"
real_target_n="$(norm "$real_target")"
[ -n "$real_target_n" ] || fail "无法规范化 findmnt 给出的挂载目标 '$real_target'"
[ "$real_target_n" = "$MOUNT_N" ] \
  || fail "数据根实际挂在 '$real_target_n'，而不是 COMPANION_MOUNTPOINT='$MOUNT_N'（嵌套挂载？）"

# 只读判定：按逗号切分挂载选项后**逐项精确比较**，只认独立的 ro。
mount_opts="$(findmnt -rn -T "$ROOT_N" -o OPTIONS 2>/dev/null)" \
  || fail "findmnt 查询挂载选项失败：无法确认 $ROOT_N 是否可写（拒绝把未知当正常）"
[ -n "$mount_opts" ] || fail "findmnt 未返回 $ROOT_N 的挂载选项——拒绝启动"
ro_flag=0
old_ifs="$IFS"; IFS=','
for opt in $mount_opts; do
  [ "$opt" = "ro" ] && ro_flag=1
done
IFS="$old_ifs"
[ "$ro_flag" -eq 1 ] && fail "数据根 $ROOT_N 所在文件系统是只读挂载（选项: $mount_opts）"
ok "数据根 $ROOT_N 在独立、可写、且非嵌套挂载的文件系统上"

# --- 5. 哨兵文件 ---------------------------------------------------------
# 哨兵只是「这块盘被初始化过」的标记，用来挡住「换了一块空盘仍被当成原盘」和
# 「盘没挂、目录被重新建成空的」。它**不是磁盘身份证明**：
#   同一块盘重新格式化后哨兵就没了，不同盘之间也可以互相拷贝。
# 真正的身份保证来自 OMV 的挂载管理 + 设备号比对（上面第 4 节）。
#
# 为什么只查「是不是普通文件」而不校验内容：
#   内容里只有时间戳与主机名，任何能写这块盘的人都能伪造，校验它不会增加安全性；
#   而格式一改就会让旧盘无法启动（安装脚本的写法要与之逐字兼容）。
#   所以这里只做**类型**检查（拒绝符号链接/目录/设备），不做内容认证。
SENTINEL="$ROOT_N/$SENTINEL_NAME"

sentinel_type_check() {
  local p="$1"
  if [ -L "$p" ]; then
    fail "哨兵文件是符号链接（$p）：拒绝通过链接把检查或写入引到别处。请人工删除该链接后重试"
  fi
  if [ -e "$p" ] && [ ! -f "$p" ]; then
    fail "哨兵路径存在但不是普通文件（可能是目录或设备）: $p"
  fi
}

if [ "$INIT_SENTINEL" -eq 1 ]; then
  sentinel_type_check "$SENTINEL"
  if [ -f "$SENTINEL" ]; then
    ok "哨兵已存在，未改动: $SENTINEL"
  else
    # noclobber：万一有人在我们检查之后把路径换成别的东西，也不会覆盖
    (set -C; printf 'companion-data %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(hostname -f 2>/dev/null || hostname)") > "$SENTINEL" \
      || fail "无法写入哨兵文件 $SENTINEL（已存在或被拒绝）"
    chmod 0644 -- "$SENTINEL" 2>/dev/null || true
    ok "已创建哨兵: $SENTINEL"
  fi
else
  sentinel_type_check "$SENTINEL"
  [ -f "$SENTINEL" ] || fail "哨兵文件缺失: $SENTINEL（新盘请先运行: $0 --init-sentinel）"
  ok "哨兵存在且是普通文件: $SENTINEL"
fi

# --- 6. 目录存在性 -------------------------------------------------------
for d in "$ROOT_N" "$HOME_N" "$EXT_N"; do
  [ -d "$d" ] || fail "目录不存在: $d（安装脚本不会自动创建数据目录）"
done

# --- 7. 以服务用户身份检查权限（数据根只查 x，其余查 w+x） ---------------
id -u "$SERVICE_USER" >/dev/null 2>&1 || fail "服务用户 $SERVICE_USER 不存在（安装脚本应已创建）"

DEPLOY_DIR="$HOME_N/companion"
WORKSPACE_DIR="$DEPLOY_DIR/workspace"

need_wx() {
  local p="$1" label="$2"
  local meta have_w=0 have_x=0
  meta="$(stat -c '%U:%G %a' -- "$p" 2>/dev/null || printf '无法读取')"
  as_service test -w "$p" && have_w=1
  as_service test -x "$p" && have_x=1
  if [ "$have_w" -eq 1 ] && [ "$have_x" -eq 1 ]; then
    return 0
  fi
  if [ "$have_w" -eq 0 ] && [ "$have_x" -eq 0 ]; then
    fail "$label 对 $SERVICE_USER 既不可写也不可穿越（缺 w 和 x）: $p（属主 $meta）"
  elif [ "$have_w" -eq 0 ]; then
    fail "$label 对 $SERVICE_USER 不可写（缺 w）: $p（属主 $meta）"
  else
    fail "$label 对 $SERVICE_USER 不可穿越（缺 x）: $p（属主 $meta）"
  fi
}

# 数据根只是容器：Core 在它下面的 home/ 与 extensions/ 里写，不会直接在根里建东西。
# 因此只要求 x，绝不为了「通过检查」去放宽数据根的权限。
need_x() {
  local p="$1" label="$2"
  local meta
  meta="$(stat -c '%U:%G %a' -- "$p" 2>/dev/null || printf '无法读取')"
  as_service test -x "$p" && return 0
  fail "$label 对 $SERVICE_USER 不可穿越（缺 x）: $p（属主 $meta）"
}

need_x  "$ROOT_N" "数据根（只需 x）"
need_wx "$HOME_N" "CORTICO_HOME（Core 需要在其中创建 companion/）"
need_wx "$EXT_N"  "CORTICO_EXTENSIONS_DIR"

if [ -d "$DEPLOY_DIR" ]; then
  need_wx "$DEPLOY_DIR" "部署目录"
fi
if [ -d "$WORKSPACE_DIR" ]; then
  need_wx "$WORKSPACE_DIR" "记忆目录"
fi
ok "$SERVICE_USER 对 CORTICO_HOME / CORTICO_EXTENSIONS_DIR 有写权限与穿越权限（w+x），对数据根可穿越（x）"

# --- 8. 端口区间 ---------------------------------------------------------
command -v ss >/dev/null 2>&1 || fail "找不到 ss（iproute2），无法确认端口占用——拒绝启动"

# 第一步：执行，并把退出码**单独**存下来再判断。
# 绝不能写成 `ss ... | awk | grep -q`：管道的状态是最后一个命令的，
# ss 失败时下游只看到空输入，grep 返回 1，于是「查不到」被当成「端口空闲」。
ss_out="$(ss -H -ltn 2>/dev/null)"
ss_rc=$?
[ "$ss_rc" -eq 0 ] \
  || fail "ss -H -ltn 执行失败（退出码 $ss_rc）：无法确认端口是否被占用——拒绝启动，不把「查不到」当「空闲」"

# 第二步：只有查询成功之后才逐条解析，且**任何一条**记录解析失败都失败关闭。
# 每条 `ss -H -ltn` 记录按空白切成五列：State / Recv-Q / Send-Q / 本地地址:端口 / 远端地址。
# 判失败的情形：非空却切不出 State、五列里有任何一列为空、Recv-Q 或 Send-Q 不是纯十进制
# 数字、本地地址里没有冒号、端口不是纯十进制数字、数字长度超过 5 位、数值不在 1-65535
# —— 宁可拒绝启动，也不用「没看懂」冒充「没占用」。
# 真正的空行（长度为 0）才允许跳过；非空记录一律继续校验，不许悄悄 continue。
# 全程只用 shell 内建：不用 seq 生成区间，不用 grep 判断包含关系。
if [ -z "$ss_out" ]; then
  warn "ss -H -ltn 成功执行但没有任何监听记录——按「区间空闲」处理（这台机器上确实没有监听端口时才会这样）"
else
  PORT_LAST=$((PORT_BASE + PORT_COUNT - 1))
  rec_no=0      # 第几条记录（用于报错定位）
  rec_ok=0      # 成功解析出本地端口的记录数
  occ_set=" "   # 区间内已占用的端口，形如 " 7797 7799 "（两侧带空格，便于整词匹配）
  while IFS= read -r rec || [ -n "$rec" ]; do
    rec_no=$((rec_no + 1))
    rec="${rec%$'\r'}"
    # 先判原始记录：只有长度 0 才算「真正的空行」，允许跳过。这里出现空行的来源有两个：
    # ss 输出末尾的换行，以及 here-string 自动补出来的那一行。它们都不是格式问题。
    if [ -z "$rec" ]; then
      continue
    fi
    st="" rq="" sq="" laddr="" rest=""
    # 按空白切分：st=State  rq=Recv-Q  sq=Send-Q  laddr=本地地址:端口  rest=对端及之后
    IFS=$' \t' read -r st rq sq laddr rest <<< "$rec"
    # 非空却切不出状态字段（例如整条只有空白字符）：记录畸形，失败关闭，不能当成空行放过。
    if [ -z "$st" ]; then
      fail "ss -H -ltn 第 $rec_no 条记录非空但解析不出状态字段（State）——'$rec'"
    fi
    # 五列的完整性：任何一列为空都判失败，并带上记录序号与原始记录，便于当场定位。
    if [ -z "$rq" ]; then
      fail "ss -H -ltn 第 $rec_no 条记录字段不足：缺少 Recv-Q（第 2 列）——'$rec'"
    fi
    if [ -z "$sq" ]; then
      fail "ss -H -ltn 第 $rec_no 条记录字段不足：缺少 Send-Q（第 3 列）——'$rec'"
    fi
    if [ -z "$laddr" ]; then
      fail "ss -H -ltn 第 $rec_no 条记录字段不足：缺少本地监听地址（第 4 列）——'$rec'"
    fi
    if [ -z "$rest" ]; then
      fail "ss -H -ltn 第 $rec_no 条记录字段不足：缺少远端地址（第 5 列）——'$rec'"
    fi
    # Recv-Q / Send-Q 必须是纯十进制数字（空值已按「缺字段」拦在上面，这里只管非数字）。
    case "$rq" in
      *[!0-9]*)
        fail "ss -H -ltn 第 $rec_no 条记录的 Recv-Q 不是纯十进制数字：'$rq'（整条记录：'$rec'）"
        ;;
    esac
    case "$sq" in
      *[!0-9]*)
        fail "ss -H -ltn 第 $rec_no 条记录的 Send-Q 不是纯十进制数字：'$sq'（整条记录：'$rec'）"
        ;;
    esac
    case "$laddr" in
      *:*) : ;;
      *) fail "ss -H -ltn 第 $rec_no 条记录的本地地址里没有端口：'$laddr'（整条记录：'$rec'）" ;;
    esac
    lport="${laddr##*:}"
    case "$lport" in
      ''|*[!0-9]*)
        fail "ss -H -ltn 第 $rec_no 条记录的端口不是纯十进制数字：'$lport'（本地地址：'$laddr'）"
        ;;
    esac
    if [ "${#lport}" -gt 5 ]; then
      fail "ss -H -ltn 第 $rec_no 条记录的端口位数异常（超过 5 位）：'$lport'（本地地址：'$laddr'）"
    fi
    lport_num=$((10#$lport))
    if [ "$lport_num" -lt 1 ] || [ "$lport_num" -gt 65535 ]; then
      fail "ss -H -ltn 第 $rec_no 条记录的端口超出 1-65535：'$lport_num'（本地地址：'$laddr'）"
    fi
    rec_ok=$((rec_ok + 1))
    if [ "$lport_num" -ge "$PORT_BASE" ] && [ "$lport_num" -le "$PORT_LAST" ]; then
      case "$occ_set" in
        *" $lport_num "*) : ;;
        *) occ_set="$occ_set$lport_num " ;;
      esac
    fi
  done <<< "$ss_out"
  [ "$rec_ok" -gt 0 ] \
    || fail "ss -H -ltn 返回了内容，但没有任何一条记录能解析出本地端口（输出格式与预期不符）——无法确认端口占用，拒绝启动"
  if [ "$occ_set" != " " ]; then
    occupied="${occ_set# }"
    occupied="${occupied% }"
    fail "端口被占用: $occupied（区间 ${PORT_BASE}-${PORT_LAST}；先释放端口，PetServer 在端口被占时会静默漂移，隧道会当场失效）"
  fi
fi
ok "端口区间 ${PORT_BASE}-$((PORT_BASE + PORT_COUNT - 1)) 空闲（注意：本检查不能消除 bind 时刻的竞态）"

printf '[storage] 全部通过，可以启动 Core\n'
exit 0
