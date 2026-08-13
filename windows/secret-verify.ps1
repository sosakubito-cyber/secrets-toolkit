# secret-verify.ps1 <name> <file> [plain|firstline]
#   ローカルキャッシュの値と原本ファイルが同一かを SHA-256 で照合する。
#   秘密の値もハッシュ値も出力しない。「一致」「不一致」だけを出す。
#
#   金庫には触れないので bw セッションは開かない（ローカル完結・読み取りのみ）。
#
#   Mac 版との違い:
#     - `rtf` モードは無い。macOS の textutil に相当するものが無いため。
#       RTF の原本は Mac 側で照合すること（原本は ~/.secrets-archive/ にある）。
#     - Mac 版はファイルをバイト列として扱うが、こちらは UTF-8 テキストとして読む。
#       BOM 付きのファイルは BOM が落ちるため、Mac 版と結果が食い違いうる。
#       BOM の有無まで含めて確かめたい場合は Mac 側で照合すること。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$Name = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$File = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
$Mode = if ($args.Count -ge 3) { [string]$args[2] } else { 'plain' }

if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($File)) {
  Write-Host "usage: secret-verify.ps1 <name> <file> [plain|firstline]"
  exit 2
}
if ($Mode -ieq 'rtf') {
  Write-Host "エラー: rtf モードは Windows では使えません（textutil 相当が無い）。Mac 側で照合してください" -ForegroundColor Red
  exit 2
}
if ($Mode -notin @('plain', 'firstline')) {
  Write-Host "エラー: 未知のモード '$Mode'（plain または firstline）" -ForegroundColor Red
  exit 2
}
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
  Write-Host ("  NOFILE {0}" -f $File) -ForegroundColor Red
  exit 1
}

# 原本側。-Encoding UTF8 は必須（省略すると PS 5.1 は CP932 として読む）
$fileText = if ($Mode -ieq 'firstline') {
  $first = Get-Content -LiteralPath $File -Encoding UTF8 -TotalCount 1
  if ($null -eq $first) { '' } else { [string]$first }
} else {
  $raw = Get-Content -LiteralPath $File -Encoding UTF8 -Raw
  if ($null -eq $raw) { '' } else { [string]$raw }
}
$hashFile = Get-SecretHash ($fileText.Trim())
Remove-Variable fileText -ErrorAction SilentlyContinue

# ローカルキャッシュ側
if (-not (Test-CachedSecret $Name)) {
  Write-Host ("  未登録 {0}" -f $Name) -ForegroundColor Red
  exit 1
}
$value = Get-CachedSecret $Name
if ($null -eq $value) {
  Write-Host ("  読出失敗 {0}" -f $Name) -ForegroundColor Red
  exit 1
}
$hashCache = Get-SecretHash ($value.Trim())
Remove-Variable value -ErrorAction SilentlyContinue

if ($hashFile -eq $hashCache) {
  Write-Host ("  一致   {0,-46} -> {1}" -f (Split-Path $File -Leaf), $Name) -ForegroundColor Green
  exit 0
} else {
  Write-Host ("  不一致 {0,-46} -> {1}" -f (Split-Path $File -Leaf), $Name) -ForegroundColor Red
  exit 1
}
