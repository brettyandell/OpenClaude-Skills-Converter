<#
.SYNOPSIS
    GUI interface for converting Claude Code skill files (SKILL.md) into OpenWebUI-compatible Python tool files.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------
# UTILITY FUNCTIONS (same logic as CLI version)
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
            return @()
        }
    }
    $found = Get-ChildItem -Path $resolvedPath -Recurse -Filter "SKILL.md" |
             Select-Object -ExpandProperty FullName
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
        } catch { }
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
                } catch { }
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
# GUI CONSTRUCTION
# ---------------------------------------------

$script:ConvertedFiles = @()

# Main Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Claude Code Skill to OpenWebUI Tool Converter"
$form.Size = New-Object System.Drawing.Size(780, 720)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)

# Header Label
$lblHeader = New-Object System.Windows.Forms.Label
$lblHeader.Text = "Claude Code Skill  ->  OpenWebUI Tool Converter"
$lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblHeader.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
$lblHeader.AutoSize = $true
$lblHeader.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($lblHeader)

$lblSubheader = New-Object System.Windows.Forms.Label
$lblSubheader.Text = "Convert SKILL.md files into OpenWebUI Python tool files"
$lblSubheader.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblSubheader.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$lblSubheader.AutoSize = $true
$lblSubheader.Location = New-Object System.Drawing.Point(22, 45)
$form.Controls.Add($lblSubheader)

# Separator
$sep1 = New-Object System.Windows.Forms.Label
$sep1.BorderStyle = "Fixed3D"
$sep1.Size = New-Object System.Drawing.Size(730, 2)
$sep1.Location = New-Object System.Drawing.Point(20, 70)
$form.Controls.Add($sep1)

# --- Input Path ---
$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Input Path (SKILL.md file or skills directory):"
$lblInput.AutoSize = $true
$lblInput.Location = New-Object System.Drawing.Point(20, 85)
$form.Controls.Add($lblInput)

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Size = New-Object System.Drawing.Size(580, 25)
$txtInput.Location = New-Object System.Drawing.Point(20, 105)
$txtInput.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtInput.ForeColor = [System.Drawing.Color]::White
$txtInput.BorderStyle = "FixedSingle"
$form.Controls.Add($txtInput)

$btnBrowseFile = New-Object System.Windows.Forms.Button
$btnBrowseFile.Text = "File..."
$btnBrowseFile.Size = New-Object System.Drawing.Size(60, 25)
$btnBrowseFile.Location = New-Object System.Drawing.Point(610, 105)
$btnBrowseFile.FlatStyle = "Flat"
$btnBrowseFile.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnBrowseFile.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnBrowseFile)

$btnBrowseDir = New-Object System.Windows.Forms.Button
$btnBrowseDir.Text = "Dir..."
$btnBrowseDir.Size = New-Object System.Drawing.Size(60, 25)
$btnBrowseDir.Location = New-Object System.Drawing.Point(680, 105)
$btnBrowseDir.FlatStyle = "Flat"
$btnBrowseDir.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnBrowseDir.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnBrowseDir)

# --- Output Path ---
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = "Output Directory:"
$lblOutput.AutoSize = $true
$lblOutput.Location = New-Object System.Drawing.Point(20, 140)
$form.Controls.Add($lblOutput)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Size = New-Object System.Drawing.Size(640, 25)
$txtOutput.Location = New-Object System.Drawing.Point(20, 160)
$txtOutput.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtOutput.ForeColor = [System.Drawing.Color]::White
$txtOutput.BorderStyle = "FixedSingle"
$form.Controls.Add($txtOutput)

$btnBrowseOut = New-Object System.Windows.Forms.Button
$btnBrowseOut.Text = "Browse"
$btnBrowseOut.Size = New-Object System.Drawing.Size(80, 25)
$btnBrowseOut.Location = New-Object System.Drawing.Point(670, 160)
$btnBrowseOut.FlatStyle = "Flat"
$btnBrowseOut.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnBrowseOut.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnBrowseOut)

