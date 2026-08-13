#!/bin/bash
# run-tests.sh — mac/ の回帰テスト。
#
#   使い方:
#     mac/tests/run-tests.sh              # 本物の金庫・キーチェーンに触れない
#     mac/tests/run-tests.sh --with-vault # 本物の金庫を読むテストも実行する（読み取りのみ）
#
#   仕組み:
#     HOME を一時ディレクトリへ向け、`security` と `bw` を差し替えた PATH で
#     mac/ のスクリプトをそのまま実行する。**本物のキーチェーンにも金庫にも触れない。**
#     秘密の値は一切登場しない（合成値のみ）。
#
#   何を守っているか:
#     ここにあるのは全て「実際に踏んだ失敗」の再発防止。テストが本体で、
#     HANDOFF.md の §3 はその理由書。文章では守れないことは実証済み
#     （注意書きのある箇所を後から自分で壊した例が複数ある）。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MAC="$REPO/mac"
WITH_VAULT=0
[ "${1:-}" = "--with-vault" ] && WITH_VAULT=1

pass=0; fail=0; failed_names=()
G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'

ok()   { pass=$((pass+1)); printf "  ${G}PASS${N} %s\n" "$1"; }
ng()   { fail=$((fail+1)); failed_names+=("$1"); printf "  ${R}FAIL${N} %s\n" "$1"; [ -n "${2:-}" ] && printf "        %s\n" "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "期待 [$2] / 実際 [$3]"; fi; }

# ---------------------------------------------------------------------------
# サンドボックス
# ---------------------------------------------------------------------------
SB="$(mktemp -d "${TMPDIR:-/tmp}/secrets-toolkit-tests.XXXXXXXX")"
chmod 700 "$SB"
cleanup_sb() { rm -rf "$SB"; }
trap cleanup_sb EXIT INT TERM

mkdir -p "$SB/home/.config/secrets" "$SB/bin" "$SB/kc" "$SB/bw"
chmod 700 "$SB/home/.config/secrets"

cat > "$SB/bin/security" <<'STUB'
#!/bin/bash
# security(1) の差し替え。本物のキーチェーンには触れない。
d="$KCSTUB_DIR"
cmd="${1:-}"; shift || true
key() { printf '%s' "$1" | tr '/' '~'; }
case "$cmd" in
  find-generic-password)
    name=""; want_val=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) name="$2"; shift 2 ;;
        -w) want_val=1; shift ;;
        -a|-l|-D|-j) shift 2 ;;
        *)  shift ;;
      esac
    done
    f="$d/$(key "$name")"
    [ -f "$f.val" ] || exit 44
    if [ "$want_val" -eq 1 ]; then cat "$f.val"; else cat "$f.attrs"; fi
    exit 0 ;;
  add-generic-password)
    name=""; val=""; enc="raw"
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) name="$2"; shift 2 ;;
        -w) val="$2"; shift 2 ;;
        -j) enc="$2"; shift 2 ;;
        -U) shift ;;
        -a|-l|-D) shift 2 ;;
        *)  shift ;;
      esac
    done
    f="$d/$(key "$name")"
    printf '%s' "$val" > "$f.val"
    printf 'keychain: "test"\n    "icmt"<blob>="%s"\n    "svce"<blob>="%s"\n' "$enc" "$name" > "$f.attrs"
    exit 0 ;;
esac
exit 1
STUB

cat > "$SB/bin/bw" <<'STUB'
#!/bin/bash
# bw CLI の差し替え。本物の金庫には触れない。
d="$BWSTUB_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
emit_items() {
  case "${BWSTUB_ITEMS_MODE:-normal}" in
    empty)   printf '' ;;
    blank)   printf '   ' ;;
    garbage) printf 'not json at all' ;;
    null)    printf 'null' ;;
    none)    printf '[]' ;;
    *)       cat "$d/items.json" ;;
  esac
}
emit_folders() {
  case "${BWSTUB_FOLDERS_MODE:-normal}" in
    empty) printf '' ;;
    none)  printf '[]' ;;
    *)     cat "$d/folders.json" ;;
  esac
}
case "${1:-}" in
  login)  exit 0 ;;
  unlock) printf 'FAKE-SESSION-KEY'; exit 0 ;;
  lock)   exit 0 ;;
  sync)   exit 0 ;;
  list)
    case "${2:-}" in
      items)   emit_items;   exit 0 ;;
      folders) emit_folders; exit 0 ;;
    esac ;;
  encode) openssl base64 -A; exit 0 ;;
  create)
    case "${2:-}" in
      folder) cat > "$d/created-folder.b64"; printf '{"id":"NEW-FOLDER-ID"}'; exit 0 ;;
      item)   cat >> "$d/created-items.b64"; printf '\n' >> "$d/created-items.b64"
              printf '{"id":"NEW-ITEM-ID"}'; exit 0 ;;
    esac ;;
  edit) cat > "$d/edited-item.b64"; printf '{"id":"EDITED"}'; exit 0 ;;
