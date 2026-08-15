# HANDOFF — 秘密情報の集約と、その周辺で見つかった欠陥

最終更新: 2026-08-14（本体は 2026-08-09 の記録。§1-5〜1-7 / §2-6 / §3-7〜3-13 / §5 は後から追記・訂正。
片付いた項目は §5 から §1 へ移し、そのつど §5 を採番し直しているので、
古いメモの「§5-◯」は当てにしないこと）
このファイルだけ読めば作業を再開できるように書いてある。
**秘密の値は一切書かない。出てくるのは「名前」だけ。**

---

## 0. 一行で

デスクトップに散っていた平文の資格情報26件を **Bitwarden（正本）+ macOS キーチェーン（実行時）**
へ集約し、その過程で **4つの実害あるバグ**を見つけて直した
（その後さらに、Windows 実機で6件 §1-5/§1-6、見張り役の付け忘れで3件 §3-8）。
**Mac / Windows とも実データで動作確認済み。平文の `.env` も片付いた。** 未処理が5件（§5）。

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
当初この文書が「特に確認すべき」と書いていた2点が、そのまま実際のバグだった。

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

### 1-6. Windows で実データの往復まで通した（2026-08-14 / `d528520`）
`secret-bootstrap.ps1` を対話端末で手動実行（§2-6）した後、残りを一気に検証した。
**値は一度も出力していない**（文字数・真偽値・ハッシュのみで確認）。

- `secret-sync.ps1` — **25件取り込み**、命名規則違反0、金庫に無い項目0
- `secret-check.ps1` — **11/12 OK**。唯一の MISS は `shibehasu-site` で、
  map 自身に「未発行」と書かれている既知分（§5-5）。バグではない
- `secrets-run.ps1` — **6プロファイル全て動作**。終了コードは `exit 42` → 42 / `exit 0` → 0
- **`@file:` の実データ検証**: `GOOGLE_APPLICATION_CREDENTIALS` が
  2404 bytes / BOM なし / JSON パース可 / node からも読める。
  コマンド終了後、ファイル・親フォルダとも削除済みを確認。
  **§1-5 の BOM 修正が実利用で効いている**（修正前なら node 側が読めずに落ちていた）

この過程で Windows 固有のバグをもう1つ発見した。**`bw` の stderr が
`$ErrorActionPreference='Stop'` の下で例外に化け、bootstrap が起動できなかった。**
→ 全ての `bw` 呼び出しを共通ラッパー `Invoke-Bw` に集約し、生の呼び出しをゼロにした。
発見の経緯は §3-9。

### 1-7. `~/Documents` の `.env` を移送した（2026-08-14）
**新しい秘密は1つも増えなかった。** `.env` の5件すべてが既存の登録と同じ値だった
（値もハッシュも表示せず、`secret-verify` で照合）。

| `.env` | 変数 | 照合結果 |
|---|---|---|
| `AI面接用アプリ` | `OPENAI_API_KEY` | `api-key/openai/general` と同一 |
| `saiten-assistant` | `OPENAI_API_KEY` | `api-key/openai/saiten-assistant` と同一 |
| | `ANTHROPIC_API_KEY` | `api-key/anthropic/test-scoring` と同一 |
| | `GEMINI_API_KEY` / `GOOGLE_VISION_API_KEY` | **2つとも同じ値**。`api-key/google/saiten-assistant`（旧 `api-token/unverified/...`）と同一 |

- `maps/ai-interview.map` を新設、`maps/saiten-assistant.map` に3変数を追加
  （本体の Vertex 経路は ADC なので鍵不要。追加分は `scripts/transcription-comparison.ts` が
  直接叩くためのもの。参照があることを grep で確認済み）
- 両プロジェクトに `.secrets-profile` を置いた → `secrets-run -- <コマンド>` でプロファイル名を省略できる
- **`.env` の値と `secrets-run` が注入する値が一致することを、退避の前に5件とも確認**してから移動した
- `.env` は `~/.secrets-archive/env/` へ退避（**削除していない**）。台帳は同ディレクトリの `moved_log.csv`

### 1-8. 回帰テストを両プラットフォームに置いた（2026-08-14）
「安全に使える」を一時点の主張でなく**維持できる状態**にするため。守っている対象は
すべて §3 に書いた「実際に踏んだ失敗」で、**テストが本体・§3 はその理由書**。

