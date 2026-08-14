# Turns a raw ClickUp payload into the model the panel renders.
#
# Input:  { tasks: [<task from /team/{id}/task>],
#           listStatuses: { "<listId>": [{ status, color, orderindex, type }] } }
# Args:   $now, $dayStart, $dayEnd  (epoch milliseconds)
#         $statusOrder              (comma-separated status names, may be empty)
#
# Kept in its own file so the helper and tests/normalize-test.sh run the exact
# same grouping logic instead of two copies that drift.

def to_ms: if . == null or . == "" then null else (tonumber? // null) end;

def sprint_tags:
  [ (.tags // [])[] | (.name // "") | select(test("sprint[^0-9]*[0-9]+"; "i")) ];

def sprint_number: capture("sprint[^0-9]*(?<n>[0-9]+)"; "i").n | tonumber;

def norm:
  ((.due_date // null) | to_ms) as $due
  | (sprint_tags | sort_by(sprint_number) | last) as $sprintTag
  | {
      id: ((.id // "") | tostring),
      name: (.name // ""),
      url: (.url // ""),
      listId: ((.list.id // "") | tostring),
      listName: (.list.name // ""),
      # A list that sits directly in a space still reports a folder, flagged
      # hidden. Rendering its placeholder name would put "hidden" in the UI.
      folderName: (if (.folder.hidden // false) then "" else (.folder.name // "") end),
      status: ((.status.status // "") | ascii_downcase),
      statusColor: (.status.color // ""),
      dueDate: $due,
      overdue: ($due != null and $due < $now),
      dueToday: ($due != null and $due >= $dayStart and $due <= $dayEnd),
      sprint: (if $sprintTag == null then null else ($sprintTag | sprint_number) end),
      sprintLabel: ($sprintTag // ""),
      tags: [ (.tags // [])[] | .name // "" ],
      updatedAt: ((.date_updated // null) | to_ms)
    };

# Every status carries the position it occupies in its own list's workflow, so
# averaging that position across the lists a status appears in orders the
# sections without anyone configuring anything, in whatever language the
# workspace uses. Closed statuses are never fetched, so the highest position
# still open is the furthest along: the ranking below runs that descending,
# putting work that is nearly done above work that has not started.
( [ (.listStatuses // {})[]?[]? ]
  | group_by(.status | ascii_downcase)
  | map({ key: (.[0].status | ascii_downcase),
          value: ([ .[] | (.orderindex | tonumber? // 999) ] | add / length) })
  | from_entries ) as $rank

| ( ($statusOrder // "") | split(",")
    | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0)) ) as $order

# An explicit statusOrder wins; anything it does not name keeps the API order,
# after the named ones, so a new status shows up at the end rather than vanishing.
# A status whose list could not be read has no position at all and sorts last.
| def srank($s): ($order | index($s)) as $i
    | if $i != null then $i else (1000 - ($rank[$s] // -999)) end;
  [ (.tasks // [])[] | norm ] as $tasks
| (.listStatuses // {}) as $listStatuses
| ( $tasks
    | group_by(.status)
    | map({
        status: .[0].status,
        count: length,
        # Dated work first, soonest at the top, so overdue rises to the front
        # on its own; undated falls to the bottom ordered by newest sprint.
        tasks: sort_by([
          (if .dueDate == null then 1 else 0 end),
          (.dueDate // 0),
          (if .sprint == null then 0 else -.sprint end),
          (.name | ascii_downcase)
        ])
      })
    | sort_by(srank(.status)) ) as $sections

| {
    totalOpen: ($tasks | length),
    overdue: ([ $tasks[] | select(.overdue) ] | length),
    dueToday: ([ $tasks[] | select(.dueToday) ] | length),
    currentSprint: ([ $tasks[] | select(.sprint != null) ] | sort_by(.sprint) | last | .sprintLabel // ""),
    sections: $sections,
    listStatuses: $listStatuses
  }
