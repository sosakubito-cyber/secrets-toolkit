# secret-verify.ps1 <name> <file> [plain|firstline]
#   ローカルキャッシュの値と原本ファイルが同一かを SHA-256 で照合する。
#   秘密の値もハッシュ値も出力しない。「一致」「不一致」だけを出す。
#
#   金庫には触れないので bw セッションは開かない（ローカル完結・読み取りのみ）。
#
#   原本は**バイト列のまま**ハッシュする。テキストとして読むと BOM が落ち、同じファイルでも
#   Mac 版と判定が食い違う（「Mac では不一致・Windows では一致」）。今日この BOM 由来の
#   壊れ方を4件踏んでいるので、照合の土俵は両プラットフォームで揃えてある。
#
#   Mac 版との違い:
#     - `rtf` モードは無い。macOS の textutil に相当するものが無いため。
#       RTF の原本は Mac 側で照合すること（原本は ~/.secrets-archive/ にある）。
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

# 原本側。Get-Content ではなくバイト列で読む（文字コード変換も BOM 除去も挟ませない）
$fileBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $File).ProviderPath)
if ($Mode -ieq 'firstline') {
  # 最初の LF まで。Mac 版の `head -n 1` に相当（CR は後段の trim が落とす）
  $idx = [Array]::IndexOf($fileBytes, [byte]10)
  if ($idx -ge 0) {
    $head = New-Object byte[] $idx      # $idx が 0 でも長さ0の配列になる
    [Array]::Copy($fileBytes, 0, $head, 0, $idx)
    $fileBytes = $head
  }
}
$hashFile = Get-SecretHashOfBytes $fileBytes
Remove-Variable fileBytes -ErrorAction SilentlyContinue

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
# キャッシュ側も同じ土俵に乗せる（UTF-8 のバイト列にしてから両端の空白を落とす）
$hashCache = Get-SecretHashOfBytes ([System.Text.Encoding]::UTF8.GetBytes($value))
Remove-Variable value -ErrorAction SilentlyContinue

if ($hashFile -eq $hashCache) {
  Write-Host ("  一致   {0,-46} -> {1}" -f (Split-Path $File -Leaf), $Name) -ForegroundColor Green
  exit 0
} else {
  Write-Host ("  不一致 {0,-46} -> {1}" -f (Split-Path $File -Leaf), $Name) -ForegroundColor Red
  exit 1
}