# Separator
$sep2 = New-Object System.Windows.Forms.Label
$sep2.BorderStyle = "Fixed3D"
$sep2.Size = New-Object System.Drawing.Size(730, 2)
$sep2.Location = New-Object System.Drawing.Point(20, 198)
$form.Controls.Add($sep2)

# --- Metadata Fields ---
$lblMeta = New-Object System.Windows.Forms.Label
$lblMeta.Text = "Tool Metadata"
$lblMeta.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblMeta.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
$lblMeta.AutoSize = $true
$lblMeta.Location = New-Object System.Drawing.Point(20, 208)
$form.Controls.Add($lblMeta)

# Author
$lblAuthor = New-Object System.Windows.Forms.Label
$lblAuthor.Text = "Author:"
$lblAuthor.AutoSize = $true
$lblAuthor.Location = New-Object System.Drawing.Point(20, 238)
$form.Controls.Add($lblAuthor)

$txtAuthor = New-Object System.Windows.Forms.TextBox
$txtAuthor.Text = "Claude Code Converter"
$txtAuthor.Size = New-Object System.Drawing.Size(230, 25)
$txtAuthor.Location = New-Object System.Drawing.Point(100, 235)
$txtAuthor.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtAuthor.ForeColor = [System.Drawing.Color]::White
$txtAuthor.BorderStyle = "FixedSingle"
$form.Controls.Add($txtAuthor)

# Author URL
$lblAuthorUrl = New-Object System.Windows.Forms.Label
$lblAuthorUrl.Text = "Author URL:"
$lblAuthorUrl.AutoSize = $true
$lblAuthorUrl.Location = New-Object System.Drawing.Point(350, 238)
$form.Controls.Add($lblAuthorUrl)

$txtAuthorUrl = New-Object System.Windows.Forms.TextBox
$txtAuthorUrl.Size = New-Object System.Drawing.Size(310, 25)
$txtAuthorUrl.Location = New-Object System.Drawing.Point(440, 235)
$txtAuthorUrl.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtAuthorUrl.ForeColor = [System.Drawing.Color]::White
$txtAuthorUrl.BorderStyle = "FixedSingle"
$form.Controls.Add($txtAuthorUrl)

# Version
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Version:"
$lblVersion.AutoSize = $true
$lblVersion.Location = New-Object System.Drawing.Point(20, 273)
$form.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Text = "0.1.0"
$txtVersion.Size = New-Object System.Drawing.Size(100, 25)
$txtVersion.Location = New-Object System.Drawing.Point(100, 270)
$txtVersion.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtVersion.ForeColor = [System.Drawing.Color]::White
$txtVersion.BorderStyle = "FixedSingle"
$form.Controls.Add($txtVersion)

# License
$lblLicense = New-Object System.Windows.Forms.Label
$lblLicense.Text = "License:"
$lblLicense.AutoSize = $true
$lblLicense.Location = New-Object System.Drawing.Point(220, 273)
$form.Controls.Add($lblLicense)

$txtLicense = New-Object System.Windows.Forms.TextBox
$txtLicense.Text = "MIT"
$txtLicense.Size = New-Object System.Drawing.Size(100, 25)
$txtLicense.Location = New-Object System.Drawing.Point(290, 270)
$txtLicense.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$txtLicense.ForeColor = [System.Drawing.Color]::White
$txtLicense.BorderStyle = "FixedSingle"
$form.Controls.Add($txtLicense)

# Separator
$sep3 = New-Object System.Windows.Forms.Label
$sep3.BorderStyle = "Fixed3D"
$sep3.Size = New-Object System.Drawing.Size(730, 2)
$sep3.Location = New-Object System.Drawing.Point(20, 308)
$form.Controls.Add($sep3)

# --- Action Buttons ---
$btnConvert = New-Object System.Windows.Forms.Button
$btnConvert.Text = "Convert Skills"
$btnConvert.Size = New-Object System.Drawing.Size(150, 38)
$btnConvert.Location = New-Object System.Drawing.Point(20, 320)
$btnConvert.FlatStyle = "Flat"
$btnConvert.BackColor = [System.Drawing.Color]::FromArgb(30, 120, 70)
$btnConvert.ForeColor = [System.Drawing.Color]::White
$btnConvert.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnConvert)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = "Preview Skills"
$btnPreview.Size = New-Object System.Drawing.Size(130, 38)
$btnPreview.Location = New-Object System.Drawing.Point(180, 320)
$btnPreview.FlatStyle = "Flat"
$btnPreview.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnPreview.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnPreview)

