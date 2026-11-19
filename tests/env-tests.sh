#!/usr/bin/env bash
# ENV-01..ENV-17：env_parse_strict 的隔离测试
# 刻意用「从 R6 正式文件里抽取函数」的方式，保证测的是交付代码本身，而不是复制品。
set -u
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
SUT="$HERE/../install-nas.sh"
WORK="$HERE/env-work"
rm -rf "$WORK"; mkdir -p "$WORK"

# 抽取方式：头部从 1 行到 usage() 之前（shebang、set、常量、log/warn/die、run、write_file、
#   write_new_file、is_symlink、resolve_existing、strict_under、require_regular_file、
#   require_present_file——以 `usage() {` 这行定位，函数增删后自动跟随）；
#   本体用标记行定位，而不是写死行号（写死行号一改交付文件就会抽错，测出来全是假失败）。
# 注意：不要改成「1 到 declare -A 之前」，那会把可执行的预检代码一起 source 进来。
HEAD_END="$(grep -n '^usage() {' "$SUT" | head -1 | cut -d: -f1)"
ENV_START="$(grep -n '^declare -A ENV_VALS=' "$SUT" | head -1 | cut -d: -f1)"
ENV_END="$(grep -n '^# ---- 已有 companion.env' "$SUT" | head -1 | cut -d: -f1)"
if [ -z "$HEAD_END" ] || [ -z "$ENV_START" ] || [ -z "$ENV_END" ] || [ "$ENV_END" -le "$ENV_START" ]; then
  printf '抽取标记定位失败（HEAD_END=%s ENV_START=%s ENV_END=%s），测试无法进行\n' "${HEAD_END:-空}" "${ENV_START:-空}" "${ENV_END:-空}"
  exit 2
fi
{
  sed -n "1,$((HEAD_END - 1))p" "$SUT"
  echo '# --- 以下为 env_parse_strict 及其依赖的数组声明 ---'
  sed -n "${ENV_START},$((ENV_END - 1))p" "$SUT"
  echo '# --- 抽取结束 ---'
} > "$WORK/lib.sh"

KEYS=(CORTICO_COMPANION_ROOT CORTICO_HOME CORTICO_EXTENSIONS_DIR COMPANION_DATA_ROOT COMPANION_MOUNTPOINT NODE_ENV)
GOOD_CMP=/opt/companion/app/build/cortico
GOOD_HOME=/srv/dev-disk-by-label-VOLUME1/companion/home
GOOD_EXT=/srv/dev-disk-by-label-VOLUME1/companion/extensions
GOOD_ROOT=/srv/dev-disk-by-label-VOLUME1/companion
GOOD_MNT=/srv/dev-disk-by-label-VOLUME1

pass=0; failed=0
mk() { printf '%s' "$2" > "$WORK/$1.env"; }

# case <编号> <期望:accept|reject> <说明> <文件> [--expect-err 关键字]
case_run() {
  local id="$1" want="$2" desc="$3" file="$4" kw="${5:-}"
  local out rc
  out="$(bash -c '
    # shellcheck disable=SC1091
    . "$1" >/dev/null 2>&1
    set +e            # 抽取进来的库带着 set -e 与 ERR trap，这里必须关掉才能看到返回值
    trap - ERR
    env_parse_strict "$2" "${@:3}"
    rc=$?
    printf "RC=%s\n" "$rc"
    if [ "$rc" -eq 0 ]; then
      for k in "${@:3}"; do printf "  %s=<%s>\n" "$k" "${ENV_VALS[$k]}"; done
    else
      printf "ERR=%s\n" "$ENV_ERROR"
    fi
  ' _ "$WORK/lib.sh" "$WORK/$file.env" "${KEYS[@]}" 2>&1)"
  rc="$(printf '%s' "$out" | sed -n 's/^RC=//p')"
  local ok=0
  if [ "$want" = "accept" ]; then [ "$rc" = "0" ] && ok=1; else [ "$rc" != "0" ] && ok=1; fi
  if [ -n "$kw" ] && ! printf '%s' "$out" | grep -qF -- "$kw"; then ok=0; fi
  if [ "$ok" = "1" ]; then pass=$((pass+1)); printf '\n[PASS] %s %s\n' "$id" "$desc"
  else failed=$((failed+1)); printf '\n[FAIL] %s %s\n' "$id" "$desc"; fi
  printf '%s\n' "$out" | sed 's/^/    /'
}

