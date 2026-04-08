
## 📄 OpenClaude Skill Converter
 >A PowerShell script that converts Claude Code skills into compatible Python tool files for Open WebUI.
---

## 🎯 Why Use This Tool?

> **Claude Code skills** are powerful prompt-based extensions stored as markdown files with YAML frontmatter. **Open WebUI** uses Python-based tools with a specific class structure, metadata docstrings, Valves, and EventEmitters.

> This script bridges the gap, letting you reuse your Claude Code skills inside Open WebUI **without manual rewriting**.

## ✨ Features

- **Batch conversion** — Point at a directory and convert all skills at once
- **YAML frontmatter parsing** — Extracts `name`, `description`, `disable-model-invocation`, `allowed-tools`, and `context`
- **Supporting file embedding** — Reads files from `templates/`, `examples/`, and `scripts/` subdirectories and embeds them as Python constants
- **Proper name conversion** — Converts `kebab-case` skill names to `PascalCase` (class names) and `snake_case` (method names)
- **OpenWebUI best practices** — Generated tools include `Valves`, `UserValves`, `EventEmitter`, async methods, type hints, and Sphinx-style docstrings
- **Editable output** — Skill instructions are stored in admin Valves so you can edit them directly from the OpenWebUI UI
## 🛠️ Requirements

- PowerShell 5.1+ (Windows) or PowerShell 7+ (cross-platform)
- No external modules required
## 📦 Installation

```powershell
git clone https://github.com/brettyandell/OpenClaude-Skills-Converter.git
cd OpenClaude-Skills-Converter
```
## 🚀 Usage
### Convert a single skill

```powershell
.\OpenClaudeSkillsConverter.ps1 `
    -InputPath "~/.claude/skills/explain-code/SKILL.md" `
    -OutputPath "./openwebui-tools"
```
### Batch convert all personal skills

```powershell
.\OpenClaudeSkillsConverter.ps1 `
    -InputPath "~/.claude/skills" `
    -OutputPath "./openwebui-tools" `
    -Author "Your Name" `
    -AuthorUrl "https://github.com/yourname"
```

### Convert project-level skills

```powershell
.\OpenClaudeSkillsConverter.ps1 `
    -InputPath "./.claude/skills" `
    -OutputPath "./tools/openwebui" `
    -Version "1.0.0"
```
## 📊 Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-InputPath` | Yes | — | Path to a single `SKILL.md` file or a directory containing skill folders |
| `-OutputPath` | Yes | — | Output directory for generated `.py` files (created if it doesn't exist) |
| `-Author` | No | `Claude Code Converter` | Author name for tool metadata |
| `-AuthorUrl` | No | `(empty)` | Author URL for tool metadata |
| `-Version` | No | `0.1.0` | Version string for tool metadata |
| `-License` | No | `MIT` | License string for tool metadata |

## ⚙️ How It Works

### Input: Claude Code Skill Structure

```
my-skill/
├── SKILL.md           # Main instructions (required)
├── template.md        # Optional template
├── examples/
│   └── sample.md      # Optional example
└── scripts/
    └── validate.sh    # Optional script
```

**A typical SKILL.md:**

```yaml
---
name: explain-code
description: Explains code with visual diagrams and analogies.
---

When explaining code, always:
1. **Start with an analogy**: Compare the code to something from everyday life
2. **Draw a diagram**: Use ASCII art to show the flow
3. **Walk through the code**: Explain step-by-step what happens
4. **Highlight a gotcha**: What's a common mistake or misconception?
```

### Output: OpenWebUI Python Tool

The script generates a complete Python file:

```python
"""
title: ExplainCode Skill Tool
author: Your Name
author_url: https://github.com/yourname
description: Explains code with visual diagrams and analogies.
required_open_webui_version: 0.7.0
requirements: pydantic
version: 0.1.0
license: MIT
"""

from typing import Any, Callable
from pydantic import BaseModel, Field

class EventEmitter:
    # ... status update helper ...

class Tools:
    class Valves(BaseModel):
        skill_instructions: str = Field(
            default='When explaining code, always include: ...',
            description="The full skill instructions from the original SKILL.md"
        )
    
    class UserValves(BaseModel):
        show_instructions: bool = Field(default=False, ...)
    
    def __init__(self):
        self.valves = self.Valves()
        self.user_valves = self.UserValves()
    
    async def execute_explain_code(
        self,
        user_input: str,
        __event_emitter__: Callable[[dict], Any] = None,
    ) -> str:
        # Combines skill instructions with user input
        # Returns structured prompt for the LLM
```

---

## 🔀 Field Mapping

| Claude Code SKILL.md | OpenWebUI Tool |
|----------------------|-----------------|
| `name` (frontmatter) | Tool title (PascalCase), method name (`execute_snake_case`), output filename |
| `description` (frontmatter) | description in metadata docstring |
| Markdown body | skill_instructions Valve default value |
| `disable-model-invocation` | Comment annotation in generated tool |
| `allowed-tools` | Comment annotation in generated tool |
| Supporting files | Embedded as Python string constants (`SUPPORT_FILE_*`) |

---

## 📂 Installing Generated Tools in OpenWebUI

1. Run the conversion script to generate `.py` files
2. Open your OpenWebUI instance
3. Navigate to **Workspace → Tools → "+" (Add Tool)**
4. Paste the contents of a generated `.py` file into the editor
5. Click **Save**

The tool will now appear in your chat interface.

> 💡 **Pro Tip:** To edit the skill instructions after import, go to the tool's settings and modify the `skill_instructions` valve.

---

## 🎨 Example Output

Running:
```powershell
.\OpenClaudeSkillsConverter.ps1 -InputPath "~/.claude/skills" -OutputPath "./tools"
```

Produces:

```
==================================================
  Claude Code Skill -> OpenWebUI Tool Converter
==================================================
Found 3 skill file(s) to convert.
[1/3] Processing: explain-code/SKILL.md
  -> Generated: ./tools/explain_code.py
[2/3] Processing: deploy/SKILL.md
  Found 2 supporting file(s)
  -> Generated: ./tools/deploy.py
[3/3] Processing: api-conventions/SKILL.md
  -> Generated: ./tools/api_conventions.py
==================================================
  Conversion Complete
  Converted: 3 | Failed: 0 | Total: 3
==================================================
```

---

## 📍 Skill Locations Reference

| Location | Path | Scope |
|----------|------|-------|
| Personal | `~/.claude/skills/<skill-name>/SKILL.md` | All your projects |
| Project | `.claude/skills/<skill-name>/SKILL.md` | Current project only |
| Legacy commands | `.claude/commands/<name>.md` | Current project only |

---


## 💫 Acknowledgments

- **Anthropic Claude Code** — for the skill system and Agent Skills open standard
- **Open WebUI** — for the tool framework
- **OpenWebUI Tool Skeleton** — for tool structure reference

---

## 🎯 Quick Reference Checklist

- [ ] Install the converter via git clone
- [ ] Place your skills in `~/.claude/skills/`
- [ ] Run the batch conversion command
- [ ] Import generated `.py` files into OpenWebUI
- [ ] Verify tools appear in Workspace → Tools
- [ ] Edit instructions via Valves as needed