```bash
mac/tests/run-tests.sh                  # 41件。本物の金庫・キーチェーンに触れない
mac/tests/run-tests.sh --with-vault     # +2件。本物の金庫を読む（読み取りのみ）
```
```powershell
.\windows\tests\run-tests.ps1            # 23件
.\windows\tests\run-tests.ps1 -WithVault
```

Mac 版は `HOME` を一時ディレクトリへ向け、`security` と `bw` を差し替えた `PATH` で
`mac/` のスクリプトをそのまま実行する。**本物のキーチェーンにも金庫にも触れない**
（実行後に登録28件・map 9件が変わっていないことを確認済み）。秘密の値は合成のみ。

**初回実行で実バグを1件見つけた**（§3-14）。テストを書く価値の実証になっている。
なお Windows 側では**テスト自身のアサーションが2件間違っていて正常なコードを FAIL と報告**した。
気づけたのは出力が目に見えていたからで、**逆（誤ったアサーションが常に PASS）だったら
気づけなかった**。テストがあること自体は保証にならない。

**`pop-economics-grading/.env` は移送していない。** 中身は `VERTEX_PROJECT` / `VERTEX_LOCATION` /
`TRANSCRIBE_MODEL` / `GRADE_MODEL` の4つで、**資格情報が1つも入っていない**（Vertex は ADC を使う）。
金庫に入れる対象ではないので、そのまま残してある。

---

## 2. 重要な設計判断

1. **Bitwarden = 正本 / OS の暗号化ストア = 実行時の読み出し口**
2. **`bundle/bitwarden/api-credentials` は金庫へ push しない**
   （金庫を開ける鍵を金庫に入れる循環依存になる）
3. **`service-account/app-store-connect/*` は金庫に無くてよい**
   正本は `bundle/app-store-connect/*` のメモ欄。CIツールがコメント行付きPEMを弾くため、
   純PEMの実行時コピーをキーチェーンに置く（`secret-sync` が除外を知っている）
4. **`settings.json` の deny を緩めない**
   `security find-generic-password` / `env` / `printenv`。値を画面に出す唯一の経路を塞いでおり、
   これが機械的な歯止めの全部。**Read 側の deny はパターン形式に注意**（§3-13）。
   `settings.json` はリポジトリ管理外なので、**マシンごとに実測して確かめること。**
5. **ローテーションは見送り中**（Yukiの条件「全アプリへ自動反映できるなら」を満たせない。
   発行元での再発行は各社にAPIが無い）。ただし Bitwarden の APIキーだけは例外（§5-3）。
   **例外がもう1つ増えた**: 発行元に CLI があるなら再発行も自動化できる（2026-08-15 に実証）。

   ```bash
   gcloud services api-keys create --format="value(response.keyString)" | secret-put <名前>
   ```

   **値が発行元の標準出力から暗号化ストアへ直接流れ、画面にもログにも人の目にも触れない。**
   一番危ないのは「作ってから登録するまで」の区間で、この書き方はその区間を消す。
   `--format` でキー文字列だけを出すこと（JSON 全体を出して後から抜くと途中が端末に残る）。
   →「全社に API が無い」のではなく「**CLI がある発行元から順に自動化できる**」が正しい。
     Cloudflare / GitHub など CLI を持つものは同じ形にできる可能性がある
6. **`secret-bootstrap` は自動化しない。対話端末で人が打つ。**
   自動化にはマスターパスワードと client_secret を渡す必要があり、それは**値を会話ログに残す**
   ことを意味する。Mac / Windows どちらも同じ。Windows 版は
   `[Console]::IsInputRedirected` で、リダイレクト経由の実行を機械的に拒否する。
   **エージェントが代行してよい範囲は bootstrap の後から。**

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

### 3-8. 見張り役を作っても、呼び出し側の付け忘れが残る（2026-08-14）
§3-2 の対策として `bw_items`（空文字を成功として通さない）を入れたが、**それを通していない
生の `bw list ...` が3箇所残っていた**。関数を足しただけで終わりにせず、
`grep -rn "bw list" mac/ windows/` で全呼び出しを洗うこと。実際に残っていたもの:

