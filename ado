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
TEAM="${ADO_TEAM:-Client XP Team}"

export ADO_ORG="$ORG"
export ADO_PROJECT="$PROJECT"

# ── spinner ────────────────────────────────────────────────────────────────

SPIN_PID=""

_spin() {
  local msg="${1:-Working...}"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  trap 'printf "\r\033[K\033[?25h"; exit 0' INT TERM
  while true; do
    printf "\r  \033[36m%s\033[0m  %s" "${frames[$((i % 10))]}" "$msg"
    sleep 0.08
    i=$((i+1))
  done
}

spin_start() {
  printf "\033[?25l"
  _spin "${1:-}" &
  SPIN_PID=$!
}
spin_stop()  {
  if [[ -n "$SPIN_PID" ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
  fi
  printf "\r\033[K\033[?25h"
}

_spin_cleanup() {
  spin_stop
  exit 130
}
trap _spin_cleanup INT TERM

_query_wiql() {
  local wiql="$1"
  local msg="${2:-Fetching tickets...}"
  spin_start "$msg"
  local result
  result=$(az boards query --wiql "$wiql" --org "$ORG" -o table 2>&1)
  spin_stop
  echo "$result"
}

# ── output mode ────────────────────────────────────────────────────────────

ADO_OUTPUT="pretty"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --quiet|-q) ADO_OUTPUT="quiet"; shift ;;
    --json|-j)  ADO_OUTPUT="json"; shift ;;
    *) break ;;
  esac
done

_emit() {
  # Pretty-mode: print as-is. Quiet: suppress. Json: caller handles.
  [[ "$ADO_OUTPUT" == "quiet" ]] && return 0
  echo "$@"
}

if [[ "$ADO_OUTPUT" != "pretty" ]]; then
  # Override spinner to no-op in non-pretty modes
  spin_start() { :; }
  spin_stop()  { :; }
