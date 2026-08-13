# secrets-run.ps1 — 対応表に従って秘密を環境変数へ入れ、コマンドを実行する。
#   値は画面にもログにも出ない（子プロセスの環境変数にのみ渡る）。
#
#   使い方:
#     .\secrets-run.ps1 answer-prompter -- npm test
#     .\secrets-run.ps1 -- python scripts/grade.py     # .secrets-profile を自動検出
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

# ---- 引数を -- で分割 ----
#
# 注意（Windows 固有）: PowerShell のパーサは素の -- を「パラメータ終端」トークンとして
# 引数配列から取り除いてしまう。取り除かれるのは最初の1個だけで、他の引数の順序は保たれる。
#   PowerShell プロンプトから  : secrets-run.ps1 voice -- npm test  → @('voice','npm','test')
#   '--' とクォートした場合    : -- は残る
#   cmd.exe から powershell -File で呼んだ場合 : -- は残る
# よって「-- が有る場合」と「食われた場合」の両方を扱う。
$all = @($args)
$sep = [array]::IndexOf($all, '--')

if ($sep -ge 0) {
  # -- が残っている。素直に分割できる。
  $profileName = if ($sep -gt 0) { $all[0] } else { $null }
  # 1..0 は降順範囲 (1,0) になるため、-- が末尾の場合は空配列を明示的に返す
  $cmdParts = if ($sep -lt $all.Count - 1) { @($all[($sep + 1)..($all.Count - 1)]) } else { @() }
} else {
  # -- が食われた。順序は保たれているので、先頭が profile かコマンドかだけを判定する。
  $profileName = $null
  $cmdParts    = $all

  if ($all.Count -ge 1) {
    $isProfile = Test-SecretMap $all[0]
    $isCommand = [bool](Get-Command -Name $all[0] -ErrorAction SilentlyContinue)

    if ($isProfile -and $isCommand) {
      throw @"
profile 名と同名のコマンドが存在するため判別できません: $($all[0])
PowerShell は素の -- を引数から取り除くため、この場合は -- をクォートしてください:
  secrets-run.ps1 '--' $($all -join ' ')        # $($all[0]) をコマンドとして実行する場合
  secrets-run.ps1 $($all[0]) '--' <command>     # $($all[0]) を profile として使う場合
"@
    }
    if ($isProfile) {
      if ($all.Count -eq 1) { throw "実行するコマンドが指定されていません" }
      $profileName = $all[0]
      $cmdParts    = @($all[1..($all.Count - 1)])
    }
  }
}

if ($cmdParts.Count -eq 0) { throw "使い方: secrets-run.ps1 [profile] -- <command> [args...]" }

# ---- profile の自動検出 ----
if (-not $profileName) {
  $d = (Get-Location).Path
  while ($d) {
    $f = Join-Path $d '.secrets-profile'
    if (Test-Path $f) { $profileName = (Get-Content $f -Raw).Trim(); break }
    $parent = Split-Path $d -Parent
    if ($parent -eq $d) { break }
    $d = $parent
  }
}
if (-not $profileName) { throw "profile が指定されておらず、.secrets-profile も見つかりません" }

# ---- 値を環境変数へ ----
$entries = @(Read-SecretMap $profileName)
$tmpRoot = $null
$setVars = @()
$loaded = 0; $files = 0
$missing = @()

