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
  n="$(basename "$f")"
  install -m 700 "$f" "$BIN/$n"
  printf '  %s\n' "$n"
done

echo
echo "== 対応表を配置（既存があれば上書きしない） =="
for f in "$REPO"/maps/*.map; do
  n="$(basename "$f")"
  if [ -e "$CONF/$n" ]; then
    if cmp -s "$f" "$CONF/$n"; then printf '  同一   %s\n' "$n"
    else printf '  \033[33m差分あり（上書きせず）\033[0m %s\n' "$n"; fi
  else
    install -m 600 "$f" "$CONF/$n"; printf '  新規   %s\n' "$n"
  fi
done

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