fi

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
prefix = '$PROJECT' + sep + 'Iteration' + sep
paths = [c['path'].lstrip(sep).replace(prefix, '$PROJECT' + sep) for c in children]
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
    spin_start "Finding current sprint..."
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
    spin_stop
    [[ -z "$CURRENT" ]] && echo "No active sprint found." && exit 0
    echo "⚡  Current sprint: $CURRENT"
    _query_wiql "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType], [System.AssignedTo]
      FROM WorkItems
      WHERE [System.TeamProject] = '$PROJECT'
        AND [System.IterationPath] = '$CURRENT'
        AND [System.State] NOT IN ('Closed', 'Done', 'Cancelled', 'Removed')
      ORDER BY [System.AssignedTo] ASC, [System.State] ASC" "Fetching sprint tickets..."
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
    ID="${1:?Usage: ado state <id> [state]}"
    STATE="${2:-}"
    spin_start "Looking up work item type..."
    ITEM_JSON=$(az boards work-item show --id "$ID" --org "$ORG" \
      --query "{type:fields.\"System.WorkItemType\",state:fields.\"System.State\"}" \
      -o json 2>/dev/null || true)
    TYPE=$(echo "$ITEM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)
    CURRENT_STATE=$(echo "$ITEM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    if [[ -z "$TYPE" ]]; then
      spin_stop
      echo "❌  Could not fetch work item #$ID"
      exit 1
    fi
    STATES_JSON=$(az devops invoke --org "$ORG" \
      --area wit --resource workitemtypestates \
      --route-parameters project="$PROJECT" type="$TYPE" \
      --api-version 7.1-preview -o json 2>/dev/null || true)
    spin_stop
    VALID_STATES=$(printf '%s' "$STATES_JSON" | python3 -c \
      'import json,sys
try:
    d=json.load(sys.stdin)
    print("\n".join(s["name"] for s in d.get("value",[])))
except Exception:
    pass')
    if [[ -z "$VALID_STATES" ]]; then
      echo "❌  Could not fetch valid states for work item type '$TYPE'"
      exit 1
    fi
    # Interactive picker when no state arg given
    if [[ -z "$STATE" ]]; then
      echo "⚙️   #$ID ($TYPE) — current state: $CURRENT_STATE"
      echo "    Available states:"
      i=1
      while IFS= read -r s; do
        if [[ "$s" == "$CURRENT_STATE" ]]; then
          echo "      $i) $s ◀ current"
        else
          echo "      $i) $s"
        fi
        i=$((i+1))
      done <<< "$VALID_STATES"
      echo ""
      read -rp "  Select state [#]: " STATE_CHOICE
      if [[ "$STATE_CHOICE" =~ ^[0-9]+$ ]]; then
        STATE=$(printf '%s\n' "$VALID_STATES" | sed -n "${STATE_CHOICE}p")
      else
        STATE="$STATE_CHOICE"
      fi
      [[ -z "$STATE" ]] && echo "  Aborted." && exit 0
    fi
    MATCHED=$(printf '%s\n' "$VALID_STATES" | awk -v s="$STATE" 'tolower($0)==tolower(s){print; exit}')
    if [[ -z "$MATCHED" ]]; then
      echo "❌  Invalid state '$STATE' for work item type '$TYPE'."
      echo "    Supported states:"
      printf '%s\n' "$VALID_STATES" | sed 's/^/      - /'
      exit 1
    fi
    echo "✏️   Updating #$ID ($TYPE) → '$MATCHED'..."

    # Wrapper that runs the update; on rule-error for required fields,
    # dynamically fetch the reference name + allowed values, prompt, and retry.
    EXTRA_FIELDS=()
    ATTEMPT=0
    while :; do
      ATTEMPT=$((ATTEMPT+1))
      spin_start "Updating..."
      set +e
      UPDATE_OUT=$(az boards work-item update \
        --id "$ID" --state "$MATCHED" --org "$ORG" \
        ${EXTRA_FIELDS[@]:+--fields "${EXTRA_FIELDS[@]}"} \
        --query "{id:id,state:fields.\"System.State\",title:fields.\"System.Title\"}" \
        -o table 2>&1)
      EXIT_CODE=$?
      set -e
      spin_stop

      if [[ $EXIT_CODE -eq 0 ]]; then
        echo "$UPDATE_OUT"
        break
      fi

      MISSING_FIELD=$(printf '%s\n' "$UPDATE_OUT" | sed -nE 's/.*Rule Error for field ([^.]+)\..*/\1/p' | head -1)
      if [[ -z "$MISSING_FIELD" || $ATTEMPT -gt 5 ]]; then
        echo "❌  Update failed:"
        echo "$UPDATE_OUT"
        exit $EXIT_CODE
      fi

      echo ""
      echo "⚠️   Transition requires field: $MISSING_FIELD"
      spin_start "Looking up field metadata..."
      FIELD_TMP=$(mktemp)
      az devops invoke --org "$ORG" \
        --area wit --resource workitemtypesfield \
        --route-parameters project="$PROJECT" type="$TYPE" \
        --query-parameters '$expand=allowedValues' \
        --api-version 7.1 -o json > "$FIELD_TMP" 2>/dev/null || true
      spin_stop

      FIELD_INFO=$(FIELD_FILE="$FIELD_TMP" MISSING="$MISSING_FIELD" python3 -c "
import os, json, sys
try:
    d = json.load(open(os.environ['FIELD_FILE']))
except Exception:
    sys.exit(0)
target = os.environ['MISSING'].strip().lower()
for f in d.get('value', []):
    if f.get('name','').strip().lower() == target:
        print(f.get('referenceName',''))
        for v in f.get('allowedValues',[]) or []:
            print(v)
        break
")
      rm -f "$FIELD_TMP"

      REF_NAME=$(printf '%s\n' "$FIELD_INFO" | head -1)
      mapfile -t ALLOWED < <(printf '%s\n' "$FIELD_INFO" | tail -n +2)

      if [[ -z "$REF_NAME" ]]; then
        echo "❌  Could not resolve reference name for field '$MISSING_FIELD'."
        echo "$UPDATE_OUT"
        exit 1
      fi

      if [[ ${#ALLOWED[@]} -gt 0 ]]; then
        echo "    Allowed values:"
        for i in "${!ALLOWED[@]}"; do
          echo "      $((i+1))) ${ALLOWED[$i]}"
        done
        read -rp "    Select [1-${#ALLOWED[@]}] or type a value: " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#ALLOWED[@]} )); then
          VALUE="${ALLOWED[$((CHOICE-1))]}"
        else
          VALUE="$CHOICE"
        fi
      else
        read -rp "    Value for '$MISSING_FIELD': " VALUE
      fi
      [[ -z "$VALUE" ]] && { echo "❌  No value provided."; exit 1; }

      EXTRA_FIELDS+=("${REF_NAME}=${VALUE}")
    done
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

  edit)
    ID="${1:?Usage: ado edit <id>}"
    spin_start "Fetching work item..."
    EDIT_JSON=$(az boards work-item show --id "$ID" --org "$ORG" \
      --query "{
        title: fields.\"System.Title\",
        state: fields.\"System.State\",
        type: fields.\"System.WorkItemType\",
        assignedTo: fields.\"System.AssignedTo\".uniqueName,
        assignedToName: fields.\"System.AssignedTo\".displayName,
        iteration: fields.\"System.IterationPath\"
      }" -o json 2>&1)
    spin_stop

    EDIT_TITLE=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))")
    EDIT_STATE=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))")
    EDIT_TYPE=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))")
    EDIT_ASSIGNED=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('assignedTo') or '')")
    EDIT_ASSIGNED_NAME=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('assignedToName') or 'Unassigned')")
    EDIT_ITERATION=$(echo "$EDIT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iteration',''))")

    echo "✏️   Editing #$ID ($EDIT_TYPE)"
    echo "    Current: $EDIT_TITLE"
    echo "    State:   $EDIT_STATE | Assigned: $EDIT_ASSIGNED_NAME | Sprint: $EDIT_ITERATION"
    echo ""

    # Title
    read -rp "  Title [$EDIT_TITLE]: " NEW_TITLE
    NEW_TITLE="${NEW_TITLE:-$EDIT_TITLE}"

    # Assigned to
    echo "  Assigned to: $EDIT_ASSIGNED_NAME ($EDIT_ASSIGNED)"
    echo "    1) Keep current"
    echo "    2) Assign to me ($ADO_EMAIL)"
    echo "    3) Unassign"
    echo "    4) Pick from team"
    echo "    5) Other (enter email)"
    read -rp "  Select [1]: " ASSIGN_CHOICE
    ASSIGN_CHOICE="${ASSIGN_CHOICE:-1}"
    case "$ASSIGN_CHOICE" in
      1) NEW_ASSIGNED="" ;;
      2) NEW_ASSIGNED="$ADO_EMAIL" ;;
      3) NEW_ASSIGNED="" ; UNASSIGN=true ;;
      4)
        spin_start "Fetching team members..."
        MEMBERS_JSON=$(az devops team list-member \
          --team "$TEAM" --project "$PROJECT" --org "$ORG" \
          --top 50 -o json 2>/dev/null || echo "[]")
        spin_stop
        mapfile -t MEMBER_EMAILS < <(echo "$MEMBERS_JSON" | python3 -c "
import sys, json
members = json.load(sys.stdin)
for m in sorted(members, key=lambda x: x.get('identity',{}).get('displayName','')):
    print(m.get('identity',{}).get('uniqueName',''))
")
        mapfile -t MEMBER_NAMES < <(echo "$MEMBERS_JSON" | python3 -c "
import sys, json
members = json.load(sys.stdin)
for m in sorted(members, key=lambda x: x.get('identity',{}).get('displayName','')):
    print(m.get('identity',{}).get('displayName',''))
")
        if [[ ${#MEMBER_EMAILS[@]} -eq 0 ]]; then
          echo "    ⚠️  Could not fetch team members."
          read -rp "    Email: " NEW_ASSIGNED
        else
          echo "    Team members:"
          for i in "${!MEMBER_NAMES[@]}"; do
            echo "      $((i+1))) ${MEMBER_NAMES[$i]} (${MEMBER_EMAILS[$i]})"
          done
          echo ""
          read -rp "    Select [#]: " MEMBER_CHOICE
          if [[ "$MEMBER_CHOICE" =~ ^[0-9]+$ ]] && (( MEMBER_CHOICE >= 1 && MEMBER_CHOICE <= ${#MEMBER_EMAILS[@]} )); then
            NEW_ASSIGNED="${MEMBER_EMAILS[$((MEMBER_CHOICE-1))]}"
          else
            NEW_ASSIGNED="$MEMBER_CHOICE"
          fi
        fi
        ;;
      5) read -rp "    Email: " NEW_ASSIGNED ;;
      *) NEW_ASSIGNED="" ;;
    esac
    UNASSIGN="${UNASSIGN:-false}"

    # Iteration
    read -rp "  Iteration [$EDIT_ITERATION]: " NEW_ITERATION
    NEW_ITERATION="${NEW_ITERATION:-$EDIT_ITERATION}"

    # Build update args
    UPDATE_ARGS=(--id "$ID" --org "$ORG")
    CHANGES=0
    if [[ "$NEW_TITLE" != "$EDIT_TITLE" ]]; then
      UPDATE_ARGS+=(--title "$NEW_TITLE")
      CHANGES=$((CHANGES+1))
    fi
    if [[ -n "$NEW_ASSIGNED" ]]; then
      UPDATE_ARGS+=(--assigned-to "$NEW_ASSIGNED")
      CHANGES=$((CHANGES+1))
    elif [[ "$UNASSIGN" == "true" ]]; then
      UPDATE_ARGS+=(--assigned-to "")
      CHANGES=$((CHANGES+1))
    fi
    if [[ "$NEW_ITERATION" != "$EDIT_ITERATION" ]]; then
      UPDATE_ARGS+=(--iteration "$NEW_ITERATION")
      CHANGES=$((CHANGES+1))
    fi

    if [[ $CHANGES -eq 0 ]]; then
      echo "  No changes."
      exit 0
    fi

    spin_start "Updating..."
    set +e
    EDIT_RESULT=$(az boards work-item update "${UPDATE_ARGS[@]}" \
      --query "{id:id,title:fields.\"System.Title\",assignedTo:fields.\"System.AssignedTo\".displayName,iteration:fields.\"System.IterationPath\"}" \
      -o json 2>&1)
    EDIT_EXIT=$?
    set -e
    spin_stop

    if [[ $EDIT_EXIT -ne 0 ]]; then
      echo "❌  Update failed:"
      echo "$EDIT_RESULT"
      exit $EDIT_EXIT
    fi

    if [[ "$ADO_OUTPUT" == "json" ]]; then
      echo "$EDIT_RESULT"
    else
      echo "$EDIT_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  ✅  Updated #{d[\"id\"]}')
print(f'     Title:     {d[\"title\"]}')
print(f'     Assigned:  {d.get(\"assignedTo\") or \"Unassigned\"}')
print(f'     Iteration: {d.get(\"iteration\") or \"None\"}')
"
    fi
    ;;

  delete|rm)
    ID="${1:?Usage: ado delete <id>}"
    spin_start "Fetching ticket info..."
    TITLE=$(az boards work-item show --id "$ID" --org "$ORG" \
      --query 'fields."System.Title"' -o tsv 2>/dev/null || echo "(unknown)")
    spin_stop
    echo "⚠️   About to delete #$ID: $TITLE"
    read -rp "  Are you sure? [y/N]: " CONFIRM
    CONFIRM_UPPER=$(echo "$CONFIRM" | tr '[:lower:]' '[:upper:]')
    if [[ "$CONFIRM_UPPER" != "Y" && "$CONFIRM_UPPER" != "YES" ]]; then
      echo "  Aborted."
      exit 0
    fi
    spin_start "Deleting..."
    set +e
    DEL_RESULT=$(az boards work-item delete --id "$ID" --project "$PROJECT" --org "$ORG" --yes -o json 2>&1)
    DEL_EXIT=$?
    set -e
    spin_stop
    if [[ $DEL_EXIT -ne 0 ]]; then
      echo "❌  Failed to delete #$ID:"
      echo "$DEL_RESULT"
      exit $DEL_EXIT
    fi
    echo "  🗑️  Deleted #$ID: $TITLE"
    ;;

  desc|description)
    ID="${1:?Usage: ado desc <id>}"
    spin_start "Fetching current description..."
    CURRENT=$(az boards work-item show --id "$ID" --org "$ORG" \
      --query 'fields."System.Description"' -o tsv 2>/dev/null || echo "")
    spin_stop

    TMPFILE=$(mktemp /tmp/ado-desc-${ID}.XXXXXX.html)
    {
      echo "<!-- Editing description for #${ID}. ADO accepts HTML. -->"
      echo "<!-- Lines starting with <!-- are stripped before submit. -->"
      echo "<!-- Save empty (after comments) to abort. -->"
      echo ""
      echo "$CURRENT"
    } > "$TMPFILE"
    ${EDITOR:-nvim} "$TMPFILE"
    NEW_DESC=$(grep -v '^<!--' "$TMPFILE" | sed '/^[[:space:]]*$/d' | head -c 50000 || true)
    rm -f "$TMPFILE"

    if [[ -z "$NEW_DESC" ]]; then
      echo "⚠️   Empty description — aborted."
      exit 0
    fi

    spin_start "Updating description..."
    set +e
    RESULT=$(az boards work-item update --id "$ID" --org "$ORG" \
      --description "$NEW_DESC" -o none 2>&1)
    EXIT_CODE=$?
    set -e
    spin_stop

    if [[ $EXIT_CODE -ne 0 ]]; then
      echo "❌  Failed to update description:"
      echo "$RESULT"
      exit $EXIT_CODE
    fi
    echo "  ✅  Updated description on #${ID}"
    echo "     URL: $ORG/$PROJECT/_workitems/edit/${ID}"
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

    # Type — enumerate enabled, non-hidden work item types from the project
    echo ""
    spin_start "Loading work item types..."
    TYPES_TMP=$(mktemp); CATS_TMP=$(mktemp)
    az devops invoke \
      --area wit --resource workitemtypes \
      --route-parameters project="$PROJECT" \
      --org "$ORG" --http-method GET --api-version 7.1 -o json > "$TYPES_TMP" 2>/dev/null
    az devops invoke \
      --area wit --resource workitemtypecategories \
      --route-parameters project="$PROJECT" \
      --org "$ORG" --http-method GET --api-version 7.1 -o json > "$CATS_TMP" 2>/dev/null
    spin_stop

    mapfile -t TYPES < <(TYPES_FILE="$TYPES_TMP" CATS_FILE="$CATS_TMP" python3 -c "
import os, sys, json
try:
    types = json.load(open(os.environ['TYPES_FILE'])).get('value', [])
    cats  = json.load(open(os.environ['CATS_FILE'])).get('value', [])
except Exception:
    sys.exit(0)
hidden = set()
for c in cats:
    if c.get('referenceName') == 'Microsoft.HiddenCategory':
        for t in c.get('workItemTypes', []):
            hidden.add(t.get('name'))
names = [t['name'] for t in types if not t.get('isDisabled', False) and t['name'] not in hidden]
names.sort(key=str.lower)
for n in names:
    print(n)
" 2>/dev/null)
    rm -f "$TYPES_TMP" "$CATS_TMP"

    if [[ ${#TYPES[@]} -eq 0 ]]; then
      echo "❌  Could not enumerate work item types for project '$PROJECT'."
      exit 1
    fi

    DEFAULT_TYPE="${TYPES[0]}"
    echo "  Work item type:"
    for i in "${!TYPES[@]}"; do
      echo "    $((i+1))) ${TYPES[$i]}"
    done
    read -rp "  Select [1-${#TYPES[@]}] (default: 1 $DEFAULT_TYPE): " TYPE_CHOICE
    TYPE_CHOICE="${TYPE_CHOICE:-1}"
    if [[ "$TYPE_CHOICE" =~ ^[0-9]+$ ]] && (( TYPE_CHOICE >= 1 && TYPE_CHOICE <= ${#TYPES[@]} )); then
      WORK_ITEM_TYPE="${TYPES[$((TYPE_CHOICE-1))]}"
    else
      WORK_ITEM_TYPE="$DEFAULT_TYPE"
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
prefix = '$PROJECT' + sep + 'Iteration' + sep
paths = [c['path'].lstrip(sep).replace(prefix, '$PROJECT' + sep) for c in children]
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

    ADO_ORG_URL="$ORG" ADO_PROJECT_NAME="$PROJECT" python3 -c "
import os, sys, json, urllib.parse
org = os.environ['ADO_ORG_URL'].rstrip('/')
project = urllib.parse.quote(os.environ['ADO_PROJECT_NAME'])
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    print(f'  ✅  Created #{d[\"id\"]}')
    print(f'     Type:      {d[\"type\"]}')
    print(f'     State:     {d[\"state\"]}')
    print(f'     Assigned:  {d.get(\"assignedTo\") or \"Unassigned\"}')
    print(f'     Iteration: {d.get(\"iteration\") or \"None\"}')
    print(f'     Title:     {d[\"title\"]}')
    print(f'     URL:       {org}/{project}/_workitems/edit/{d[\"id\"]}')
except Exception:
    print('Raw response:')
    print(raw)
    raise
" <<< "$RESULT" || echo "$RESULT"
    ;;

  help|--help|-h|*)
    cat <<EOF
ADO CLI — Azure DevOps work item helper

Global flags (must come before the command):
  --quiet, -q              Suppress spinners and decorative output
  --json, -j               Suppress spinners, emit raw JSON where supported

Commands:
  ado mine                     List my open tickets
  ado current                  Show all team tickets in my latest sprint
  ado upcoming                 Show team tickets in next 2 sprints after my latest
  ado sprint [iteration]       List my tickets in a sprint (prompts if no arg given)
  ado show <id>                Show ticket details
  ado assign <id>              Assign a ticket to yourself
  ado unassign <id>            Remove assignment from a ticket
  ado state <id> [state]       Update ticket state (interactive picker if no state given)
  ado edit <id>                Edit title, assignment, and iteration interactively
  ado comment <id> <text>      Add a discussion comment
  ado open <id>                Open ticket in browser
  ado desc <id>                Edit description in $EDITOR (prefilled with current)
  ado delete <id>              Delete a work item (with confirmation)
  ado create ["title"]         Create a new work item (interactive)
EOF
    ;;
esac
