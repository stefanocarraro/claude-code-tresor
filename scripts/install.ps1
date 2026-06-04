param(
    [switch]$SkillsOnly,
    [switch]$CommandsOnly,
    [switch]$AgentsOnly,
    [switch]$OrchestrationOnly,
    [switch]$ResourcesOnly,
    [switch]$UpdateOnly,
    [switch]$NoBackup
)

# Claude Code Tresor Installation Script (PowerShell)
# Converted from Bash

$ErrorActionPreference = "Stop"

# Colors
function Log($msg) { Write-Host "[INFO] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function ErrorExit($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Header($msg) { Write-Host "`n=== $msg ===`n" -ForegroundColor Blue }

# Config
$CLAUDE_CODE_DIR = Join-Path $HOME ".claude"
$REPO_URL = "https://github.com/alirezarezvani/claude-code-tresor"
$TRESOR_DIR = Join-Path $CLAUDE_CODE_DIR "tresor"
$BACKUP_DIR = Join-Path $CLAUDE_CODE_DIR ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

# Flags (from params)
$SKILLS_ONLY = $SkillsOnly.IsPresent
$COMMANDS_ONLY = $CommandsOnly.IsPresent
$AGENTS_ONLY = $AgentsOnly.IsPresent
$ORCHESTRATION_ONLY = $OrchestrationOnly.IsPresent
$RESOURCES_ONLY = $ResourcesOnly.IsPresent
$UPDATE_ONLY = $UpdateOnly.IsPresent
$NO_BACKUP = $NoBackup.IsPresent

# -----------------------
function Check-Dependencies {
    Header "Checking Dependencies"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        ErrorExit "Git is not installed."
    }
    Log "Git is available"

    if (Get-Command claude-code -ErrorAction SilentlyContinue) {
        Log "Claude Code CLI detected"
    } else {
        Warn "Claude Code CLI not found (optional)"
    }
}

# -----------------------
function Create-Directories {
    Header "Creating Directories"

    if (-not (Test-Path $CLAUDE_CODE_DIR)) {
        Log "Creating $CLAUDE_CODE_DIR"
        New-Item -ItemType Directory -Force -Path $CLAUDE_CODE_DIR | Out-Null
    }

    "commands","agents","skills","templates" | ForEach-Object {
        New-Item -ItemType Directory -Force -Path (Join-Path $CLAUDE_CODE_DIR $_) | Out-Null
    }

    Log "Directory structure ready"
}

# -----------------------
function Backup-Existing {
    Header "Backup Existing"

    if (Test-Path $TRESOR_DIR) {
        Log "Creating backup: $BACKUP_DIR"
        Copy-Item $CLAUDE_CODE_DIR $BACKUP_DIR -Recurse
    } else {
        Log "No existing installation"
    }
}

# -----------------------
function Clone-Repository {
    Header "Downloading Repo"

    if (Test-Path $TRESOR_DIR) {
        Log "Updating existing repo"
        Push-Location $TRESOR_DIR
        git pull origin main
        Pop-Location
    } else {
        git clone $REPO_URL $TRESOR_DIR
    }
}

# -----------------------
function Install-Commands {
    Header "Installing Commands"

    $src = Join-Path $TRESOR_DIR "commands"
    $dest = Join-Path $CLAUDE_CODE_DIR "commands"

    if (-not (Test-Path $src)) {
        Warn "Commands not found"
        return
    }

    Get-ChildItem $src -Directory | ForEach-Object {
        $category = $_.Name
        Get-ChildItem $_.FullName -Directory | ForEach-Object {
            $cmd = $_.Name
            $destDir = Join-Path $dest "$category-$cmd"

            Log "Installing $category/$cmd"
            Copy-Item $_.FullName $destDir -Recurse -Force
        }
    }
}

# -----------------------
function Install-Orchestration {
    Header "Installing Orchestration Commands"

    $categories = "security","performance","operations","quality"
    $src = Join-Path $TRESOR_DIR "commands"
    $dest = Join-Path $CLAUDE_CODE_DIR "commands"

    foreach ($cat in $categories) {
        $path = Join-Path $src $cat
        if (Test-Path $path) {
            Get-ChildItem $path -Directory | ForEach-Object {
                $cmd = $_.Name
                $destDir = Join-Path $dest "$cat-$cmd"
                Copy-Item $_.FullName $destDir -Recurse -Force
            }
        }
    }
}

# -----------------------
function Filter-YamlText($yaml, $allowedFields) {
    $lines = $yaml -split "\r?\n"
    $result = @()
    foreach ($line in $lines) {
        foreach ($field in $allowedFields) {
            if ($line -match "^$field\s*:") {
                $result += $line
                break
            }
        }
    }
    return ($result -join "`n")
}