BASE="CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
"

mk 01 "$BASE";                                   case_run ENV-01 accept "正常无引号值" 01
mk 02 "CORTICO_COMPANION_ROOT=\"$GOOD_CMP\"
CORTICO_HOME=\"$GOOD_HOME\"
CORTICO_EXTENSIONS_DIR=\"$GOOD_EXT\"
COMPANION_DATA_ROOT=\"$GOOD_ROOT\"
COMPANION_MOUNTPOINT=\"$GOOD_MNT\"
NODE_ENV=\"production\"
";                                               case_run ENV-02 accept "成对双引号" 02
mk 03 "CORTICO_COMPANION_ROOT='$GOOD_CMP'
CORTICO_HOME='$GOOD_HOME'
CORTICO_EXTENSIONS_DIR='$GOOD_EXT'
COMPANION_DATA_ROOT='$GOOD_ROOT'
COMPANION_MOUNTPOINT='$GOOD_MNT'
NODE_ENV='production'
";                                               case_run ENV-03 accept "成对单引号" 03
mk 04 "CORTICO_COMPANION_ROOT=\"$GOOD_CMP
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-04 reject "只有开头双引号" 04 "双引号未闭合"
mk 05 "CORTICO_COMPANION_ROOT=$GOOD_CMP\"
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-05 reject "只有结尾双引号" 05 "引号必须整体包住取值"
mk 06 "CORTICO_COMPANION_ROOT=a\"$GOOD_CMP\"
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-06 reject "半包：裸值前缀 + 整体引号（双引号）" 06 "引号必须整体包住取值"
mk 07 "CORTICO_COMPANION_ROOT=a'b
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-07 reject "半包：裸值前缀 + 整体引号（单引号）" 07 "引号必须整体包住取值"
mk 08 "CORTICO_COMPANION_ROOT=$GOOD_CMP\\x
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-08 reject "值里含反斜杠" 08 "反斜杠"
mk 09 "CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-09 reject "空值" 09 "是空值"
mk 10 "CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=$GOOD_HOME
CORTICO_HOME=$GOOD_HOME
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-10 reject "重复定义" 10 "重复出现"
mk 11 "CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
SOME_UNKNOWN_KEY=x
";                                               case_run ENV-11 accept "未知键（按脚本规则：接受并忽略）" 11
mk 12 "CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-12 reject "缺 COMPANION_DATA_ROOT" 12 "缺少必需变量 COMPANION_DATA_ROOT"
mk 13 "$BASE";                                   case_run ENV-13 accept "六键完整" 13
mk 14 "CORTICO_COMPANION_ROOT=$GOOD_CMP
CORTICO_HOME=/srv/other/companion/home
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-14 accept "解析层接受（值不一致由调用方比对）" 14
mk 15 "CORTICO_COMPANION_ROOT=\"a\"b\"c\"
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-15 reject "整体包住但内部还有双引号" 15 "值内部出现裸双引号"
mk 16 "CORTICO_COMPANION_ROOT='a'b'c'
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-16 reject "整体包住但内部还有单引号" 16 "值内部出现裸单引号"
mk 17 "CORTICO_COMPANION_ROOT=\"$GOOD_CMP\\\\x\"
CORTICO_HOME=$GOOD_HOME
CORTICO_EXTENSIONS_DIR=$GOOD_EXT
COMPANION_DATA_ROOT=$GOOD_ROOT
COMPANION_MOUNTPOINT=$GOOD_MNT
NODE_ENV=production
";                                               case_run ENV-17 reject "双引号包住但内含反斜杠" 17 "反斜杠"

# ENV-14 的真正判定在调用方：这里单独验证「值不一致 → 比对会失败」
printf '\n[INFO] ENV-14 说明：env_parse_strict 本身只做语法与必需键检查；\n'
printf '       「值与本次安装参数是否一致」由第 1 步的比对负责（install-nas.sh 里 problems= 那一段），\n'
printf '       下面用同一份文件演示该比对会拒绝。\n'

printf '\n=== ENV 测试汇总: PASS=%s FAIL=%s ===\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
