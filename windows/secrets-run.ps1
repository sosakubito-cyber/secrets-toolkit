# secrets-run.ps1 — 対応表に従って秘密を環境変数へ入れ、コマンドを実行する。
#   値は画面にもログにも出ない（子プロセスの環境変数にのみ渡る）。
#
#   使い方:
#     .\secrets-run.ps1 answer-prompter -- npm test
#     .\secrets-run.ps1 -- python scripts/grade.py     # .secrets-profile を自動検出
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-common.ps1')

# ---- 引数を -- で分割 ----
$all = @($args)
$sep = [array]::IndexOf($all, '--')
if ($sep -lt 0) { throw "使い方: secrets-run.ps1 [profile] -- <command> [args...]" }
$profileName = if ($sep -gt 0) { $all[0] } else { $null }
$cmdParts    = @($all[($sep + 1)..($all.Count - 1)])
if ($cmdParts.Count -eq 0) { throw "実行するコマンドが指定されていません" }

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
      }
      $dest = Join-Path $tmpRoot ($name -replace '[\\/:*?"<>|]', '_')
      Set-Content -Path $dest -Value $val -Encoding UTF8 -NoNewline
      # 作成者だけが読めるようにする
      $acl = Get-Acl $dest
      $acl.SetAccessRuleProtection($true, $false)
      $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'Allow')))
      Set-Acl -Path $dest -AclObject $acl
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
  $cmdArgs = if ($cmdParts.Count -gt 1) { $cmdParts[1..($cmdParts.Count - 1)] } else { @() }
  & $cmdParts[0] @cmdArgs
  exit $LASTEXITCODE
}
finally {
  foreach ($v in $setVars) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  if ($tmpRoot -and (Test-Path $tmpRoot)) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
