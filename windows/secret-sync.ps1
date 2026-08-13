# secret-sync.ps1 — Bitwarden の金庫を Windows のローカルキャッシュへ同期する。
#   値は一切表示しない。Mac 版 secret-sync と同じ役割。
#   -DryRun で確認のみ。
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$session = Open-BwSession
try {
  Write-Host "同期中..."
  if ((Invoke-Bw sync --session $session).ExitCode -ne 0) {
    throw "bw sync に失敗しました。ネットワークとログイン状態を確認してください"
  }

  # 空・非配列を「金庫が空」と解釈しないよう Get-BwItems 経由で取得する
  $items = @(Get-BwItems)
  if ($items.Count -eq 0) {
    Write-Host "金庫に項目がありません。取り込むものはありません" -ForegroundColor Yellow
  }

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
      $n = Get-NameFromCacheFile $f.BaseName
      if ($vaultNames -notcontains $n) {
        # 意図的にローカルだけに置くもの（金庫に無くても異常ではない）:
        #   bundle/bitwarden/*                  金庫を開ける鍵。入れると循環依存になる
        #   service-account/app-store-connect/* 金庫の bundle 項目から取り出した純 PEM の
        #                                       実行時コピー。正本は bundle 側。CI ツールは
        #                                       コメント行付きの PEM を弾くため必要
        if ($n -notlike 'bundle/bitwarden/*' -and $n -notlike 'service-account/app-store-connect/*') {
          Write-Host "  金庫に無い $n" -ForegroundColor Yellow; $miss++
        }
      }
    }
  }
  if ($miss -eq 0) { Write-Host "  （なし）" }

  # ローカルは1名前に1値しか持てないため、ログイン項目(password を取り込む)に
  # メモ欄があるとその中身は同期で黙って捨てられる。捨てたことを告げる。
  Write-Host "`n【3】ログイン項目にメモ欄がある（同期ではメモ側が取り込まれません）"
  $both = @($items | Where-Object {
    $_.type -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($_.notes) -and
    -not [string]::IsNullOrWhiteSpace($_.login.password)
  })
  if ($both.Count -eq 0) { Write-Host "  （なし）" }
  else { $both | ForEach-Object { Write-Host "  取り込み対象外のメモあり $($_.name)" -ForegroundColor Yellow } }

  Write-Host "`n【4】命名規則 <種別>/<サービス>/<用途> に従っていない項目"
  $types = 'api-key|api-token|service-account|app-password|webhook-url|recovery-codes|bundle'
  $bad = @($items | Where-Object { $_.name.Trim() -notmatch "^($types)/[^/]+/.+$" })
  if ($bad.Count -eq 0) { Write-Host "  （なし・全項目が規則に従っています）" }
  else { $bad | ForEach-Object { Write-Host "  要修正 $($_.name)" -ForegroundColor Yellow } }

  Write-Host "`n取り込み $added 件 / 金庫に無い $miss 件 / メモあり $($both.Count) 件 / 名前要修正 $($bad.Count) 件"
}
finally { Close-BwSession }
