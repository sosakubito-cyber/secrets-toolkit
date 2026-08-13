# secret-pull.ps1 <Bitwardenの項目名> <ローカル名> [--notes]
#
#   Bitwarden から値を1件取り出し、ローカルの暗号化キャッシュ(DPAPI)へ格納する。
#   値は画面にもログにも出ない。スマホで登録した鍵を1件だけ取り込む用途。
#   全件まとめて取り込むなら secret-sync.ps1 を使う。
#
#   --notes を付けると password 欄ではなく「セキュアメモ」欄から取得する
#   （サービスアカウントJSON など複数行の値はこちら）。
#
#   事前に secret-bootstrap.ps1 を1回実行しておくこと。
#
#   実装注: param() ブロックを置いてはいけない（secret-put.ps1 の注記と同じ理由）。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

$Item      = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$LocalName = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
$Notes     = $false
for ($i = 2; $i -lt $args.Count; $i++) {
  if ([string]$args[$i] -ieq '--notes' -or [string]$args[$i] -ieq '-notes') { $Notes = $true }
}

if ([string]::IsNullOrWhiteSpace($Item) -or [string]::IsNullOrWhiteSpace($LocalName)) {
  Write-Host "usage: secret-pull.ps1 <Bitwardenの項目名> <ローカル名> [--notes]"
  Write-Host "  金庫の項目名を確かめる: secret-list-remote.ps1"
  exit 2
}
$LocalName = $LocalName.Trim()

$exitCode = 0
$session  = Open-BwSession
try {
  if ((Invoke-Bw sync --session $session).ExitCode -ne 0) {
    throw "bw sync に失敗しました。ネットワークとログイン状態を確認してください"
  }

  if ($Notes) {
    $r = Invoke-Bw get item $Item --session $session
    $value = if ($r.ExitCode -eq 0 -and $r.Output) {
      try { ($r.Output | ConvertFrom-Json).notes } catch { $null }
    } else { $null }
  } else {
    $r = Invoke-Bw get password $Item --session $session
    $value = if ($r.ExitCode -eq 0) { $r.Output } else { $null }
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    Write-Host "エラー: Bitwarden に項目 '$Item' が見つからない、または値が空です" -ForegroundColor Red
    Write-Host "  複数行の値なら --notes を試してください"
    Write-Host "  項目名の確認: secret-list-remote.ps1"
    $exitCode = 1
  } else {
    $value = $value.Trim()
    $existed = Test-CachedSecret $LocalName

    # 書き込んだあと読み戻してハッシュで照合する（secret-put.ps1 と同じ確かめ方）
    Set-CachedSecret $LocalName $value
    $back = Get-CachedSecret $LocalName
    if ($null -eq $back -or (Get-SecretHash $back) -ne (Get-SecretHash $value)) {
      Write-Host "エラー: 登録後の読み戻しが一致しません ($LocalName)" -ForegroundColor Red
      $exitCode = 1
    } else {
      $what = if ($existed) { '更新' } else { '登録' }
      Write-Host ("  ok  Bitwarden '{0}' -> ローカル '{1}'  ({2} 文字を{3} / 読み戻し照合 OK)" -f `
        $Item, $LocalName, $value.Length, $what) -ForegroundColor Green
    }
    Remove-Variable back -ErrorAction SilentlyContinue
  }
  Remove-Variable value, r -ErrorAction SilentlyContinue
}
finally { Close-BwSession }

exit $exitCode   # 明示しないと呼び出し側の $LASTEXITCODE に直前の値が残る