- `secret-push-bw` の重複チェック → 空に化けると「まだ無い」と誤解し、**全項目を金庫に二重登録**する
- `secret-push-bw` のフォルダ検索 → 同じ理由で**フォルダを重複作成**する
- `secret-sync` の空白修正後の再取得 → 【1】【2】が**逆さまの報告**になる（空白修正時のみ通る経路）

いずれも「読み取りの失敗が、書き込みの事故や誤報告に変わる」形。修正は `0414329` / `8d2d01d`。
ついでに `secret-sync` の集計行に、【3】メモありと空白修正の件数を追加した。
**未実行での修正**（金庫を開けずに、読解と `bash -n` と判定ロジック単体の確認のみ）。

### 3-9. 検証条件が実コードと違うと「問題なし」と誤報告になる（2026-08-14）
Windows 側で「`bw` の stderr は `$ErrorActionPreference='Stop'` でも例外化しない」と
**一度は問題なしと報告された**。しかしそれは**リダイレクト無しで試した**結果で、
実コードは全箇所 `2>$null` 等を付けて呼んでいた。リダイレクトが付くと挙動が変わり、
**bootstrap がそもそも起動できない**という形で後から出た（§1-6）。
→ 動作確認は**実コードと同じ呼び方**で行う。呼び出し形が1つでも違うなら、それは別物。
→ 同じ理由で、対策は1箇所に集約する方が安全（`Invoke-Bw` ラッパー、生の呼び出しゼロ）。

### 3-10. 設計判断が1つのスクリプトにしか実装されていなかった（2026-08-14）
§2-2「`bundle/bitwarden/*` は金庫へ push しない」は `secret-sync` の【2】には実装されていたが、
**実際に書き込む `secret-push-bw` には無かった**。`registry.txt` の19行目に
`bundle/bitwarden/api-credentials` があるため、**引数なしで `secret-push-bw` を実行すると
マスターパスワードを含む項目が金庫へ入る**。まだ発火していない（金庫に無いことを確認済み）。
→ 禁止規則は「報告する側」ではなく「**書き込む側**」に置く。
→ `secret-push-bw` は名指しされても拒否するようにした。
   `service-account/app-store-connect/*` は既定でスキップ・名指しなら通す（正本は bundle 側）。
→ Windows 版 `secret-push-bw.ps1` は最初から同じ規則を実装している。

### 3-11. 「食い違う」と注記するより、土俵を揃える（2026-08-14）
`secret-verify.ps1` は原本を `Get-Content` でテキストとして読んでいた。**BOM が落ちる**ので、
Mac 版（`cat` でバイト列）と同じファイルでも判定が変わる。「Mac では不一致・Windows では一致」
という、最も疑いにくい形の食い違いになる。最初は注記で済ませたが、
**BOM 由来の壊れ方はこの1日で4件踏んでいる**ので、注記ではなく実装を合わせた。
→ `[System.IO.File]::ReadAllBytes` で読み、`Get-SecretHashOfBytes` で両端の ASCII 空白だけ
   落としてハッシュ。キャッシュ側も UTF-8 バイト列にしてから同じ関数に通す。
→ pwsh が無くても**アルゴリズムは検証できる**: Mac 版の `cat|trim|shasum` と、移植した
   バイト処理を同じ入力に通して突き合わせた（16ケース一致 / BOM・CRLF・前後空白・複数行・
   日本語・空白のみ × plain・firstline）。**構文が試せないことと、論理が試せないことは別。**

### 3-12. 副作用を先に置くと、何もしなかった実行でも痕跡が残る（2026-08-14）
`secret-push-bw` はフォルダの用意をループの**前**に行っていた。そのため
**全件が拒否・スキップで終わった実行でも、空のフォルダだけが金庫に残る**。
`--folder <打ち間違えた名前>` で1回叩くと、そのゴミが金庫に増える。
→ 作成は**1件目を実際に登録する直前**まで遅延させる。Mac / Windows とも修正済み。
→ 一般化: 「入力の検査 → 副作用」の順を崩さない。読み取り（一覧の取得）は先でよいが、
   **書き込みは、書く対象が1つ以上あると確定してから**。

同時に、コメントには「`exit` は `try/finally` を抜けてから呼ぶ」と書きながら
**実装は `try` の中で `exit` していた**箇所も見つかった（Windows 版）。
→ 意図をコメントに書いた時点で満足せず、コードが実際にそうなっているか読み直す。

