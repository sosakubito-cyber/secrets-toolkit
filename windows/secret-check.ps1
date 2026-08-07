# secret-check.ps1 — ローカルキャッシュの登録状況を表示する。値は絶対に表示しない。
#   引数なしで全件、名前を指定すると個別に確認する。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$names = @($args)
if ($names.Count -eq 0) {
  if (-not (Test-Path $script:CacheDir)) { Write-Host "キャッシュがありません。secret-sync.ps1 を実行してください"; exit 1 }
  $names = @(Get-ChildItem $script:CacheDir -Filter *.dat | ForEach-Object { $_.BaseName -replace '__', '/' } | Sort-Object)
}

$rc = 0
foreach ($n in $names) {
  if (Test-CachedSecret $n) { Write-Host "  OK    $n" -ForegroundColor Green }
  else { Write-Host "  MISS  $n" -ForegroundColor Red; $rc = 1 }
}
Write-Host "`n$($names.Count) 件"
exit $rc
