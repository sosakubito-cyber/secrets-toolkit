# Windows での秘密情報運用 セットアップ手順

> **検証済み**: Windows 11 / Windows PowerShell 5.1 (ja-JP, CP932) / Bitwarden CLI 2026.7.0。
> 実際の金庫に接続し、bootstrap → sync（25件取り込み）→ check → secrets-run の
> 全工程を実機で通してあります。`@file:` の GCP 認証 JSON が node の `JSON.parse` を
> 通ること、コマンド終了時に一時ファイルが消えること、終了コードが伝播することを
> 実データで確認済み。値が漏れる設計にはなっていませんが、初回は `-DryRun` や
> `secret-check.ps1` から試すことを勧めます。

## 変更したら回帰テストを回す

```powershell
.\windows\tests\run-tests.ps1              # 金庫に触れないテストだけ
.\windows\tests\run-tests.ps1 -WithVault   # 金庫を開くテストも含める
```

合成値のみを使い、**テスト中は `$env:USERPROFILE` を一時フォルダへ向ける**ので、
本物の `%USERPROFILE%\.config\secrets` には触れません。

下の「落とし穴」は文章で書いてあるだけでは守れませんでした（実際に、注意書きのある
箇所を後から壊しています）。**テストが本体で、下の説明はその理由書**だと考えてください。

## Windows 固有の落とし穴（修正済み・触るときは注意）

以下は macOS では起きず Windows でだけ壊れる箇所です。編集時に戻さないでください。
すべて `windows/tests/run-tests.ps1` が検査しています。

1. **`.ps1` は UTF-8 BOM 付きで保存する。**
   PS 5.1 は BOM が無い `.ps1` を ANSI（日本語環境では CP932）として読みます。
   日本語コメント行の末尾が CP932 のリードバイトになると**直後の改行を食って
   次の行が消えます**。メッセージが文字化けするだけでなく、コードが1行黙って
   消えるため、極めて発見しにくい壊れ方をします。

2. **`.map` の読み込みは `Get-Content -Encoding UTF8` を明示する。**
   `.map` は Mac と共通ファイルなので BOM を付けられません。上と同じ理由で、
   エンコーディングを明示しないと項目が1つ黙って減ります。

3. **PowerShell は素の `--` を引数から取り除く。**
   詳細は下の「`--` の書き方」を参照。

4. **`Set-Content -Encoding UTF8` は BOM を付ける。**
   `@file:` で書き出す認証 JSON に BOM が付くと Google のクライアント
   ライブラリが読めません。`secrets-run.ps1` は BOM 無しで書き出します。
   なお **PowerShell の `ConvertFrom-Json` は BOM を許容してしまう**ため、
   PowerShell だけで検証すると「OK」と出て見逃します。

## Mac 版との違い

