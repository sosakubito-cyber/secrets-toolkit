# secrets-toolkit

APIキー・トークンを平文ファイルに置かず、**Bitwarden を正本・OS の暗号化ストアを実行時の
読み出し口**として運用するためのツール群。macOS と Windows の両方に対応する。

> **このリポジトリに秘密の値は一切入らない。** 入るのは「名前」と「対応表」だけ。
> それでも念のため **private リポジトリのまま**運用すること。

## 構成

```
[iPhone Bitwarden]  ←→  [Bitwarden クラウド]   ← 正本（Mac / Windows 共通）
                              ↓
        macOS キーチェーン        DPAPI暗号化ファイル(Windows)   ← 実行時の読み出し口
                              ↓
                    secrets-run （環境変数として注入）
                              ↓
                        各プロジェクト
```

Claude に渡すのは常に **名前だけ**。値は渡さないし、ツールは値を出力しない。

## 命名規則

`<種別>/<サービス>/<用途>`

| 種別 | 意味 | 例 |
|---|---|---|
| `api-key` | サービス発行のAPIキー | `api-key/openai/answer-prompter` |
| `api-token` | スコープ付き・取消可能なトークン | `api-token/cloudflare/fushigi-touch` |
| `service-account` | サービスアカウントJSON（複数行） | `service-account/gcp/speech` |
| `app-password` | アプリ専用パスワード | `app-password/bluesky/main` |
| `webhook-url` | Webhook URL | `webhook-url/unknown/main` |
| `recovery-codes` | アカウント復旧コード | `recovery-codes/github/main` |
| `bundle` | 複数の値をまとめたもの（複数行） | `bundle/ebay/sandbox-production` |

**キーチェーン名と Bitwarden の項目名は常に同一**に保つ。同じなので
`secret-pull <名前> <名前>` で戻せる。

Bitwarden の金庫はプロジェクト単位のフォルダで整理する（フォルダ名は
`secrets-run` のプロファイル名に合わせる）。用途未定は `_unassigned`。

**例外**: `bundle/bitwarden/api-credentials`（Bitwarden 自身の client_id / client_secret）は
ローカルにのみ置き、**Bitwarden へは push しない**。金庫を開ける鍵を金庫に入れる
循環依存になるため。

## インストール

### macOS

```bash
./install-mac.sh
```

`mac/` の11本を `~/.local/bin/` へ、`maps/` を `~/.config/secrets/` へ配置する。
初回のみ `secret-bootstrap` を対話端末で実行する。

### Windows

`windows/SETUP.md` を参照。Windows 11 / Windows PowerShell 5.1 (ja-JP) /
Bitwarden CLI 2026.7.0 で、実データを通した往復まで検証済み。

**Windows 版は9本（Mac は11本）。** 未移植は `secret-rotate-bw`（Bitwarden APIキーの入れ替え）と
`secret-push`（Cloudflare / GitHub Actions への配布）の2本のみ。
**日々の運用は Windows だけで完結する。**

## 変更したら回帰テストを走らせる

```bash
mac/tests/run-tests.sh                  # 本物の金庫・キーチェーンに触れない
mac/tests/run-tests.sh --with-vault     # 本物の金庫を読むものも含む（読み取りのみ）
```

Windows は `.\windows\tests\run-tests.ps1`（`-WithVault` で金庫も）。

守っているのは全て**実際に踏んだ失敗**で、テストが本体・`HANDOFF.md` の §3 はその理由書。
注意書きのある箇所を後から自分で壊した例が複数あるので、**文章では守れない**。

## 日常の使い方

```bash
secrets-run <profile> -- <コマンド>   # プロジェクト直下に .secrets-profile があれば省略可
secret-sync                            # 金庫→ローカルを一括同期
secret-check                           # 登録状況（値は出ない）
```

## 設計上の約束

- どのツールも**秘密の値を標準出力・標準エラーに出さない**。照合はすべてハッシュ比較で行う
- 値の読み出し口は OS の暗号化ストアのみ。平文ファイルには戻さない
- 改行を含む値は base64 で格納する。macOS の `security -w` は改行入りの値を
  16進エンコードして返すため、そのままでは往復で壊れる。
  格納形式はキーチェーンのコメント欄に `raw` / `b64` として記録される
- Claude Code の `settings.json` deny で、値を画面に出す経路
  （`security find-generic-password` / `env` / `printenv`）を塞ぐ

## 複数セッションからの同時利用

`bw` CLI は単一の状態ファイル（macOS: `~/Library/Application Support/Bitwarden CLI/data.json`、
Windows: `%AppData%\Bitwarden CLI\data.json`）を共有する。複数の Claude Code セッションが
同時に bw を使うと、**後発の `bw lock` が先行セッションの鍵を破壊し、エラーにならず
空の結果が返る**（終了コードも 0）。「金庫が空」「その秘密は登録されていない」という
誤った結論を招く。**この問題は macOS / Windows の両方で起きる。**

- **macOS**: `mac/_bw-common.sh` が排他ロック（`~/.config/secrets/.bw.lock`）と
  結果の妥当性検証を行う。ロックが残ってしまった場合は
  `rm -rf ~/.config/secrets/.bw.lock`（保持プロセスが死んでいれば自動で奪う）。
- **Windows**: `windows/_secret-common.ps1` が名前付き Mutex（`Local\secrets-toolkit-bw`）
  で排他し、`Get-BwItems` が空・非配列の応答を失敗として扱う。保持プロセスが死ぬと
  OS が自動的に解放するため、掃除は不要。

どちらも後から来た方が待機してから実行される（既定 180 秒でタイムアウト。
`BW_LOCK_TIMEOUT` で変更可）。

## 既知の注意点

- **Bitwarden CLI 2026.3.0 / 2026.4.1** はヘッドレス解錠が壊れている
  （`bw unlock` がセッションを返すのに金庫が施錠のまま）。
  該当したら `npm install -g @bitwarden/cli@2026.1.0` にピン留めする。
  `secret-bootstrap` はこれを自動検知する
- **APIキーの再発行そのものは自動化できない**。`bw` CLI に該当コマンドが無く、
  Bitwarden は Web 金庫の UI に限定している。`secret-rotate-bw` は再発行後の
  反映のみを担当し、失敗時は古い認証情報へ自動で巻き戻す
- **Google Apps Script のスクリプトプロパティは自動反映できない**。`secret-push` が
  対応するのは Cloudflare Workers と GitHub Actions のみ
- 項目名の前後に空白が混入すると完全一致検索から漏れる。**Mac 版の** `secret-sync` が
  金庫の項目名を書き換えて自動修正する。**Windows 版は未実装**（金庫への書き込みを伴うため
  見送り中）。Windows しか使わない環境では、末尾の空白は手で直すか Mac 側で `secret-sync` を
  1回流す必要がある