### 3-13. `Read(**/...)` の deny は作業フォルダの外に効かない（2026-08-14）★重要
`settings.json` にあった3行

```
"Read(**/.env)"  "Read(**/.env.*)"  "Read(**/secrets/**)"
```

は、**作業フォルダ配下にしか当たらない**。作業フォルダ外の絶対パスは素通りする。
Windows で先に発覚し、**Mac でも囮ファイルで同じ結果を再現した**（`~/Projects/_permtest/.env` を
そのまま読めた）。Claude Code のセッションは色々な場所で開くので、
**`~/.config/secrets/` は常に作業フォルダの外**。つまり一度も守られていなかった。

たちが悪いのは、`CLAUDE.md` に「`.env` を読まない」と書かれ deny も並んでいるため、
**守られているように見えていた**こと。**「ルールが書いてある」と「ルールが効いている」は別。**

→ macOS で効く形は `~/` 始まり。**囮ファイルで実測して確定した。**

```
"Read(~/**/.env)"  "Read(~/**/.env.*)"  "Read(~/**/secrets/**)"  "Read(~/.config/secrets/**)"
```

Windows は `//c/Users/<user>/...` 形式。既存の `**/...` 3行は作業フォルダ内では有効なので残す。
誤爆しないことも確認済み（`~/Projects/secrets-toolkit/maps/*.map` は読める。
ディレクトリ名が `secrets-toolkit` であって `secrets` ではないため）。
`secret-check` などの allow 側も無事。

★ **`settings.json` はこのリポジトリの管理外**。Mac と Windows で別々に直す必要があり、
新しいマシンでは**また同じ穴が開いている**。囮ファイルでの実測を最初にやること。

### 3-14. §3-3 の修正は片方の経路しか直っていなかった（2026-08-14）
**回帰テストの初回実行で見つかった実バグ。** `secrets-run` で存在しないコマンドを指定すると、
終了コードが **127 ではなく 1（場合によっては 0）** になっていた。成功と区別できない。

原因は §3-3 と同じ EXIT トラップだが、**効き方が経路で違う**:

| 経路 | 挙動 |
|---|---|
| `@file:` あり（`"$@"` → `exit $rc`） | **明示的な `exit N` はトラップに上書きされない** → §3-3 の修正で直っていた |
| `@file:` なし（`exec "$@"`） | exec 失敗時、bash は**本来の 127 を失ったまま**トラップを走らせる |

実測（`cleanup(){ return 0; }` + trap の下で存在しないコマンドを exec）:

```
トラップ無し            -> 127   （正しい）
トラップ有り・直接 exec ->   0   ★ 失敗が成功になる
トラップ有り・if の中   ->   1
```

**`cleanup` の書き方では直せない。** `local rc=$?; return $rc` にしても復元できなかった
（トラップ突入時点で既に失われている。実測済み）。
→ `exec` に渡す前に `command -v` で解決可否を確かめ、`127` / `126` を自分で返す。
   Windows 版も同じく 127 を返す（`$LASTEXITCODE` のリセット）ので、これで挙動が揃った。

教訓は **「§3-3 は直した」と書いてあったが、直っていたのは2経路のうち1つだけ**だったこと。
片方で確認して直ったと記録すると、残りは記録によって**見えなくなる**。

### 3-16. `install-mac.sh` が途中で死んでいて、対応表が一度も配られていなかった（2026-08-15）
`mac/tests/` を作った時点から、`for f in "$REPO"/mac/*` が**ディレクトリを `install` しようとして
失敗**し、`set -e` で**終了コード 71 のまま停止**していた。停止位置がスクリプト配置の直後なので、
その先の「対応表を配置」に一度も到達していない。**`.map` の更新が毎回手作業だったのはこれが原因。**

見えにくかった理由が2つ:

- **スクリプトは全部配られていた。** `tests` が名前順で最後だったという偶然による。
  つまり「動いているように見える」状態が続いた
- `./install-mac.sh >/dev/null 2>&1 && <次の処理>` と書いていたため、
  **失敗すると後続が黙って実行されない**。出力を捨てていたので気づけなかった

→ `[ -f "$f" ] || continue` を入れて修正。
→ あわせて `--update-maps` を追加した。既定は従来どおり**上書きしない**が、
   差分があるときに件数と反映コマンドを表示する（黙って古いままにしない）。
