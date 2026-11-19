#!/usr/bin/env bash
# 单元测：install-nas.sh 的 write_new_file()（第七轮问题二的核心机制）
# 从交付脚本里抽出 1..usage() 之前的定义区，直接调用被测函数，不碰系统路径。
set -u
HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SUT="$HERE/../install-nas.sh"
WT="$(mktemp -d)"
trap 'rm -rf "$WT"' EXIT

HEAD_END="$(grep -n '^usage() {' "$SUT" | head -1 | cut -d: -f1)"
[ -n "$HEAD_END" ] || { echo "抽取标记定位失败"; exit 2; }
sed -n "1,$((HEAD_END - 1))p" "$SUT" > "$WT/lib.sh"
bash -n "$WT/lib.sh" || { echo "抽取出来的定义区有语法错误"; exit 2; }
# shellcheck disable=SC1090
. "$WT/lib.sh"
# 被测脚本开了 set -e / ERR trap；单测里要自己收集每个用例的退出码，先关掉。
set +e
trap - ERR

pass=0; fail=0
chk() { # chk <期望码> <描述>
  local want="$1" desc="$2"
  if [ "$RC" = "$want" ]; then pass=$((pass+1)); printf 'PASS %s\n' "$desc"
  else fail=$((fail+1)); printf 'FAIL %s（期望 %s，实际 %s）\n' "$desc" "$want" "$RC"; fi
}

# W1 正常新建：内容与字节数完全一致
f="$WT/w1.txt"
( DRY_RUN=0; write_new_file "$f" "hello 世界" "测试文件" ) >/dev/null 2>&1
RC=$?
chk 0 "W1 新建成功"
if [ "$(cat "$f")" = "hello 世界" ] && [ "$(wc -c < "$f" | tr -d ' ')" = "12" ]; then
  pass=$((pass+1)); echo "PASS W1 内容与字节数正确（12 字节）"
else fail=$((fail+1)); echo "FAIL W1 内容或字节数不对"; fi

# W2 已存在：拒绝覆盖，原内容不变
f="$WT/w2.txt"; printf 'keep' > "$f"
( DRY_RUN=0; write_new_file "$f" "new" "测试文件" ) >/dev/null 2>&1
RC=$?
chk 2 "W2 已存在时拒绝（退出码 2）"
[ "$(cat "$f")" = "keep" ] && { pass=$((pass+1)); echo "PASS W2 原文件内容未被改动"; } || { fail=$((fail+1)); echo "FAIL W2 原文件被改了"; }

# W3 路径是符号链接：拒绝，链接目标不被写穿
t="$WT/target.txt"; printf 'target-elsewhere' > "$t"
l="$WT/w3.link"
MSYS=winsymlinks:nativestrict ln -s "$t" "$l" 2>/dev/null
if [ -L "$l" ]; then
  ( DRY_RUN=0; write_new_file "$l" "evil" "测试文件" ) >/dev/null 2>&1
  RC=$?
  chk 2 "W3 目标是符号链接时拒绝（退出码 2）"
  [ "$(cat "$t")" = "target-elsewhere" ] && { pass=$((pass+1)); echo "PASS W3 链接目标未被写穿"; } || { fail=$((fail+1)); echo "FAIL W3 链接目标被写穿"; }
else
  echo "SKIP W3 本机无法创建符号链接"
fi

# W4 dry-run：对已存在文件也不报错、不做任何修改
f="$WT/w4.txt"; printf 'keep' > "$f"
( DRY_RUN=1; write_new_file "$f" "new" "测试文件" ) >/dev/null 2>&1
RC=$?
chk 0 "W4 dry-run 不报错"
[ "$(cat "$f")" = "keep" ] && { pass=$((pass+1)); echo "PASS W4 dry-run 未改动文件"; } || { fail=$((fail+1)); echo "FAIL W4 dry-run 改了文件"; }

# W5 多字节内容：字节数按 wc -c 计（不是字符数）
f="$WT/w5.txt"
( DRY_RUN=0; write_new_file "$f" "中文六个字" "测试文件" ) >/dev/null 2>&1
RC=$?
chk 0 "W5 多字节内容新建成功"
[ "$(wc -c < "$f" | tr -d ' ')" = "15" ] && { pass=$((pass+1)); echo "PASS W5 字节数 15（5 字符 × 3 字节）"; } || { fail=$((fail+1)); echo "FAIL W5 字节数不对：$(wc -c < "$f" | tr -d ' ')"; }

echo
echo "总计: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
