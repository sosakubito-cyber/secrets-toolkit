# secret-push-bw.ps1 [--folder <フォルダ名>] [名前 ...]
#
#   ローカルの暗号化キャッシュ(DPAPI)にある秘密を Bitwarden の金庫へ登録する。
#   Mac 版 secret-push-bw と同じ役割。値は一切表示しない。
#
#   引数なしならローカルにある全件。名前を指定すればその分だけ。
#   同名の項目が金庫に既にある場合は上書きせずスキップする（多重登録の防止）。
#
#   - 1行の値    -> 「ログイン」項目の password 欄
#   - 複数行の値  -> 「セキュアメモ」項目の notes 欄
#   - 項目名はローカル名と同一にする（Mac 版と揃える）
#
#   実装注: param() ブロックを置いてはいけない（secret-put.ps1 の注記と同じ理由）。
#   引数は $args で受ける。--folder / -Folder のどちらでも受け付ける。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$FolderName = '_unassigned'
$names      = @()

for ($i = 0; $i -lt $args.Count; $i++) {
  $a = [string]$args[$i]
  if ($a -ieq '--folder' -or $a -ieq '-folder') {
    if ($i + 1 -ge $args.Count) {
      Write-Host "usage: secret-push-bw.ps1 [--folder <フォルダ名>] [名前 ...]" -ForegroundColor Red
      exit 2
    }
    $FolderName = [string]$args[$i + 1]; $i++
  } else {
    $names += $a.Trim()
  }
}

# 名前を明示したかどうかで、app-store-connect の扱いを変える（下の除外規則を参照）
$explicit = $names.Count -gt 0
if (-not $explicit) {
  $names = @(Get-CachedSecretNames)
  if ($names.Count -eq 0) {
    Write-Host "ローカルに登録された秘密がありません。先に secret-sync.ps1 か secret-put.ps1 を実行してください" -ForegroundColor Yellow
    exit 1
  }
}

# --- 金庫へ入れてはいけない / 入れなくてよいもの ---
# secret-sync.ps1 の【2】と同じ判断基準。あちらは報告から除外しているだけだが、
# こちらは実際に書き込むため判断を厳しくする。
#
#   bundle/bitwarden/*  金庫を開ける鍵そのもの。ここにはマスターパスワードが入る。
#                       金庫に入れれば循環依存になり、かつ「金庫を開ける鍵が金庫の中」
#                       という最悪の置き方になる。名指しされても拒否する。
#   service-account/app-store-connect/*
#                       正本は bundle/app-store-connect/* のメモ欄。純PEMの実行時コピーを
#                       金庫にも置くと正本が2つになる。既定では対象外。名指しなら通す。
function Test-Forbidden([string]$Name) { $Name -like 'bundle/bitwarden/*' }
function Test-LocalOnly([string]$Name) { $Name -like 'service-account/app-store-connect/*' }

# 名前の <種別>/<サービス>/... から、アプリ一覧に出す種別ラベルを組み立てる
function Get-ItemLabel([string]$Name) {
  $parts = $Name -split '/'
  $typ   = $parts[0]
  $svc   = if ($parts.Count -ge 2) { $parts[1] } else { '' }
  $label = switch ($typ) {
    'api-key'         { 'APIキー' }
    'api-token'       { 'APIトークン' }
    'service-account' { 'サービスアカウントJSON' }
    'app-password'    { 'アプリパスワード' }
    'webhook-url'     { 'Webhook URL' }
    'recovery-codes'  { 'リカバリコード' }
    'bundle'          { '複数値まとめ' }
    default           { $typ }
  }
  "$label ($svc)"
}

