# secret-check.ps1 — 登録状況を表示する。値は絶対に表示しない。
#   引数なし: 全 .map が参照する名前を実際に解決できるか検証する。
#             （キャッシュを列挙して同じものの存在を確かめても何も検証したことにならない）
#   名前を指定: その名前だけを個別に確認する。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$names = @($args)
$rc = 0

if ($names.Count -gt 0) {
  foreach ($n in $names) {
    if (Test-CachedSecret $n) { Write-Host "  OK    $n" -ForegroundColor Green }
    else { Write-Host "  MISS  $n" -ForegroundColor Red; $rc = 1 }
  }
  Write-Host "`n$($names.Count) 件"
  exit $rc
}

# ---- 引数なし: profile ごとに対応表の参照先を検証する ----
$profiles = Get-SecretProfiles
if ($profiles.Count -eq 0) {
  Write-Host "対応表(.map)がありません。SETUP.md の手順3を実施してください" -ForegroundColor Red
  exit 1
}

$referenced = New-Object System.Collections.Generic.HashSet[string]
$total = 0; $miss = 0
$badProfiles = @()

foreach ($p in $profiles) {
  Write-Host "`n[$p]"
  $entries = @(Read-SecretMap $p)
  if ($entries.Count -eq 0) { Write-Host "  （項目なし）"; continue }

  $profileMiss = 0
  foreach ($e in $entries) {
    $name = $e.Name
    $tag  = ''
    if ($name.StartsWith('@file:')) { $name = $name.Substring(6); $tag = '  [@file]' }
    [void]$referenced.Add($name)
    $total++

    if (Test-CachedSecret $name) {
      Write-Host "  OK    $($e.Var) -> $name$tag" -ForegroundColor Green
    } else {
      Write-Host "  MISS  $($e.Var) -> $name$tag" -ForegroundColor Red
      $miss++; $profileMiss++; $rc = 1
    }
  }
  if ($profileMiss -gt 0) { $badProfiles += $p }
}

# ---- どの対応表からも参照されていないキャッシュ（情報として表示するだけ） ----
$orphans = @()
if (Test-Path $script:CacheDir) {
  foreach ($f in Get-ChildItem $script:CacheDir -Filter *.dat) {
    $n = Get-NameFromCacheFile $f.BaseName
    if (-not $referenced.Contains($n)) { $orphans += $n }
  }
}
if ($orphans.Count -gt 0) {
  Write-Host "`n[対応表から参照されていないキャッシュ]（問題ではありません）"
  $orphans | Sort-Object | ForEach-Object { Write-Host "  --    $_" -ForegroundColor DarkGray }
}

Write-Host "`n参照 $total 件 / MISS $miss 件 / 未参照キャッシュ $($orphans.Count) 件"
if ($miss -gt 0) {
  Write-Host "不足のある profile: $($badProfiles -join ', ')" -ForegroundColor Yellow
  Write-Host "secret-sync.ps1 を実行するか、金庫に該当項目を登録してください"
}
exit $rc
