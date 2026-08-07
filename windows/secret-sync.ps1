# secret-sync.ps1 — Bitwarden の金庫を Windows のローカルキャッシュへ同期する。
#   値は一切表示しない。Mac 版 secret-sync と同じ役割。
#   -DryRun で確認のみ。
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$session = Open-BwSession
try {
  Write-Host "同期中..."
  bw sync --session $session *>$null

  $items = bw list items --session $session | ConvertFrom-Json

  Write-Host "`n【1】金庫にあってローカルに無いもの"
  $added = 0
  foreach ($it in $items) {
    $name = $it.name.Trim()
    if (Test-CachedSecret $name) { continue }

    if ($DryRun) { Write-Host "  [dry-run] 取り込む: $name"; $added++; continue }

    $val = if ($it.type -eq 1) { $it.login.password } else { $it.notes }
    if ([string]::IsNullOrWhiteSpace($val)) {
      Write-Host "  スキップ $name (値が空)" -ForegroundColor Yellow
      continue
    }
    Set-CachedSecret $name $val
    Write-Host "  取り込み $name" -ForegroundColor Green
    $added++
    Remove-Variable val
  }
  if ($added -eq 0) { Write-Host "  （なし・すべて取り込み済み）" }

  Write-Host "`n【2】ローカルにあって金庫に無いもの（消しません）"
  $vaultNames = @($items | ForEach-Object { $_.name.Trim() })
  $miss = 0
  if (Test-Path $script:CacheDir) {
    foreach ($f in Get-ChildItem $script:CacheDir -Filter *.dat) {
      $n = ($f.BaseName -replace '__', '/')
      if ($vaultNames -notcontains $n) {
        # bundle/bitwarden/* は循環依存のため意図的に金庫へ入れない
        if ($n -notlike 'bundle/bitwarden/*') {
          Write-Host "  金庫に無い $n" -ForegroundColor Yellow; $miss++
        }
      }
    }
  }
  if ($miss -eq 0) { Write-Host "  （なし）" }

  Write-Host "`n【3】命名規則 <種別>/<サービス>/<用途> に従っていない項目"
  $types = 'api-key|api-token|service-account|app-password|webhook-url|recovery-codes|bundle'
  $bad = @($items | Where-Object { $_.name.Trim() -notmatch "^($types)/[^/]+/.+$" })
  if ($bad.Count -eq 0) { Write-Host "  （なし・全項目が規則に従っています）" }
  else { $bad | ForEach-Object { Write-Host "  要修正 $($_.name)" -ForegroundColor Yellow } }

  Write-Host "`n取り込み $added 件 / 金庫に無い $miss 件 / 名前要修正 $($bad.Count) 件"
}
finally { Close-BwSession }
