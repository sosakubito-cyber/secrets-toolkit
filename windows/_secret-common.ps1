# _secret-common.ps1 — Windows 版の共通処理。単体では実行しない。
#
#   保管場所:
#     %USERPROFILE%\.config\secrets\bw.cred        Bitwarden認証情報（DPAPI暗号化）
#     %USERPROFILE%\.config\secrets\cache\*.dat    秘密の値のキャッシュ（DPAPI暗号化）
#     %USERPROFILE%\.config\secrets\*.map          対応表（秘密を含まない・Macと共通）
#
#   DPAPI(CurrentUser) は「このWindowsユーザー・このPC」でしか復号できない。

$script:ConfDir  = Join-Path $env:USERPROFILE '.config\secrets'
$script:CacheDir = Join-Path $script:ConfDir 'cache'
$script:CredFile = Join-Path $script:ConfDir 'bw.cred'

function Get-SecretPathFor([string]$Name) {
  # 名前に / が入るのでファイル名用に置換する
  $safe = $Name -replace '[\\/:*?"<>|]', '__'
  Join-Path $script:CacheDir "$safe.dat"
}

function Protect-Text([string]$Text) {
  ConvertTo-SecureString $Text -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-Text([string]$Encrypted) {
  # BSTR は必ず ZeroFreeBSTR で解放する。放置すると平文が非管理メモリに残る。
  $ss = ConvertTo-SecureString $Encrypted
  $bstr = [IntPtr]::Zero
  try {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $ss.Dispose()
  }
}

function Set-CachedSecret([string]$Name, [string]$Value) {
  New-Item -ItemType Directory -Force -Path $script:CacheDir | Out-Null
  Set-Content -Path (Get-SecretPathFor $Name) -Value (Protect-Text $Value) -Encoding ASCII
}

function Get-CachedSecret([string]$Name) {
  $p = Get-SecretPathFor $Name
  if (-not (Test-Path $p)) { return $null }
  Unprotect-Text (Get-Content -Path $p -Raw).Trim()
}

function Test-CachedSecret([string]$Name) { Test-Path (Get-SecretPathFor $Name) }

function Get-NameFromCacheFile([string]$BaseName) {
  # Get-SecretPathFor の逆変換。区切りに使った __ を / に戻す。
  $BaseName -replace '__', '/'
}

function Get-BwCredentials {
  if (-not (Test-Path $script:CredFile)) {
    throw "未設定です。先に secret-bootstrap.ps1 を実行してください"
  }
  (Unprotect-Text (Get-Content -Path $script:CredFile -Raw).Trim()) | ConvertFrom-Json
}

function Open-BwSession {
  # Bitwarden にログイン・解錠し、セッションキーを返す
  $c = Get-BwCredentials
  $env:BW_CLIENTID     = $c.clientId
  $env:BW_CLIENTSECRET = $c.clientSecret
  $env:BW_PASSWORD     = $c.masterPw

  bw login --check *>$null
  if ($LASTEXITCODE -ne 0) {
    bw login --apikey --quiet *>$null
    if ($LASTEXITCODE -ne 0) { throw "bw login に失敗しました" }
  }
  $s = (bw unlock --passwordenv BW_PASSWORD --raw 2>$null)
  if (-not $s) { throw "bw unlock に失敗しました" }
  $s
}

function Close-BwSession {
  bw lock *>$null
  # BW_CLIENTID も必ず消す（消し忘れると後続プロセスに引き継がれる）
  Remove-Item Env:BW_CLIENTID, Env:BW_CLIENTSECRET, Env:BW_PASSWORD -ErrorAction SilentlyContinue
}

function Get-SecretMapPath([string]$ProfileName) {
  Join-Path $script:ConfDir "$ProfileName.map"
}

function Test-SecretMap([string]$ProfileName) {
  if ([string]::IsNullOrWhiteSpace($ProfileName)) { return $false }
  Test-Path (Get-SecretMapPath $ProfileName)
}

function Get-SecretProfiles {
  if (-not (Test-Path $script:ConfDir)) { return @() }
  @(Get-ChildItem $script:ConfDir -Filter *.map | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Read-SecretMap([string]$ProfileName) {
  # <環境変数名>=<キーチェーン名> の行を読む。# 以降はコメント。
  $map = Get-SecretMapPath $ProfileName
  if (-not (Test-Path $map)) { throw "対応表がありません: $map" }
  # -Encoding UTF8 は必須。省略すると PS 5.1 は .map を ANSI(日本語環境では CP932)
  # として読み、日本語コメント行の末尾が CP932 のリードバイトになった場合に
  # 直後の改行を食って次の行が消える（= 項目が黙って1つ減る）。
  Get-Content $map -Encoding UTF8 | ForEach-Object {
    $line = ($_ -split '#', 2)[0].Trim()
    if ($line) {
      $i = $line.IndexOf('=')
      if ($i -lt 1) { throw "対応表の書式が不正です: $line" }
      [pscustomobject]@{
        Var  = $line.Substring(0, $i).Trim()
        Name = $line.Substring($i + 1).Trim()
      }
    }
  }
}