$btnOpenOutput = New-Object System.Windows.Forms.Button
$btnOpenOutput.Text = "Open Output Folder"
$btnOpenOutput.Size = New-Object System.Drawing.Size(150, 38)
$btnOpenOutput.Location = New-Object System.Drawing.Point(320, 320)
$btnOpenOutput.FlatStyle = "Flat"
$btnOpenOutput.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnOpenOutput.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnOpenOutput)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear Log"
$btnClearLog.Size = New-Object System.Drawing.Size(100, 38)
$btnClearLog.Location = New-Object System.Drawing.Point(480, 320)
$btnClearLog.FlatStyle = "Flat"
$btnClearLog.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnClearLog.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnClearLog)

$btnCopyLog = New-Object System.Windows.Forms.Button
$btnCopyLog.Text = "Copy Log"
$btnCopyLog.Size = New-Object System.Drawing.Size(100, 38)
$btnCopyLog.Location = New-Object System.Drawing.Point(590, 320)
$btnCopyLog.FlatStyle = "Flat"
$btnCopyLog.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
$btnCopyLog.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnCopyLog)

# --- Progress Bar ---
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Size = New-Object System.Drawing.Size(730, 10)
$progressBar.Location = New-Object System.Drawing.Point(20, 368)
$progressBar.Style = "Continuous"
$form.Controls.Add($progressBar)

# --- Status Label ---
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Ready"
$lblStatus.AutoSize = $true
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$lblStatus.Location = New-Object System.Drawing.Point(20, 383)
$form.Controls.Add($lblStatus)

# --- Log Output ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Conversion Log:"
$lblLog.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
$lblLog.AutoSize = $true
$lblLog.Location = New-Object System.Drawing.Point(20, 402)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Size = New-Object System.Drawing.Size(730, 250)
$txtLog.Location = New-Object System.Drawing.Point(20, 425)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = "None"
$txtLog.WordWrap = $true
$form.Controls.Add($txtLog)


# ---------------------------------------------
# LOG HELPER
# ---------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(200, 200, 200)
    )
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.SelectionColor = $Color
    $txtLog.AppendText("$Message`r`n")
    $txtLog.ScrollToCaret()
    $form.Refresh()
}


# ---------------------------------------------
# EVENT HANDLERS
# ---------------------------------------------

# Browse for SKILL.md file
$btnBrowseFile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select a SKILL.md file"
    $dlg.Filter = "SKILL.md files (SKILL.md)|SKILL.md|Markdown files (*.md)|*.md|All files (*.*)|*.*"
    $dlg.InitialDirectory = [Environment]::GetFolderPath("UserProfile")
    if ($dlg.ShowDialog() -eq "OK") {
        $txtInput.Text = $dlg.FileName
    }
})

# Browse for skills directory
$btnBrowseDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select the skills directory"
    $dlg.RootFolder = "MyComputer"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtInput.Text = $dlg.SelectedPath
    }
})

# Browse for output directory
$btnBrowseOut.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select the output directory"
    $dlg.RootFolder = "MyComputer"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtOutput.Text = $dlg.SelectedPath
    }
})

# Clear log
$btnClearLog.Add_Click({
    $txtLog.Clear()
    $lblStatus.Text = "Ready"
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $progressBar.Value = 0
})

# Copy log to clipboard
$btnCopyLog.Add_Click({
    if ($txtLog.Text.Length -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($txtLog.Text)
        $lblStatus.Text = "Log copied to clipboard"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
    }
})

# Open output folder
$btnOpenOutput.Add_Click({
    $outPath = $txtOutput.Text
    if ($outPath -and (Test-Path $outPath)) {
        Start-Process "explorer.exe" -ArgumentList $outPath
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Output directory does not exist yet. Run a conversion first.",
            "Folder Not Found",
            "OK",
            "Information"
        )
    }
})

