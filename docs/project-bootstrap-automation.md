# Project Bootstrap Automation with uv and VS Code

This guide explains how the project bootstrap script works, how to run it from terminal or VS Code task, and what files it creates.

## Why this exists

In this repo, each project under projects uses its own:

- .venv interpreter
- src import root
- pytest config
- .vscode settings

Creating that by hand is repetitive and error-prone. The bootstrap script standardizes it.

## Files added for automation

- scripts/new-project.ps1
- projects/<existing-project>/.vscode/tasks.json (task runner entrypoint)

The script also writes these in each newly created project:

- .vscode/settings.json
- .vscode/tasks.json
- pyrightconfig.json
- tests/test_smoke.py (unless pytest is skipped)

It also sets:

- AI_LEARN_PROJECT for the script process
- AI_LEARN_PROJECT in User environment variables for future terminals

## What the script does

Given a project name like 04-my-new-project, the script will:

1. Run uv init with your selected mode and Python version.
2. Ensure src and tests folders exist.
3. Write pyrightconfig.json so Pylance resolves imports from src in tests.
4. Optionally add pytest and create a smoke test.
5. Create .vscode/settings.json with per-project interpreter and src path.
6. Create .vscode/tasks.json so any project can bootstrap the next one.
7. Optionally create .venv and run uv sync.
8. Optionally append the project folder to ai-learn.code-workspace.
9. Set AI_LEARN_PROJECT to the project name for this run and persist it for future shells.

## Naming convention

Project names must match:

- two digits
- hyphen
- lowercase slug

Pattern: ^\\d{2}-[a-z0-9-]+$

Examples:

- 04-my-new-project
- 12-rag-evals

## Script parameters

Required:

- -ProjectName

Optional:

- -PythonVersion (default: 3.11)
- -Mode app|package (default: package)
- -SkipPytest
- -CreateVenv (default: true)
- -RunSync (default: true)
- -AddToWorkspace (default: true)

## Usage from terminal

Run from repository root:

    pwsh ./scripts/new-project.ps1 -ProjectName 04-my-new-project

Choose app mode and Python 3.12:

    pwsh ./scripts/new-project.ps1 -ProjectName 05-cli-tool -Mode app -PythonVersion 3.12

Skip pytest setup:

    pwsh ./scripts/new-project.ps1 -ProjectName 06-fast-scratch -SkipPytest

Do not create venv or sync yet:

    pwsh ./scripts/new-project.ps1 -ProjectName 07-later-setup -CreateVenv:$false -RunSync:$false

Do not update workspace file:

    pwsh ./scripts/new-project.ps1 -ProjectName 08-experiment -AddToWorkspace:$false

## Usage from VS Code task

From any project folder already in the workspace:

1. Open Command Palette.
2. Run Tasks: Run Task.
3. Choose AI Learn: Bootstrap New Project.
4. Provide project name, mode, and Python version when prompted.

The task calls scripts/new-project.ps1 from the repository root.

## Generated VS Code settings details

Each new project gets:

- python.defaultInterpreterPath = ${workspaceFolder}/.venv/Scripts/python.exe
- python.analysis.extraPaths = [${workspaceFolder}/src]
- pytest enabled with tests as default target

This avoids cross-project import bleed and keeps Pylance resolution local.

## Common issues

uv command not found:

- Ensure uv is installed and available on PATH.

Project already exists:

- Pick a new project name or remove the existing folder first.

Task cannot find script:

- Run the task from a project folder that lives under projects.
- Confirm scripts/new-project.ps1 exists.

New project not appearing in Explorer:

- If AddToWorkspace was disabled, add the folder manually to ai-learn.code-workspace.
- If enabled, reload the window if Explorer does not refresh immediately.

## Suggested workflow

1. Create project with the task.
2. Open the new project folder in workspace explorer.
3. Run tests.
4. Start implementation in src.
5. Commit the scaffold before feature work.
