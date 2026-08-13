# HANDOFF — 秘密情報の集約と、その周辺で見つかった欠陥

最終更新: 2026-08-14（本体は 2026-08-09 の記録。§1-5 / §3-7 / §5-3 のみ後から追記・訂正）
このファイルだけ読めば作業を再開できるように書いてある。
**秘密の値は一切書かない。出てくるのは「名前」だけ。**

---

## 0. 一行で

デスクトップに散っていた平文の資格情報26件を **Bitwarden（正本）+ macOS キーチェーン（実行時）**
へ集約し、その過程で **4つの実害あるバグ**を見つけて直した。未処理が6件（§5）。

---

## 1. 完了したこと

### 1-1. 平文の資格情報を全廃した
- デスクトップの平文ファイル **0件**（作業前: 16件 + `API_Key/` 10件 + `bitwarden_API_keys.txt`）
- 全件を **SHA-256 で原本照合**してから移動。値は一度も画面に出していない
- 原本は `~/.secrets-archive/`（iCloud圏外・700）へ退避。**削除していない**
- SPEC_desktop の手順に従い `~/Desktop/_tidy/` に `move_sec1〜4.sh` / `undo_sec1〜4.sh` と
  台帳 `moved_log.csv`（18行）を残した。**巻き戻し可能**

### 1-2. 26件を集約した
- 命名規則 `<種別>/<サービス>/<用途>`
  種別 = `api-key` / `api-token` / `service-account` / `app-password` /
  `webhook-url` / `recovery-codes` / `bundle`
- **キーチェーン名と Bitwarden の項目名は常に同一** → `secret-pull <名前> <名前>` で戻せる
- 金庫はプロジェクト単位のフォルダ（名前は `secrets-run` のプロファイル名と一致）
- `secret-sync` が「不一致0 / 規則違反0 / フォルダ未設定0」を返す状態

### 1-3. ツール一式（`~/.local/bin/`、正本は secrets-toolkit の `mac/`）

| コマンド | 役割 |
|---|---|
| `secrets-run <profile> -- <cmd>` | 環境変数へ注入して実行。`@file:` で一時ファイル(0600)化＋自動削除 |
| `secret-sync` | 金庫→キーチェーン一括同期＋点検 |
| `secret-put` / `secret-check` / `secret-verify` | 登録 / 存在確認 / 原本照合（**値を出力しない**） |
| `secret-pull` / `secret-push-bw` | Bitwarden ↔ キーチェーン |
| `secret-push` | キーチェーン → Cloudflare Workers / GitHub Actions |
| `secret-bootstrap` / `secret-rotate-bw` | 初期設定 / APIキー入れ替え（失敗時は自動巻き戻し） |
| `secret-list-remote` | 金庫の項目名一覧（値は出ない） |

★ **ローカルを直接編集しない。** リポジトリを編集して `./install-mac.sh` を再実行する。

### 1-4. saiten-assistant #229 G2 の検証（Mac 側で実施）
コミット `3e99f5d` を独立 worktree に取り出し、`src/index.ts:2724` の呼び出しを忠実に再現
（本物の OpenRouter・本物の道具・本物の D1・本物の資格検査。違いはインメモリD1だけ）。
- `typecheck` 緑 / `npm test` **1877 passed**（112 files）
- 学籍番号の漏れ **0/8走行** / 予算ガード正常 / 1往復 0.07〜0.15円
- staging Worker のシークレット一覧を確認 → **`OPENROUTER_API_KEY` は設定済み**
  （「鍵が無いから G1 が動いていない」という仮説は**外れ**）

### 1-5. Windows 版を実機で検証した（2026-08-09 / 別マシン・後から追記）
Windows 11 / Windows PowerShell 5.1（ja-JP・CP932）/ Bitwarden CLI 2026.7.0 で
`windows/*.ps1` 5本を実行し、**Windows でだけ壊れる欠陥を5つ**見つけて直した（`a5d37e0`）。
旧 §5-3 が「特に確認すべき」と書いていた2点が、そのまま実際のバグだった。

- **`--` が消える**: PowerShell が素の `--` を引数から取り除くため `IndexOf($args,'--')` が常に -1。
  **全呼び出しが usage エラーで死んでいた**（`--` が最後の引数のときの `1..0` 逆順範囲の罠も同時に修正）
- **終了コードの伝播**: 実行前に `$LASTEXITCODE` をリセット。コマンド不在は 127
- **`@file:` の後始末**: 一時ディレクトリの ACL を作成時に絞り、消えたことを検証する
  （従来は削除失敗を握り潰し、既定権限の平文がディスクに残り得た）。BOM 無しで書き出す
  （`Set-Content -Encoding UTF8` の BOM で Google クライアントの `JSON.parse` が落ちる）
