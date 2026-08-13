# secret-bootstrap.ps1 — Windows 版 初回設定（対話端末で1回だけ実行）
#
#   Bitwarden の認証情報を DPAPI で暗号化して保存する。
#   DPAPI は「このWindowsユーザー・このPC」でしか復号できないため、
#   macOS のログインキーチェーンと同等の保護になる。
#
#   前提: bw コマンドが PATH にあること
#         winget install --id Bitwarden.CLI   または   npm i -g @bitwarden/cli
$ErrorActionPreference = 'Stop'
# Invoke-Bw を共有するため読み込む（bw の stderr で落ちないようにするラッパー）
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$ConfDir  = $script:ConfDir
$CredFile = $script:CredFile
New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null

if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
  Write-Error "bw コマンドが見つかりません。先に Bitwarden CLI を入れてください:`n  winget install --id Bitwarden.CLI"
}

# マスターパスワードを対話入力するため、標準入力が繋がった端末でしか実行できない。
# これは仕様。自動化・スクリプト経由の実行はここで止める。
if ([Console]::IsInputRedirected) {
  Write-Error "対話端末で実行してください。標準入力がリダイレクトされているため、マスターパスワードを安全に入力できません（この処理は自動化しない設計です）"
}

Write-Host "Bitwarden 連携の初回設定を行います。入力内容は画面に表示されません。`n"

$Email    = Read-Host "Bitwarden のメールアドレス"
$ClientId = Read-Host "client_id"       -AsSecureString
$ClientSec= Read-Host "client_secret"   -AsSecureString
$MasterPw = Read-Host "マスターパスワード" -AsSecureString
$MasterPw2= Read-Host "マスターパスワード（確認）" -AsSecureString

function Plain([System.Security.SecureString]$s) {
  # BSTR は必ず ZeroFreeBSTR で解放する（平文を非管理メモリに残さない）
  $bstr = [IntPtr]::Zero
  try {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

if ((Plain $MasterPw) -ne (Plain $MasterPw2)) { Write-Error "マスターパスワードが一致しません" }

$env:BW_CLIENTID     = Plain $ClientId
$env:BW_CLIENTSECRET = Plain $ClientSec
$env:BW_PASSWORD     = Plain $MasterPw

Write-Host "`n== ログイン確認 =="
# bw の呼び出しは必ず Invoke-Bw を通す。素の `bw ... *>$null` は、bw が情報メッセージを
# stderr に書いた時点で ErrorRecord 化され、終了コード 0 でもここで落ちる。
if ((Invoke-Bw login --check).ExitCode -ne 0) {
  if ((Invoke-Bw login --apikey --quiet).ExitCode -ne 0) {
    Write-Error "bw login に失敗しました。client_id / client_secret を確認してください"
  }
}
Write-Host "  ログイン成功"

Write-Host "== ヘッドレス解錠の確認 =="
$u = Invoke-Bw unlock --passwordenv BW_PASSWORD --raw
$session = $u.Output
if ($u.ExitCode -ne 0 -or -not $session) {
  Write-Error "bw unlock に失敗しました。マスターパスワードを確認してください"
}
# セッションが本当に有効か、実際に金庫を読んで確かめる（既知のリグレッション対策）
if ((Invoke-Bw list items --session $session).ExitCode -ne 0) {
  Write-Error "セッションは返りましたが金庫が解錠されていません。bw 2026.3.0 / 2026.4.1 の既知不具合です。`n  npm install -g @bitwarden/cli@2026.1.0 でピン留めしてください"
}
Write-Host "  解錠成功（金庫の読み出しまで確認）"

Write-Host "== DPAPI で暗号化して保存 =="
$payload = @{
  email        = $Email
  clientId     = $env:BW_CLIENTID
  clientSecret = $env:BW_CLIENTSECRET
  masterPw     = $env:BW_PASSWORD
} | ConvertTo-Json -Compress

# ConvertFrom-SecureString は鍵を指定しない場合 DPAPI(CurrentUser) で暗号化する
$enc = ConvertTo-SecureString $payload -AsPlainText -Force | ConvertFrom-SecureString
Set-Content -Path $CredFile -Value $enc -Encoding ASCII
Write-Host "  保存しました: $CredFile"

[void](Invoke-Bw lock)
Remove-Item Env:BW_CLIENTID, Env:BW_CLIENTSECRET, Env:BW_PASSWORD -ErrorAction SilentlyContinue

Write-Host "`n完了しました。次に secret-sync.ps1 を実行すると金庫の全項目が取り込まれます。"
