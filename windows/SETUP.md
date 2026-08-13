# Windows での秘密情報運用 セットアップ手順

> **検証済み**: Windows 11 / Windows PowerShell 5.1 (ja-JP, CP932) / Bitwarden CLI 2026.7.0。
> 実際の金庫に接続し、bootstrap → sync（25件取り込み）→ check → secrets-run の
> 全工程を実機で通してあります。`@file:` の GCP 認証 JSON が node の `JSON.parse` を
> 通ること、コマンド終了時に一時ファイルが消えること、終了コードが伝播することを
> 実データで確認済み。値が漏れる設計にはなっていませんが、初回は `-DryRun` や
> `secret-check.ps1` から試すことを勧めます。

## Windows 固有の落とし穴（修正済み・触るときは注意）

以下は macOS では起きず Windows でだけ壊れる箇所です。編集時に戻さないでください。

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

`windows\` フォルダの6ファイルを `%USERPROFILE%\.local\bin\` に置きます。

- `_secret-common.ps1`（共通処理・単体実行しない）
- `secret-bootstrap.ps1`
- `secret-sync.ps1`
- `secrets-run.ps1`
- `secret-check.ps1`
- `secret-put.ps1`

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
別マシンでも使う値は Web 金庫にも同名で登録してください
（`secret-push-bw` は Windows 未移植）。

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