- **`.map` の CP932 読み**: 日本語コメント行の末尾がリードバイトになると次の行を飲み、**項目が黙って1つ減る**。
  同じ理由で `.ps1` は全て UTF-8 BOM 付きで保存する（`secret-check.ps1` が実際に4行失っていた）
- **`secret-check.ps1` の検査が自己成就だった**: キャッシュを列挙してそのファイルの存在を確かめており
  **常に通っていた**。`.map` が参照する名前を検査するよう修正
- 平文の後始末として `ZeroFreeBSTR`、`Close-BwSession` で `BW_CLIENTID` を消す、も追加

続いて §3-2（`bw` 同時実行）の対策を Windows へ移植した（`feadbfc`）。名前付き mutex
（`Local\secrets-toolkit-bw`）を使う。Windows は保持プロセスが死ぬと mutex を自動解放するので、
Mac 版のような PID 生存確認つきロックディレクトリは要らない。

---

## 2. 重要な設計判断

1. **Bitwarden = 正本 / OS の暗号化ストア = 実行時の読み出し口**
2. **`bundle/bitwarden/api-credentials` は金庫へ push しない**
   （金庫を開ける鍵を金庫に入れる循環依存になる）
3. **`service-account/app-store-connect/*` は金庫に無くてよい**
   正本は `bundle/app-store-connect/*` のメモ欄。CIツールがコメント行付きPEMを弾くため、
   純PEMの実行時コピーをキーチェーンに置く（`secret-sync` が除外を知っている）
4. **`settings.json` の deny 3行を緩めない**
   `security find-generic-password` / `env` / `printenv`。値を画面に出す唯一の経路を塞いでおり、
   これが機械的な歯止めの全部
5. **ローテーションは見送り中**（Yukiの条件「全アプリへ自動反映できるなら」を満たせない。
   発行元での再発行は各社にAPIが無い）。ただし Bitwarden の APIキーだけは例外（§5-4）

---

## 3. 踏んだ罠（同じ形が再発しうる）

### 3-1. `security` は改行入りの値を16進で返す
`-w` は値に改行があると**平文でなく16進**（長さ2倍・1行）を返す。接頭辞が付かず見分けられない。
**推測での判別は危険**（Deepgram の鍵は40文字の16進なので誤爆する）。
→ 改行を含む値は base64 格納し、**格納形式をコメント欄 `-j raw|b64` に記録**。読み出し側が属性を見る。

### 3-2. `bw` の同時実行で片方が黙って空を返す
`bw` は単一の状態ファイルを共有。同時実行すると**後発の `bw lock` が先行の鍵を壊し、
エラーにならず空＋終了コード0**を返す。「金庫が空」に見えて誤った結論を招く。
→ `mac/_bw-common.sh` が排他ロック（`~/.config/secrets/.bw.lock`、保持PIDが死んでいれば奪う）と
「実際に金庫を読めるか」の検証を行う。残ったら `rm -rf ~/.config/secrets/.bw.lock`

### 3-3. `secrets-run` が `@file:` 使用時に終了コードを常に1で返していた
EXITトラップ内の最終コマンドのステータスが本来の終了コードを上書きしていた。
**`voice` プロファイルでテストが成功しても全部失敗扱いになっていた。**
→ `cleanup()` が必ず `return 0`。`true`→0 / `exit 42`→42 を確認済み。

### 3-4. 項目名の前後の空白で完全一致検索から漏れる
スマホ入力で末尾空白が混入した。→ `secret-sync` が自動修正する。

### 3-5. 日本語ファイル名の NFC/NFD 差
`楽天アプリID.txt` が `grep` のパターンから漏れた（APFS は lookup で正規化するので `test -e` は通る）。
**実在確認は `find -name` の手打ちでなく `test -e` か `ls` 出力の機械照合で**（SPEC_desktop §17）。

### 3-6. `secret-sync` がログイン項目のメモ欄を黙って捨てていた
キーチェーンは1名前に1値しか持てないため。→ 捨てていることを報告するようにした（`【3】`）。

### 3-7. Windows 固有の罠は `windows/SETUP.md` の冒頭にある
文字コード（BOM）・`--` の書き方・`@file:` の扱いなど、macOS では起きない壊れ方が4件。
**編集時に戻さないこと。** 実物は §1-5 と `windows/SETUP.md`「Windows 固有の落とし穴」を見る。

---

## 4. 環境の制約（時間を溶かさないために）

