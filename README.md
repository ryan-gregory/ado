# ado

A minimal CLI for Azure DevOps work items. Wraps the `az boards` commands you actually use day-to-day into fast, readable interactions.

Works for any Azure DevOps org/project — configured per-user on first run.

## Prerequisites

- macOS or Linux with `bash`, `python3`, `jq`
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (`brew install azure-cli`)
- `azure-devops` extension for Azure CLI
- A logged-in Azure session

```bash
brew install azure-cli jq
az extension add --name azure-devops
az login
```

## Install

```bash
git clone https://github.com/ryan-gregory/ado.git ~/projects/ado
~/projects/ado/bin/install.sh
```

The install script symlinks `ado` into `~/.local/bin/`. Re-run after `git pull` is unnecessary — the symlink stays valid.

If `~/.local/bin` isn't on your PATH, the installer will tell you and give you the line to add.

## Quick start

First invocation prompts for org URL, project, email, and team area path(s), then writes `~/.config/ado/config`.

```bash
ado mine                    # tickets assigned to me, open
ado current                 # all team tickets in my latest sprint
ado show 12345              # full detail on a work item
ado state 12345 Active      # transition state
ado open 12345              # open in browser
```

## Configuration

Stored at `~/.config/ado/config`:

```bash
ADO_ORG=https://dev.azure.com/yourorg
ADO_PROJECT=YourProject
ADO_EMAIL=you@yourcompany.com
ADO_DEFAULT_AREA=YourProject\YourTeam
```

Optional — multiple area-path options for the `create` prompt:

```bash
ADO_AREA_OPTIONS="Team A:Project\Team A\nTeam B:Project\Team B"
```

## Commands

```
ado mine                     List my open tickets
ado current                  Show all team tickets in my latest sprint
ado upcoming                 Show team tickets in next 2 sprints
ado sprint [iteration]       List my tickets in a sprint
ado show <id>                Show ticket details
ado assign <id>              Assign a ticket to yourself
ado unassign <id>            Remove assignment
ado state <id> [state]       Update ticket state (interactive picker if no state given)
ado edit <id>                Edit title, assignment, and iteration interactively
ado comment <id> <text>      Add a comment
ado open <id>                Open ticket in browser
ado desc <id>                Edit description in $EDITOR
ado delete <id>              Delete a work item (with confirmation)
ado create ["title"]         Create a new work item (interactive)
```

### Global flags

Flags go before the command:

```
ado --quiet mine             Suppress spinners and emoji
ado --json show 12345        Emit raw JSON (for scripting)
ado -q state 12345 Active    Silent mode, just do it
```

### States

`New` · `Active` · `Accepted` · `In Development` · `Done` · `Closed`

## License

MIT — see `LICENSE`.