# try の中で exit すると finally の Close-BwSession が走るかどうかが分かりにくい。
# 走らないと金庫が解錠のまま・Mutex が握られたままになるので、終了コードは変数に持ち、
# exit は try/finally を抜けてから1回だけ行う。
$exitCode = 0
$session  = Open-BwSession
try {
  if ((Invoke-Bw sync --session $session).ExitCode -ne 0) {
    throw "bw sync に失敗しました。ネットワークとログイン状態を確認してください"
  }

  # --- フォルダを用意 ---
  # 空応答を「フォルダが無い」と解釈すると、既存フォルダを重複作成する。Get-BwFolders が弾く。
  $folders  = @(Get-BwFolders)
  $folderId = @($folders | Where-Object { $_.name -eq $FolderName } | ForEach-Object { $_.id })[0]
  if ([string]::IsNullOrWhiteSpace($folderId)) {
    $enc = ConvertTo-BwEncoded (@{ name = $FolderName } | ConvertTo-Json -Compress)
    $r   = Invoke-BwStdin -InputText $enc -BwArgs @('create', 'folder', '--session', $session)
    $folderId = if ($r.ExitCode -eq 0 -and $r.Output) {
      try { ($r.Output | ConvertFrom-Json).id } catch { $null }
    } else { $null }
    # 作成に失敗したまま進むと、全項目が不正な folderId を持って登録に失敗する
    if ([string]::IsNullOrWhiteSpace($folderId)) {
      throw "フォルダ '$FolderName' を作成できませんでした"
    }
    Write-Host "フォルダ '$FolderName' を作成しました"
  }

  # --- 金庫に既にある項目名（空応答を「まだ何も無い」と誤解しないよう Get-BwItems 経由） ---
  $existing = @(Get-BwItems | ForEach-Object { $_.name.Trim() })

  $added = 0; $skipped = 0; $failed = 0
  foreach ($n in $names) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }

    if (Test-Forbidden $n) {
      Write-Host ("  拒否      {0,-40} (金庫を開ける鍵は金庫に入れない)" -f $n) -ForegroundColor Red
      $skipped++; continue
    }
    if ((Test-LocalOnly $n) -and (-not $explicit)) {
      Write-Host ("  スキップ  {0,-40} (正本は bundle/app-store-connect/* のメモ欄)" -f $n)
      $skipped++; continue
    }
    if ($existing -contains $n) {
      Write-Host ("  スキップ  {0,-40} (同名の項目が既にある)" -f $n)
      $skipped++; continue
    }

    $value = Get-CachedSecret $n
    if ([string]::IsNullOrEmpty($value)) {
      Write-Host ("  失敗      {0,-40} (ローカルに無い、または空)" -f $n) -ForegroundColor Red
      $failed++; continue
    }

    try {
      if ($value.Contains("`n")) {
        $obj  = @{ type = 2; name = $n; notes = $value; favorite = $false
                   folderId = $folderId; secureNote = @{ type = 0 } }
        $kind = 'セキュアメモ'
      } else {
        $obj  = @{ type = 1; name = $n; notes = $null; favorite = $false
                   folderId = $folderId
                   login = @{ username = (Get-ItemLabel $n); password = $value; totp = $null } }
        $kind = 'ログイン'
      }
      # 値を含む JSON なので、コマンドライン引数ではなく標準入力で渡す
      $enc = ConvertTo-BwEncoded ($obj | ConvertTo-Json -Depth 5 -Compress)
      $r   = Invoke-BwStdin -InputText $enc -BwArgs @('create', 'item', '--session', $session)
      if ($r.ExitCode -eq 0) {
        Write-Host ("  登録      {0,-40} ({1})" -f $n, $kind) -ForegroundColor Green
        $added++
      } else {
        Write-Host ("  失敗      {0,-40} (bw create item が終了コード {1})" -f $n, $r.ExitCode) -ForegroundColor Red
        $failed++
      }
    } finally {
      # 平文を変数に残さない
      Remove-Variable value, obj, enc, r -ErrorAction SilentlyContinue
    }
  }

  Write-Host "`n登録 $added 件 / スキップ $skipped 件 / 失敗 $failed 件"
  if ($failed -gt 0) { exit 1 }
  exit 0   # 明示しないと呼び出し側の $LASTEXITCODE に直前の値が残る
}
finally { Close-BwSession }