| | Mac | Windows |
|---|---|---|
| 秘密の保管 | macOS キーチェーン | **DPAPI 暗号化ファイル**（`%USERPROFILE%\.config\secrets\cache\`） |
| 保護の範囲 | ログイン中のユーザー | **このWindowsユーザー・このPCでのみ復号可**（同等の強度） |
| 正本 | Bitwarden（共通） | Bitwarden（共通） |

Bitwarden が正本なので、**Mac と Windows で同じ秘密が同じ名前で使えます。**
片方で `secret-push-bw` すれば、もう片方は `secret-sync.ps1` で取り込めます。

## 手順1. Bitwarden CLI を入れる

```powershell
winget install --id Bitwarden.CLI
```

Node.js があるなら `npm i -g @bitwarden/cli` でも可（更新が楽）。

確認：

```powershell
bw --version
```

`2026.3.0` または `2026.4.1` が出た場合は、ヘッドレス解錠が壊れている既知バージョンです。
`npm install -g @bitwarden/cli@2026.1.0` でピン留めしてください。

バージョン番号だけで判断せず、`secret-bootstrap.ps1` の解錠チェックを信用してください。
同スクリプトは `bw unlock` の戻り値だけでなく**実際に金庫を1回読んで**確認します
（このリグレッションは「セッションは返るのに金庫は施錠のまま」という形で出るため、
バージョン番号での判定だけでは取りこぼします）。2026.7.0 は実機で正常動作を確認済み。

## 手順2. スクリプトを配置する

`windows\` フォルダの10ファイルを `%USERPROFILE%\.local\bin\` に置きます。

- `_secret-common.ps1`（共通処理・単体実行しない）
- `secret-bootstrap.ps1`
- `secret-sync.ps1`
- `secrets-run.ps1`
- `secret-check.ps1`
- `secret-put.ps1`
- `secret-push-bw.ps1`
- `secret-pull.ps1`
- `secret-verify.ps1`
- `secret-list-remote.ps1`

`.ps1` は **UTF-8 BOM 付きのまま**コピーしてください（理由は冒頭の落とし穴1）。

PATH に追加：

```powershell
[Environment]::SetEnvironmentVariable('Path', $env:Path + ";$env:USERPROFILE\.local\bin", 'User')
```

PowerShell の実行ポリシーが厳しい場合：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## 手順3. 対応表を置く

`%USERPROFILE%\.config\secrets\` に以下の `.map` を作ります。
**秘密は一切含まれていません**（キーチェーン上の「名前」だけ）。

`answer-prompter.map`
```
OPENAI_API_KEY=api-key/openai/answer-prompter
```

`opportunity-radar.map`
```
OPENAI_API_KEY=api-key/openai/general
```

`grading.map`
```
OPENAI_API_KEY=api-key/openai/homework-scoring
GEMINI_API_KEY=api-key/gemini/aistudio
```

`saiten-assistant.map`
```
OPENAI_API_KEY=api-key/openai/saiten-assistant
REPRO_PASSCODE=app-password/saiten-assistant/staging
OPENROUTER_API_KEY=api-key/openrouter/saiten-assistant
```

`voice.map`
```
DEEPGRAM_API_KEY=api-key/deepgram/main
GOOGLE_APPLICATION_CREDENTIALS=@file:service-account/gcp/speech
```

`default.map`
```
ANTHROPIC_API_KEY=api-key/anthropic/test-scoring
OPENAI_API_KEY=api-key/openai/general
```

`shibehasu-site.map`（トークン未発行のため、発行するまでこのプロファイルは使えません）
```
CLOUDFLARE_API_TOKEN=api-token/cloudflare/shibehasu-site
```

## 手順4. 初回設定（対話端末で1回だけ）

```powershell
secret-bootstrap.ps1
```

Bitwarden のメールアドレス、client_id、client_secret、マスターパスワードを聞かれます。
**入力は画面に表示されません。チャットに貼らないでください。**

client_id / client_secret は `https://vault.bitwarden.com` →
設定 → セキュリティ → キー → 「APIキーを表示」で確認できます。

### 起動できない場合

実機で実際に踏んだ順に2つあります。

**1. コマンドプロンプトで実行している**

プロンプトが `C:\Users\thebi>` なら cmd.exe です。PowerShell は先頭に `PS` が付いて
`PS C:\Users\thebi>` になります。cmd では `.ps1` を打っても実行されません
（既定の関連付けで開こうとするだけで、エラーすら出ないことがあります）。
`Win + R` → `powershell` で開き直してください。

**2. 実行ポリシーで拒否される**

> このシステムではスクリプトの実行が無効になっているため…

