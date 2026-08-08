#!/bin/bash
# _bw-common.sh — Bitwarden 操作の共通処理。source して使う（単体実行しない）。
#
#   なぜ必要か:
#     bw CLI は単一の状態ファイル（~/Library/Application Support/Bitwarden CLI/data.json）を
#     共有する。複数の Claude Code セッションが同時に bw を使うと、後から走った方の
#     `bw lock` が先行セッションの鍵を破壊し、**エラーにならず空の結果が返る**。
#     「金庫が空」に見えて誤った結論を招くため、排他ロックと結果の妥当性検証を行う。

BW_LOCKDIR="$HOME/.config/secrets/.bw.lock"
BW_LOCK_HELD=0
BW_LOCK_TIMEOUT="${BW_LOCK_TIMEOUT:-180}"   # 秒

bw_lock_acquire() {
  local waited=0
  while ! mkdir "$BW_LOCKDIR" 2>/dev/null; do
    # 古いロック（プロセスが死んでいる）は奪う
    local pid
    pid="$(cat "$BW_LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$BW_LOCKDIR" 2>/dev/null || true
      continue
    fi
    if [ "$waited" -ge "$BW_LOCK_TIMEOUT" ]; then
      echo "エラー: 他のセッションが Bitwarden を使用中です（${BW_LOCK_TIMEOUT}秒待機しても解放されず）" >&2
      echo "  終わるのを待ってから再実行してください。停止しているなら: rm -rf $BW_LOCKDIR" >&2
      return 1
    fi
    [ "$waited" -eq 0 ] && echo "他のセッションが Bitwarden を使用中です。待機します..." >&2
    sleep 2; waited=$((waited+2))
  done
  printf '%s' "$$" > "$BW_LOCKDIR/pid"
  BW_LOCK_HELD=1
  return 0
}

bw_lock_release() {
  if [ "$BW_LOCK_HELD" -eq 1 ]; then
    rm -rf "$BW_LOCKDIR" 2>/dev/null || true
    BW_LOCK_HELD=0
  fi
  return 0
}

_bw_kc() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null; }

# 認証情報を読み、ログイン・解錠し、$BW_SESSION を export する。
# 解錠できたと主張するだけでなく、実際に金庫を読めるところまで確認する。
bw_session_open() {
  bw_lock_acquire || return 1

  BW_CLIENTID="$(_bw_kc bw/client-id)"
  BW_CLIENTSECRET="$(_bw_kc bw/client-secret)"
  BW_PASSWORD="$(_bw_kc bw/master-password)"
  if [ -z "${BW_PASSWORD:-}" ]; then
    echo "エラー: 未設定です。secret-bootstrap を実行してください" >&2
    bw_lock_release; return 1
  fi
  export BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD

  if ! bw login --check >/dev/null 2>&1; then
    bw login --apikey --quiet >/dev/null 2>&1 || {
      echo "エラー: bw login に失敗しました" >&2; bw_lock_release; return 1; }
  fi

  local s
  s="$(bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null || true)"
  if [ -z "$s" ]; then
    echo "エラー: bw unlock に失敗しました" >&2; bw_lock_release; return 1
  fi
  export BW_SESSION="$s"

  # 「セッションは返るが金庫は施錠のまま」（bw 2026.3.0/2026.4.1 の既知不具合）と、
  # 他プロセスに鍵を壊された場合の両方をここで検出する
  if ! bw list items --session "$BW_SESSION" >/dev/null 2>&1; then
    echo "エラー: セッションは返りましたが金庫を読めません" >&2
    echo "  bw のバージョンが 2026.3.0 / 2026.4.1 なら既知不具合です:" >&2
    echo "    npm install -g @bitwarden/cli@2026.1.0" >&2
    bw_lock_release; return 1
  fi
  return 0
}

bw_session_close() {
  bw lock >/dev/null 2>&1 || true
  unset BW_PASSWORD BW_CLIENTSECRET BW_SESSION
  bw_lock_release
  return 0
}

# 金庫の全項目を取得する。取得できなければ空文字ではなく失敗を返す。
bw_items() {
  local j
  j="$(bw list items --session "$BW_SESSION" 2>/dev/null)" || return 1
  printf '%s' "$j" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$j"
  return 0
}