esac
exit 1
STUB

chmod 700 "$SB/bin/security" "$SB/bin/bw"

export KCSTUB_DIR="$SB/kc"
export BWSTUB_DIR="$SB/bw"
printf '[]' > "$SB/bw/items.json"
printf '[]' > "$SB/bw/folders.json"

# サンドボックス内で mac/ のスクリプトを実行する
run() { ( export HOME="$SB/home"; export PATH="$MAC:$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin"; "$@" ); }

# bootstrap 相当（bw の資格情報だけ入れておく。値は合成）
run secret-put bundle/bitwarden/api-credentials <<< 'fake-credentials' >/dev/null 2>&1
printf 'fake-master' > "$SB/kc/bw~master-password.val"
printf '"icmt"<blob>="raw"\n' > "$SB/kc/bw~master-password.attrs"

echo
echo "== A. 静的検査 =="

# 1. 構文
syntax_bad=""
for f in "$MAC"/*; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || syntax_bad="$syntax_bad $(basename "$f")"
done
check "全スクリプトの構文が通る" "" "$syntax_bad"

# 2. 生の bw list が _bw-common.sh の外に無い（§3-8）
#    コメント中の言及は数えない（sed で落とす）。
#    正当な例外は2つだけ:
#      secret-bootstrap  … 資格情報を確立する側なので、まだヘルパを使えない
#      secret-rotate-bw  … **新しい**資格情報が有効かを、専用セッションで試す必要がある
raw=""
for f in "$MAC"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in _bw-common.sh|secret-bootstrap|secret-rotate-bw) continue ;; esac
  if sed 's/#.*//' "$f" | grep -q 'bw list \(items\|folders\)'; then raw="$raw $b"; fi
done
check "生の bw list が _bw-common.sh の外に無い（§3-8）" "" "${raw# }"

# 3. 金庫を開ける鍵を金庫へ入れない仕掛けがある（§2-2 / §3-10）
if grep -q 'bundle/bitwarden' "$MAC/secret-push-bw"; then
  ok "secret-push-bw が bundle/bitwarden/* を知っている（§3-10）"
else
  ng "secret-push-bw が bundle/bitwarden/* を知っている（§3-10）" "除外規則が消えている"
fi

# 4. cleanup が必ず 0 を返す（§3-3）
if awk '/^cleanup\(\)/,/^}/' "$MAC/secrets-run" | grep -q 'return 0'; then
  ok "secrets-run の cleanup が return 0 を持つ（§3-3）"
else
  ng "secrets-run の cleanup が return 0 を持つ（§3-3）" "終了コードが握り潰される"
fi

# 5. exec の前にコマンドの実行可否を確かめている（下の 127 テストが本体。これは意図の固定）
if grep -q 'command -v "\$1"' "$MAC/secrets-run"; then
  ok "secrets-run が exec 前にコマンドを解決する"
else
  ng "secrets-run が exec 前にコマンドを解決する" "コマンド不在が 1 や 0 に化ける"
fi

echo
echo "== B. 金庫応答の検証（§3-2） =="

probe_items() {  # <モード> -> 成功なら ok / 失敗なら ng を返す文字列
  ( export BWSTUB_ITEMS_MODE="$1" HOME="$SB/home" PATH="$MAC:$SB/bin:/usr/bin:/bin"
    . "$MAC/_bw-common.sh"; export BW_SESSION=FAKE
    if bw_items >/dev/null 2>&1; then echo "通す"; else echo "弾く"; fi )
}
check "bw_items: 正常な配列を通す"      "通す" "$(probe_items normal)"
check "bw_items: [] を通す（空の金庫は正当）" "通す" "$(probe_items none)"
check "bw_items: 空文字を弾く"          "弾く" "$(probe_items empty)"
check "bw_items: 空白のみを弾く"        "弾く" "$(probe_items blank)"
check "bw_items: 非 JSON を弾く"        "弾く" "$(probe_items garbage)"
check "bw_items: null を弾く"           "弾く" "$(probe_items null)"

