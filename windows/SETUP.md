# Windows での秘密情報運用 セットアップ手順

> **⚠️ このスクリプト群は macOS 上で書かれており、Windows で未検証です。**
> 動かない箇所があれば Windows 側の Claude Code セッションに
> このファイルを読ませて修正させてください。値が漏れる設計にはなっていませんが、
> 初回は `-DryRun` や `secret-check.ps1` から試すことを勧めます。

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

## 手順2. スクリプトを配置する

`windows\` フォルダの5ファイルを `%USERPROFILE%\.local\bin\` に置きます。

- `_secret-common.ps1`（共通処理・単体実行しない）
- `secret-bootstrap.ps1`
- `secret-sync.ps1`
- `secrets-run.ps1`
- `secret-check.ps1`

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

## 動作確認のしかた（値を出さずに確かめる）

シングルクォートで囲むこと（ダブルクォートだと `$env:` が呼び出し側で先に展開されてしまい、
**値がコマンドライン履歴に残ります**）。

```powershell
secrets-run.ps1 voice -- powershell -NoProfile -Command 'Write-Host ("DEEPGRAM_API_KEY の長さ: " + $env:DEEPGRAM_API_KEY.Length); try { Get-Content $env:GOOGLE_APPLICATION_CREDENTIALS -Raw | ConvertFrom-Json > $null; Write-Host "JSON妥当性: OK" } catch { Write-Host "JSON妥当性: NG" }'
```

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
