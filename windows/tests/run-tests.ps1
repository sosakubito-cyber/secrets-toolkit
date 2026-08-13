# run-tests.ps1 — Windows 版の回帰テスト。合成値のみを使い、秘密の値は一切扱わない。
#
#   .\tests\run-tests.ps1            # 金庫に触れないテストだけ（既定）
#   .\tests\run-tests.ps1 -WithVault # Bitwarden を実際に開くテストも含める
#
#   守っている対象は「読んで正しいのに Windows で実行すると壊れる」型のバグ。
#   これらは全て実際に踏んだもので、コメントやドキュメントでは再発を防げなかった。
#
#   テスト中は $env:USERPROFILE を一時フォルダへ向けるため、
#   本物の %USERPROFILE%\.config\secrets には一切触れない。
[CmdletBinding()]
param([switch]$WithVault)

$ErrorActionPreference = 'Stop'
$RepoWindows = Split-Path $PSScriptRoot -Parent

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$script:Failures = @()

function Test-Case([string]$Name, [scriptblock]$Body) {
  try {
    $r = & $Body
    if ($r -eq $true) { $script:Pass++; Write-Host ("  PASS  " + $Name) -ForegroundColor Green }
    else {
      $script:Fail++; $script:Failures += $Name
      Write-Host ("  FAIL  " + $Name + "  -> " + $r) -ForegroundColor Red
    }
  } catch {
    $script:Fail++; $script:Failures += $Name
    Write-Host ("  FAIL  " + $Name + "  -> 例外: " + $_.Exception.Message.Split([char]10)[0]) -ForegroundColor Red
  }
}
function Skip-Case([string]$Name, [string]$Why) {
  $script:Skip++; Write-Host ("  SKIP  " + $Name + "  (" + $Why + ")") -ForegroundColor DarkGray
}
function Section([string]$Name) { Write-Host "`n[$Name]" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
Section "ソースの健全性"

Test-Case "全 .ps1 が UTF-8 BOM 付き（BOM が無いと CP932 として読まれ、コードが1行消える）" {
  $bad = @()
  foreach ($f in Get-ChildItem "$RepoWindows\*.ps1") {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad += $f.Name }
  }
  if ($bad.Count -eq 0) { $true } else { "BOM 無し: " + ($bad -join ', ') }
}

Test-Case "CP932 として読んでも行が消えない（日本語コメント末尾のリードバイトが改行を食う）" {
  $ansi = [System.Text.Encoding]::GetEncoding(932)
  $bad = @()
  foreach ($f in Get-ChildItem "$RepoWindows\*.ps1") {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    # BOM 付きなら PS は UTF-8 で読むので安全。BOM 無しのものだけ危険。
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if ($hasBom) { continue }
    $u = ([System.Text.Encoding]::UTF8.GetString($b) -split "`r?`n").Count
    $a = ($ansi.GetString($b) -split "`r?`n").Count
    if ($u -ne $a) { $bad += ("{0} ({1}行消失)" -f $f.Name, ($u - $a)) }
  }
  if ($bad.Count -eq 0) { $true } else { ($bad -join ', ') }
}

Test-Case "全 .ps1 が構文エラー無し" {
  $bad = @()
  foreach ($f in Get-ChildItem "$RepoWindows\*.ps1") {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { $bad += $f.Name }
  }
  if ($bad.Count -eq 0) { $true } else { "構文エラー: " + ($bad -join ', ') }
}

Test-Case "生の bw 呼び出しが無い（Invoke-Bw を通さないと stderr で落ち、排他制御も外れる）" {
  $bad = @()
  foreach ($f in Get-ChildItem "$RepoWindows\*.ps1") {
    foreach ($m in (Select-String -Path $f.FullName -Pattern '(?<!Invoke-)\bbw\s+(login|unlock|lock|list|get|create|edit|sync|status)\b')) {
      $line = $m.Line.Trim()
      if ($line -match '^\s*#') { continue }        # コメント
      if ($line -match '"[^"]*bw ') { continue }    # エラーメッセージ中の文字列
      $bad += ("{0}:{1}" -f $f.Name, $m.LineNumber)
    }
  }
  if ($bad.Count -eq 0) { $true } else { "生の bw: " + ($bad -join ', ') }
}

# ---------------------------------------------------------------------------
# 以降は隔離したサンドボックスで動かす（本物の設定には触れない）
$RealProfile = $env:USERPROFILE
$Sandbox = Join-Path $env:TEMP ("secrets-tests." + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox '.config\secrets') | Out-Null
$env:USERPROFILE = $Sandbox