# Preview skills (scan only, no conversion)
$btnPreview.Add_Click({
    $txtLog.Clear()
    $progressBar.Value = 0
    $inputPath = $txtInput.Text

    if (-not $inputPath -or -not (Test-Path $inputPath)) {
        Write-Log "ERROR: Input path is empty or does not exist." ([System.Drawing.Color]::FromArgb(255, 100, 100))
        $lblStatus.Text = "Error: Invalid input path"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
        return
    }

    Write-Log "=== SKILL PREVIEW ===" ([System.Drawing.Color]::FromArgb(100, 180, 255))
    Write-Log "Scanning: $inputPath" ([System.Drawing.Color]::FromArgb(180, 180, 180))
    Write-Log ""

    try {
        $skillFiles = Get-SkillFiles -Path $inputPath

        if ($skillFiles.Count -eq 0) {
            Write-Log "No SKILL.md files found." ([System.Drawing.Color]::FromArgb(255, 200, 100))
            $lblStatus.Text = "No skills found"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
            return
        }

        Write-Log "Found $($skillFiles.Count) skill(s):" ([System.Drawing.Color]::FromArgb(100, 220, 100))
        Write-Log ""

        $count = 0
        foreach ($sf in $skillFiles) {
            $count++
            $parsed = Parse-SkillFrontmatter -FilePath $sf
            $yaml = $parsed.yaml
            $parentDir = Split-Path (Split-Path $sf -Parent) -Leaf

            $name = if ($yaml.ContainsKey("name") -and $yaml["name"]) { $yaml["name"] } else { "(unnamed)" }
            $desc = if ($yaml.ContainsKey("description") -and $yaml["description"]) { $yaml["description"] } else { "(no description)" }
            $pascal = ConvertTo-PascalCase -Value $name
            $snake = "execute_" + (ConvertTo-SnakeCase -Value $name)

            $supportFiles = Get-SupportingFiles -SkillFilePath $sf
            $supportCount = $supportFiles.Count
            $contentLen = $parsed.content.Length

            Write-Log "  [$count] $parentDir/" ([System.Drawing.Color]::FromArgb(100, 180, 255))
            Write-Log "      Name:          $name"
            Write-Log "      Description:   $desc"
            Write-Log "      Class Name:    $pascal"
            Write-Log "      Method Name:   $snake"
            Write-Log "      Content:       $contentLen chars"
            Write-Log "      Support Files: $supportCount"
            Write-Log "      Output File:   $(ConvertTo-SnakeCase -Value $name).py"
            Write-Log ""
        }

        $lblStatus.Text = "Preview complete: $($skillFiles.Count) skill(s) found"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 100)

    } catch {
        Write-Log "ERROR: $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 100, 100))
        $lblStatus.Text = "Preview failed"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    }
})

