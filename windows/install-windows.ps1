# install-windows.ps1 — windows/ のスクリプトと maps/ の対応表を所定の場所へ配置する。
#   このリポジトリが正本。配備先を直接編集せず、ここを編集してから再実行すること。
#
#   使い方（リポジトリのどこからでもよい）:
#     .\windows\install-windows.ps1                # 既存の対応表は上書きしない
#     .\windows\install-windows.ps1 -UpdateMaps    # 対応表も正本で上書きする
#
#   Mac 版 install-mac.sh と同じ役割・同じ既定。
param([switch]$UpdateMaps)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Bin      = Join-Path $env:USERPROFILE '.local\bin'
$Conf     = Join-Path $env:USERPROFILE '.config\secrets'

New-Item -ItemType Directory -Force -Path $Bin, $Conf | Out-Null

Write-Host "== スクリプトを配置 =="
# -File は必須。ディレクトリ（windows\tests\）を掴むと Copy-Item がフォルダごと
# 配ってしまう。Mac 版はここでディレクトリを install しようとして終了コード 71 で
# 止まり、下の対応表の処理に一度も到達していなかった（2026-08-15 に発覚）。
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '*.ps1') -File | Sort-Object Name) {
  if ($f.Name -eq 'install-windows.ps1') { continue }
  Copy-Item $f.FullName (Join-Path $Bin $f.Name) -Force
  Write-Host "  $($f.Name)"
}

Write-Host ""
if ($UpdateMaps) {
  Write-Host "== 対応表を配置（-UpdateMaps: 差分は正本で上書きする） =="
} else {
  Write-Host "== 対応表を配置（既存があれば上書きしない。更新は -UpdateMaps） =="
}
$stale = 0
foreach ($m in Get-ChildItem (Join-Path $RepoRoot 'maps\*.map') -File | Sort-Object Name) {
  $dst = Join-Path $Conf $m.Name
  if (Test-Path $dst) {
    $same = (Get-FileHash $m.FullName).Hash -eq (Get-FileHash $dst).Hash
    if ($same) {
      Write-Host "  同一   $($m.Name)"
    } elseif ($UpdateMaps) {
      # 対応表に秘密の値は入っていない（名前だけ）ので、変更点は表示してよい
      $strip = { param($p) @(Get-Content $p -Encoding UTF8 |
                   ForEach-Object { ($_ -split '#', 2)[0].Trim() } | Where-Object { $_ }) }
      $before = & $strip $dst
      $after  = & $strip $m.FullName
      foreach ($d in (Compare-Object $before $after)) {
        $mark = if ($d.SideIndicator -eq '=>') { '追加' } else { '削除' }
        Write-Host "    $mark $($d.InputObject)"
      }
      Copy-Item $m.FullName $dst -Force
      Write-Host "  更新   $($m.Name)" -ForegroundColor Green
    } else {
      Write-Host "  差分あり（上書きせず） $($m.Name)" -ForegroundColor Yellow
      $stale++
    }
  } else {
    Copy-Item $m.FullName $dst -Force
    Write-Host "  新規   $($m.Name)"
  }
}
if ($stale -gt 0) {
  Write-Host ""
  Write-Host "  配備先が古いままの対応表が $stale 件あります。反映するには:" -ForegroundColor Yellow
  Write-Host "    .\windows\install-windows.ps1 -UpdateMaps"
  Write-Host "  （正本はこのリポジトリ。配備先を手で編集しないこと）"
}

Write-Host ""
if ($env:Path -split ';' -contains $Bin) {
  Write-Host "PATH OK: $Bin"
} else {
  Write-Host "注意: $Bin が PATH にありません。次を実行してください:" -ForegroundColor Yellow
  Write-Host '  [Environment]::SetEnvironmentVariable(''Path'', $env:Path + ";$env:USERPROFILE\.local\bin", ''User'')'
}

Write-Host ""
Write-Host "次の手順:"
Write-Host "  1. 初回のみ  secret-bootstrap.ps1   （対話端末で実行）"
Write-Host "  2. 取り込み  secret-sync.ps1"
Write-Host "  3. 確認      secret-check.ps1"
exit 0   # 明示しないと呼び出し側の $LASTEXITCODE に直前の値が残る
