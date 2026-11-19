#!/usr/bin/env bash
# 第六轮 install-nas.sh 的桩环境测试（只在测试目录里用，不进交付）
#
# 做法：install-nas.sh 里写死的绝对路径（/opt、/etc、/usr/local/lib、/var/lib）
# 在副本里 sed 到本测试的沙箱根 $WT 下，脚本因此整个活在自己的目录树里，
# 绝不碰真实的 /opt、/etc。所有用例都在「第 1 步预检」阶段被拒绝，
# 一个写操作都不会发生（第一次写操作是 useradd，在第 459 行之后）。
#
# 用法：./run.sh          （在 Git Bash 下跑，需要 MSYS=winsymlinks:nativestrict 的符号链接）
set -u
mklink() { MSYS=winsymlinks:nativestrict ln -s "$@"; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
SUT_SRC="$HERE/../../install-nas.sh"
WT="$HERE/work"
BIN="$HERE/bin"
pass=0; failc=0; skipped=0

note() { printf '\n=== %s ===\n' "$*"; }
ok()   { pass=$((pass+1)); printf 'PASS %s\n' "$*"; }
bad()  { failc=$((failc+1)); printf 'FAIL %s\n' "$*"; }

# ---------------------------------------------------------------- 桩 ---
make_stubs() {
  rm -rf "$BIN"; mkdir -p "$BIN"

  cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-u" ] && [ $# -eq 1 ]; then printf '%s\n' "${ID_UID:-0}"; exit 0; fi
if [ "${1:-}" = "-u" ] && [ -n "${2:-}" ]; then
  case "$2" in companion) printf '1001\n'; exit 0 ;; *) exit 1 ;; esac
fi
exec /usr/bin/id "$@"
EOF

  # 设备号：DEVMAP 形如 "路径=设备号;路径=设备号"
  cat > "$BIN/stat" <<'EOF'
