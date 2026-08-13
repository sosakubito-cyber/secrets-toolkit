# secret-put.ps1 <name>
#   標準入力から秘密の値を受け取り、ローカルの暗号化キャッシュ(DPAPI)に登録する。
#   値は標準出力にも標準エラーにも一切出さない（文字数と照合結果だけ報告する）。
#
#   値は必ず標準入力から渡すこと。コマンドライン引数に書くと平文がコマンド履歴に残る。
#
#   例:
#     Get-Content sa.json -Raw | secret-put.ps1 service-account/gcp/speech
#     $v = Read-Host -AsSecureString ...  →  値を変数に平文で置かない。ファイル経由か
#                                            Bitwarden 経由（secret-sync.ps1）を使う
#
#   Mac 版との違い: macOS の security(1) は改行を含む値を -w で読み出すと16進で返すため
#   base64 格納（コメント欄に raw/b64 を記録）が必要だが、DPAPI は改行・CRLF・UTF-8 を
#   そのまま往復できる。よって Windows では常に raw で格納し、格納形式の区別を持たない。
#   実装注: param() ブロックを置いてはいけない。param() があるスクリプトは、
#   ValueFromPipeline を宣言したパラメータが無い限りパイプライン入力を
#   「バインドできない」として拒否し、$input に何も入らなくなる。
#   このツール群の他のスクリプトと同じく $args で受ける。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$Name = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

if ([string]::IsNullOrWhiteSpace($Name)) {
  Write-Host "usage: secret-put.ps1 <name>   (値は標準入力から渡す)"
  Write-Host "  例: Get-Content sa.json -Raw | secret-put.ps1 service-account/gcp/speech"
  exit 2
}

# 項目名の前後に空白が混入すると完全一致検索から漏れる。ここで落としておく。
$trimmed = $Name.Trim()
if ($trimmed -ne $Name) {
  Write-Host "  注意: 名前の前後の空白を除去しました" -ForegroundColor Yellow
  $Name = $trimmed
}

# ---- 値を標準入力から受け取る ----
#   PowerShell のパイプライン（'x' | secret-put.ps1 name）は $input に入る。
#   cmd.exe から type file | powershell -File ... とした場合は Console.In が
#   リダイレクトされるので、そちらも拾う。
$piped = @($input)
if ($piped.Count -gt 0) {
  # Get-Content（-Raw なし）で渡されると行の配列になるため復元する
  $value = ($piped | ForEach-Object { [string]$_ }) -join "`n"
} elseif ([Console]::IsInputRedirected) {
  $value = [Console]::In.ReadToEnd()
} else {
  Write-Host "エラー: 値が標準入力から渡されていません" -ForegroundColor Red
  Write-Host "  例: Get-Content sa.json -Raw | secret-put.ps1 $Name"
  exit 2
}

$value = $value.Trim()
if ([string]::IsNullOrEmpty($value)) {
  Write-Host "エラー: 空の値です ($Name)" -ForegroundColor Red
  exit 1
}

# ---- 命名規則の確認（Mac 版と同じく、警告するが登録は止めない） ----
$types = 'api-key|api-token|service-account|app-password|webhook-url|recovery-codes|bundle'
if ($Name -notmatch "^($types)/[^/]+/.+$") {
  Write-Host "  注意: 命名規則 <種別>/<サービス>/<用途> に従っていません: $Name" -ForegroundColor Yellow
  Write-Host "        種別: api-key api-token service-account app-password webhook-url recovery-codes bundle" -ForegroundColor Yellow
}

$existed = Test-CachedSecret $Name

# ---- 登録し、書き戻しをハッシュで照合する（値は出さない） ----
Set-CachedSecret $Name $value

$back = Get-CachedSecret $Name
if ($null -eq $back -or (Get-SecretHash $back) -ne (Get-SecretHash $value)) {
  Write-Host "エラー: 登録後の読み戻しが一致しません ($Name)" -ForegroundColor Red
  exit 1
}

$what = if ($existed) { "更新" } else { "登録" }
Write-Host "  ok  $Name  ($($value.Length) 文字を$what / 読み戻し照合 OK)" -ForegroundColor Green
Write-Host "  これはローカルだけです。金庫（正本）へ入れるには: secret-push-bw.ps1 --folder <プロジェクト> $Name"
exit 0   # 明示しないと呼び出し側の $LASTEXITCODE に直前の値が残る
