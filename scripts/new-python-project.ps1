#Requires -Version 7.2
<#
.SYNOPSIS
  Scaffold the Python side of a module project: projects/<NN>-<name>/python/.

.DESCRIPTION
  Creates a uv project in the library (src/, installed) or service (app/, never installed) shape
  from docs/conventions.md, with ruff, pyright and pytest as dev tools and a smoke test that runs.
  Then syncs and runs ruff, pyright and pytest on it, so it starts green. If any step fails,
  everything it created is removed and the workspace file is put back.

  Full guide: docs/project-bootstrap-automation.md.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{2}-[a-z0-9]+(-[a-z0-9]+)*$')]
  [string]$ProjectName,

  [string]$PythonVersion = "3.12",

  [ValidateSet("app", "package")]
  [string]$Mode = "package",

  # One line for pyproject.toml and the package docstring. Default: "Module NN: <name>."
  [string]$Description,

  # Don't add pytest or a smoke test (ruff and pyright are still added).
  [switch]$SkipPytest,

  # Write the files only: no .venv, no uv sync, no checks.
  [switch]$NoSync,

  # Don't add the folder to ai-learn.code-workspace.
  [switch]$NoWorkspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

# uv is a native command; $ErrorActionPreference doesn't stop on its failures.
function Invoke-Uv {
  Write-Host "  > uv $($args -join ' ')" -ForegroundColor DarkGray
  & uv @args
  if ($LASTEXITCODE -ne 0) {
    throw "uv $($args -join ' ') failed with exit code $LASTEXITCODE"
  }
}

