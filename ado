#!/usr/bin/env bash
# ado — Azure DevOps CLI work item helper
# Requires: az cli with azure-devops extension, logged in via `az login`
#
# Config: ~/.config/ado/config (auto-created on first run)
#
# Usage:
#   ado mine                        List my open tickets
#   ado sprint [iteration]          List my tickets in a sprint
#   ado show <id>                   Show ticket details
#   ado state <id> <state>          Update ticket state
#   ado comment <id> <text>         Add a discussion comment
#   ado open <id>                   Open ticket in browser
#   ado create ["title"]            Create a new work item (interactive)

set -euo pipefail

# ── config ─────────────────────────────────────────────────────────────────

CONFIG_DIR="$HOME/.config/ado"
CONFIG_FILE="$CONFIG_DIR/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  mkdir -p "$CONFIG_DIR"
  echo "  ⚙️  First run — let's configure ado."
  echo ""
  read -rp "  Azure DevOps org URL (e.g. https://dev.azure.com/myorg): " _ORG
  read -rp "  Project name: " _PROJECT
  read -rp "  Your ADO email: " _EMAIL
  echo ""
  echo "  How many team area paths do you want to configure?"
  read -rp "  Number of teams [1]: " _TEAM_COUNT
  _TEAM_COUNT="${_TEAM_COUNT:-1}"
  _AREA_OPTIONS=""
  _DEFAULT_AREA=""
  for i in $(seq 1 "$_TEAM_COUNT"); do
    read -rp "  Team $i label (e.g. 'Client XP'): " _LABEL
    read -rp "  Team $i full area path (e.g. 'Project\\Team'): " _PATH
    if [[ $i -eq 1 ]]; then
      _DEFAULT_AREA="$_PATH"
      _AREA_OPTIONS="${_LABEL}:${_PATH}"
    else
      _AREA_OPTIONS="${_AREA_OPTIONS}\n${_LABEL}:${_PATH}"
    fi
  done
  cat > "$CONFIG_FILE" <<CONF
ADO_ORG="${_ORG}"
ADO_PROJECT="${_PROJECT}"
ADO_EMAIL="${_EMAIL}"
ADO_DEFAULT_AREA="${_DEFAULT_AREA}"
ADO_AREA_OPTIONS="${_AREA_OPTIONS}"
CONF
  echo ""
  echo "  ✅ Config saved to $CONFIG_FILE"
  echo ""
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

ORG="${ADO_ORG}"
PROJECT="${ADO_PROJECT}"
ADO_EMAIL="${ADO_EMAIL}"
DEFAULT_AREA="${ADO_DEFAULT_AREA:-}"
AREA_OPTIONS="${ADO_AREA_OPTIONS:-}"

export ADO_ORG="$ORG"
export ADO_PROJECT="$PROJECT"

# ── spinner ────────────────────────────────────────────────────────────────

_spin() {
  local msg="${1:-Working...}"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  while true; do
    printf "\r  \033[36m%s\033[0m  %s" "${frames[$((i % 10))]}" "$msg"
    sleep 0.08
    i=$((i+1))
  done
}

spin_start() { _spin "${1:-}" & SPIN_PID=$!; }
spin_stop()  {
  kill "$SPIN_PID" 2>/dev/null || true
  wait "$SPIN_PID" 2>/dev/null || true
  printf "\r\033[K"
}

_query_wiql() {
  local wiql="$1"
  local msg="${2:-Fetching tickets...}"
  spin_start "$msg"
  local result
  result=$(az boards query --wiql "$wiql" --org "$ORG" -o table 2>&1)
  spin_stop
  echo "$result"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  mine)
    echo "🎫  My open tickets:"
    spin_start "Fetching your tickets..."
    MINE_RESULT=$(az boards query \
      --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.IterationPath]
        FROM WorkItems
        WHERE [System.AssignedTo] = @Me
          AND [System.TeamProject] = '$PROJECT'
          AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')
        ORDER BY [System.IterationPath] DESC, [System.State] ASC" \
      --org "$ORG" -o json 2>&1)
    spin_stop
    echo "$MINE_RESULT" | python3 -c "