→ 教訓: **`>/dev/null 2>&1 && ...` は、失敗を「何も起きない」に変える。**
   終了コードを見ないなら繋げない。

同時に、配備先の `saiten-assistant.map` が正本より2行多いことも判明した
（`CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`）。配備先を直接編集したもので、
**正本を上書きすれば消えていた**。正本へ取り込み済み。
`~/.config/secrets/**` は Read が deny なので中身を直接読めず、
`secrets-run` に候補の変数名を渡して**長さだけ**を出させて特定した。

### 3-15. Mac の `secret-check` も「常に通る検査」だった（2026-08-14）
Windows 版は `a5d37e0` で直っていた（キャッシュを列挙してそのファイルの存在を確かめており
**常に通っていた**）。**Mac 版は同じ形のまま残っていた** — `registry.txt` は
「登録に成功した名前」の台帳なので、そこだけを見る検査はほぼ必ず通る。

見つけ方が示唆的で、**Windows は `shibehasu-site` で MISS を出すのに Mac は終了コード 0**
という食い違いから辿り着いた。**プラットフォーム間で答えが違うときは、
どちらかが壊れている。**
→ `.map` が参照する名前（＝実行時に本当に要るもの）を先に検査し、
   台帳にしかないものを後から足す形にした。どの `.map` が原因かも出す。
→ 直後に本物で MISS 1件（`api-token/cloudflare/shibehasu-site`）を検出。
   **この1件は §5-5 に書いてあったのに、Mac の `secret-check` は今日までずっと OK と言っていた。**

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

### 5-3. Bitwarden APIキーの再発行（急がない）
`bitwarden_API_keys.txt` が iCloud 圏内に平文で置かれていた。ただし**マスターパスワードは含まれず、
APIキー単体では金庫を復号できない**（E2E暗号化）ので緊急ではない。
再発行は Web 金庫のみ（`bw` CLI に該当コマンドが無い）。その後 `secret-rotate-bw` で反映。

### 5-4. Windows は残り2本が未移植
**目標は「Windows でも Mac と同等以上に使える、同期された環境」**（2026-08-14 に本人確認）。
Mac 11本 / **Windows 9本**。日々の運用は Windows だけで完結する。

未移植は **`secret-rotate-bw`**（Bitwarden APIキーの入れ替え・失敗時に自動巻き戻し）と
**`secret-push`**（Cloudflare Workers / GitHub Actions へ配布）の2本のみ。
どちらも頻度が低く、失敗したときの影響が大きい。**移植するなら Mac 版で1回通してから。**

`secret-pull` / `secret-verify` / `secret-list-remote` は Windows で検証済み（`801e6bd`、修正なし）。
`secret-verify` は合成値のみで9ケース、`secret-pull` は6ケース。**`secret-pull` の正しさは
「取り込んだ値が `secret-sync` の結果とハッシュ一致するか」で確かめた** — 値を出さずに
往復を検証できる筋の良い方法なので、今後もこの形を使う。

`secret-verify.ps1` はその後バイト列読みに作り直した（§3-11）が、**Windows で再検証済み**
（`d87419b`・8ケース通過。両端の空白除去を node の独立実装とも突き合わせている）。

`secret-push-bw.ps1` は Windows で**書き込み経路まで実証済み**（`221c20a`）。合成値を1件登録して
ハッシュ一致を確認し、そのあと消して金庫を元の26件に戻している。1行→ログイン項目、
複数行（日本語・改行込み）→セキュアメモ、日本語ラベルも正常。安全弁（`bundle/bitwarden/*` の拒否）、
重複スキップ、引数なし全件も期待どおり。

**base64 で渡す設計判断は実測で裏が取れた。** `$OutputEncoding` を PS 5.1 の既定（ASCII）に
戻して比較すると、base64 は無傷だが**生の UTF-8 JSON は `"???\r\n??????"` と日本語が全滅**する。
（測定時の注意: ハーネスが `$OutputEncoding` を UTF-8 にしている環境では**この差が見えない**。
ASCII を強制して測り直すこと。§3-9 と同じ「測り方が実環境と違う」問題。）

同じ Windows 側で残っている細かい差:

