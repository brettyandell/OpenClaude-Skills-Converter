<#
.SYNOPSIS
    Converts Claude Code skill files (SKILL.md) into OpenWebUI-compatible Python tool files.

.DESCRIPTION
    This script parses Claude Code SKILL.md files (with YAML frontmatter and markdown instructions),
    then generates OpenWebUI Python tool files with proper metadata, Valves, EventEmitter, and tool methods.
    It supports batch conversion of entire skill directories and embeds supporting files.

.PARAMETER InputPath
    Path to a single SKILL.md file or a directory containing skill folders.

.PARAMETER OutputPath
    Path to the output directory for generated .py files. Created if it does not exist.

.PARAMETER Author
    Author name for tool metadata. Default: "Claude Code Converter"

.PARAMETER AuthorUrl
    Optional author URL for metadata.

.PARAMETER Version
    Version string for metadata. Default: "0.1.0"

.PARAMETER License
    License string for metadata. Default: "MIT"

.EXAMPLE
    .\Convert-ClaudeSkillsToOpenWebUI.ps1 -InputPath "~/.claude/skills" -OutputPath "./openwebui-tools"

.EXAMPLE
    .\Convert-ClaudeSkillsToOpenWebUI.ps1 -InputPath "./my-skill/SKILL.md" -OutputPath "./tools" -Author "Jane Doe"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to SKILL.md file or directory containing skill folders")]
    [string]$InputPath,

    [Parameter(Mandatory = $true, HelpMessage = "Output directory for generated Python tool files")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$Author = "Claude Code Converter",

    [Parameter(Mandatory = $false)]
    [string]$AuthorUrl = "",

    [Parameter(Mandatory = $false)]
    [string]$Version = "0.1.0",

    [Parameter(Mandatory = $false)]
    [string]$License = "MIT"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------
# UTILITY FUNCTIONS
# ---------------------------------------------

function ConvertTo-PascalCase {
    param([string]$Value)
    $parts = $Value -split '[-_]'
    return ($parts | ForEach-Object {
        if ($_.Length -gt 0) {
            $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
        } else { "" }
    }) -join ''
}

function ConvertTo-SnakeCase {
    param([string]$Value)
    return ($Value -replace '-', '_').ToLower()
}

function Get-SkillFiles {
    param([string]$Path)

    $resolvedPath = Resolve-Path -Path $Path -ErrorAction Stop

    if (Test-Path $resolvedPath -PathType Leaf) {
        if ((Split-Path $resolvedPath -Leaf) -eq "SKILL.md") {
            return @($resolvedPath.ToString())
        } else {
            Write-Warning "File '$resolvedPath' is not a SKILL.md file. Skipping."
            return @()
        }
    }

    $found = Get-ChildItem -Path $resolvedPath -Recurse -Filter "SKILL.md" |
             Select-Object -ExpandProperty FullName
    if ($found.Count -eq 0) {
        Write-Warning "No SKILL.md files found under '$resolvedPath'."
    }
    return @($found)
}

function Parse-SkillFrontmatter {
    param([string]$FilePath)

    $lines = Get-Content -Path $FilePath -Encoding UTF8

    $yaml = @{}
    $bodyStartIndex = 0

    if ($lines.Count -gt 2 -and $lines[0].Trim() -eq '---') {
        $endIndex = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') {
                $endIndex = $i
                break
            }
        }

        if ($endIndex -gt 0) {
            $yamlBlock = $lines[1..($endIndex - 1)]
            $bodyStartIndex = $endIndex + 1

            foreach ($yline in $yamlBlock) {
                if ($yline -match '^\s*([\w][\w\-]*)\s*:\s*(.*)$') {
                    $key = $Matches[1].Trim()
                    $val = $Matches[2].Trim()
                    if ($val -match '^["''](.*)["'']$') {
                        $val = $Matches[1]
                    }
                    $yaml[$key] = $val
                }
            }
        }
    }

    $bodyLines = if ($bodyStartIndex -lt $lines.Count) {
        $lines[$bodyStartIndex..($lines.Count - 1)]
    } else { @() }
    $body = ($bodyLines -join "`n").Trim()

    return @{
        yaml    = $yaml
        content = $body
    }
}

