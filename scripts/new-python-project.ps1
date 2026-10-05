param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{2}-[a-z0-9-]+$')]
  [string]$ProjectName,

  [string]$PythonVersion = "3.12",

  [ValidateSet("app", "package")]
  [string]$Mode = "package",

  [switch]$SkipPytest,

  [switch]$CreateVenv = $true,

  [switch]$RunSync = $true,

  [switch]$AddToWorkspace = $true
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
  & uv @args
  if ($LASTEXITCODE -ne 0) {
    throw "uv $($args -join ' ') failed with exit code $LASTEXITCODE"
  }
}

Require-Command -Name "uv"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $repoRoot "projects"
# Polyglot layout: projects/<NN>-<name>/python sits next to projects/<NN>-<name>/csharp.
$projectDir = Join-Path $projectsRoot (Join-Path $ProjectName "python")
$workspaceFile = Join-Path $repoRoot "ai-learn.code-workspace"

if (Test-Path $projectDir) {
  throw "Project already exists: $projectDir"
}

# 1) Initialize the project with uv. Pass --name explicitly: uv defaults to the folder
#    name, which is now "python" for every project. Drop the "NN-" prefix so the import
#    package is a valid identifier: 03-token-lab -> name "token-lab", module "token_lab".
$packageName = $ProjectName -replace '^\d{2}-', ''
$uvArgs = @("init", $projectDir, "--name", $packageName, "--python", $PythonVersion)
if ($Mode -eq "package") {
  $uvArgs += "--package"
}
Invoke-Uv @uvArgs

# 2) Lay out the code folder for the chosen shape (docs/conventions.md#python-project-shapes).
#    package: code in src/<module>/ (uv init --package made it), installed via [build-system].
#    app:     code in app/ at the root, never installed; pytest finds it via pythonpath = ["."].
if ($Mode -eq "app") {
  $codeDir = "app"
  New-Item -ItemType Directory -Path (Join-Path $projectDir "app") -Force | Out-Null
  New-Item -ItemType File -Path (Join-Path $projectDir "app/__init__.py") -Force | Out-Null
  # uv init writes a hello-world main.py for apps; the Service shape keeps code in app/.
  Remove-Item -Path (Join-Path $projectDir "main.py") -ErrorAction SilentlyContinue
  Add-Content -Path (Join-Path $projectDir "pyproject.toml") -Encoding UTF8 -Value @'

[tool.pytest.ini_options]
pythonpath = ["."]
'@
}
else {
  $codeDir = "src"
}
New-Item -ItemType Directory -Path (Join-Path $projectDir "tests") -Force | Out-Null
$extraPath = if ($Mode -eq "app") { "." } else { "src" }

# 2a) Create a Pyright config so imports resolve reliably in tests.
$pyrightConfig = @"
{
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
Set-Content -Path (Join-Path $projectDir "pyrightconfig.json") -Value $pyrightConfig -Encoding UTF8

# 2b) Docker ignore file. BuildKit reads <Dockerfile>.dockerignore from next to the Dockerfile
#     whatever the build context is (this folder, the project root, or projects/), and the
#     **/ patterns match at any depth, so one file works for all three.
@'
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
'@ | Set-Content -Path (Join-Path $projectDir "Dockerfile.dockerignore") -Encoding UTF8

# 3) Optional test setup.
if (-not $SkipPytest) {
  Push-Location $projectDir
  try {
    # --no-sync: only record the dependency; step 5 decides whether a .venv gets created.
    Invoke-Uv add --dev pytest --no-sync
  }
  finally {
    Pop-Location
  }

  $testFile = Join-Path $projectDir "tests/test_smoke.py"
  @'
def test_smoke():
    assert True
'@ | Set-Content -Path $testFile -Encoding UTF8
}

# 4) Create project-local VS Code settings.
$vscodeDir = Join-Path $projectDir ".vscode"
New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null

$settings = @'
{
  "python.analysis.typeCheckingMode": "standard",
  "python.analysis.autoImportCompletions": true,
  "python.analysis.inlayHints.variableTypes": true,
  "python.analysis.inlayHints.functionReturnTypes": true,
  "python.analysis.diagnosticMode": "workspace",
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/Scripts/python.exe",
  "python.analysis.extraPaths": [
    "${workspaceFolder}/__EXTRA_PATH__"
  ],
  "python.testing.pytestEnabled": true,
  "python.testing.pytestArgs": [
    "tests"
  ],
  "python.testing.cwd": "${workspaceFolder}"
}
'@
$settings = $settings.Replace("/__EXTRA_PATH__", $(if ($extraPath -eq ".") { "" } else { "/$extraPath" }))
Set-Content -Path (Join-Path $vscodeDir "settings.json") -Value $settings -Encoding UTF8

# 5) Optional venv creation and dependency sync.
if ($CreateVenv) {
  Push-Location $projectDir
  try {
    if (-not (Test-Path ".venv")) {
      Invoke-Uv venv ".venv"
    }
    if ($RunSync) {
      Invoke-Uv sync
    }
  }
  finally {
    Pop-Location
  }
}

# 6) Optionally add this folder to the workspace file.
if ($AddToWorkspace -and (Test-Path $workspaceFile)) {
  $workspaceJson = Get-Content $workspaceFile -Raw | ConvertFrom-Json
  $relativePath = "projects/$ProjectName/python"
  $alreadyPresent = $false

  foreach ($folder in $workspaceJson.folders) {
    if ($folder.path -eq $relativePath) {
      $alreadyPresent = $true
      break
    }
  }

  if (-not $alreadyPresent) {
    $workspaceJson.folders += [pscustomobject]@{ path = $relativePath }
    # The committed file is tab-indented; ConvertTo-Json uses two spaces. Convert back so the
    # diff shows only the new folder.
    $json = $workspaceJson | ConvertTo-Json -Depth 10
    $json = [regex]::Replace($json, "(?m)^((?:  )+)", { param($m) "`t" * ($m.Groups[1].Value.Length / 2) })
    Set-Content -Path $workspaceFile -Value $json -Encoding UTF8
  }
}

# 7) Set AI_LEARN_PROJECT to the new project name.
$env:AI_LEARN_PROJECT = $ProjectName
[Environment]::SetEnvironmentVariable("AI_LEARN_PROJECT", $ProjectName, "User")

Write-Host "Created project: $projectDir"
Write-Host "Package: $packageName | Mode: $Mode | Python: $PythonVersion | Pytest enabled: $(-not $SkipPytest)"
Write-Host "Venv created: $CreateVenv | Synced: $RunSync | Added to workspace: $AddToWorkspace"
Write-Host "AI_LEARN_PROJECT set for this script process: $ProjectName"
Write-Host "AI_LEARN_PROJECT persisted for future terminals (User scope): $ProjectName"
Write-Host "If you ran this via 'pwsh ./scripts/new-python-project.ps1 ...', run this in your current shell now: `n`$env:AI_LEARN_PROJECT = `"$ProjectName`""
