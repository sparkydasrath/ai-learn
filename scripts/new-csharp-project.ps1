param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{2}-[a-z0-9-]+$')]
  [string]$ProjectName,

  # Solution/assembly name. Defaults to the slug in PascalCase: 03-token-lab -> TokenLab.
  [ValidatePattern('^[A-Z][A-Za-z0-9.]*$')]
  [string]$Name,

  [string]$Framework = "net10.0",

  [ValidateSet("console", "classlib", "webapi")]
  [string]$Template = "console",

  [switch]$SkipTests,

  # Skip the final dotnet build.
  [switch]$NoBuild,

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

# dotnet is a native command; $ErrorActionPreference doesn't stop on its failures.
function Invoke-Dotnet {
  & dotnet @args
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet $($args -join ' ') failed with exit code $LASTEXITCODE"
  }
}

Require-Command -Name "dotnet"

if (-not $Name) {
  $slug = $ProjectName -replace '^\d{2}-', ''
  $Name = -join ($slug -split '-' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) })
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $repoRoot "projects"
# Polyglot layout: projects/<NN>-<name>/csharp sits next to projects/<NN>-<name>/python.
$projectDir = Join-Path $projectsRoot (Join-Path $ProjectName "csharp")
$workspaceFile = Join-Path $repoRoot "ai-learn.code-workspace"
$testName = "$Name.Tests"

if (Test-Path $projectDir) {
  throw "Project already exists: $projectDir"
}
New-Item -ItemType Directory -Path $projectDir -Force | Out-Null

Push-Location $projectDir
try {
  # 1) Solution. The .NET 10 SDK creates .slnx by default.
  Invoke-Dotnet new sln -n $Name

  # 2) Main project under src/.
  Invoke-Dotnet new $Template -n $Name -o "src/$Name" -f $Framework
  Invoke-Dotnet sln add "src/$Name"

  # 3) Optional NUnit test project under tests/, referencing the main project.
  if (-not $SkipTests) {
    Invoke-Dotnet new nunit -n $testName -o "tests/$testName" -f $Framework
    Invoke-Dotnet sln add "tests/$testName"
    Invoke-Dotnet add "tests/$testName" reference "src/$Name"

    # Swap the template's UnitTest1.cs for a named smoke test (mirrors tests/test_smoke.py).
    Remove-Item "tests/$testName/UnitTest1.cs" -ErrorAction SilentlyContinue
    @"
using NUnit.Framework;

namespace $testName;

public class SmokeTests
{
    [Test]
    public void Smoke() => Assert.Pass();
}
"@ | Set-Content -Path "tests/$testName/SmokeTests.cs" -Encoding UTF8
  }
}
finally {
  Pop-Location
}

# 4) Shared build settings for every project in the solution (the C# analogue of pyrightconfig strictness).
@'
<Project>
  <PropertyGroup>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
</Project>
'@ | Set-Content -Path (Join-Path $projectDir "Directory.Build.props") -Encoding UTF8

# 5) Keep local build output and downloaded models out of the Docker build context.
#    BuildKit reads <Dockerfile>.dockerignore from next to the Dockerfile whatever the build
#    context is (this folder, the project root, or projects/), and the **/ patterns match at
#    any depth, so one file works for all three (docs/conventions.md#docker).
@'
**/bin/
**/obj/
**/.vs/
**/models/
**/.venv/
**/__pycache__/
**/outputs/
**/runs/
'@ | Set-Content -Path (Join-Path $projectDir "Dockerfile.dockerignore") -Encoding UTF8

# 6) Project README with the everyday commands.
$filterLine = if ($SkipTests) { "" } else { "dotnet test --filter `"FullyQualifiedName~SmokeTests`"`n" }
@"
# $ProjectName — C#

``````bash
dotnet build
dotnet test
$($filterLine)dotnet run --project src/$Name
``````
"@ | Set-Content -Path (Join-Path $projectDir "README.md") -Encoding UTF8

# 7) Project-local VS Code settings: point C# Dev Kit at this solution.
$solutionFile = Get-ChildItem -Path $projectDir -Filter "$Name.sln*" | Select-Object -First 1
$vscodeDir = Join-Path $projectDir ".vscode"
New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
@"
{
  "dotnet.defaultSolution": "$($solutionFile.Name)"
}
"@ | Set-Content -Path (Join-Path $vscodeDir "settings.json") -Encoding UTF8

# 8) Optional restore + build so the scaffold is known-good before you write code.
if (-not $NoBuild) {
  Push-Location $projectDir
  try {
    Invoke-Dotnet build
  }
  finally {
    Pop-Location
  }
}

# 9) Optionally add this folder to the workspace file.
if (-not $NoWorkspace -and (Test-Path $workspaceFile)) {
  $workspaceJson = Get-Content $workspaceFile -Raw | ConvertFrom-Json
  $relativePath = "projects/$ProjectName/csharp"
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

# 10) Set AI_LEARN_PROJECT to the new project name.
$env:AI_LEARN_PROJECT = $ProjectName
[Environment]::SetEnvironmentVariable("AI_LEARN_PROJECT", $ProjectName, "User")

Write-Host "Created project: $projectDir"
Write-Host "Solution: $($solutionFile.Name) | Template: $Template | Framework: $Framework | NUnit tests: $(-not $SkipTests)"
Write-Host "Built: $(-not $NoBuild) | Added to workspace: $(-not $NoWorkspace)"
Write-Host "AI_LEARN_PROJECT persisted for future terminals (User scope): $ProjectName"
Write-Host "If you ran this via 'pwsh ./scripts/new-csharp-project.ps1 ...', run this in your current shell now: `n`$env:AI_LEARN_PROJECT = `"$ProjectName`""