probe_folders() {
  ( export BWSTUB_FOLDERS_MODE="$1" HOME="$SB/home" PATH="$MAC:$SB/bin:/usr/bin:/bin"
    . "$MAC/_bw-common.sh"; export BW_SESSION=FAKE
    if bw_folders >/dev/null 2>&1; then echo "通す"; else echo "弾く"; fi )
}
check "bw_folders: [] を通す"   "通す" "$(probe_folders none)"
check "bw_folders: 空文字を弾く" "弾く" "$(probe_folders empty)"

echo
echo "== C. secrets-run =="

run secret-put api-key/test/one <<< 'value-one' >/dev/null 2>&1
run secret-put service-account/test/json <<< '{"type":"service_account","project_id":"x"}' >/dev/null 2>&1
printf 'ONE_KEY=api-key/test/one\n' > "$SB/home/.config/secrets/t1.map"

run secrets-run t1 -- true >/dev/null 2>&1; check "終了コード 0 が伝わる" "0" "$?"
run secrets-run t1 -- bash -c 'exit 42' >/dev/null 2>&1; check "終了コード 42 が伝わる（§3-3）" "42" "$?"
run secrets-run t1 -- no-such-command-xyz >/dev/null 2>&1; check "コマンド不在は 127" "127" "$?"
printf '#!/bin/bash\ntrue\n' > "$SB/notexec.sh"; chmod 600 "$SB/notexec.sh"
run secrets-run t1 -- "$SB/notexec.sh" >/dev/null 2>&1; check "在るが実行できないファイルは 126" "126" "$?"

got="$(run secrets-run t1 -- printenv ONE_KEY 2>/dev/null)"
check "環境変数が子プロセスへ渡る" "value-one" "$got"

# 引数がちょうど1個（Windows で実際に壊れた形。Mac でも回帰として固定する）
got="$(run secrets-run t1 -- bash -c 'printf "%s" "$1"' _ solo-arg 2>/dev/null)"
check "引数がちょうど1個でも壊れない" "solo-arg" "$got"

# .secrets-profile の自動検出
mkdir -p "$SB/home/proj/sub"
printf 't1\n' > "$SB/home/proj/.secrets-profile"
got="$( cd "$SB/home/proj/sub" && run secrets-run -- printenv ONE_KEY 2>/dev/null )"
check ".secrets-profile を上位から自動検出する" "value-one" "$got"

# キーチェーンに無い項目は名指しして 1 で止まる
printf 'MISSING_KEY=api-key/test/absent\n' > "$SB/home/.config/secrets/t2.map"
out="$(run secrets-run t2 -- true 2>&1)"; rc=$?
check "不足項目があれば終了コード 1" "1" "$rc"
case "$out" in *api-key/test/absent*) ok "不足項目を名指しする" ;;
               *) ng "不足項目を名指しする" "出力に名前が無い" ;; esac

echo
echo "== D. @file:（§1-5 / §3-3） =="

printf 'SA=@file:service-account/test/json\n' > "$SB/home/.config/secrets/t3.map"
info="$(run secrets-run t3 -- bash -c 'printf "%s|%s|%s" "$(stat -f %Lp "$SA")" "$(head -c1 "$SA")" "$SA"' 2>/dev/null)"
mode="${info%%|*}"; rest="${info#*|}"; first="${rest%%|*}"; path="${rest#*|}"
check "一時ファイルの権限が 0600" "600" "$mode"
check "一時ファイルの中身が復元される（BOM 無し）" "{" "$first"
if [ -e "$path" ]; then ng "コマンド終了後に一時ファイルが消える" "$path が残っている"
else ok "コマンド終了後に一時ファイルが消える"; fi

run secrets-run t3 -- bash -c 'exit 42' >/dev/null 2>&1
check "@file: 使用時も終了コードが伝わる（§3-3）" "42" "$?"

echo
echo "== E. secret-put / 複数行の往復（§3-1） =="

run secret-put api-key/test/empty <<< '   ' >/dev/null 2>&1
check "空の値を拒否する" "1" "$?"

printf 'line1\nline2\n' | run secret-put bundle/test/multi >/dev/null 2>&1
enc="$(grep -o 'b64' "$SB/kc/bundle~test~multi.attrs" || true)"
check "複数行の値は b64 で格納される（§3-1）" "b64" "$enc"
printf 'MULTI=bundle/test/multi\n' > "$SB/home/.config/secrets/t4.map"
got="$(run secrets-run t4 -- bash -c 'printf "%s" "$MULTI"' 2>/dev/null)"
check "複数行の値が元通り復元される" "$(printf 'line1\nline2')" "$got"

echo
echo "== F. secret-verify（§3-11） =="