# Convert button (main action)
$btnConvert.Add_Click({
    $txtLog.Clear()
    $progressBar.Value = 0
    $script:ConvertedFiles = @()

    $inputPath = $txtInput.Text
    $outputPath = $txtOutput.Text
    $author = $txtAuthor.Text
    $authorUrl = $txtAuthorUrl.Text
    $version = $txtVersion.Text
    $license = $txtLicense.Text

    # Validation
    if (-not $inputPath -or -not (Test-Path $inputPath)) {
        Write-Log "ERROR: Input path is empty or does not exist." ([System.Drawing.Color]::FromArgb(255, 100, 100))
        $lblStatus.Text = "Error: Invalid input path"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
        return
    }
    if (-not $outputPath) {
        Write-Log "ERROR: Output path is empty." ([System.Drawing.Color]::FromArgb(255, 100, 100))
        $lblStatus.Text = "Error: No output path"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
        return
    }

    Write-Log "=======================================================" ([System.Drawing.Color]::FromArgb(100, 180, 255))
    Write-Log "  Claude Code Skill -> OpenWebUI Tool Converter" ([System.Drawing.Color]::FromArgb(100, 180, 255))
    Write-Log "=======================================================" ([System.Drawing.Color]::FromArgb(100, 180, 255))
    Write-Log ""
    Write-Log "Input:   $inputPath"
    Write-Log "Output:  $outputPath"
    Write-Log "Author:  $author"
    Write-Log ""

    try {
        # Create output directory
        if (-not (Test-Path $outputPath)) {
            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
            Write-Log "Created output directory: $outputPath" ([System.Drawing.Color]::FromArgb(180, 180, 180))
        }

        # Find skills
        $skillFiles = Get-SkillFiles -Path $inputPath

        if ($skillFiles.Count -eq 0) {
            Write-Log "No SKILL.md files found. Nothing to convert." ([System.Drawing.Color]::FromArgb(255, 200, 100))
            $lblStatus.Text = "No skills found"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
            return
        }

        $totalFiles = $skillFiles.Count
        Write-Log "Found $totalFiles skill file(s) to convert." ([System.Drawing.Color]::FromArgb(100, 220, 100))
        Write-Log ""

        $converted = 0
        $failed = 0

        foreach ($skillFile in $skillFiles) {
            $relativeName = Split-Path $skillFile -Leaf
            $parentDir = Split-Path (Split-Path $skillFile -Parent) -Leaf
            $currentIndex = $converted + $failed + 1

            $progressBar.Value = [math]::Min(100, [math]::Floor(($currentIndex / $totalFiles) * 100))
            $lblStatus.Text = "Converting [$currentIndex/$totalFiles]: $parentDir/$relativeName"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
            $form.Refresh()

            Write-Log "[$currentIndex/$totalFiles] Processing: $parentDir/$relativeName" ([System.Drawing.Color]::White)

            try {
                $parsed = Parse-SkillFrontmatter -FilePath $skillFile
                $yaml = $parsed.yaml
                $content = $parsed.content

                $supportFiles = Get-SupportingFiles -SkillFilePath $skillFile

                if ($supportFiles.Count -gt 0) {
                    Write-Log "  Found $($supportFiles.Count) supporting file(s)" ([System.Drawing.Color]::FromArgb(150, 150, 150))
                }

                $toolCode = New-OpenWebUITool `
                    -Yaml $yaml `
                    -SkillContent $content `
                    -SupportingFiles $supportFiles `
                    -Author $author `
                    -AuthorUrl $authorUrl `
                    -Version $version `
                    -License $license

                $outSkillName = if ($yaml.ContainsKey("name") -and $yaml["name"]) {
                    $yaml["name"]
                } else { "unnamed-skill" }
                $outFileName = (ConvertTo-SnakeCase -Value $outSkillName) + ".py"
                $outFilePath = Join-Path $outputPath $outFileName

                Set-Content -Path $outFilePath -Value $toolCode -Encoding UTF8
                Write-Log "  -> Generated: $outFilePath" ([System.Drawing.Color]::FromArgb(100, 220, 100))

                $script:ConvertedFiles += $outFilePath
                $converted++

            } catch {
                Write-Log "  X FAILED: $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 100, 100))
                $failed++
            }
        }

        $progressBar.Value = 100
        Write-Log ""
        Write-Log "=======================================================" ([System.Drawing.Color]::FromArgb(100, 180, 255))
        Write-Log "  Conversion Complete" ([System.Drawing.Color]::FromArgb(100, 180, 255))
        Write-Log "  Converted: $converted | Failed: $failed | Total: $totalFiles" ([System.Drawing.Color]::FromArgb(100, 180, 255))
        Write-Log "=======================================================" ([System.Drawing.Color]::FromArgb(100, 180, 255))

        if ($failed -eq 0) {
            $lblStatus.Text = "Done: $converted skill(s) converted successfully"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 100)
        } else {
            $lblStatus.Text = "Done: $converted converted, $failed failed"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
        }

    } catch {
        Write-Log "CRITICAL ERROR: $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(255, 100, 100))
        $lblStatus.Text = "Critical error during conversion"
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 100)
    }
})


# ---------------------------------------------
# SHOW THE FORM
# ---------------------------------------------

[void]$form.ShowDialog()
$form.Dispose()