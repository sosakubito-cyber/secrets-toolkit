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

function Get-SecretHash([string]$Text) {
  # 値そのものを出さずに一致を確かめるための照合用。表示してよいのは一致/不一致だけ。
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) |
      ForEach-Object { $_.ToString('x2') }) -join ''
  } finally { $sha.Dispose() }
}

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

function Invoke-Bw {
  # bw の呼び出しは必ずこれを通す。直接 `bw ... *>$null` と書いてはいけない。
  #
  #   bw は情報メッセージ（例: "Could not find dir, ...; creating it instead."）を
  #   stderr に書く。PS 5.1 では native コマンドの stderr をリダイレクトすると
  #   ErrorRecord に変換されるため、$ErrorActionPreference='Stop' の下では
  #   終了コードが 0 でもスクリプト全体が落ちる。bash の 2>&1 には無い挙動で、
  #   Mac 版には存在しない問題。ここだけ Continue にして受け止める。
  #
  #   戻り値: ExitCode と Output(stdout のみ)。値を含みうるので呼び出し側で表示しないこと。
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$BwArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $merged = & bw @BwArgs 2>&1
    $code   = $LASTEXITCODE
    # stderr 由来の ErrorRecord は捨て、stdout の行だけを残す
    $stdout = @($merged |
      Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
      ForEach-Object { [string]$_ })
    [pscustomobject]@{
      ExitCode = $code
      Output   = ($stdout -join "`n").Trim()
    }
  } finally { $ErrorActionPreference = $prev }
}

function Invoke-BwStdin {
  # 標準入力を渡す版の Invoke-Bw。`bw create item` は encode 済み JSON を
  # 標準入力からも受け取る。引数で渡すと**秘密がコマンドラインに載る**
  # （同一ユーザーの他プロセスから見え、PowerShell の transcript にも残る）ため、
  # 値を含むものは必ずこちらを使う。
  #
  #   $InputText に渡すのは base64（ASCII のみ）に限ること。PS 5.1 の $OutputEncoding
  #   は既定が ASCII で、native コマンドへのパイプはこれで符号化される。非 ASCII を
  #   直接流すと文字化けする。JSON の UTF-8 符号化は呼び出し側が
  #   [Text.Encoding]::UTF8.GetBytes → ToBase64String で確定させる。
  param(
    [Parameter(Mandatory = $true)][string]$InputText,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$BwArgs
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $merged = $InputText | & bw @BwArgs 2>&1
    $code   = $LASTEXITCODE
    $stdout = @($merged |
      Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
      ForEach-Object { [string]$_ })
    [pscustomobject]@{
      ExitCode = $code
      Output   = ($stdout -join "`n").Trim()
    }
  } finally { $ErrorActionPreference = $prev }
}

function ConvertTo-BwEncoded([string]$Json) {
  # `bw encode` と同じ base64 化を PowerShell 側で行う。外部プロセスに平文を
  # 渡す回数を1回減らせるうえ、UTF-8 のバイト列を自分で確定できる。
  [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Json))
}

# --- bw の排他制御 -----------------------------------------------------------
#   bw CLI は単一の状態ファイル（%AppData%\Bitwarden CLI\data.json）を共有する。
#   複数のセッションが同時に bw を使うと、後発の `bw lock` が先行セッションの鍵を
#   破壊し、エラーにならず空の結果が返る（終了コードも 0）。「金庫が空」という
#   誤った結論を招くため、排他ロックと結果の妥当性検証を行う。
#   Mac 版は ~/.config/secrets/.bw.lock のロックディレクトリ + PID 生死判定だが、
#   Windows では名前付き Mutex を使う。保持プロセスが死ぬと OS が自動的に解放する
#   （AbandonedMutexException）ため、古いロックの手動掃除が要らない。
$script:BwMutex   = $null
$script:BwSession = $null

function Lock-BwCli {
  $timeoutSec = if ($env:BW_LOCK_TIMEOUT) { [int]$env:BW_LOCK_TIMEOUT } else { 180 }
  $created = $false
  $m = New-Object System.Threading.Mutex($false, 'Local\secrets-toolkit-bw', [ref]$created)
  $acquired = $false
  try {
    $acquired = $m.WaitOne(0)
    if (-not $acquired) {
      Write-Host "他のセッションが Bitwarden を使用中です。待機します..." -ForegroundColor Yellow
      $acquired = $m.WaitOne([TimeSpan]::FromSeconds($timeoutSec))
    }
  } catch [System.Threading.AbandonedMutexException] {
    # 保持していたプロセスが死んだ場合。所有権はこちらに移っている。
    $acquired = $true
  }
  if (-not $acquired) {
    $m.Dispose()
    throw "他のセッションが Bitwarden を使用中です（${timeoutSec}秒待機しても解放されませんでした）。終わるのを待ってから再実行してください"
  }
  $script:BwMutex = $m
}