- **`secret-sync` の項目名の空白自動修正が Windows 未実装**（金庫への書き込みを伴うため見送り）。
  README にはこの差を明記した（`0f1cd0b`）。実装するか、Mac 側で年に数回流すかを決める
- **`service-account/app-store-connect/*` のローカルコピーが Windows に無い。**
  §2-3 の通り正本は `bundle/...` のメモ欄で、そこから純PEMを取り出す手当ては Mac 版にしかない。
  CI を Windows から回すなら別途必要
- キャッシュの `.dat` は DPAPI 暗号化済みで他ユーザーは復号できないが、
  フォルダの ACL は既定（SYSTEM / Administrators / 本人）。本人限定に絞る余地はある

### 5-5. その他
- **キーチェーンに孤児が2件**（`secret-sync`【2】に毎回出る）。**値はどちらも別の正しい名前で
  金庫にもキーチェーンにも残っている**ので消して失われるものは無い。
  **削除は破壊的なので本人が行う**（2026-08-15 にその方針で合意）。
  - `api-token/unverified/saiten-assistant-gcp` — `api-key/google/saiten-assistant` への改名の残骸
  - `saiten-access-setup (temporary)/cloudflare/api` — 金庫側が規約外の名前だった間に
    `secret-sync` がその名前のまま取り込んだもの。金庫側は
    `api-token/cloudflare/saiten-access-setup` へ改名済み（同じ値であることを照合で確認）
  - 消し方: `security delete-generic-password -a "$USER" -s "<名前>"`
- **`api-token/unverified/saiten-assistant-gcp` の正体は判明した**（2026-08-14）。
  saiten-assistant の `.env` の `GEMINI_API_KEY` と `GOOGLE_VISION_API_KEY` が**同一の値**で、
  どちらもこの項目と一致した。→ `api-key/google/saiten-assistant` へ改名済み（金庫・キーチェーンとも）。
- **金庫の項目名は `secret-sync` の入口**（2026-08-15 に2件やり直して確認）。
  規約外の名前（`civitai api key` / `saiten-access-setup (temporary)/cloudflare/api`）だと
  `secret-sync` が対応付けられず、`secret-pull` での個別取り込みに逃げることになる。
  さらに**そのまま同期すると規約外の名前がキーチェーン側にも増える**。
  スマホから項目を足したら、**まず金庫側で規約名に直してから** `secret-sync` を回すこと。
- `api-token/cloudflare/saiten-mirror-readonly` は形状からの推定で Cloudflare と判断。**要確認**
- `shibehasu-site.map` が参照する `api-token/cloudflare/shibehasu-site` は**未発行**。
  `secret-check` の唯一の MISS はこれ。発行は Cloudflare のダッシュボードでしかできない
- GitHub リカバリコードは金庫に入ったが、**紙の控えも1部**持っておくのが望ましい
- `bw_session.ps1`（別プロジェクト）は **`secrets-run.ps1` を使う経路に置き換わり、不要になった**
  （`b11852a` で `maps/listening-quiz-factory.map` を作成・検証済み）。ファイル自体は残っているので、
  誰かが実行すれば §3-2 の衝突は起きうる。`windows/SETUP.md`「併用してはいけないもの」を参照。
  なお `MINIMAX_API_KEY` / `MINIMAX_GROUP_ID` / `HF_TOKEN` はパイプラインが参照しているが
  **金庫に未登録**のため map に載せていない
- `api-key/elevenlabs/listening-quiz-factory`（2026-08-14 追加、登録28件目）。
  金庫・キーチェーンとも整備済み（フォルダ `listening-quiz-factory`）だが、
  **`.map` がまだ無いので `secrets-run` からは使えない。** プロジェクト実体も未作成。
  着手時に `maps/listening-quiz-factory.map` を作る:
  `ELEVENLABS_API_KEY=api-key/elevenlabs/listening-quiz-factory`（変数名はコード側に合わせる）

---

## 6. よく使うコマンド

```bash
secret-sync                          # 金庫→キーチェーン一括同期＋点検
secret-check                         # 登録状況（値は出ない）
secrets-run <profile> -- <コマンド>    # .secrets-profile があればプロファイル省略可
secret-list-remote                   # 金庫の項目名一覧
cd ~/Projects/secrets-toolkit && git pull && ./install-mac.sh   # ツールの更新
```
