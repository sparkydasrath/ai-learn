# Project Bootstrap Automation (Python + C#)

This guide explains how the two project bootstrap scripts work, how to run them from a terminal or a VS Code task, and what files they create.

## Why this exists

From module 03 on, every project is built twice, once in Python and once in C#. See [00 — Two languages](00-how-to-use-these-docs.md#two-languages-python-first-then-c). Each project folder holds one self-contained subfolder per language:

```
projects/<NN>-<name>/
├── fixtures/   # shared data both languages read; created by hand (not by either script)
├── python/     # created by scripts/new-python-project.ps1
└── csharp/     # created by scripts/new-csharp-project.ps1
```

Each language side has its own:

- toolchain environment: `.venv` for Python, a `.slnx` solution for C#
- code and `tests/` layout: `src/` (Python library, C#) or `app/` (Python service)
- test framework: pytest or NUnit
- `Dockerfile.dockerignore` (the Dockerfile itself comes from the module doc)
- `.vscode/settings.json`

The rules these files follow are in [Conventions](conventions.md).

Creating that by hand is repetitive and error-prone. The scripts standardize it. Run the Python one first, since Python is the spec, then the C# one when you're ready for the second implementation. Neither script touches the other language's folder.

## Files added for automation

- `scripts/new-python-project.ps1`
- `scripts/new-csharp-project.ps1`
- `.vscode/tasks.json`: one task per script, loaded by VS Code from the root folder

Both scripts also:

- set `AI_LEARN_PROJECT` for the script process
- set `AI_LEARN_PROJECT` in User environment variables for future terminals
- optionally add their language folder to `ai-learn.code-workspace`

## Naming convention

Both scripts take the same project name, which must match:

- two digits
- hyphen
- lowercase slug

Pattern: `^\d{2}-[a-z0-9-]+$`

Examples:

- `04-my-new-project`
- `12-rag-evals`

Use the same name for both languages so they land in the same `projects/<NN>-<name>/` folder.

## Python: `new-python-project.ps1`

### What it does

Given a project name like `04-my-new-project`, the script will:

1. Run `uv init` into `projects/04-my-new-project/python/` with your selected mode and Python version. It passes `--name` with the `NN-` prefix dropped (`04-my-new-project` → package `my-new-project`, module `my_new_project`), so the package isn't named after the `python` folder and the module name is a valid Python identifier.
2. Lay out the code for the chosen [project shape](conventions.md#python-project-shapes):
   - `package` (library, the default): `uv init --package` creates `src/<module>/` and a `[build-system]` using `uv_build`, so the project installs itself.
   - `app` (service): creates `app/__init__.py` at the root, deletes `uv init`'s hello-world `main.py`, and adds `[tool.pytest.ini_options] pythonpath = ["."]` so tests can `import app`. No build system; it's never installed.
3. Create `tests/`, and write `pyrightconfig.json` so Pylance resolves imports from `src` (or the root, for `app`) in tests.
4. Write `Dockerfile.dockerignore` (`.venv/`, caches, `outputs/`, `bin/`, `obj/`, all as `**/` patterns, so it works whatever the build context).
5. Optionally add pytest as a dev dependency (`uv add --dev pytest --no-sync`) and create `tests/test_smoke.py`.
6. Create `.vscode/settings.json` with the per-project interpreter and import path.
7. Optionally create `.venv` and run `uv sync`. With `-CreateVenv:$false`, no `.venv` is created at all.
8. Optionally append `projects/04-my-new-project/python` to `ai-learn.code-workspace`.
9. Set `AI_LEARN_PROJECT` (see [environment settings](env-settings.md#the-active-project)).

### Parameters

Required:

- `-ProjectName`

Optional:

- `-PythonVersion` (default: 3.12)
- `-Mode app|package` (default: package)
- `-SkipPytest`
- `-CreateVenv` (default: true)
- `-RunSync` (default: true)
- `-AddToWorkspace` (default: true)

### Usage

Run from the repository root:

    pwsh ./scripts/new-python-project.ps1 -ProjectName 04-my-new-project

A service (FastAPI app) instead of a library:

    pwsh ./scripts/new-python-project.ps1 -ProjectName 07-rag-service -Mode app

A different Python version (the curriculum assumes 3.12):

    pwsh ./scripts/new-python-project.ps1 -ProjectName 05-cli-tool -PythonVersion 3.13

Skip pytest setup:

    pwsh ./scripts/new-python-project.ps1 -ProjectName 06-fast-scratch -SkipPytest

Do not create venv or sync yet:

    pwsh ./scripts/new-python-project.ps1 -ProjectName 07-later-setup -CreateVenv:$false -RunSync:$false

Do not update workspace file:

    pwsh ./scripts/new-python-project.ps1 -ProjectName 08-experiment -AddToWorkspace:$false

### Generated VS Code settings

Each Python project gets:

- `python.defaultInterpreterPath = ${workspaceFolder}/.venv/Scripts/python.exe`
- `python.analysis.extraPaths = [${workspaceFolder}/src]` (or `[${workspaceFolder}]` for `-Mode app`)
- pytest enabled with `tests` as default target

This avoids cross-project import bleed and keeps Pylance resolution local.

## C#: `new-csharp-project.ps1`

### What it does

Given a project name like `04-my-new-project`, the script will:

1. Create `projects/04-my-new-project/csharp/` and a solution in it. The .NET 10 SDK produces `.slnx`. The solution name defaults to the slug in PascalCase (`04-my-new-project` → `MyNewProject`); override it with `-Name`.
2. Create the main project in `src/<Name>` from the chosen template and target framework, and add it to the solution.
3. Optionally create an NUnit test project in `tests/<Name>.Tests`, add it to the solution, reference the main project, and replace the template's `UnitTest1.cs` with `SmokeTests.cs`. (A module whose tests must not see the app's types, like the capstone's contract tests, tells you to remove that reference.)
4. Write `Directory.Build.props` (nullable enabled, implicit usings, latest C#, warnings as errors) so every project in the solution shares the same settings. It's the C# counterpart of the strictness in `pyrightconfig.json`.
5. Write `Dockerfile.dockerignore` (`bin/`, `obj/`, `.vs/`, `models/`, `.venv/`, as `**/` patterns) so local build output and downloaded model files stay out of the build context. BuildKit reads it from next to the Dockerfile whatever the context is: `csharp/`, the project root, or `projects/` ([Docker conventions](conventions.md#docker)).
6. Write a `README.md` with the everyday `dotnet build` / `test` / `run` commands.
7. Create `.vscode/settings.json` pointing C# Dev Kit at the solution (`dotnet.defaultSolution`).
8. Optionally run `dotnet build`, so the scaffold is known to build before you write code.
9. Optionally append `projects/04-my-new-project/csharp` to `ai-learn.code-workspace`.
10. Set `AI_LEARN_PROJECT`.

Any `dotnet` command that fails stops the script with its exit code. It won't carry on with a half-built scaffold.

### Parameters

Required:

- `-ProjectName`

Optional:

- `-Name` (default: slug in PascalCase; must start with an uppercase letter)
- `-Framework` (default: net10.0)
- `-Template console|classlib|webapi` (default: console)
- `-SkipTests`
- `-RunBuild` (default: true)
- `-AddToWorkspace` (default: true)

### Usage

Run from the repository root:

    pwsh ./scripts/new-csharp-project.ps1 -ProjectName 04-my-new-project

A web API with an explicit solution name:

    pwsh ./scripts/new-csharp-project.ps1 -ProjectName 07-rag-service -Template webapi -Name RagService

A class library without tests, without building yet:

    pwsh ./scripts/new-csharp-project.ps1 -ProjectName 08-experiment -Template classlib -SkipTests -RunBuild:$false

### What you get

    projects/04-my-new-project/csharp/
    ├── MyNewProject.slnx
    ├── Directory.Build.props
    ├── Dockerfile.dockerignore
    ├── .vscode/settings.json
    ├── README.md
    ├── src/MyNewProject/MyNewProject.csproj
    └── tests/MyNewProject.Tests/
        ├── MyNewProject.Tests.csproj
        └── SmokeTests.cs

Add packages with `dotnet add src/<Name> package <Package>`. Each module's doc lists the ones it needs. The script doesn't write a Dockerfile because it's specific to each module. The module's doc gives you one.

## Usage from VS Code tasks

From the repository root or `ai-learn.code-workspace`:

1. Open Command Palette.
2. Run **Tasks: Run Task**.
3. Choose **AI Learn: Bootstrap New Python Project** or **AI Learn: Bootstrap New C# Project**.
4. Answer the prompts: project name, plus mode and Python version (Python) or template and framework (C#).

The C# task doesn't ask for `-Name` or `-SkipTests`. When a module gives you a command with those, run it from a pwsh terminal instead.

Both tasks run their script from the repository root.

## Common issues

`pwsh`, `uv` or `dotnet` command not found:

- The scripts and tasks need PowerShell 7 (`pwsh`), not the Windows PowerShell 5.1 that ships with Windows: `winget install Microsoft.PowerShell`.
- Ensure uv / the .NET 10 SDK is installed and on PATH (`uv --version`, `dotnet --list-sdks`).

Project already exists:

- Each script checks only its own language folder. `03-token-lab/python` existing doesn't block creating `03-token-lab/csharp`.
- If the language folder already exists, pick a new name or remove that folder first.

`dotnet new nunit` or `dotnet build` fails:

- The script stops and prints the failing command. Usually it's a missing template or SDK. Check `dotnet new list nunit` and `dotnet --list-sdks`.
- Build failures in a fresh scaffold are almost always warnings promoted to errors by `Directory.Build.props`. Fix the warning rather than turning the setting off.

Task cannot find script:

- Make sure you opened `ai-learn.code-workspace` (not a single subfolder).
- Confirm `scripts/new-python-project.ps1` and `scripts/new-csharp-project.ps1` exist.

Task does not appear in Tasks: Run Task:

- In VS Code, tasks are scoped to the current workspace context.
- This repository defines the bootstrap tasks in `.vscode/tasks.json` at the repository root.
- If you opened only a project subfolder (for example `projects/01-python-warmup`) instead of the repository root or workspace file, the tasks won't be available.
- Fix: open the repository root or `ai-learn.code-workspace`, then run Tasks: Run Task again.
- If it still does not appear, run Developer: Reload Window and retry.

New project not appearing in Explorer:

- If AddToWorkspace was disabled, add the language folder (e.g. `projects/04-my-new-project/csharp`) to `ai-learn.code-workspace` manually.
- If enabled, reload the window if Explorer does not refresh immediately.

## Suggested workflow

1. Create the Python side with its task or script.
2. Build it, run its tests, commit.
3. Create the C# side with its task or script.
4. Build it against the same behavior, cross-check outputs with the Python version, commit.