#!/usr/bin/env bash
set -u
args=("$@"); fmt=""
for ((i=0;i<${#args[@]};i++)); do
  [ "${args[$i]}" = "-c" ] && { fmt="${args[$((i+1))]}"; break; }
done
target="${args[${#args[@]}-1]}"
if [ "$fmt" = "%d" ] && [ -n "${DEVMAP:-}" ]; then
  IFS=';' read -r -a pairs <<< "$DEVMAP"
  best=""; bestlen=-1
  for kv in "${pairs[@]}"; do
    [ -z "$kv" ] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    case "$target/" in
      "$k"/*) if [ "${#k}" -gt "$bestlen" ]; then best="$v"; bestlen="${#k}"; fi ;;
    esac
  done
  [ -n "$best" ] && { printf '%s\n' "$best"; exit 0; }
fi
exec /usr/bin/stat "${args[@]}"
EOF

  cat > "$BIN/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${MP_OK:-1}" = "1" ] && exit 0
exit 1
EOF

  cat > "$BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  # 只有本机没有、且预检阶段确实会用到的命令才做桩。
  # 注意：sed / cut / ls / date / grep / awk / cp 这些真命令必须留给真实现，
  # 否则 Node 版本解析（sed+cut）会被空桩吃掉，所有用例都会卡在同一步。
  #
  # 会「改系统」的那几条（rsync/install/useradd/patch/systemctl）额外记一行到
  # $STUB_LOG：新增用例靠「日志是否为空」证明前置失败时确实一个写操作都没发生。
  for c in rsync install useradd runuser findmnt systemctl patch; do
    case "$c" in
      rsync|install|useradd|systemctl|patch)
        cat > "$BIN/$c" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_LOG:-}" ]; then printf '%s\n' "$c \$*" >> "\$STUB_LOG"; fi
exit 0
EOF
        ;;
      *)
        printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$c"
        ;;
    esac
  done
  chmod +x "$BIN"/*
}

# 写操作是否发生过：STUB_LOG 里只要有任何一行就说明越过了预检
no_write() { # no_write <用例名>
  if [ -s "$WT/stub.log" ]; then
    failc=$((failc+1))
    printf 'FAIL %s（前置失败后仍调用了写操作）\n' "$1"
    sed 's/^/    | /' "$WT/stub.log"
  else
    pass=$((pass+1))
    printf 'PASS %s（无任何写操作：STUB_LOG 为空）\n' "$1"
  fi
}

# ---------------------------------------------------------------- 沙箱 ---
# 生成 sed 过的脚本副本，并把 /opt /etc /usr/local/lib /var/lib 改到 $WT 下
build_tree() {
  rm -rf "$WT"; mkdir -p "$WT/opt/companion" "$WT/etc/systemd/system" \
      "$WT/usr/local/lib" "$WT/var/lib" "$WT/mnt/companion/home" "$WT/mnt/companion/extensions" \
      "$WT/src/core" "$WT/src/build/cortico/src/core" "$WT/data" "$WT/data2"
  printf '{}' > "$WT/src/package.json"
  : > "$WT/src/core/boot.ts"
  : > "$WT/mnt/companion/.companion-volume-id"
  printf 'ID=debian\nVERSION_ID="13"\nVERSION_CODENAME=trixie\n' > "$WT/etc/os-release"

  sed -e "s|/opt/|$WT/opt/|g" \
      -e "s|/etc/|$WT/etc/|g" \
      -e "s|/usr/local/lib/|$WT/usr/local/lib/|g" \
      -e "s|/var/lib/|$WT/var/lib/|g" \
      "$SUT_SRC" > "$WT/install-under-test.sh"
  chmod +x "$WT/install-under-test.sh"
  cp "$HERE/../../check-storage.sh" "$WT/check-storage.sh" 2>/dev/null || true
  cp "$HERE/../../companion.service" "$WT/companion.service" 2>/dev/null || true
  cp "$HERE/../../plan-a/companion.service" "$WT/companion.service" 2>/dev/null || true
}

# 假 node：版本由 NODE_VER 控制
make_node() {
  rm -rf "$WT/opt/node22"; mkdir -p "$WT/opt/node22/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${NODE_VER:-v22.20.0}"\n' > "$WT/opt/node22/bin/node"
  chmod +x "$WT/opt/node22/bin/node"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WT/opt/node22/bin/npm"
  chmod +x "$WT/opt/node22/bin/npm"
}

# ---------------------------------------------------------------- 用例 ---
DEVMAP=""; MP_OK=1; ID_UID=0; NODE_VER=""; SRC="$WT/src"; MNT="$WT/mnt"
DROOT="$WT/mnt/companion"; EXTRA=(); NODE_PRESENT=1

reset_vars() {
  DEVMAP="$WT/mnt=100;$WT/mnt/companion=100;/=1"
  MP_OK=1; ID_UID=0; NODE_VER="v22.20.0"; NODE_PRESENT=1
  SRC="$WT/src"; MNT="$WT/mnt"; DROOT="$WT/mnt/companion"; EXTRA=()
}

# run <期望码> <描述> <日志里应当出现的子串>
run() {
  local want="$1" name="$2" needle="${3:-}" out rc
  [ "$NODE_PRESENT" -eq 1 ] && make_node || rm -rf "$WT/opt/node22"
  : > "$WT/stub.log"
  out="$(env -i \
      PATH="$BIN:/usr/bin:/bin" \
      HOME="$HOME" \
      DEVMAP="$DEVMAP" MP_OK="$MP_OK" ID_UID="$ID_UID" NODE_VER="$NODE_VER" \
      STUB_LOG="$WT/stub.log" \
      bash "$WT/install-under-test.sh" \
        --src "$SRC" --mountpoint "$MNT" --data-root "$DROOT" "${EXTRA[@]}" 2>&1)"
  rc=$?
  if [ "$rc" != "$want" ]; then
    bad "$name（期望 exit $want，实际 exit $rc）"; printf '%s\n' "$out" | sed 's/^/    | /'; return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    bad "$name（exit $rc 对，但输出里没有「$needle」）"; printf '%s\n' "$out" | sed 's/^/    | /'; return
  fi
  ok "$name（exit $rc）"
}

# ---------------------------------------------------------------- 开跑 ---
make_stubs
build_tree
note "I1 缺少 --src（参数阶段）"
reset_vars
out="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME" bash "$WT/install-under-test.sh" --mountpoint "$MNT" --data-root "$DROOT" 2>&1)"
[ $? -eq 1 ] && printf '%s' "$out" | grep -qF '缺少 --src' && ok "I1 缺 --src 拒绝（exit 1）" || { bad "I1 缺 --src"; printf '%s\n' "$out" | sed 's/^/    | /'; }

note "I2 未知参数"
reset_vars; EXTRA=(--bogus); run 1 "I2 未知参数拒绝" "未知参数: --bogus"

note "I3 --fix-perms-recursive 没带 --yes"
reset_vars; EXTRA=(--fix-perms-recursive); run 1 "I3 递归无确认拒绝" "必须同时加 --yes"

note "I4 非 root"
reset_vars; ID_UID=1000; run 1 "I4 非 root 拒绝" "需要 root 运行"

note "I5 缺必需命令（把 rsync 移走）"
reset_vars
mv "$BIN/rsync" "$BIN/rsync.off"
run 1 "I5 缺命令拒绝" "缺少必需命令"
mv "$BIN/rsync.off" "$BIN/rsync"

note "I6 Node 不存在"
reset_vars; NODE_PRESENT=0; run 2 "I6 无 Node 拒绝" "找不到"

note "I7 Node 版本过低"
reset_vars; NODE_VER="v20.11.0"; run 2 "I7 Node 20 拒绝" "Node 版本过低"

note "I8 源目录缺 core/boot.ts"
reset_vars; rm -f "$WT/src/core/boot.ts"; run 2 "I8 src 不完整拒绝" "core/boot.ts 不存在"
: > "$WT/src/core/boot.ts"

note "I9 挂载点未挂载"
reset_vars; MP_OK=0; run 2 "I9 未挂载拒绝" "未挂载"

note "I10 data-root 不是 mountpoint 的子目录（/data2 对 /data）"
reset_vars; MNT="$WT/data"; DROOT="$WT/data2"; run 2 "I10 非子目录拒绝" "严格子目录"

note "I11 data-root 等于 mountpoint"
reset_vars; DROOT="$WT/mnt"; run 2 "I11 相等拒绝" "不能等于 --mountpoint"

note "I12 mountpoint 与 / 同设备"
reset_vars; DEVMAP="$WT/mnt=1;$WT/mnt/companion=1;/=1"; run 2 "I12 同设备拒绝" "不是真正独立的挂载点"

note "I13 数据根与挂载点不同设备（嵌套挂载）"
reset_vars; DEVMAP="$WT/mnt=100;$WT/mnt/companion=101;/=1"; run 2 "I13 嵌套挂载拒绝" "不在同一个文件系统上"

note "I14 home 目录不存在（脚本不代建）"
reset_vars; rm -rf "$WT/mnt/companion/home"; run 2 "I14 缺 home 拒绝" "本脚本不会代建"
mkdir -p "$WT/mnt/companion/home"

note "I15 home 是逃逸符号链接"
reset_vars; rm -rf "$WT/mnt/companion/home"; mkdir -p "$WT/outside"; mklink "$WT/outside" "$WT/mnt/companion/home"
if [ -L "$WT/mnt/companion/home" ]; then
  run 2 "I15 逃逸拒绝" "符号链接逃逸"
else
  skipped=$((skipped+1)); printf 'SKIP I15 本机无法创建符号链接\n'
fi
rm -rf "$WT/mnt/companion/home"; mkdir -p "$WT/mnt/companion/home"

note "I16 home 与 extensions 指向同一个目录"
reset_vars; rm -rf "$WT/mnt/companion/extensions"; mklink "$WT/mnt/companion/home" "$WT/mnt/companion/extensions"
if [ -L "$WT/mnt/companion/extensions" ]; then
  run 2 "I16 同目录拒绝" "指向同一个目录"
else
  skipped=$((skipped+1)); printf 'SKIP I16 本机无法创建符号链接\n'
fi
rm -rf "$WT/mnt/companion/extensions"; mkdir -p "$WT/mnt/companion/extensions"

ENVF="$WT/etc/companion/companion.env"
ENV_OK='CORTICO_COMPANION_ROOT=/srv/companion
CORTICO_HOME=/srv/companion/home
CORTICO_EXTENSIONS_DIR=/srv/companion/extensions
COMPANION_DATA_ROOT=/srv/companion
COMPANION_MOUNTPOINT=/srv
NODE_ENV=production'

note "I17 companion.env 是符号链接"
reset_vars; mkdir -p "$WT/etc/companion"; printf '%s\n' "$ENV_OK" > "$WT/etc/companion/real.env"
mklink "$WT/etc/companion/real.env" "$ENVF"
if [ -L "$ENVF" ]; then
  run 2 "I17 符号链接拒绝" "companion.env 是符号链接"
else
  skipped=$((skipped+1)); printf 'SKIP I17 本机无法创建符号链接\n'
fi
rm -f "$ENVF"

note "I18 companion.env 重复键"
reset_vars; mkdir -p "$WT/etc/companion"; printf '%s\nNODE_ENV=production\n' "$ENV_OK" > "$ENVF"
run 2 "I18 重复键拒绝" "重复出现"
rm -f "$ENVF"

note "I19 companion.env 缺必需键"
reset_vars; printf 'CORTICO_COMPANION_ROOT=/srv/companion\nCORTICO_HOME=/srv/companion/home\n' > "$ENVF"
run 2 "I19 缺必需变量拒绝" "缺少必需变量"
rm -f "$ENVF"

note "I20 companion.env 值里有反斜杠"
reset_vars; printf '%s\n' "$ENV_OK" | sed 's|^NODE_ENV=.*|NODE_ENV=C:\\\\tmp|' > "$ENVF"
run 2 "I20 反斜杠拒绝" "反斜杠"
rm -f "$ENVF"

note "I21 companion.env 引号半包（a\"b\" 写法）"
reset_vars; printf '%s\n' "$ENV_OK" | sed 's|^NODE_ENV=.*|NODE_ENV=pro"duction|' > "$ENVF"
run 2 "I21 半包引号拒绝" "整体包住取值"
rm -f "$ENVF"

note "I23 companion.env 双引号未闭合"
reset_vars; printf '%s\n' "$ENV_OK" | sed 's|^NODE_ENV=.*|NODE_ENV="production|' > "$ENVF"
run 2 "I23 未闭合引号拒绝" "双引号未闭合"
rm -f "$ENVF"

note "I24 companion.env 值里带 export 前缀"
reset_vars; printf '%s\n' "$ENV_OK" | sed 's|^NODE_ENV=.*|export NODE_ENV=production|' > "$ENVF"
run 2 "I24 export 前缀拒绝" "变量名非法"
rm -f "$ENVF"

note "I25 已有 companion.env 与本次参数不一致"
reset_vars; printf '%s\n' "$ENV_OK" > "$ENVF"
run 2 "I25 配置不一致拒绝" "不一致"
rm -f "$ENVF"

note "I22 data-root 落在程序目录下"
reset_vars; MNT="$WT/opt/companion/mnt"; DROOT="$WT/opt/companion/mnt/companion"
mkdir -p "$DROOT/home" "$DROOT/extensions"
DEVMAP="$MNT=100;$DROOT=100;/=1"
run 2 "I22 程序目录拒绝" "不能是程序目录"
rm -rf "$WT/opt/companion/mnt"

# ================= 本轮（第七轮）定点修复新增用例 =================
# 覆盖两件事：
#   1) 只读预检必须全部跑到「首次写操作（useradd）」之前 —— 用 STUB_LOG 为空来证明
#   2) companion.service(.new) 与 APP_TARGET 的类型/冲突检查
SYSD="$WT/etc/systemd/system"
UNIT_T="$SYSD/companion.service"

note "I26 随附文件 check-storage.sh 缺失"
reset_vars; mv "$WT/check-storage.sh" "$WT/check-storage.sh.off" 2>/dev/null || :
run 2 "I26 缺 check-storage.sh 拒绝" "check-storage.sh 不存在"
no_write "I26 未发生任何写操作"
mv "$WT/check-storage.sh.off" "$WT/check-storage.sh" 2>/dev/null || :

note "I27 随附文件 companion.service 缺失"
reset_vars; mv "$WT/companion.service" "$WT/companion.service.off" 2>/dev/null || :
run 2 "I27 缺 companion.service 拒绝" "companion.service 不存在"
no_write "I27 未发生任何写操作"
mv "$WT/companion.service.off" "$WT/companion.service" 2>/dev/null || :

note "I28 随附文件 check-storage.sh 是符号链接"
reset_vars; mv "$WT/check-storage.sh" "$WT/chk-real.sh" 2>/dev/null || :
mklink "$WT/chk-real.sh" "$WT/check-storage.sh"
if [ -L "$WT/check-storage.sh" ]; then
  run 2 "I28 随附文件符号链接拒绝" "是符号链接"
  no_write "I28 未发生任何写操作"
else
  skipped=$((skipped+1)); printf 'SKIP I28 本机无法创建符号链接\n'
fi
rm -f "$WT/check-storage.sh"; mv "$WT/chk-real.sh" "$WT/check-storage.sh" 2>/dev/null || :

note "I29 --apply-patch 但补丁文件哪里都没有"
reset_vars; EXTRA=(--apply-patch); run 2 "I29 缺补丁拒绝" "都没有找到"
no_write "I29 未发生任何写操作"

note "I30 --apply-patch 且补丁在脚本同目录（预检应放行）"
reset_vars; cp "$HERE/../../0001-window-key-from-env.diff" "$WT/" 2>/dev/null || :
EXTRA=(--apply-patch --dry-run)
run 0 "I30 脚本同目录的补丁被接受" "补丁文件："
no_write "I30 dry-run 未发生任何写操作"
rm -f "$WT/0001-window-key-from-env.diff"

note "I31 APP_TARGET 是普通文件"
reset_vars; printf 'x' > "$WT/opt/companion/app"
run 2 "I31 APP_TARGET 普通文件拒绝" "存在但不是目录"
no_write "I31 未发生任何写操作"
rm -f "$WT/opt/companion/app"

note "I32 APP_TARGET 是符号链接"
reset_vars; mkdir -p "$WT/opt/companion/elsewhere"; mklink "$WT/opt/companion/elsewhere" "$WT/opt/companion/app"
if [ -L "$WT/opt/companion/app" ]; then
  run 2 "I32 APP_TARGET 符号链接拒绝" "是符号链接"
  no_write "I32 未发生任何写操作"
else
  skipped=$((skipped+1)); printf 'SKIP I32 本机无法创建符号链接\n'
fi
rm -rf "$WT/opt/companion/app" "$WT/opt/companion/elsewhere"

note "I33 APP_TARGET 是已存在的空目录（应放行）"
reset_vars; mkdir -p "$WT/opt/companion/app"; EXTRA=(--dry-run)
run 0 "I33 空目录 APP_TARGET 放行" "预检通过"
no_write "I33 dry-run 未发生任何写操作"

note "I34 单元目标 companion.service 是目录"
reset_vars; mkdir -p "$UNIT_T"
run 2 "I34 单元目标是目录拒绝" "存在但不是普通文件"
no_write "I34 未发生任何写操作"
rm -rf "$UNIT_T"

note "I35 单元目标 companion.service 是符号链接"
reset_vars; printf 'unit' > "$SYSD/real.unit"; mklink "$SYSD/real.unit" "$UNIT_T"
if [ -L "$UNIT_T" ]; then
  run 2 "I35 单元目标符号链接拒绝" "是符号链接"
  no_write "I35 未发生任何写操作"
else
  skipped=$((skipped+1)); printf 'SKIP I35 本机无法创建符号链接\n'
fi
rm -f "$UNIT_T" "$SYSD/real.unit"

note "I36 单元目标已存在且 .new 也已存在（不得覆盖用户已有的 .new）"
reset_vars; printf 'old-unit\n' > "$UNIT_T"; printf 'pending-new\n' > "$UNIT_T.new"
run 2 "I36 不覆盖已有的 .new" "不覆盖已有的 .new"
no_write "I36 未发生任何写操作"
[ "$(cat "$UNIT_T.new")" = "pending-new" ] && { pass=$((pass+1)); printf 'PASS I36 已有的 .new 未被改写\n'; } || { failc=$((failc+1)); printf 'FAIL I36 已有的 .new 被改写了\n'; }
rm -f "$UNIT_T" "$UNIT_T.new"

note "I37 单元目标的 .new 是符号链接"
reset_vars; printf 'old-unit\n' > "$UNIT_T"; printf 'target-elsewhere\n' > "$SYSD/elsewhere.new"
mklink "$SYSD/elsewhere.new" "$UNIT_T.new"
if [ -L "$UNIT_T.new" ]; then
  run 2 "I37 .new 符号链接拒绝" "是符号链接"
  no_write "I37 未发生任何写操作"
  [ "$(cat "$SYSD/elsewhere.new")" = "target-elsewhere" ] && { pass=$((pass+1)); printf 'PASS I37 链接指向的文件未被写穿\n'; } || { failc=$((failc+1)); printf 'FAIL I37 链接指向的文件被写穿了\n'; }
else
  skipped=$((skipped+1)); printf 'SKIP I37 本机无法创建符号链接\n'
fi
rm -f "$UNIT_T" "$UNIT_T.new" "$SYSD/elsewhere.new"

printf '\n总计: PASS=%s FAIL=%s SKIP=%s\n' "$pass" "$failc" "$skipped"
[ "$failc" -eq 0 ]