function Get-SupportingFiles {
    param([string]$SkillFilePath)

    $dir = Split-Path -Parent $SkillFilePath
    $supportFiles = @{}

    $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne "SKILL.md" }
    foreach ($f in $files) {
        try {
            $fileContent = Get-Content -Path $f.FullName -Raw -Encoding UTF8
            $supportFiles[$f.Name] = $fileContent
        } catch {
            Write-Warning "Could not read supporting file: $($f.FullName)"
        }
    }

    $subdirs = @("templates", "examples", "scripts")
    foreach ($sub in $subdirs) {
        $subPath = Join-Path $dir $sub
        if (Test-Path $subPath -PathType Container) {
            $subFiles = Get-ChildItem -Path $subPath -File -Recurse -ErrorAction SilentlyContinue
            foreach ($sf in $subFiles) {
                try {
                    $relPath = $sf.FullName.Substring($dir.Length + 1)
                    $fileContent = Get-Content -Path $sf.FullName -Raw -Encoding UTF8
                    $supportFiles[$relPath] = $fileContent
                } catch {
                    Write-Warning "Could not read supporting file: $($sf.FullName)"
                }
            }
        }
    }

    return $supportFiles
}

function Escape-PythonString {
    param([string]$Value)
    $escaped = $Value -replace '\\', '\\\\' `
                       -replace "'", "\\\'" `
                       -replace "`r`n", '\n' `
                       -replace "`n", '\n' `
                       -replace "`r", '\n'
    return $escaped
}