printf 'value-one' > "$SB/plain.txt"
run secret-verify api-key/test/one "$SB/plain.txt" >/dev/null 2>&1
check "一致を検出する" "0" "$?"
printf 'different' > "$SB/other.txt"
run secret-verify api-key/test/one "$SB/other.txt" >/dev/null 2>&1
check "不一致を検出する" "1" "$?"
printf '\xef\xbb\xbfvalue-one' > "$SB/bom.txt"
run secret-verify api-key/test/one "$SB/bom.txt" >/dev/null 2>&1
check "BOM 付きは不一致（バイト単位・§3-11）" "1" "$?"
printf '  value-one  \n\n' > "$SB/ws.txt"
run secret-verify api-key/test/one "$SB/ws.txt" >/dev/null 2>&1
check "前後の空白は無視する" "0" "$?"
printf 'value-one\nsecond line\n' > "$SB/two.txt"
run secret-verify api-key/test/one "$SB/two.txt" firstline >/dev/null 2>&1
check "firstline モードが効く" "0" "$?"
run secret-verify api-key/test/one "$SB/does-not-exist" >/dev/null 2>&1
check "ファイルが無ければ 1" "1" "$?"
run secret-verify >/dev/null 2>&1
check "引数不足なら 2" "2" "$?"

echo
echo "== G. secret-push-bw（§3-10 / §3-12） =="

: > "$SB/bw/calls.log"; : > "$SB/bw/created-items.b64"; rm -f "$SB/bw/created-folder.b64"
run secret-push-bw --folder zzz-should-not-exist bundle/bitwarden/api-credentials >/dev/null 2>&1
if grep -q 'create item' "$SB/bw/calls.log"; then
  ng "bundle/bitwarden/* は名指しでも登録しない（§3-10）" "create item が呼ばれた"
else ok "bundle/bitwarden/* は名指しでも登録しない（§3-10）"; fi
if [ -f "$SB/bw/created-folder.b64" ]; then
  ng "全件スキップならフォルダを作らない（§3-12）" "create folder が呼ばれた"
else ok "全件スキップならフォルダを作らない（§3-12）"; fi

: > "$SB/bw/calls.log"; : > "$SB/bw/created-items.b64"
run secret-push-bw --folder t api-key/test/one >/dev/null 2>&1
kind="$(openssl base64 -d -A < "$SB/bw/created-items.b64" 2>/dev/null | jq -r '.type' 2>/dev/null || true)"
check "1行の値はログイン項目(type=1)になる" "1" "$kind"

: > "$SB/bw/created-items.b64"
run secret-push-bw --folder t bundle/test/multi >/dev/null 2>&1
kind="$(openssl base64 -d -A < "$SB/bw/created-items.b64" 2>/dev/null | jq -r '.type' 2>/dev/null || true)"
check "複数行の値はセキュアメモ(type=2)になる" "2" "$kind"

echo
echo "== H. secret-sync の集計行 =="

printf '[]' > "$SB/bw/items.json"
out="$(run secret-sync 2>&1 | tail -1)"
n="$(printf '%s' "$out" | grep -o '[0-9]\+ 件' | wc -l | tr -d ' ')"
check "集計行に6つの件数が出る（【3】と空白修正を含む）" "6" "$n"

if [ "$WITH_VAULT" -eq 1 ]; then
  echo
  echo "== I. 本物の金庫（読み取りのみ） =="
  export PATH="$HOME/.local/bin:$PATH"
  if out="$(secret-list-remote 2>&1)"; then
    n="$(printf '%s' "$out" | sed -n 's/^金庫の項目数: \([0-9]*\)$/\1/p')"
    if [ "${n:-0}" -gt 0 ]; then ok "本物の金庫を読める（項目数 $n）"
    else ng "本物の金庫を読める" "項目数が 0"; fi
  else
    ng "本物の金庫を読める" "secret-list-remote が失敗"
  fi
  if secret-check >/dev/null 2>&1 || [ $? -eq 1 ]; then
    ok "secret-check が実行できる（MISS の有無は問わない）"
  else
    ng "secret-check が実行できる" ""
  fi
fi

echo
printf "%s\n" "----------------------------------------"
if [ "$fail" -eq 0 ]; then
  printf "${G}%d件すべて通過${N}\n" "$pass"
else
  printf "${G}PASS %d${N} / ${R}FAIL %d${N}\n" "$pass" "$fail"
  for f in "${failed_names[@]}"; do printf "  ${R}✗${N} %s\n" "$f"; done
fi
[ "$fail" -eq 0 ]
