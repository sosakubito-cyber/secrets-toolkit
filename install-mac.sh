#!/bin/bash
# install-mac.sh — mac/ のスクリプトと maps/ の対応表を所定の場所へ配置する。
#   このリポジトリが正本。ローカルを直接編集せず、ここを編集してから再実行すること。
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
CONF="$HOME/.config/secrets"

mkdir -p "$BIN" "$CONF"
chmod 700 "$CONF"

echo "== スクリプトを配置 =="
for f in "$REPO"/mac/*; do
  # mac/tests/ のようなディレクトリは配置対象外。
  # これを見落として install がディレクトリで失敗し、終了コード 71 で止まって
  # 下の対応表の処理に一度も到達していなかった（2026-08-15 に発覚）。
  # スクリプトが全部配置済みに見えたのは、tests が名前順で最後だっただけ。
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  install -m 700 "$f" "$BIN/$n"
  printf '  %s\n' "$n"
done

UPDATE_MAPS=0
[ "${1:-}" = "--update-maps" ] && UPDATE_MAPS=1

echo
if [ "$UPDATE_MAPS" -eq 1 ]; then
  echo "== 対応表を配置（--update-maps: 差分は正本で上書きする） =="
else
  echo "== 対応表を配置（既存があれば上書きしない。更新は --update-maps） =="
fi
stale=0
for f in "$REPO"/maps/*.map; do
  n="$(basename "$f")"
  if [ -e "$CONF/$n" ]; then
    if cmp -s "$f" "$CONF/$n"; then
      printf '  同一   %s\n' "$n"
    elif [ "$UPDATE_MAPS" -eq 1 ]; then
      # 対応表に秘密の値は入っていない（名前だけ）ので、変更点は表示してよい
      diff <(grep -v '^[[:space:]]*#' "$CONF/$n" | grep .) \
           <(grep -v '^[[:space:]]*#' "$f" | grep .) \
        | grep '^[<>]' | sed 's/^</    削除/; s/^>/    追加/' || true
      install -m 600 "$f" "$CONF/$n"
      printf '  \033[32m更新\033[0m   %s\n' "$n"
    else
      printf '  \033[33m差分あり（上書きせず）\033[0m %s\n' "$n"; stale=$((stale+1))
    fi
  else
    install -m 600 "$f" "$CONF/$n"; printf '  新規   %s\n' "$n"
  fi
done
if [ "$stale" -gt 0 ]; then
  printf '\n  \033[33m配備先が古いままの対応表が %s 件あります。\033[0m 反映するには:\n' "$stale"
  echo   "    ./install-mac.sh --update-maps"
  echo   "  （正本はこのリポジトリ。配備先を手で編集しないこと）"
fi

echo
case ":$PATH:" in
  *":$BIN:"*) echo "PATH OK: $BIN" ;;
  *) echo "注意: $BIN が PATH にありません。~/.zshrc に次を追加してください:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo
echo "次の手順:"
echo "  1. 初回のみ  secret-bootstrap   （対話端末で実行）"
echo "  2. 取り込み  secret-sync"
echo "  3. 確認      secret-check"