function Unlock-BwCli {
  if ($script:BwMutex) {
    try { $script:BwMutex.ReleaseMutex() } catch { }
    $script:BwMutex.Dispose()
    $script:BwMutex = $null
  }
}

function Open-BwSession {
  # Bitwarden にログイン・解錠し、セッションキーを返す
  Lock-BwCli
  try {
    $c = Get-BwCredentials
    $env:BW_CLIENTID     = $c.clientId
    $env:BW_CLIENTSECRET = $c.clientSecret
    $env:BW_PASSWORD     = $c.masterPw

    if ((Invoke-Bw login --check).ExitCode -ne 0) {
      if ((Invoke-Bw login --apikey --quiet).ExitCode -ne 0) {
        throw "bw login に失敗しました。client_id / client_secret を確認してください"
      }
    }
    $u = Invoke-Bw unlock --passwordenv BW_PASSWORD --raw
    $s = $u.Output
    if ($u.ExitCode -ne 0 -or -not $s) { throw "bw unlock に失敗しました。マスターパスワードを確認してください" }

    # 「セッションは返るが金庫は施錠のまま」（bw 2026.3.0/2026.4.1 の既知不具合）と、
    # 他プロセスに鍵を壊された場合の両方をここで検出する
    if ((Invoke-Bw list items --session $s).ExitCode -ne 0) {
      throw "セッションは返りましたが金庫を読めません`n  bw が 2026.3.0 / 2026.4.1 なら既知不具合です: npm install -g @bitwarden/cli@2026.1.0"
    }

    $script:BwSession = $s
    $s
  } catch {
    # ロックを握ったまま抜けない
    Remove-Item Env:BW_CLIENTID, Env:BW_CLIENTSECRET, Env:BW_PASSWORD -ErrorAction SilentlyContinue
    Unlock-BwCli
    throw
  }
}

function Get-BwItems {
  # 金庫の全項目を取得する。取得できなければ「空」ではなく失敗として扱う。
  # 鍵を壊されると bw は終了コード 0 のまま空を返すことがあるため。
  if (-not $script:BwSession) { throw "セッションが開かれていません" }
  $r = Invoke-Bw list items --session $script:BwSession
  if ($r.ExitCode -ne 0) { throw "金庫の項目を取得できませんでした（bw が終了コード $($r.ExitCode) を返しました）" }
  $raw = $r.Output
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "金庫の項目を取得できませんでした（空の応答）。他のセッションが bw を操作した可能性があります。終わるのを待ってから再実行してください"
  }
  if ($raw -eq '[]') { return @() }   # 本当に空の金庫は正当
  try { $items = $raw | ConvertFrom-Json } catch {
    throw "金庫の項目を取得できませんでした（JSON として解釈できません）"
  }
  if ($null -eq $items) {
    throw "金庫の項目を取得できませんでした（配列が返りませんでした）"
  }
  # ここで `,@($items)` としてはいけない。呼び出し側は @(Get-BwItems) で受けるため、
  # 外側の1要素配列が展開されて「常に1件」になる。
  @($items)
}

function Get-BwFolders {
  # フォルダ一覧。項目と同じ理由で、空応答を「フォルダが1つも無い」と解釈させない。
  # 空に化けたまま進むと、既にあるフォルダをもう一度作ってしまう。
  if (-not $script:BwSession) { throw "セッションが開かれていません" }
  $r = Invoke-Bw list folders --session $script:BwSession
  if ($r.ExitCode -ne 0) { throw "金庫のフォルダ一覧を取得できませんでした（bw が終了コード $($r.ExitCode) を返しました）" }
  $raw = $r.Output
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "金庫のフォルダ一覧を取得できませんでした（空の応答）。他のセッションが bw を操作した可能性があります"
  }
  if ($raw -eq '[]') { return @() }
  try { $folders = $raw | ConvertFrom-Json } catch {
    throw "金庫のフォルダ一覧を取得できませんでした（JSON として解釈できません）"
  }
  if ($null -eq $folders) { throw "金庫のフォルダ一覧を取得できませんでした（配列が返りませんでした）" }
  @($folders)
}

function Get-CachedSecretNames {
  # ローカルキャッシュに入っている秘密の名前一覧（値は読まない）。
  # Mac 版の registry.txt に相当する。Windows は .dat の存在そのものが台帳。
  if (-not (Test-Path $script:CacheDir)) { return @() }
  @(Get-ChildItem $script:CacheDir -Filter *.dat |
    ForEach-Object { Get-NameFromCacheFile $_.BaseName } | Sort-Object)
}

function Close-BwSession {
  [void](Invoke-Bw lock)
  # BW_CLIENTID も必ず消す（消し忘れると後続プロセスに引き継がれる）
  Remove-Item Env:BW_CLIENTID, Env:BW_CLIENTSECRET, Env:BW_PASSWORD -ErrorAction SilentlyContinue
  $script:BwSession = $null
  Unlock-BwCli
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