- **クラウドのセッション（`uname -s` が `Linux`）からは Bitwarden にもキーチェーンにも
  原理的に到達できない。** マスターパスワードが Mac のキーチェーンにのみ存在し、通信路が無い。
  設定不足ではないので**直せない**。★ **鍵の入手を前提にした計画を立てないこと**
- セッション作成時のプロンプト欄に **Environment（Local / Cloud / SSH）** の選択がある。
  **既定をローカルに固定する設定は存在しない**（公式ドキュメントで確認済み）
- 見分け方: `uname -s` が `Darwin` か / Mac のセッション一覧に載るか /
  バイパスモードが選べるか（クラウドでは選べない）

---

## 5. 次の一手（優先度順）

### 5-1. `~/Downloads/AuthKey_P39W8N52CT.p8` の処遇 ★要判断
App Store Connect の秘密鍵。**Apple は再ダウンロードさせない**ので削除は不可逆。
Bitwarden（`bundle/app-store-connect/fushigi-touch-ci` のメモ欄）とキーチェーン
（`service-account/app-store-connect/fushigi-touch-ci`）の両方に入り照合済み。
Key ID `P39W8N52CT` / Issuer ID もメモ欄ヘッダに記録済み。
→ **Yuki に「消す / `~/.secrets-archive/` へ退避 / そのまま」を確認する。**

### 5-2. saiten-assistant #229: 予算の状態がモデルに見えていない ★実装が要る
PR #1 の看板は「『この試験、進めて』で一続きに進む」だが、**実モデルでは 0/4 で採点依頼に到達しない**
（予算3000円を設定しても、無料・可逆の読み取り確認すら実行せず訊き返して止まる）。

**原因**: モデルは「予算が決まっているか」を知る手段を持たない。`get_exam_overview` の返り値に
予算の状態が無く、予算は `request_grading_for_submission` の内部でしか確認されない。
一方システムプロンプトは「予算を決めること」を禁止事項に挙げている。

→ `get_exam_overview` に予算の状態（設定済みか・上限・残り）を載せるのが最小の修正候補。
→ **測定の限界も伝えること**: フィクスチャは1学生・1設問・1ページ、各条件4回のみ。

**staging の HTTP 経路を通した往復は未実施。** 修正後に Mac 側で実施できる
（`.dev.vars` の Access サービストークン + `app-password/saiten-assistant/staging`、
走者は `scripts/repro-run.ts`）。

### 5-3. Windows: `bw` 同時実行対策を入れた後の、本物の金庫での往復
実機検証そのものは済んでいる（**§1-5 を見ること**）。残っているのはその後の1点だけ。

`feadbfc`（名前付き mutex への移植）は **金庫に触れずに**検証した — 6秒保持する側の後ろで
別プロセスが 5.1 秒待つこと、保持側を kill すると即座に引き継げること、`Get-BwItems` が
`[]` と正常な配列を受け入れ、空・空白・非 JSON・null を弾くこと。
つまり **`bw` セッション経路を書き換えた後、本物の金庫を通した `secret-sync.ps1` /
`secrets-run.ps1` の往復を Windows で走らせていない。** 次に Windows を触るときに1回やる。

### 5-4. Bitwarden APIキーの再発行（急がない）
`bitwarden_API_keys.txt` が iCloud 圏内に平文で置かれていた。ただし**マスターパスワードは含まれず、
APIキー単体では金庫を復号できない**（E2E暗号化）ので緊急ではない。
再発行は Web 金庫のみ（`bw` CLI に該当コマンドが無い）。その後 `secret-rotate-bw` で反映。

### 5-5. `~/Documents` の `.env` 3件
`pop-economics-grading` / `AI面接用アプリ` / `saiten-assistant` の `.env` が
**平文のまま iCloud にある**。ルールに従い中身は読んでいない。指示があれば同じ方式で移送する。

### 5-6. その他
- `api-token/unverified/saiten-assistant-gcp` は名前と中身の形状が食い違う
  （53文字・Cloudflareトークンと同形。GCPキーの形式ではない）。**要確認**
- `api-token/cloudflare/saiten-mirror-readonly` は形状からの推定で Cloudflare と判断。**要確認**
- `shibehasu-site.map` が参照する `api-token/cloudflare/shibehasu-site` は**未発行**
- GitHub リカバリコードは金庫に入ったが、**紙の控えも1部**持っておくのが望ましい

---

## 6. よく使うコマンド

```bash
secret-sync                          # 金庫→キーチェーン一括同期＋点検
secret-check                         # 登録状況（値は出ない）
secrets-run <profile> -- <コマンド>    # .secrets-profile があればプロファイル省略可
secret-list-remote                   # 金庫の項目名一覧
cd ~/Projects/secrets-toolkit && git pull && ./install-mac.sh   # ツールの更新
```