function Install-Agents {
    Header "Installing Agents (Advanced YAML parsing)"

    $src = Join-Path $TRESOR_DIR "subagents/core"
    $dest = Join-Path $CLAUDE_CODE_DIR "agents"

    if (-not (Test-Path $src)) {
        Warn "Subagents core directory not found"
        return
    }

    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    # Try load YAML module (optional but recommended)
    $yamlAvailable = $false
    if (Get-Module -ListAvailable -Name powershell-yaml) {
        Import-Module powershell-yaml
        $yamlAvailable = $true
    } else {
        Warn "powershell-yaml not installed → fallback parser will be used"
    }

    $allowedFields = @("name","description","tools","model","enabled")

    Get-ChildItem $src -Directory | ForEach-Object {
        $agentName = $_.Name
        $file = Join-Path $_.FullName "agent.md"

        if (-not (Test-Path $file)) { return }

        Log "Processing agent: $agentName"

        $content = Get-Content $file -Raw

        # Split frontmatter + body
        if ($content -match "(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$") {
            $yamlRaw = $matches[1]
            $body = $matches[2]

            if ($yamlAvailable) {
                try {
                    $yamlObj = ConvertFrom-Yaml $yamlRaw

                    # Filter allowed fields
                    $filtered = @{}
                    foreach ($key in $allowedFields) {
                        if ($yamlObj.ContainsKey($key)) {
                            $filtered[$key] = $yamlObj[$key]
                        }
                    }

                    # Rebuild YAML
                    $newYaml = ($filtered | ConvertTo-Yaml).Trim()

                } catch {
                    Warn "YAML parsing failed → fallback to text filter"
                    $newYaml = Filter-YamlText $yamlRaw $allowedFields
                }
            } else {
                $newYaml = Filter-YamlText $yamlRaw $allowedFields
            }

            # Rebuild final file
            $final = @"
---
$newYaml
---
$body
"@

            $outFile = Join-Path $dest "$agentName.md"
            $final | Set-Content $outFile -Encoding UTF8
        }
    }

    Log "Agents installed with YAML filtering"
}

# -----------------------
function Install-Subagents {
    Header "Installing Subagents"

    $src = Join-Path $TRESOR_DIR "subagents"
    $dest = Join-Path $CLAUDE_CODE_DIR "subagents"

    if (Test-Path $src) {
        Copy-Item $src $dest -Recurse -Force
    }
}

# -----------------------
function Install-Skills {
    Header "Installing Skills"

    $src = Join-Path $TRESOR_DIR "skills"
    $dest = Join-Path $CLAUDE_CODE_DIR "skills"

    if (-not (Test-Path $src)) { return }

    Get-ChildItem $src -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName "SKILL.md")) {
                Copy-Item $_.FullName (Join-Path $dest $_.Name) -Recurse -Force
            }
        }
    }
}

# -----------------------
function Install-Resources {
    Header "Installing Resources"

    $dest = Join-Path $CLAUDE_CODE_DIR "tresor-resources"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    "prompts","standards","examples" | ForEach-Object {
        $path = Join-Path $TRESOR_DIR $_
        if (Test-Path $path) {
            Copy-Item $path $dest -Recurse -Force
        }
    }
}

# -----------------------
function Create-Config {
    Header "Creating Config"

    $config = @{
        version = "1.0.0"
        installed = (Get-Date).ToUniversalTime().ToString("o")
        repository = $REPO_URL
    }

    $config | ConvertTo-Json | Set-Content (Join-Path $CLAUDE_CODE_DIR "tresor.config.json")
}

# -----------------------
function Main {
    Header "Claude Code Tresor Installation"

    Check-Dependencies
    Create-Directories

    if (-not $NO_BACKUP) { Backup-Existing }

    Clone-Repository

    if ($SKILLS_ONLY) { Install-Skills }
    elseif ($COMMANDS_ONLY) { Install-Commands }
    elseif ($AGENTS_ONLY) {
        Install-Agents
        Install-Subagents
    }
    elseif ($ORCHESTRATION_ONLY) { Install-Orchestration }
    elseif ($RESOURCES_ONLY) { Install-Resources }
    elseif ($UPDATE_ONLY) {
        Install-Skills
        Install-Commands
        Install-Agents
        Install-Subagents
        Install-Resources
    }
    else {
        Install-Skills
        Install-Commands
        Install-Agents
        Install-Subagents
        Install-Resources
        Create-Config
    }

    Log "Installation completed"
}

# -----------------------
Main