import sys, json
items = json.load(sys.stdin)
grouped = {}
for item in items:
    f = item['fields']
    iteration = f.get('System.IterationPath') or 'No Iteration'
    grouped.setdefault(iteration, []).append({
        'id': item['id'],
        'title': f.get('System.Title', '')[:60],
        'state': f.get('System.State', ''),
        'type': f.get('System.WorkItemType', ''),
    })
import re

def sort_key(iteration):
    nums = [int(n) for n in re.findall(r'\d+', iteration)]
    return nums if nums else [-1]

def is_relevant(iteration):
    years = [int(n) for n in re.findall(r'\d{4}', iteration)]
    return not years or max(years) >= 2026

for iteration in sorted(grouped.keys(), key=sort_key):
    if not is_relevant(iteration):
        continue
    tickets = grouped[iteration]
    print(f'\n📁  {iteration}')
    print(f'  {\"ID\":<8} {\"State\":<18} {\"Type\":<16} Title')
    print(f'  {\"-\"*8} {\"-\"*18} {\"-\"*16} {\"-\"*50}')
    for t in tickets:
        print(f'  {t[\"id\"]:<8} {t[\"state\"]:<18} {t[\"type\"]:<16} {t[\"title\"]}')
"
    ;;

  sprint)
    if [[ -n "${1:-}" ]]; then
      ITER="$1"
    else
      echo "Available sprints with your tickets:"
      az boards query \
        --wiql "SELECT [System.IterationPath] FROM WorkItems
          WHERE [System.AssignedTo] = @Me
            AND [System.TeamProject] = '$PROJECT'
            AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')" \
        --org "$ORG" -o json 2>/dev/null \
        | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
def is_relevant(p):
    years = [int(n) for n in re.findall(r'\d{4}', p)]
    return not years or max(years) >= 2026
paths = sorted({i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}, key=sort_key)
for i, p in enumerate([p for p in paths if is_relevant(p)], 1):
    print(f'  {i}) {p}')