PowerShell は起動時の実行ポリシーを保持するため、`Set-ExecutionPolicy` を実行する
**前**から開いていたウィンドウでは反映されません。開き直すか、システム設定を
一切変更せずにその1回だけ迂回する次の形で実行してください。

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.local\bin\secret-bootstrap.ps1"
```

## 対応表を更新する（`.map` を手で書かない）

**`.map` の正本は secrets-toolkit リポジトリの `maps/`。** 配備先
（`%USERPROFILE%\.config\secrets\`）を直接編集しないでください。編集しても次の配布で
戻りますし、Mac 側の正本と食い違ったまま気づけなくなります。

Mac 側で `maps/` に行が足されたら、Windows ではこの2つだけです。

```powershell
git -C <secrets-toolkitのパス> pull
```

```powershell
Copy-Item <secrets-toolkitのパス>\maps\*.map "$env:USERPROFILE\.config\secrets\" -Force
```

そのあと `secret-check.ps1` で新しい項目が `OK` になれば配線完了です。
（Mac 側は `./install-mac.sh --update-maps` が同じことをします。）

新しい鍵を足す手順は「金庫へ登録 → Mac 側で `maps/` に1行 → 両機で上記2コマンド」です。

## 手順5. 金庫から取り込む

```powershell
secret-sync.ps1 -DryRun    # まず確認だけ
secret-sync.ps1            # 実行
secret-check.ps1           # 結果確認（値は出ない）
```

## 使い方

```powershell
secrets-run.ps1 answer-prompter -- npm test
secrets-run.ps1 -- python scripts/grade.py    # .secrets-profile を自動検出
```

### 手元の値を登録する（`secret-put.ps1`）

```powershell
Get-Content sa.json -Raw | secret-put.ps1 service-account/gcp/speech
```

**値は必ず標準入力から渡します。** 引数に書くと平文がコマンド履歴に残ります。
登録後に読み戻してハッシュで照合し、文字数と結果だけを表示します（値は出ません）。

Mac 版と違い base64 格納はしません。macOS の `security(1)` は改行入りの値を16進で
返すため往復が壊れますが、DPAPI は改行・CRLF・UTF-8 をそのまま往復できます。

`secret-put.ps1` が書くのは**ローカルのキャッシュだけ**です。正本は Bitwarden なので、
別マシンでも使う値は続けて金庫へ入れてください（次項）。

### 金庫へ保存する（`secret-push-bw.ps1`）

```powershell
secret-push-bw.ps1 --folder listening-quiz-factory api-key/elevenlabs/listening-quiz-factory
secret-push-bw.ps1                                  # 引数なしならローカル全件
```

**`secret-put.ps1` だけで終えると、その値はその PC にしか存在しません。**
Bitwarden が正本という前提（README「設計上の約束」）から外れるので、必ず続けて実行してください。

- 同名の項目が金庫に既にある場合は**上書きせずスキップ**します
- 1行の値は「ログイン」項目、複数行の値は「セキュアメモ」項目になります（Mac 版と同じ）
- フォルダ名は `secrets-run` のプロファイル名に合わせます。未定なら `_unassigned`
- **`bundle/bitwarden/*` は名指ししても拒否します。** 金庫を開ける鍵を金庫に入れると
  循環依存になり、マスターパスワードが「開けたい金庫の中」に入ってしまうためです
- 値は `bw` の**標準入力**へ渡します。引数に載せると同一ユーザーの他プロセスから
  コマンドラインが見え、PowerShell の transcript にも残るためです

### 金庫から1件だけ取り込む（`secret-pull.ps1`）

```powershell
secret-list-remote.ps1                                          # まず金庫の項目名を見る（値は出ない）
secret-pull.ps1 api-key/elevenlabs/listening-quiz-factory api-key/elevenlabs/listening-quiz-factory
secret-pull.ps1 service-account/gcp/speech service-account/gcp/speech --notes
```

スマホで登録した鍵を1件だけ入れたいときに使います。全件なら `secret-sync.ps1` の方が速いです。
**複数行の値（サービスアカウント JSON など）は `--notes`** を付けてください。
`password` 欄ではなくセキュアメモ欄から取り出します。

項目名は Bitwarden 側とローカル側で**同じ名前にする**のが約束です
（`secret-pull.ps1 <名前> <同じ名前>`）。取り込み後に読み戻してハッシュで照合します。

### 原本と照合する（`secret-verify.ps1`）

```powershell
secret-verify.ps1 api-key/openai/general C:\path\to\original.txt
secret-verify.ps1 api-key/openai/general C:\path\to\original.txt firstline
```

「一致」「不一致」だけを出します。**値もハッシュ値も出しません。** 金庫にも触れません。

Mac 版にある `rtf` モードはありません（`textutil` 相当が無いため）。RTF の原本は Mac 側で照合してください。

原本は**バイト列のまま**ハッシュします。`Get-Content` で読むと BOM が落ち、同じファイルでも
Mac 版と判定が食い違う（「Mac では不一致・Windows では一致」）ためです。
Mac 版の `cat | trim | shasum` と16ケースでハッシュ一致を確認済み
（BOM・CRLF・前後の空白・複数行・日本語・空白のみ、各 plain / firstline）。
Windows 側でも実行して確認済み（両端の空白除去は node の独立実装ともハッシュ一致）。

**BOM 付きの原本は「不一致」になります**（Mac / Windows とも）。バイト列が実際に
異なるためで、仕様どおりの挙動です。メモ帳などで原本を保存し直すと BOM が付くことが
あるので、身に覚えのない「不一致」が出たらまず BOM を疑ってください。

### `--` の書き方（Windows 固有）

PowerShell のパーサは素の `--` を「パラメータ終端」トークンとみなし、
**引数配列から取り除きます**（取り除かれるのは最初の1個だけで、他の引数の順序は保たれる）。
そのため `secrets-run.ps1` は次の2通りを自動で判別します。

| 呼び出し方 | `--` は | 判別方法 |
|---|---|---|
| PowerShell から `secrets-run.ps1 voice -- npm test` | 消える | 先頭が profile 名か（同名の `.map` があるか）で判定 |
| `secrets-run.ps1 voice '--' npm test`（クォート） | 残る | `--` の位置で分割 |
| cmd.exe から `powershell -File ...` | 残る | `--` の位置で分割 |

上の表のどれでも動くので、**普段は素の `--` のままで構いません。**

profile 名と同名のコマンドが存在する場合だけ判別できないため、その時は
エラーで止まり `'--'` をクォートするよう案内します。

## 動作確認のしかた（値を出さずに確かめる）

シングルクォートで囲むこと（ダブルクォートだと `$env:` が呼び出し側で先に展開されてしまい、
**値がコマンドライン履歴に残ります**）。

```powershell
secrets-run.ps1 voice -- powershell -NoProfile -Command 'Write-Host ("DEEPGRAM_API_KEY の長さ: " + $env:DEEPGRAM_API_KEY.Length); $b=[IO.File]::ReadAllBytes($env:GOOGLE_APPLICATION_CREDENTIALS); Write-Host ("BOM が付いていない: " + (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))); Write-Host ("JSON妥当性: " + $(try { [Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json > $null; "OK" } catch { "NG" }))'
```

`BOM が付いていない: True` と `JSON妥当性: OK` の**両方**を確認してください。
BOM の確認を省いてはいけません — PowerShell の `ConvertFrom-Json` は BOM 付きでも
`OK` を返しますが、Google のクライアントライブラリ（node の `JSON.parse` 等）は
BOM 付き JSON を読めずに失敗します。

終了コードが正しく伝わるかも確認してください（Mac 版で実際に踏んだ不具合です）：

```powershell
secrets-run.ps1 voice -- cmd /c "exit 42"
$LASTEXITCODE   # 42 になるはず
```

## Windows でやってはいけないこと

- キーの値をチャットに貼る（会話ログに残ります）
- `.txt` でデスクトップに置く
- `cache\*.dat` を git に入れる（DPAPI暗号化済みだが、そもそも同期する意味がない。
  別PCでは復号できません。**移行は必ず Bitwarden 経由で行ってください**）
- **`bw` を自前で解錠・施錠するスクリプトと併用する**（次項）

## 併用してはいけないもの: `bw` を直接叩く別スクリプト

このツール群のコマンドは、**終了時にかならず `bw lock` します**
（`_secret-common.ps1` の `Close-BwSession`）。例外はありません。

そのため、`bw unlock` のセッショントークンを自前で保存して使い回すスクリプトと併用すると、
**こちらのコマンドを1回実行しただけで、相手のセッションが無効になります。**
逆に相手が `bw lock` すると、こちらの実行中のセッションが壊れます。
`bw` は単一の状態ファイル（`%AppData%\Bitwarden CLI\data.json`）を共有していて、
**壊れても bw はエラーを返さず空の結果を終了コード 0 で返す**ため（冒頭の「落とし穴」と同じ問題）、
症状は「金庫が空に見える」という形で出ます。原因にたどり着きにくい壊れ方です。

併用したい場合は、相手側を次のどちらかに合わせてください。

1. `secrets-run.ps1` 経由で値を受け取る形に変える（推奨。セッションを持ち回らなくて済む）
2. 最低限、`Lock-BwCli` と同じ名前付き Mutex（`Local\secrets-toolkit-bw`）を取ってから
   `bw` を呼び、セッショントークンを**永続化しない**

なお、セッショントークンをユーザー環境変数（`HKCU\Environment`）に置くのは避けてください。
再起動しても残り、同一ユーザーの全プロセスから読め、全子プロセスに継承されます。
このツール群が DPAPI 暗号化・コマンドごとの開閉・終了時ロックにしているのは、これを避けるためです。