try {
  . (Join-Path $RepoWindows '_secret-common.ps1')

  $Conf = Join-Path $Sandbox '.config\secrets'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  Section "共通処理"

  Test-Case "DPAPI 往復がバイト単位で一致（複数行・CRLF・日本語・末尾空白）" {
    $cases = @{
      'ascii'     = 'value-0123456789'
      'multiline' = "{`n  `"a`": 1,`n  `"b`": 2`n}"
      'crlf'      = "l1`r`nl2`r`nl3"
      'japanese'  = 'パスワード-日本語'
      'trailing'  = 'value-with-space   '
    }
    foreach ($k in $cases.Keys) {
      Set-CachedSecret "api-key/_tests/$k" $cases[$k]
      $back = Get-CachedSecret "api-key/_tests/$k"
      if ((Get-SecretHash $back) -ne (Get-SecretHash $cases[$k])) { return "不一致: $k" }
    }
    $true
  }

  Test-Case "名前 <-> キャッシュファイル名の往復" {
    $n = 'service-account/gcp/speech'
    if ((Get-NameFromCacheFile ((Get-SecretPathFor $n) | Split-Path -Leaf).Replace('.dat','')) -ne $n) { return "往復不一致" }
    $true
  }

  Test-Case "Get-SecretHashOfBytes は両端の空白のみ落とす（BOM は残す = Mac と同じ判定）" {
    $core = [System.Text.Encoding]::UTF8.GetBytes('abc')
    $pad  = [System.Text.Encoding]::UTF8.GetBytes(" `t abc `r`n")
    if ((Get-SecretHashOfBytes $core) -ne (Get-SecretHashOfBytes $pad)) { return "空白除去が効いていない" }
    $withBom = [byte[]](0xEF,0xBB,0xBF) + $core
    if ((Get-SecretHashOfBytes $core) -eq (Get-SecretHashOfBytes $withBom)) { return "BOM が落ちている（Mac と判定がずれる）" }
    $true
  }

  Test-Case "Get-BwItems が空・非配列を失敗として扱う（金庫が空に見える事故の防止）" {
    $script:BwSession = 'stub'
    $script:StubCase = ''
    function bw { switch ($script:StubCase) {
        'empty'    { }
        'blank'    { '   ' }
        'garbage'  { 'Vault is locked.' }
        'null'     { 'null' }
        'emptyarr' { '[]' }
        'good'     { '[{"name":"a"},{"name":"b"}]' }
      }; $global:LASTEXITCODE = 0 }
    foreach ($c in 'empty','blank','garbage','null') {
      $script:StubCase = $c
      try { $null = Get-BwItems; return "拒否されなかった: $c" } catch { }
    }
    $script:StubCase = 'emptyarr'
    if (@(Get-BwItems).Count -ne 0) { return "[] が 0 件にならない" }
    $script:StubCase = 'good'
    if (@(Get-BwItems).Count -ne 2) { return "正常応答が 2 件にならない（,@() で包むと常に1件になる）" }
    Remove-Item Function:\bw -ErrorAction SilentlyContinue
    $script:BwSession = $null
    $true
  }

  # -------------------------------------------------------------------------
  Section "secrets-run（引数の扱い）"

  # テスト用 profile
  [System.IO.File]::WriteAllText((Join-Path $Conf '_tests.map'),
    "TESTVAR=api-key/_tests/ascii`n", $utf8NoBom)
  $Run = Join-Path $RepoWindows 'secrets-run.ps1'

  # 子プロセスで判定する。secrets-run 自身の Write-Host は情報ストリームなので
  # 2>&1 では捕まらず、親側で出力を突き合わせても検証にならない。
  $argProbe = Join-Path $Sandbox 'argprobe.ps1'
  [System.IO.File]::WriteAllText($argProbe,
    'Write-Host ("ARGC=" + $args.Count + " ARGS=" + ($args -join "|") + " TESTVARLEN=" + $env:TESTVAR.Length)',
    (New-Object System.Text.UTF8Encoding($true)))

  function Invoke-Run { param([string[]]$Extra)
    $a = @('_tests','--','powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',$argProbe) + $Extra
    (& $Run @a 2>&1 | Out-String)
  }

  # 今日の実バグ: 引数ちょうど1個のとき if 文の結果が String に潰れ、splat が1文字ずつ展開する
  Test-Case "引数0個" { if ((Invoke-Run @()) -match 'ARGC=0') { $true } else { "ARGC=0 が出ない" } }
  Test-Case "引数1個（if の結果が String に潰れ、1文字ずつ展開されたバグ）" {
    $o = Invoke-Run @('alpha')
    if ($o -match 'ARGC=1\s+ARGS=alpha') { $true } else { "期待 ARGC=1/alpha、実際: " + (($o -split "`n" | Select-String 'ARGC') -join '') }
  }
  Test-Case "引数2個" {
    $o = Invoke-Run @('alpha','beta')
    if ($o -match 'ARGC=2\s+ARGS=alpha\|beta') { $true } else { "期待 ARGC=2" }
  }
  Test-Case "引数3個" {
    $o = Invoke-Run @('a','b','c')
    if ($o -match 'ARGC=3') { $true } else { "期待 ARGC=3" }
  }
  Test-Case "空白を含む引数が1個に保たれる" {
    $o = Invoke-Run @('hello world')
    if ($o -match 'ARGC=1\s+ARGS=hello world') { $true } else { "空白入り引数が分割された" }
  }

  Test-Case "終了コードの伝播（42 / 0 / 127）" {
    & $Run _tests -- cmd /c "exit 42" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 42) { return "42 が伝わらない: $LASTEXITCODE" }
    & $Run _tests -- cmd /c "exit 0" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return "0 が伝わらない: $LASTEXITCODE" }
    & $Run _tests -- no-such-command-xyz 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 127) { return "コマンド不在で 127 にならない: $LASTEXITCODE" }
    $true
  }

  Test-Case "profile 自動検出（.secrets-profile を親までたどる）" {
    $sub = Join-Path $Sandbox 'proj\deep\nested'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Sandbox 'proj\.secrets-profile'), "_tests`n", $utf8NoBom)
    Push-Location $sub
    try {
      # 子プロセスに値が届いていれば、profile が解決できた証拠になる
      $o = (& $Run -- powershell -NoProfile -ExecutionPolicy Bypass -File $argProbe 2>&1 | Out-String)
      if ($o -match 'TESTVARLEN=([1-9]\d*)') { $true } else { "profile を解決できず値が注入されていない" }
    } finally { Pop-Location }
  }

  Test-Case "不足している秘密があると終了コード 1 で止まる" {
    [System.IO.File]::WriteAllText((Join-Path $Conf '_missing.map'),
      "NOPE=api-key/_tests/does-not-exist`n", $utf8NoBom)
    & $Run _missing -- cmd /c "exit 0" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 1) { $true } else { "期待 1、実際 $LASTEXITCODE" }
  }

  Section "secrets-run（@file: の実体化）"

  Test-Case "@file: が BOM 無しで書かれ、終了後に確実に削除される" {
    $json = "{`n  `"type`": `"service_account`",`n  `"project_id`": `"t`"`n}"
    Set-CachedSecret 'service-account/_tests/json' $json
    [System.IO.File]::WriteAllText((Join-Path $Conf '_file.map'),
      "TESTFILE=@file:service-account/_tests/json`n", $utf8NoBom)
    $fileProbe = Join-Path $Sandbox 'fileprobe.ps1'
    [System.IO.File]::WriteAllText($fileProbe, @'
$p = $env:TESTFILE
$b = [System.IO.File]::ReadAllBytes($p)
$bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
Write-Host ("BOM=" + $bom + " PATH=" + $p)
'@, (New-Object System.Text.UTF8Encoding($true)))
    $o = (& $Run _file -- powershell -NoProfile -ExecutionPolicy Bypass -File $fileProbe 2>&1 | Out-String)
    if ($o -notmatch 'BOM=False') { return "BOM が付いている（node の JSON.parse が失敗する）" }
    if ($o -match 'PATH=(.+?)[\r\n]') {
      $p = $Matches[1].Trim()
      if (Test-Path $p) { return "終了後も一時ファイルが残っている: $p" }
      if (Test-Path (Split-Path $p -Parent)) { return "一時フォルダが残っている" }
    } else { return "パスを取得できなかった" }
    $true
  }

  # -------------------------------------------------------------------------
  Section "secret-put"

  $Put = Join-Path $RepoWindows 'secret-put.ps1'

  Test-Case "パイプライン入力を受け取れる（param() を置くと拒否される）" {
    'put-test-single-line' | & $Put 'api-key/_tests/put1' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return "終了コード $LASTEXITCODE" }
    if ((Get-SecretHash (Get-CachedSecret 'api-key/_tests/put1')) -ne (Get-SecretHash 'put-test-single-line')) { return "値が一致しない" }
    $true
  }
  Test-Case "複数行を Get-Content（-Raw 無し）で渡しても復元される" {
    $f = Join-Path $Sandbox 'multi.txt'
    [System.IO.File]::WriteAllText($f, "line1`nline2`nline3", $utf8NoBom)
    Get-Content $f | & $Put 'api-key/_tests/put2' 2>&1 | Out-Null
    if ((Get-CachedSecret 'api-key/_tests/put2') -notmatch 'line2') { return "複数行が壊れた" }
    $true
  }
  Test-Case "空の値は 1、名前なしは 2" {
    '   ' | & $Put 'api-key/_tests/empty' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 1) { return "空値の終了コードが $LASTEXITCODE" }
    'x' | & $Put 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 2) { return "名前なしの終了コードが $LASTEXITCODE" }
    $true
  }

  # -------------------------------------------------------------------------
  Section "secret-verify"

  $Verify = Join-Path $RepoWindows 'secret-verify.ps1'
  Set-CachedSecret 'api-key/_tests/verify' 'verify-target-value'

  Test-Case "一致 / 不一致 / 末尾改行 / BOM / firstline / 未登録 / rtf 拒否" {
    $mk = { param($n,$t,$enc) $p = Join-Path $Sandbox $n; [System.IO.File]::WriteAllText($p,$t,$enc); $p }
    $bomEnc = New-Object System.Text.UTF8Encoding($true)
    $ok    = & $mk 'v-ok.txt'    'verify-target-value'          $utf8NoBom
    $ng    = & $mk 'v-ng.txt'    'verify-target-valueX'         $utf8NoBom
    $crlf  = & $mk 'v-crlf.txt'  "verify-target-value`r`n"      $utf8NoBom
    $bom   = & $mk 'v-bom.txt'   'verify-target-value'          $bomEnc
    $multi = & $mk 'v-multi.txt' "verify-target-value`nsecond"  $utf8NoBom

    & $Verify 'api-key/_tests/verify' $ok    2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { return "一致が 0 でない" }
    & $Verify 'api-key/_tests/verify' $ng    2>&1 | Out-Null; if ($LASTEXITCODE -ne 1) { return "不一致が 1 でない" }
    & $Verify 'api-key/_tests/verify' $crlf  2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { return "末尾 CRLF が落ちていない" }
    & $Verify 'api-key/_tests/verify' $bom   2>&1 | Out-Null; if ($LASTEXITCODE -ne 1) { return "BOM 付きが一致になった（Mac と判定がずれる）" }
    & $Verify 'api-key/_tests/verify' $multi firstline 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { return "firstline が効かない" }
    & $Verify 'api-key/_tests/verify' $multi 2>&1 | Out-Null; if ($LASTEXITCODE -ne 1) { return "plain で複数行が一致した" }
    & $Verify 'api-key/_tests/nope'   $ok    2>&1 | Out-Null; if ($LASTEXITCODE -ne 1) { return "未登録が 1 でない" }
    & $Verify 'api-key/_tests/verify' $ok rtf 2>&1 | Out-Null; if ($LASTEXITCODE -ne 2) { return "rtf 拒否が 2 でない" }
    $true
  }

  # -------------------------------------------------------------------------
  Section "金庫を開くテスト"
  if (-not $WithVault) {
    Skip-Case "secret-sync / secret-list-remote / secret-push-bw" "-WithVault 未指定"
  } else {
    # 本物の設定でしか動かないので USERPROFILE を戻して実行する
    $env:USERPROFILE = $RealProfile
    # 6>&1 が要る。これらのスクリプトは Write-Host で出力しており、Write-Host は
    # 情報ストリーム(6)なので 2>&1 だけでは捕まらず、$o が空のまま「失敗」に見える。
    Test-Case "secret-list-remote が項目を返す（値は出さない）" {
      $o = (& (Join-Path $RepoWindows 'secret-list-remote.ps1') 6>&1 2>&1 | Out-String)
      if ($o -notmatch '金庫の項目数: [1-9]') { return "項目数が取れない" }
      if ($o -match '(sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{20,})') { return "値らしき文字列が出力された" }
      $true
    }
    Test-Case "secret-push-bw が bundle/bitwarden/* を拒否する" {
      $o = (& (Join-Path $RepoWindows 'secret-push-bw.ps1') 'bundle/bitwarden/api-credentials' 6>&1 2>&1 | Out-String)
      if ($o -match '拒否' -and $o -match '登録 0 件') { $true } else { "安全弁が働いていない" }
    }
    $env:USERPROFILE = $Sandbox
  }
}
finally {
  $env:USERPROFILE = $RealProfile
  if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
  Get-ChildItem $env:TEMP -Directory -Filter 'secrets-run.*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("PASS {0} / FAIL {1} / SKIP {2}" -f $script:Pass, $script:Fail, $script:Skip)
if ($script:Fail -gt 0) {
  Write-Host "失敗:" -ForegroundColor Red
  $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
exit ([int]($script:Fail -gt 0))