# UTF-8 without a BOM, LF line endings (.gitattributes normalizes to LF anyway).
function Write-TextFile {
  param([string]$Path, [AllowEmptyString()][string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $text = ($Content -replace "`r`n", "`n").TrimEnd("`n") + "`n"
  [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

Require-Command -Name "uv"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $repoRoot "projects"
# Polyglot layout: projects/<NN>-<name>/python sits next to projects/<NN>-<name>/csharp.
$projectRoot = Join-Path $projectsRoot $ProjectName
$projectDir = Join-Path $projectRoot "python"
$workspaceFile = Join-Path $repoRoot "ai-learn.code-workspace"

# Drop the "NN-" prefix so the import package is a valid identifier:
# 03-token-lab -> distribution "token-lab", module "token_lab".
$packageName = $ProjectName -replace '^\d{2}-', ''
$moduleName = $packageName -replace '-', '_'
$moduleNumber = $ProjectName.Substring(0, 2)
if (-not $Description) { $Description = "Module ${moduleNumber}: $packageName." }
$ruffTarget = "py" + ($PythonVersion -replace '\.', '')

# --- Preconditions: fail before creating anything. ----------------------------------------------
if (Test-Path $projectDir) {
  throw "Project already exists: $projectDir"
}
# A package named after a stdlib module (json, logging, types...) shadows the real one.
$check = 'import keyword, sys; n = sys.argv[1]; print("stdlib" if n in sys.stdlib_module_names else "keyword" if keyword.iskeyword(n) else "ok")'
$verdict = & uv run --no-project --quiet python -c $check $moduleName 2>$null
if ($LASTEXITCODE -eq 0 -and $verdict -eq 'stdlib') {
  throw "'$moduleName' is a standard-library module name; it would shadow the real one. Pick another project name."
}
if ($LASTEXITCODE -eq 0 -and $verdict -eq 'keyword') {
  throw "'$moduleName' is a Python keyword and can't be imported. Pick another project name."
}

$projectRootExisted = Test-Path $projectRoot   # the csharp/ side may already be there
$workspaceBefore = if (Test-Path $workspaceFile) { Get-Content $workspaceFile -Raw } else { $null }

try {
  # 1) uv init. --vcs none: no nested git repo. --author-from none: no name/email from git config.
  $uvArgs = @("init", $projectDir, "--name", $packageName, "--python", $PythonVersion,
    "--description", $Description, "--vcs", "none", "--author-from", "none", "--quiet")
  if ($Mode -eq "package") {
    $uvArgs += "--package"
  }
  Invoke-Uv @uvArgs

  $pyproject = Join-Path $projectDir "pyproject.toml"

  # 2) Lay out the code folder for the chosen shape (docs/conventions.md#python-project-shapes).
  #    package: code in src/<module>/ (uv init --package made it), installed via [build-system].
  #    app:     code in app/ at the root, never installed; pytest finds it via pythonpath = ["."].
  if ($Mode -eq "app") {
    $codeDir = "app"
    # uv init writes a hello-world main.py for apps; the Service shape keeps code in app/.
    Remove-Item -Path (Join-Path $projectDir "main.py") -ErrorAction SilentlyContinue
    Write-TextFile (Join-Path $projectDir "app/__init__.py") "`"`"`"$Description`"`"`""
  }
  else {
    $codeDir = "src"
    # uv init --package writes a hello-world main() and a [project.scripts] entry pointing at it.
    # Neither belongs in a library; a module doc adds an entry point when it has a CLI.
    Write-TextFile (Join-Path $projectDir "src/$moduleName/__init__.py") "`"`"`"$Description`"`"`""
    Write-TextFile (Join-Path $projectDir "src/$moduleName/py.typed") ""
    $toml = Get-Content $pyproject -Raw
    $toml = [regex]::Replace($toml, '(?ms)^\[project\.scripts\]\r?\n.*?(?=^\[|\z)', '')
    Write-TextFile $pyproject $toml
  }
  New-Item -ItemType Directory -Path (Join-Path $projectDir "tests") -Force | Out-Null
  $extraPath = if ($Mode -eq "app") { "." } else { "src" }

  # 3) Tool config. Pyright reads ONLY pyrightconfig.json when it exists (a [tool.pyright] table or
  #    a VS Code typeCheckingMode setting is then ignored), so every pyright setting lives here.
  Write-TextFile (Join-Path $projectDir "pyrightconfig.json") @"
{
  "pythonVersion": "$PythonVersion",
  "typeCheckingMode": "standard",
  "include": [
    "$codeDir",
    "tests"
  ],
  "executionEnvironments": [
    {
      "root": ".",
      "extraPaths": [
        "$extraPath"
      ]
    }
  ]
}
"@

  $pytestConfig = if ($Mode -eq "app") { "`n[tool.pytest.ini_options]`npythonpath = [`".`"]`n" } else { "" }
  Add-Content -Path $pyproject -Encoding utf8NoBOM -Value @"
$pytestConfig
[tool.ruff]
target-version = "$ruffTarget"
line-length = 100

[tool.ruff.lint]
# pyflakes, pycodestyle, isort, bugbear, pyupgrade
select = ["E", "F", "I", "B", "UP"]
"@

  # 3a) Docker ignore file. BuildKit reads <Dockerfile>.dockerignore from next to the Dockerfile
  #     whatever the build context is (this folder, the project root, or projects/), and the
  #     **/ patterns match at any depth, so one file works for all three.
  Write-TextFile (Join-Path $projectDir "Dockerfile.dockerignore") @'
**/.venv/
**/__pycache__/
**/.pytest_cache/
**/.ruff_cache/
**/.mypy_cache/
**/.vscode/
**/outputs/
**/runs/
**/bin/
**/obj/
'@

  # 4) Dev tools: ruff and pyright always, pytest unless skipped. --no-sync only records them;
  #    step 6 decides whether a .venv gets created.
  $devTools = @("ruff", "pyright")
  if (-not $SkipPytest) { $devTools += "pytest" }
  Push-Location $projectDir
  try {
    Invoke-Uv add --dev --no-sync --quiet @devTools
  }
  finally {
    Pop-Location
  }

  # 5) Smoke test. A library's test proves the package is *installed* (the thing a hand setup
  #    gets wrong); a service's proves app/ imports through pythonpath.
  if (-not $SkipPytest) {
    $smoke = if ($Mode -eq "package") {
      @"
"""Smoke test from the scaffold. Replace it once real tests exist."""

from importlib.metadata import version

import $moduleName


def test_package_is_installed() -> None:
    assert version("$packageName") == "0.1.0"
    assert $moduleName.__doc__
"@
    }
    else {
      @"
"""Smoke test from the scaffold. Replace it once real tests exist."""

import app


def test_app_package_imports() -> None:
    assert app.__doc__
"@
    }
    Write-TextFile (Join-Path $projectDir "tests/test_smoke.py") $smoke
  }

  # 5a) Project-local VS Code settings: interpreter and test discovery only. Type checking is
  #     configured in pyrightconfig.json, never here.
  $vscodeExtraPath = if ($extraPath -eq ".") { '${workspaceFolder}' } else { '${workspaceFolder}/' + $extraPath }
  Write-TextFile (Join-Path $projectDir ".vscode/settings.json") @"
{
  "python.analysis.autoImportCompletions": true,
  "python.analysis.inlayHints.variableTypes": true,
  "python.analysis.inlayHints.functionReturnTypes": true,
  "python.analysis.diagnosticMode": "workspace",
  "python.defaultInterpreterPath": "`${workspaceFolder}/.venv/Scripts/python.exe",
  "python.analysis.extraPaths": [
    "$vscodeExtraPath"
  ],
  "python.testing.pytestEnabled": true,
  "python.testing.pytestArgs": [
    "tests"
  ],
  "python.testing.cwd": "`${workspaceFolder}"
}
"@

  # 6) Sync, then check. A scaffold that starts red is a broken scaffold.
  if (-not $NoSync) {
    Push-Location $projectDir
    try {
      Invoke-Uv sync --quiet
      Invoke-Uv run --quiet ruff format .
      Invoke-Uv run --quiet ruff check .
      Invoke-Uv run --quiet pyright
      if (-not $SkipPytest) { Invoke-Uv run --quiet pytest -q }
    }
    finally {
      Pop-Location
    }
  }

  # 7) Optionally add this folder to the workspace file.
  if (-not $NoWorkspace -and (Test-Path $workspaceFile)) {
    $workspaceJson = Get-Content $workspaceFile -Raw | ConvertFrom-Json
    $relativePath = "projects/$ProjectName/python"
    if (-not ($workspaceJson.folders | Where-Object { $_.path -eq $relativePath })) {
      $workspaceJson.folders += [pscustomobject]@{ path = $relativePath }
      # The committed file is tab-indented; ConvertTo-Json uses two spaces. Convert back so the
      # diff shows only the new folder.
      $json = $workspaceJson | ConvertTo-Json -Depth 10
      $json = [regex]::Replace($json, "(?m)^((?:  )+)", { param($m) "`t" * ($m.Groups[1].Value.Length / 2) })
      Set-Content -Path $workspaceFile -Value $json -Encoding UTF8
    }
  }
}
catch {
  Write-Host "Failed: $_" -ForegroundColor Red
  Write-Host "Rolling back." -ForegroundColor Yellow
  if (Test-Path $projectDir) { Remove-Item $projectDir -Recurse -Force }
  if (-not $projectRootExisted -and (Test-Path $projectRoot)) { Remove-Item $projectRoot -Recurse -Force }
  if ($null -ne $workspaceBefore) { Set-Content -Path $workspaceFile -Value $workspaceBefore -NoNewline }
  throw
}

# 8) Set AI_LEARN_PROJECT to the new project name (docs/env-settings.md#the-active-project).
$env:AI_LEARN_PROJECT = $ProjectName
[Environment]::SetEnvironmentVariable("AI_LEARN_PROJECT", $ProjectName, "User")

Write-Host ""
Write-Host "Created project: $projectDir" -ForegroundColor Cyan
Write-Host "Package: $packageName | Module: $moduleName | Mode: $Mode | Python: $PythonVersion | Pytest: $(-not $SkipPytest)"
if ($NoSync) {
  Write-Host "Skipped sync and checks (-NoSync). Run from the project folder: uv sync; uv run pytest"
}
else {
  Write-Host "Synced; ruff, pyright$(if (-not $SkipPytest) { ' and pytest' }) pass."
}
Write-Host "Added to workspace: $(-not $NoWorkspace)"
Write-Host "AI_LEARN_PROJECT persisted for future terminals (User scope). In this shell, run: `n`$env:AI_LEARN_PROJECT = `"$ProjectName`""