function New-OpenWebUITool {
    param(
        [hashtable]$Yaml,
        [string]$SkillContent,
        [hashtable]$SupportingFiles,
        [string]$Author,
        [string]$AuthorUrl,
        [string]$Version,
        [string]$License
    )

    $skillName = if ($Yaml.ContainsKey("name") -and $Yaml["name"]) {
        $Yaml["name"]
    } else { "unnamed-skill" }

    $description = if ($Yaml.ContainsKey("description") -and $Yaml["description"]) {
        $Yaml["description"]
    } else { "Converted Claude Code skill" }

    $titlePascal = ConvertTo-PascalCase -Value $skillName
    $methodSnake = "execute_" + (ConvertTo-SnakeCase -Value $skillName)

    $escapedInstructions = Escape-PythonString -Value $SkillContent

    $supportBlock = ""
    if ($SupportingFiles.Count -gt 0) {
        $supportBlock += "`n`n# -- Supporting Files --`n"
        foreach ($key in $SupportingFiles.Keys) {
            $safeName = ($key -replace '[^\w]', '_').ToUpper()
            $escapedFile = Escape-PythonString -Value $SupportingFiles[$key]
            $supportBlock += "SUPPORT_FILE_$safeName = '$escapedFile'`n"
        }
    }

    $py = @"
"""
title: $titlePascal Skill Tool
author: $Author
author_url: $AuthorUrl
description: $description
required_open_webui_version: 0.7.0
requirements: pydantic
version: $Version
license: $License
"""

from typing import Any, Callable
from pydantic import BaseModel, Field
$supportBlock

class EventEmitter:
    """Helper class for sending status updates back to OpenWebUI."""

    def __init__(self, event_emitter: Callable[[dict], Any] = None):
        self.event_emitter = event_emitter

    async def progress_update(self, description: str):
        await self.emit(description)

    async def error_update(self, description: str):
        await self.emit(description, "error", True)

    async def success_update(self, description: str):
        await self.emit(description, "success", True)

    async def emit(
        self,
        description: str = "Unknown State",
        status: str = "in_progress",
        done: bool = False,
    ):
        if self.event_emitter:
            await self.event_emitter(
                {
                    "type": "status",
                    "data": {
                        "status": status,
                        "description": description,
                        "done": done,
                    },
                }
            )


class Tools:
    """OpenWebUI tool generated from Claude Code skill: $skillName"""

    class Valves(BaseModel):
        """Administrator-level configuration for this skill tool."""
        skill_instructions: str = Field(
            default='$escapedInstructions',
            description="The full skill instructions from the original SKILL.md"
        )

    class UserValves(BaseModel):
        """User-level configuration options."""
        show_instructions: bool = Field(
            default=False,
            description="If True, include raw skill instructions in the output"
        )

    def __init__(self):
        self.valves = self.Valves()
        self.user_valves = self.UserValves()

    async def $methodSnake(
        self,
        user_input: str,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        """
        Execute the $titlePascal skill with the given user input.

        This tool applies the Claude Code skill instructions to the user's request,
        combining them into a structured prompt for the language model.

        :param user_input: The user's input text or request to process with this skill.
        :return: A combined prompt containing skill instructions and user input.
        """
        emitter = EventEmitter(__event_emitter__)

        try:
            await emitter.progress_update("Preparing $titlePascal skill...")

            instructions = self.valves.skill_instructions
            show_raw = self.user_valves.show_instructions if hasattr(self, 'user_valves') else False

            parts = []
            parts.append("## Skill Instructions")
            parts.append("")
            parts.append(instructions)
            parts.append("")
            parts.append("## User Request")
            parts.append("")
            parts.append(user_input)

            if show_raw:
                parts.append("")
                parts.append("---")
                parts.append("*Raw skill instructions shown above per user preference.*")

            result = "\n".join(parts)

            await emitter.success_update("$titlePascal skill applied successfully.")
            return result

        except Exception as e:
            await emitter.error_update(f"Error executing $titlePascal skill: {str(e)}")
            return f"Error: {str(e)}"
"@

    return $py
}


# ---------------------------------------------
# MAIN PROCESSING
# ---------------------------------------------

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Claude Code Skill -> OpenWebUI Tool Converter" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

try {
    if (-not (Test-Path $OutputPath)) {
        Write-Verbose "Creating output directory: $OutputPath"
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $skillFiles = Get-SkillFiles -Path $InputPath
    $totalFiles = $skillFiles.Count

    if ($totalFiles -eq 0) {
        Write-Host "No SKILL.md files found. Nothing to convert." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $totalFiles skill file(s) to convert." -ForegroundColor Green
    Write-Host ""

    $converted = 0
    $failed = 0

    foreach ($skillFile in $skillFiles) {
        $relativeName = Split-Path $skillFile -Leaf
        $parentDir = Split-Path (Split-Path $skillFile -Parent) -Leaf

        Write-Host "[$($converted + $failed + 1)/$totalFiles] Processing: $parentDir/$relativeName" -ForegroundColor White

        try {
            $parsed = Parse-SkillFrontmatter -FilePath $skillFile
            $yaml = $parsed.yaml
            $content = $parsed.content

            $supportFiles = Get-SupportingFiles -SkillFilePath $skillFile

            if ($supportFiles.Count -gt 0) {
                Write-Host "  Found $($supportFiles.Count) supporting file(s)" -ForegroundColor DarkGray
            }

            $toolCode = New-OpenWebUITool `
                -Yaml $yaml `
                -SkillContent $content `
                -SupportingFiles $supportFiles `
                -Author $Author `
                -AuthorUrl $AuthorUrl `
                -Version $Version `
                -License $License

            $outSkillName = if ($yaml.ContainsKey("name") -and $yaml["name"]) {
                $yaml["name"]
            } else { "unnamed-skill" }
            $outFileName = (ConvertTo-SnakeCase -Value $outSkillName) + ".py"
            $outFilePath = Join-Path $OutputPath $outFileName

            Set-Content -Path $outFilePath -Value $toolCode -Encoding UTF8
            Write-Host "  -> Generated: $outFilePath" -ForegroundColor Green

            $converted++

        } catch {
            Write-Host "  X FAILED: $_" -ForegroundColor Red
            $failed++
        }
    }

    Write-Host ""
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "  Conversion Complete" -ForegroundColor Cyan
    Write-Host "  Converted: $converted | Failed: $failed | Total: $totalFiles" -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Error "Critical error during conversion: $_"
    exit 1
}
Save as Convert-ClaudeSkillsToOpenWebUI.ps1 and run like:


.\Convert-ClaudeSkillsToOpenWebUI.ps1 -InputPath "~/.claude/skills" -OutputPath "./openwebui-tools" -Author "Brett Yandell"