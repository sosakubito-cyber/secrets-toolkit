# secret-list-remote.ps1 — Bitwarden 金庫の「項目名」だけを一覧する。値は一切出力しない。
#   secret-pull.ps1 に渡す名前が合っているか確かめる用途。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$exitCode = 0
$session  = Open-BwSession
try {
  if ((Invoke-Bw sync --session $session).ExitCode -ne 0) {
    throw "bw sync に失敗しました。ネットワークとログイン状態を確認してください"
  }

  # 空応答を「金庫が空」と解釈しないよう、必ず Get-BwItems / Get-BwFolders を通す
  $items   = @(Get-BwItems)
  $folders = @(Get-BwFolders)

  Write-Host "金庫の項目数: $($items.Count)"

  # フォルダIDから名前を引く表
  $fmap = @{}
  foreach ($f in $folders) { $fmap[[string]$f.id] = [string]$f.name }

  # type: 1=ログイン 2=セキュアメモ 3=カード 4=ID
  $rows = foreach ($it in $items) {
    $fid = if ($null -eq $it.folderId) { '' } else { [string]$it.folderId }
    [pscustomobject]@{
      Folder = if ($fmap.ContainsKey($fid)) { $fmap[$fid] } else { '(フォルダなし)' }
      Name   = [string]$it.name
      Kind   = switch ([int]$it.type) {
                 1 { 'ログイン' } 2 { 'メモ' } 3 { 'カード' } default { 'ID' }
               }
    }
  }

  foreach ($g in ($rows | Group-Object Folder | Sort-Object Name)) {
    Write-Host "`n  [$($g.Name)]"
    foreach ($r in ($g.Group | Sort-Object Name)) {
      Write-Host ("    {0,-40} {1}" -f $r.Name, $r.Kind)
    }
  }

  Remove-Variable items, folders, rows -ErrorAction SilentlyContinue
}
finally { Close-BwSession }

exit $exitCode   # 明示しないと呼び出し側の $LASTEXITCODE に直前の値が残る