try {
  foreach ($e in $entries) {
    $name = $e.Name
    $asFile = $false
    if ($name.StartsWith('@file:')) { $asFile = $true; $name = $name.Substring(6) }

    $val = Get-CachedSecret $name
    if ($null -eq $val) { $missing += "$($e.Var) -> $name"; continue }

    if ($asFile) {
      if (-not $tmpRoot) {
        $tmpRoot = Join-Path $env:TEMP ("secrets-run." + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        # 先にフォルダを本人専用にしておく。中のファイルはこれを継承するので、
        # 平文が既定 ACL のまま存在する瞬間を作らない。
        $me    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $dAcl  = Get-Acl $tmpRoot
        $dAcl.SetAccessRuleProtection($true, $false)
        $dAcl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
          $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -Path $tmpRoot -AclObject $dAcl
      }
      $dest = Join-Path $tmpRoot ($name -replace '[\\/:*?"<>|]', '_')
      # PS 5.1 の Set-Content -Encoding UTF8 は BOM を付ける。BOM 付き JSON は
      # Google のクライアントライブラリ（node の JSON.parse 等）が読めないため、
      # BOM 無しで書く。PowerShell の ConvertFrom-Json は BOM を許容してしまうので、
      # PowerShell だけで検証すると見逃す。
      [System.IO.File]::WriteAllText($dest, $val, (New-Object System.Text.UTF8Encoding($false)))
      Set-Item -Path "Env:$($e.Var)" -Value $dest
      $files++
    } else {
      Set-Item -Path "Env:$($e.Var)" -Value $val
      $loaded++
    }
    $setVars += $e.Var
    Remove-Variable val
  }

  if ($missing.Count -gt 0) {
    Write-Host "secrets-run: ローカルに見つからない項目があります:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" }
    Write-Host "  secret-sync.ps1 を実行して取り込んでください"
    exit 1
  }

  Write-Host "secrets-run: profile=$profileName / 環境変数 $loaded 件, 一時ファイル $files 件を注入しました"

  # 注意: PowerShell の 1..0 は降順範囲 (1,0) になるため、
  #       引数が無い場合に $cmdParts[1..($cmdParts.Count-1)] を使ってはいけない
  #
  # @() で包むのは必須。潰れるのは範囲そのものではなく、**if 文の結果を代入する**ところ。
  # 実測（PS 5.1）:
  #     $c[1..1]                              -> Object[]（配列のまま）
  #     $x = if (...) { $c[1..1] } else {@()} -> String（if の出力がパイプラインを通り、
  #                                              要素1個の配列が展開されてスカラーになる）
  #     $x = @(if (...) { ... })              -> Object[]（これで防げる）
  # String を @cmdArgs で splat すると **1文字ずつの引数** に展開される。
  #   secrets-run -- python script.py  →  python は 's' 'c' 'r' ... を受け取って落ちる
  # 引数がちょうど1個のときだけ壊れる（2個以上なら if の出力も配列のまま）ため、
  # 2個以上で試すと気づけない。範囲の書き方を変えても直らないので @() を外さないこと。
  $cmdArgs = @(if ($cmdParts.Count -gt 1) { $cmdParts[1..($cmdParts.Count - 1)] } else { @() })

  # 子が PowerShell の関数・コマンドレットだと $LASTEXITCODE が更新されず、
  # 前のコマンドの値が残る。0 に初期化してから実行する。
  $global:LASTEXITCODE = 0
  try {
    & $cmdParts[0] @cmdArgs
  } catch [System.Management.Automation.CommandNotFoundException] {
    Write-Host "secrets-run: コマンドが見つかりません: $($cmdParts[0])" -ForegroundColor Red
    exit 127
  }
  exit $LASTEXITCODE
}
finally {
  foreach ($v in $setVars) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }

  # @file: の一時ファイルには平文が入っている。消えたことを必ず確認する
  # （握り潰すと、失敗したまま平文がディスクに残る）。
  if ($tmpRoot -and (Test-Path $tmpRoot)) {
    for ($i = 0; $i -lt 5 -and (Test-Path $tmpRoot); $i++) {
      if ($i -gt 0) { Start-Sleep -Milliseconds 200 }   # 子プロセスが掴んだままの場合に備える
      Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $tmpRoot) {
      # 削除できない場合、せめて中身を消してから知らせる（黙って残さない）
      Get-ChildItem $tmpRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try { [System.IO.File]::WriteAllBytes($_.FullName, (New-Object byte[] 0)) } catch { }
      }
      Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $tmpRoot) {
      Write-Host "secrets-run: 警告 — 一時ファイルを削除できませんでした: $tmpRoot" -ForegroundColor Red
      Write-Host "  内容は消去済みですが、手動で削除してください" -ForegroundColor Red
    }
  }
}
