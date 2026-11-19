#!/usr/bin/env bash
# 第六轮 check-storage.sh 的桩环境测试（只在测试目录里用，不进交付）
set -u
# 让 ln -s 真的创建符号链接（MSYS 默认会退化成复制），否则符号链接相关用例无意义。
# 注意：MSYS 这个变量必须在进程启动时就存在于环境里，脚本内 export 不生效，
# 必须写成「命令前缀 MSYS=... ln」的形式传给 ln 进程本身。
mklink() { MSYS=winsymlinks:nativestrict ln -s "$@"; }
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BIN="$HERE/bin"
SUT="$HERE/../check-storage.sh"
BASE="$HERE/work"
pass=0; failc=0; skipped=0

note() { printf '\n=== %s ===\n' "$*"; }
chk() {
  if [ "$1" = "$3" ]; then pass=$((pass+1)); printf 'PASS %s（exit %s）\n' "$2" "$3"
  else failc=$((failc+1)); printf 'FAIL %s（期望 exit %s，实际 exit %s）\n' "$2" "$1" "$3"; fi
}

setup() {
  rm -rf "$BASE"; mkdir -p "$BASE/mnt/companion/home" "$BASE/mnt/companion/extensions"
  : > "$BASE/mnt/companion/.companion-volume-id"
  DEV_MOUNT=100; DEV_DATA=100; DEV_ROOT=1
  FM_TARGET="$BASE/mnt"; FM_OPTIONS='rw,relatime,errors=remount-ro'; FM_FAIL=0; FM_EMPTY=0
  MP_OK=1; SS_FAKE_OUT=""; SS_RC=0
  HOME_ENV="$BASE/mnt/companion/home"; EXT_ENV="$BASE/mnt/companion/extensions"
  ROOT_ENV="$BASE/mnt/companion"; MP_ENV="$BASE/mnt"; EXTRA=()
}