"
      echo ""
      read -rp "Select [#] or type path: " CHOICE
      if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        ITER=$(az boards query \
          --wiql "SELECT [System.IterationPath] FROM WorkItems
            WHERE [System.AssignedTo] = @Me
              AND [System.TeamProject] = '$PROJECT'
              AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')" \
          --org "$ORG" -o json 2>/dev/null \
          | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
def is_relevant(p):
    years = [int(n) for n in re.findall(r'\d{4}', p)]
    return not years or max(years) >= 2026
paths = sorted({i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}, key=sort_key)
print([p for p in paths if is_relevant(p)][int('$CHOICE')-1])
")
      else
        ITER="$CHOICE"
      fi
    fi
    [[ -z "$ITER" ]] && exit 0
    echo "🏃  Sprint: $ITER"
    _query_wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.AssignedTo]
      FROM WorkItems
      WHERE [System.TeamProject] = '$PROJECT'
        AND [System.IterationPath] = '$ITER'
        AND [System.AssignedTo] = @Me
        AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')
      ORDER BY [System.State] ASC"
    ;;

  upcoming)
    echo "🔭  Finding upcoming sprints..."
    # Get all project iterations (normalized to match ticket paths)
    ALL_ITERS=$(az boards iteration project list \
      --org "$ORG" --project "$PROJECT" --depth 1 -o json 2>/dev/null \
      | python3 -c "
import sys, json, re
children = json.load(sys.stdin).get('children', [])
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
sep = '\\\\'
prefix = 'OTR' + sep + 'Iteration' + sep
paths = [c['path'].lstrip(sep).replace(prefix, 'OTR' + sep) for c in children]
for p in sorted(paths, key=sort_key):
    print(p)
")

    # Get my latest sprint from assigned tickets
    MY_LATEST=$(az boards query \
      --wiql "SELECT [System.IterationPath] FROM WorkItems
        WHERE [System.AssignedTo] = @Me
          AND [System.TeamProject] = '$PROJECT'
          AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')" \
      --org "$ORG" -o json 2>/dev/null \
      | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
paths = {i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}
relevant = [p for p in paths if re.search(r'\d{4}', p)]
print(sorted(relevant, key=sort_key)[-1] if relevant else '')
")

    # Get next 2 sprints after my latest
    UPCOMING=$(echo "$ALL_ITERS" | MY_LATEST="$MY_LATEST" python3 -c "
import sys, os
lines = [l.strip() for l in sys.stdin if l.strip()]
latest = os.environ['MY_LATEST']
try:
    idx = lines.index(latest)
    upcoming = lines[idx+1:idx+3]
except ValueError:
    upcoming = []
for p in upcoming:
    print(p)
")

    if [[ -z "$UPCOMING" ]]; then
      echo "No upcoming sprints found after: $MY_LATEST"
      exit 0
    fi

    while IFS= read -r ITER; do
      echo ""
      echo "📅  $ITER"
      echo "  $(az boards query \
        --wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.AssignedTo]
          FROM WorkItems
          WHERE [System.TeamProject] = '$PROJECT'
            AND [System.IterationPath] = '$ITER'
            AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')
          ORDER BY [System.AssignedTo] ASC, [System.State] ASC" \
        --org "$ORG" -o table 2>/dev/null)"
    done <<< "$UPCOMING"
    ;;

  show)
    ID="${1:?Usage: ado show <id>}"
    echo "🔍  Ticket #$ID:"
    spin_start "Loading ticket..."
    SHOW_RESULT=$(az boards work-item show \
      --id "$ID" \
      --org "$ORG" \
      --query "{
        id: id,
        type: fields.\"System.WorkItemType\",
        state: fields.\"System.State\",
        title: fields.\"System.Title\",
        assignedTo: fields.\"System.AssignedTo\".displayName,
        iteration: fields.\"System.IterationPath\",
        tags: fields.\"System.Tags\",
        description: fields.\"System.Description\"
      }" \
      -o json 2>&1)
    spin_stop
    echo "$SHOW_RESULT" | python3 -c "
import sys, json, re, os
d = json.load(sys.stdin)
print(f\"  ID:          {d['id']}\")
print(f\"  Type:        {d['type']}\")
print(f\"  State:       {d['state']}\")
print(f\"  Assigned To: {d['assignedTo']}\")
print(f\"  Iteration:   {d['iteration']}\")
print(f\"  Tags:        {d.get('tags') or 'none'}\")
print(f\"  Title:       {d['title']}\")
print(f\"  URL:         {os.environ.get('ADO_ORG','')}/{os.environ.get('ADO_PROJECT','')}/_workitems/edit/{d['id']}\")
desc = re.sub(r'<[^>]+>', '', d.get('description') or '').strip()
if desc:
    print(f\"\nDescription:\n{desc[:800]}\")
"
    ;;

  current)
    CURRENT=$(az boards query \
      --wiql "SELECT [System.IterationPath] FROM WorkItems
        WHERE [System.AssignedTo] = @Me
          AND [System.TeamProject] = '$PROJECT'
          AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')" \
      --org "$ORG" -o json 2>/dev/null \
      | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
paths = {i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}
relevant = [p for p in paths if re.search(r'\d{4}', p)]
print(sorted(relevant, key=sort_key)[-1] if relevant else '')
")
    [[ -z "$CURRENT" ]] && echo "No active sprint found." && exit 0
    echo "⚡  Current sprint: $CURRENT"
    _query_wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.AssignedTo]
      FROM WorkItems
      WHERE [System.TeamProject] = '$PROJECT'
        AND [System.IterationPath] = '$CURRENT'
        AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')
      ORDER BY [System.AssignedTo] ASC, [System.State] ASC"
    ;;

  assign)
    ID="${1:?Usage: ado assign <id>}"
    echo "🙋  Assigning #$ID to you..."
    spin_start "Updating..."
    az boards work-item update \
      --id "$ID" --assigned-to "$ADO_EMAIL" --org "$ORG" \
      --query "{id:id,assignedTo:fields.\"System.AssignedTo\",title:fields.\"System.Title\"}" \
      -o table 2>&1 | { spin_stop; cat; }
    ;;

  unassign)
    ID="${1:?Usage: ado unassign <id>}"
    echo "🚫  Unassigning #$ID..."
    spin_start "Updating..."
    az boards work-item update \
      --id "$ID" --assigned-to "" --org "$ORG" \
      --query "{id:id,assignedTo:fields.\"System.AssignedTo\",title:fields.\"System.Title\"}" \
      -o table 2>&1 | { spin_stop; cat; }
    ;;

  state)
    ID="${1:?Usage: ado state <id> <state>}"
    STATE="${2:?Usage: ado state <id> <state>}"
    echo "✏️   Updating #$ID → '$STATE'..."
    spin_start "Updating..."
    az boards work-item update \
      --id "$ID" --state "$STATE" --org "$ORG" \
      --query "{id:id,state:fields.\"System.State\",title:fields.\"System.Title\"}" \
      -o table 2>&1 | { spin_stop; cat; }
    ;;

  comment)
    ID="${1:?Usage: ado comment <id> <text>}"
    TEXT="${2:?Usage: ado comment <id> <text>}"
    echo "💬  Adding comment to #$ID..."
    spin_start "Posting comment..."
    az boards work-item update \
      --id "$ID" \
      --discussion "$TEXT" \
      --org "$ORG" \
      --query "{id:id,title:fields.\"System.Title\"}" \
      -o table
    ;;

  open)
    ID="${1:?Usage: ado open <id>}"
    URL="$ORG/$PROJECT/_workitems/edit/$ID"
    echo "🌐  Opening $URL"
    open "$URL"
    ;;

  create)
    echo "✨  Create a new work item"
    echo ""

    # Title
    TITLE="${1:-}"
    if [[ -z "$TITLE" ]]; then
      read -rp "  Title: " TITLE
    fi
    [[ -z "$TITLE" ]] && echo "Title is required." && exit 1

    # Type
    echo ""
    echo "  Work item type:"
    TYPES=("User Story" "Task" "Bug" "Feature" "Epic")
    for i in "${!TYPES[@]}"; do
      echo "    $((i+1))) ${TYPES[$i]}"
    done
    read -rp "  Select [1-${#TYPES[@]}] (default: 1 User Story): " TYPE_CHOICE
    TYPE_CHOICE="${TYPE_CHOICE:-1}"
    if [[ "$TYPE_CHOICE" =~ ^[0-9]+$ ]] && (( TYPE_CHOICE >= 1 && TYPE_CHOICE <= ${#TYPES[@]} )); then
      WORK_ITEM_TYPE="${TYPES[$((TYPE_CHOICE-1))]}"
    else
      WORK_ITEM_TYPE="User Story"
    fi

    # Sprint / iteration — my sprints + next 2 upcoming, merged and sorted
    echo ""
    echo "  Available sprints:"
    ITER_JSON=$(az boards query \
      --wiql "SELECT [System.IterationPath] FROM WorkItems
        WHERE [System.AssignedTo] = @Me
          AND [System.TeamProject] = '$PROJECT'
          AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')" \
      --org "$ORG" -o json 2>/dev/null)
    ALL_ITERS=$(az boards iteration project list \
      --org "$ORG" --project "$PROJECT" --depth 1 -o json 2>/dev/null \
      | python3 -c "
import sys, json, re
children = json.load(sys.stdin).get('children', [])
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
sep = '\\\\'
prefix = 'OTR' + sep + 'Iteration' + sep
paths = [c['path'].lstrip(sep).replace(prefix, 'OTR' + sep) for c in children]
for p in sorted(paths, key=sort_key):
    print(p)
")
    ITER_LIST=$(echo "$ITER_JSON" | ALL_ITERS="$ALL_ITERS" python3 -c "
import sys, json, re, os
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
def is_relevant(p):
    years = [int(n) for n in re.findall(r'\d{4}', p)]
    return not years or max(years) >= 2026
my_paths = {i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}
relevant_mine = [p for p in my_paths if is_relevant(p)]
latest = sorted(relevant_mine, key=sort_key)[-1] if relevant_mine else ''
all_iters = [l.strip() for l in os.environ['ALL_ITERS'].splitlines() if l.strip()]
try:
    idx = all_iters.index(latest)
    upcoming = all_iters[idx+1:idx+3]
except ValueError:
    upcoming = []
merged = sorted(set(relevant_mine) | set(upcoming), key=sort_key)
for i, p in enumerate(merged, 1):
    print(f'{i}\t{p}')
")
    DEFAULT_ITER=$(echo "$ITER_JSON" | python3 -c "
import sys, json, re
items = json.load(sys.stdin)
def sort_key(p):
    nums = [int(n) for n in re.findall(r'\d+', p)]
    return nums if nums else [-1]
paths = {i['fields']['System.IterationPath'] for i in items if i['fields'].get('System.IterationPath')}
relevant = [p for p in paths if re.search(r'\d{4}', p)]
print(sorted(relevant, key=sort_key)[-1] if relevant else '')
")
    DEFAULT_NUM=$(echo "$ITER_LIST" | awk -F'\t' -v d="$DEFAULT_ITER" '$2==d {print $1}')
    echo "$ITER_LIST" | awk -F'\t' -v d="$DEFAULT_ITER" '{
      marker = ($2 == d) ? " ◀ default" : ""
      printf "    %s) %s%s\n", $1, $2, marker
    }'
    echo ""
    read -rp "  Select sprint [${DEFAULT_NUM:-#}] or leave blank to skip: " ITER_CHOICE
    ITER_CHOICE="${ITER_CHOICE:-$DEFAULT_NUM}"
    if [[ "$ITER_CHOICE" =~ ^[0-9]+$ ]]; then
      ITERATION=$(echo "$ITER_LIST" | awk -F'\t' -v n="$ITER_CHOICE" '$1==n {print $2}')
    else
      ITERATION="$ITER_CHOICE"
    fi

    # Assign to self
    echo ""
    read -rp "  Assign to yourself? [Y/n]: " ASSIGN_SELF
    ASSIGN_SELF="${ASSIGN_SELF:-Y}"

    # Area path
    echo ""
    if [[ -n "$AREA_OPTIONS" ]]; then
      echo "  Area path:"
      i=1
      while IFS= read -r opt; do
        LABEL=$(echo "$opt" | cut -d: -f1)
        [[ $i -eq 1 ]] && echo "    $i) $LABEL (default)" || echo "    $i) $LABEL"
        i=$((i+1))
      done <<< "$(echo -e "$AREA_OPTIONS")"
      echo ""
      read -rp "  Select area [1]: " AREA_CHOICE
      AREA_CHOICE="${AREA_CHOICE:-1}"
      AREA_PATH=$(echo -e "$AREA_OPTIONS" | sed -n "${AREA_CHOICE}p" | cut -d: -f2-)
      [[ -z "$AREA_PATH" ]] && AREA_PATH=$(echo -e "$AREA_OPTIONS" | head -1 | cut -d: -f2-)
    elif [[ -n "$DEFAULT_AREA" ]]; then
      AREA_PATH="$DEFAULT_AREA"
    else
      AREA_PATH=""
    fi

    # Description — open $EDITOR in a temp file
    echo ""
    TMPFILE=$(mktemp /tmp/ado-desc.XXXXXX.md)
    printf "# Enter description below. Lines starting with # are ignored.\n# Save and quit to continue, leave empty to skip.\n\n" > "$TMPFILE"
    ${EDITOR:-nvim} "$TMPFILE"
    DESCRIPTION=$(grep -v '^#' "$TMPFILE" | sed '/^[[:space:]]*$/d' | head -c 10000 || true)
    rm -f "$TMPFILE"

    # Build command
    echo ""
    echo "📝  Creating '$WORK_ITEM_TYPE': $TITLE..."

    CREATE_ARGS=(
      --title "$TITLE"
      --type "$WORK_ITEM_TYPE"
      --project "$PROJECT"
      --org "$ORG"
    )
    [[ -n "$ITERATION" ]] && CREATE_ARGS+=(--iteration "$ITERATION")
    ASSIGN_UPPER=$(echo "$ASSIGN_SELF" | tr '[:lower:]' '[:upper:]')
    [[ "$ASSIGN_UPPER" == "Y" || "$ASSIGN_UPPER" == "YES" ]] && CREATE_ARGS+=(--assigned-to "$ADO_EMAIL")
    [[ -n "$DESCRIPTION" ]] && CREATE_ARGS+=(--description "$DESCRIPTION")

    set +e
    spin_start "Creating work item..."
    RESULT=$(az boards work-item create "${CREATE_ARGS[@]}" \
      --query "{id:id,type:fields.\"System.WorkItemType\",state:fields.\"System.State\",title:fields.\"System.Title\",assignedTo:fields.\"System.AssignedTo\".displayName,iteration:fields.\"System.IterationPath\"}" \
      -o json 2>&1)
    EXIT_CODE=$?
    spin_stop
    set -e

    if [[ $EXIT_CODE -ne 0 ]]; then
      echo "❌  Failed to create work item:"
      echo "$RESULT"
      exit $EXIT_CODE
    fi

    # Set area path (not supported in create, must update after)
    CREATED_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
    if [[ -n "$CREATED_ID" && -n "$AREA_PATH" ]]; then
      spin_start "Setting area path..."
      az boards work-item update --id "$CREATED_ID" --area "$AREA_PATH" --org "$ORG" -o none 2>/dev/null || true
      spin_stop
    fi

    echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f'  ✅  Created #{d[\"id\"]}')
    print(f'     Type:      {d[\"type\"]}')
    print(f'     State:     {d[\"state\"]}')
    print(f'     Assigned:  {d.get(\"assignedTo\") or \"Unassigned\"}')
    print(f'     Iteration: {d.get(\"iteration\") or \"None\"}')
    print(f'     Title:     {d[\"title\"]}')
    print(f'     URL:       {ORG}/{PROJECT}/_workitems/edit/{d[\"id\"]}')
except Exception as e:
    print('Raw response:')
    print(sys.stdin.read() if False else open('/dev/stdin').read() if False else '')
    raise
" || echo "$RESULT"
    ;;

  help|--help|-h|*)
    cat <<EOF
ADO CLI — Azure DevOps work item helper

Commands:
  ado mine                     List my open tickets
  ado current                  Show all team tickets in my latest sprint
  ado upcoming                 Show team tickets in next 2 sprints after my latest
  ado sprint [iteration]       List my tickets in a sprint (prompts if no arg given)
  ado show <id>                Show ticket details
  ado assign <id>              Assign a ticket to yourself
  ado unassign <id>            Remove assignment from a ticket
  ado state <id> <state>       Update ticket state
                               States: New, Active, Accepted, In Development, Done, Closed
  ado comment <id> <text>      Add a discussion comment
  ado open <id>                Open ticket in browser
  ado create ["title"]         Create a new work item (interactive)
EOF
    ;;
esac
