# ado

A minimal CLI for Azure DevOps work items. Wraps the `az boards` commands you actually use day-to-day into fast, readable interactions.

## Requirements

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) with the `azure-devops` extension
- Logged in via `az login`

```bash
az extension add --name azure-devops
az login
```

## Installation

```bash
git clone <repo>
echo 'export PATH="$HOME/projects/ado:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Configuration

On first run, `ado` will prompt you to create `~/.config/ado/config`:

```bash
ADO_ORG=https://dev.azure.com/yourorg
ADO_PROJECT=YourProject
ADO_EMAIL=you@yourcompany.com
ADO_DEFAULT_AREA=YourProject\YourTeam
```

**Optional:** Add multiple area options for the `create` prompt:

```bash
# Format: "Label:Full\Area\Path" — one per line, newline-separated
ADO_AREA_OPTIONS="Team A:Project\Team A\nTeam B:Project\Team B"
```

## Usage

```
ado mine                     List my open tickets
ado current                  Show all team tickets in my latest sprint
ado upcoming                 Show team tickets in next 2 sprints
ado sprint [iteration]       List my tickets in a sprint
ado show <id>                Show ticket details
ado assign <id>              Assign a ticket to yourself
ado unassign <id>            Remove assignment
ado state <id> <state>       Update ticket state
ado comment <id> <text>      Add a comment
ado open <id>                Open ticket in browser
ado create ["title"]         Create a new work item (interactive)
```

### States

`New` · `Active` · `Accepted` · `In Development` · `Done` · `Closed`
