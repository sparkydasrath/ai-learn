param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{2}-[a-z0-9-]+$')]
  [string]$ProjectName,

  [string]$PythonVersion = "3.11",

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

Require-Command -Name "uv"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $repoRoot "projects"
$projectDir = Join-Path $projectsRoot $ProjectName
$workspaceFile = Join-Path $repoRoot "ai-learn.code-workspace"

if (Test-Path $projectDir) {
  throw "Project already exists: $projectDir"
}

# 1) Initialize the project with uv.
$uvArgs = @("init", $projectDir, "--python", $PythonVersion)
if ($Mode -eq "package") {
  $uvArgs += "--package"
}
& uv @uvArgs

# 2) Ensure conventional source and test folders exist.
New-Item -ItemType Directory -Path (Join-Path $projectDir "src") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $projectDir "tests") -Force | Out-Null

# 3) Optional test setup.
if (-not $SkipPytest) {
  Push-Location $projectDir
  try {
    & uv add --dev pytest
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
    "${workspaceFolder}/src"
  ],
  "python.testing.pytestEnabled": true,
  "python.testing.pytestArgs": [
    "tests"
  ],
  "python.testing.cwd": "${workspaceFolder}"
}
'@
Set-Content -Path (Join-Path $vscodeDir "settings.json") -Value $settings -Encoding UTF8

# 5) Create a local task so any project can scaffold another project.
$tasks = @'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "AI Learn: Bootstrap New Project",
      "type": "shell",
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/../../scripts/new-project.ps1",
        "-ProjectName",
        "${input:projectName}",
        "-Mode",
        "${input:projectMode}",
        "-PythonVersion",
        "${input:pythonVersion}"
      ],
      "options": {
        "cwd": "${workspaceFolder}/../.."
      },
      "problemMatcher": []
    }
  ],
  "inputs": [
    {
      "id": "projectName",
      "type": "promptString",
      "description": "Project folder name (example: 04-my-new-project)",
      "default": "04-my-new-project"
    },
    {
      "id": "projectMode",
      "type": "pickString",
      "description": "uv init mode",
      "options": [
        "package",
        "app"
      ],
      "default": "package"
    },
    {
      "id": "pythonVersion",
      "type": "promptString",
      "description": "Python version passed to uv init --python",
      "default": "3.11"
    }
  ]
}
'@
Set-Content -Path (Join-Path $vscodeDir "tasks.json") -Value $tasks -Encoding UTF8

# 6) Optional venv creation and dependency sync.
if ($CreateVenv) {
  Push-Location $projectDir
  try {
    & uv venv ".venv"
    if ($RunSync) {
      & uv sync
    }
  }
  finally {
    Pop-Location
  }
}

# 7) Optionally add this folder to the workspace file.
if ($AddToWorkspace -and (Test-Path $workspaceFile)) {
  $workspaceJson = Get-Content $workspaceFile -Raw | ConvertFrom-Json
  $relativePath = "projects/$ProjectName"
  $alreadyPresent = $false

  foreach ($folder in $workspaceJson.folders) {
    if ($folder.path -eq $relativePath) {
      $alreadyPresent = $true
      break
    }
  }

  if (-not $alreadyPresent) {
    $workspaceJson.folders += [pscustomobject]@{ path = $relativePath }
    $workspaceJson | ConvertTo-Json -Depth 10 | Set-Content -Path $workspaceFile -Encoding UTF8
  }
}

# 8) Set AI_LEARN_PROJECT to the new project name.
$env:AI_LEARN_PROJECT = $ProjectName
[Environment]::SetEnvironmentVariable("AI_LEARN_PROJECT", $ProjectName, "User")

Write-Host "Created project: $projectDir"
Write-Host "Mode: $Mode | Python: $PythonVersion | Pytest enabled: $(-not $SkipPytest)"
Write-Host "Venv created: $CreateVenv | Synced: $RunSync | Added to workspace: $AddToWorkspace"
Write-Host "AI_LEARN_PROJECT set for this script process: $ProjectName"
Write-Host "AI_LEARN_PROJECT persisted for future terminals (User scope): $ProjectName"
Write-Host "If you ran this via 'pwsh ./scripts/new-project.ps1 ...', run this in your current shell now: `n`$env:AI_LEARN_PROJECT = `"$ProjectName`""