# run <期望码> <描述>
run() {
  local want="$1" name="$2" out rc
  local envs=(
    "PATH=$BIN:/usr/bin:/bin"
    "HOME=$HOME"
    "DEVMAP=$BASE/mnt=$DEV_MOUNT;$BASE/mnt/companion=$DEV_DATA;/=$DEV_ROOT"
    "FM_TARGET=$FM_TARGET" "FM_OPTIONS=$FM_OPTIONS" "FM_FAIL=$FM_FAIL" "FM_EMPTY=$FM_EMPTY"
    "MP_OK=$MP_OK" "SS_FAKE_OUT=$SS_FAKE_OUT" "SS_RC=$SS_RC"
    "COMPANION_SERVICE_USER=companion"
  )
  [ -n "$HOME_ENV" ] && envs+=("CORTICO_HOME=$HOME_ENV")
  [ -n "$EXT_ENV" ] && envs+=("CORTICO_EXTENSIONS_DIR=$EXT_ENV")
  [ -n "$ROOT_ENV" ] && envs+=("COMPANION_DATA_ROOT=$ROOT_ENV")
  [ -n "$MP_ENV" ] && envs+=("COMPANION_MOUNTPOINT=$MP_ENV")
  out="$(env -i "${envs[@]}" bash "$SUT" "${EXTRA[@]}" 2>&1)"; rc=$?
  chk "$want" "$name" "$rc"
  if [ "$want" != "$rc" ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
  LAST_OUT="$out"
}

note "S1 正常可写挂载，选项含 errors=remount-ro（不能误判只读）"; setup; run 0 "S1 正常"
note "S2 真只读挂载（独立 ro 选项）"; setup; FM_OPTIONS='rw,relatime,ro'; run 78 "S2 只读拒绝"
note "S3 rw 选项放行"; setup; FM_OPTIONS='rw,noatime'; run 0 "S3 rw 放行"
note "S4 findmnt 失败必须失败关闭"; setup; FM_FAIL=1; run 78 "S4 findmnt 失败"
note "S5 findmnt 空结果必须失败关闭"; setup; FM_EMPTY=1; run 78 "S5 findmnt 空"
note "S6 数据根与挂载点不同设备"; setup; DEV_DATA=101; run 78 "S6 设备不一致"
note "S7 数据根与 / 同设备（盘未挂）"; setup; DEV_DATA=1; run 78 "S7 未挂载"
note "S8 未设置 COMPANION_MOUNTPOINT"; setup; MP_ENV=""; run 78 "S8 缺挂载点拒绝"
note "S9 CORTICO_HOME 等于数据根"; setup; HOME_ENV="$BASE/mnt/companion"; run 78 "S9 home==root 拒绝"
note "S10 home 是逃逸符号链接"; setup
mkdir -p "$BASE/outside"; rm -rf "$BASE/mnt/companion/home2"; mklink "$BASE/outside" "$BASE/mnt/companion/home2"
HOME_N2="$BASE/mnt/companion/home2"; HOME_ENV="$HOME_N2"
if [ -L "$HOME_N2" ]; then run 78 "S10 逃逸拒绝"
else skipped=$((skipped+1)); printf 'SKIP S10 本机无法创建符号链接\n'; fi
note "S11 哨兵是符号链接"; setup
rm -f "$BASE/mnt/companion/.companion-volume-id"; mklink "$BASE/mnt/companion/home" "$BASE/mnt/companion/.companion-volume-id"
[ -L "$BASE/mnt/companion/.companion-volume-id" ] || { skipped=$((skipped+1)); printf 'SKIP S11 本机无法创建符号链接\n'; }
[ -L "$BASE/mnt/companion/.companion-volume-id" ] && run 78 "S11 哨兵符号链接拒绝"
note "S12 哨兵是目录"; setup; rm -f "$BASE/mnt/companion/.companion-volume-id"; mkdir "$BASE/mnt/companion/.companion-volume-id"
run 78 "S12 哨兵目录拒绝"
note "S13 未挂载点（mountpoint 返回非挂载）"; setup; MP_OK=0; run 78 "S13 非挂载点拒绝"
note "S14 端口占用"; setup; printf 'LISTEN 0 4096 0.0.0.0:7799 0.0.0.0:*\n' > "$HERE/ss.out"; SS_FAKE_OUT="$HERE/ss.out"
run 78 "S14 端口占用拒绝"
note "S15 --init-sentinel 创建哨兵"; setup; rm -f "$BASE/mnt/companion/.companion-volume-id"; EXTRA=(--init-sentinel)
run 0 "S15 初始化哨兵"
[ -f "$BASE/mnt/companion/.companion-volume-id" ] && { pass=$((pass+1)); printf 'PASS 哨兵已创建\n'; } || { failc=$((failc+1)); printf 'FAIL 哨兵未创建\n'; }

note "S16 ss 执行失败必须失败关闭（不能把「查不到」当「端口空闲」）"; setup; SS_RC=1
run 78 "S16 ss 失败拒绝"
printf '%s' "$LAST_OUT" | grep -qF 'ss -H -ltn 执行失败' && { pass=$((pass+1)); printf 'PASS S16 报错文案点明 ss 执行失败\n'; } || { failc=$((failc+1)); printf 'FAIL S16 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }
note "S17 ss 成功但没有任何监听记录（真空机器）→ 按空闲放行"; setup; SS_RC=0; SS_FAKE_OUT=""
run 0 "S17 空输出放行"
note "S18 ss 有输出但解析不出端口（格式异常）必须失败关闭"; setup
printf 'State Recv-Q\n' > "$HERE/ss-odd.out"; SS_FAKE_OUT="$HERE/ss-odd.out"; SS_RC=0
run 78 "S18 解析不出端口拒绝"

note "S19 COMPANION_DATA_ROOT 是相对路径必须拒绝"; setup; ROOT_ENV="mnt/companion"
run 78 "S19 DATA_ROOT 相对路径拒绝"
printf '%s' "$LAST_OUT" | grep -qF 'COMPANION_DATA_ROOT 必须是绝对路径' && { pass=$((pass+1)); printf 'PASS S19 报错文案点明相对路径\n'; } || { failc=$((failc+1)); printf 'FAIL S19 报错文案不对\n'; }

note "S20 COMPANION_MOUNTPOINT 是相对路径必须拒绝"; setup; MP_ENV="mnt"
run 78 "S20 MOUNTPOINT 相对路径拒绝"
printf '%s' "$LAST_OUT" | grep -qF 'COMPANION_MOUNTPOINT 必须是绝对路径' && { pass=$((pass+1)); printf 'PASS S20 报错文案点明相对路径\n'; } || { failc=$((failc+1)); printf 'FAIL S20 报错文案不对\n'; }

note "S21 多条监听记录、其中两条落在区间内"; setup
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:7799 0.0.0.0:*\nLISTEN 0 4096 [::]:7801 [::]:*\n' > "$HERE/ss-multi.out"
SS_FAKE_OUT="$HERE/ss-multi.out"; SS_RC=0
run 78 "S21 区间内两个端口拒绝"
printf '%s' "$LAST_OUT" | grep -qF '7799' && printf '%s' "$LAST_OUT" | grep -qF '7801' && { pass=$((pass+1)); printf 'PASS S21 报错列出了两个占用端口\n'; } || { failc=$((failc+1)); printf 'FAIL S21 报错未列出全部占用端口\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

note "S22 记录字段不足必须失败关闭"; setup
printf 'LISTEN 0 4096\n' > "$HERE/ss-short.out"; SS_FAKE_OUT="$HERE/ss-short.out"; SS_RC=0
run 78 "S22 字段不足拒绝"
printf '%s' "$LAST_OUT" | grep -qF '字段不足' && { pass=$((pass+1)); printf 'PASS S22 报错点明字段不足\n'; } || { failc=$((failc+1)); printf 'FAIL S22 报错文案不对\n'; }

note "S23 端口不是纯十进制数字必须失败关闭"; setup
printf 'LISTEN 0 4096 0.0.0.0:abcd 0.0.0.0:*\n' > "$HERE/ss-badport.out"; SS_FAKE_OUT="$HERE/ss-badport.out"; SS_RC=0
run 78 "S23 非数字端口拒绝"

note "S24 IPv6 写法解析正确，落在区间内必须拒绝"; setup
printf 'LISTEN 0 0 [::]:7806 [::]:*\n' > "$HERE/ss-ipv6.out"; SS_FAKE_OUT="$HERE/ss-ipv6.out"; SS_RC=0
run 78 "S24 IPv6 区间端口拒绝"

note "S25 多条记录全部解析成功且都不在区间内 → 放行"; setup
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 0 [::]:9000 [::]:*\n' > "$HERE/ss-ok.out"
SS_FAKE_OUT="$HERE/ss-ok.out"; SS_RC=0
run 0 "S25 区间外放行"

note "S26 端口 0 越界必须失败关闭"; setup
printf 'LISTEN 0 4096 127.0.0.1:0 0.0.0.0:*\n' > "$HERE/ss-port0.out"; SS_FAKE_OUT="$HERE/ss-port0.out"; SS_RC=0
run 78 "S26 端口 0 拒绝"

# --- 环境配置文件：重复键 -------------------------------------------------
# ENV_FILE 固定为 /etc/companion/companion.env；这里临时造一份，跑完立刻删掉。
ENV_D="/etc/companion"
if mkdir -p "$ENV_D" 2>/dev/null && [ -w "$ENV_D" ]; then
  note "S27 companion.env 里同一有效键出现两次必须拒绝"; setup
  printf 'CORTICO_HOME=/tmp/dup-a\nCORTICO_HOME=/tmp/dup-b\n' > "$ENV_D/companion.env"
  run 78 "S27 重复键拒绝"
  printf '%s' "$LAST_OUT" | grep -qF '重复出现' && { pass=$((pass+1)); printf 'PASS S27 报错点明键重复\n'; } || { failc=$((failc+1)); printf 'FAIL S27 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

  note "S28 companion.env 键不重复时不影响外部环境优先"; setup
  printf 'CORTICO_HOME=/nonexistent/would-fail-if-applied\nCORTICO_EXTENSIONS_DIR=/nonexistent/also-fails\nCOMPANION_SERVICE_USER=companion\n' > "$ENV_D/companion.env"
  run 0 "S28 外部值优先，文件里的坏值不生效"
  rm -f "$ENV_D/companion.env"
  rmdir "$ENV_D" 2>/dev/null || true
else
  skipped=$((skipped+2)); printf 'SKIP S27/S28 无法写入 %s\n' "$ENV_D"
fi

note "S29 缺少第 5 列（远端地址）必须失败关闭"; setup
printf 'LISTEN 0 4096 0.0.0.0:7800\n' > "$HERE/ss-norest.out"; SS_FAKE_OUT="$HERE/ss-norest.out"; SS_RC=0
run 78 "S29 缺远端地址拒绝"
printf '%s' "$LAST_OUT" | grep -qF '缺少远端地址' && { pass=$((pass+1)); printf 'PASS S29 报错点明缺第 5 列\n'; } || { failc=$((failc+1)); printf 'FAIL S29 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

note "S30 Recv-Q 不是纯十进制数字必须失败关闭"; setup
printf 'LISTEN x 4096 0.0.0.0:22 0.0.0.0:*\n' > "$HERE/ss-badrq.out"; SS_FAKE_OUT="$HERE/ss-badrq.out"; SS_RC=0
run 78 "S30 Recv-Q 非数字拒绝"
printf '%s' "$LAST_OUT" | grep -qF 'Recv-Q 不是纯十进制数字' && { pass=$((pass+1)); printf 'PASS S30 报错点明 Recv-Q\n'; } || { failc=$((failc+1)); printf 'FAIL S30 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

note "S31 Send-Q 不是纯十进制数字必须失败关闭"; setup
printf 'LISTEN 0 4x96 0.0.0.0:22 0.0.0.0:*\n' > "$HERE/ss-badsq.out"; SS_FAKE_OUT="$HERE/ss-badsq.out"; SS_RC=0
run 78 "S31 Send-Q 非数字拒绝"
printf '%s' "$LAST_OUT" | grep -qF 'Send-Q 不是纯十进制数字' && { pass=$((pass+1)); printf 'PASS S31 报错点明 Send-Q\n'; } || { failc=$((failc+1)); printf 'FAIL S31 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

note "S32 非空记录（全空白）但解析不出状态字段必须失败关闭"; setup
printf '   \t  \n' > "$HERE/ss-nostate.out"; SS_FAKE_OUT="$HERE/ss-nostate.out"; SS_RC=0
run 78 "S32 无状态字段拒绝"
printf '%s' "$LAST_OUT" | grep -qF '解析不出状态字段' && { pass=$((pass+1)); printf 'PASS S32 报错点明无状态字段\n'; } || { failc=$((failc+1)); printf 'FAIL S32 报错文案不对\n'; printf '%s\n' "$LAST_OUT" | sed 's/^/    | /'; }

note "S33 两列合法监听记录（IPv4+IPv6）仍然放行，确认没误伤正常输出"; setup
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 [::]:22 [::]:*\n' > "$HERE/ss-ok2.out"
SS_FAKE_OUT="$HERE/ss-ok2.out"; SS_RC=0
run 0 "S33 正常多记录放行"

printf '\n总计: PASS=%s FAIL=%s SKIP=%s\n' "$pass" "$failc" "$skipped"
[ "$failc" -eq 0 ]
