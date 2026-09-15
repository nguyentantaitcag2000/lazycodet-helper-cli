#!/bin/bash

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository."
    exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is not installed."
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)

# Every branch that exists right now, with the date of its last commit. Used
# both to drop reflog entries whose branch is gone and to list branches that
# were never checked out under their current name.
LOCAL_BRANCHES=$(
    git for-each-ref \
        --format='%(committerdate:format:%Y-%m-%d %H:%M:%S)%09%(refname:short)' \
        refs/heads/
)

if [ -z "$LOCAL_BRANCHES" ]; then
    echo "Info: No local branches found."
    exit 0
fi

# Checkout targets from the HEAD reflog, replayed oldest first so that
# "Branch: renamed" entries can carry a checkout forward to the name the
# branch has today. Each branch identity gets a slot; a rename relabels the
# slot instead of creating a second one, and dropping the old name from the
# lookup keeps a later branch reusing that name separate.
CHECKOUT_HISTORY=$(
    GIT_PAGER=cat git reflog show --date=format:'%Y-%m-%d %H:%M:%S' --format='%gd%x09%gs' |
    awk -F'\t' '
    {
        selector[NR] = $1
        message[NR] = $2
    }
    END {
        for (i = NR; i >= 1; i--) {
            date = selector[i]
            sub(/^[^{]*\{/, "", date)
            sub(/\}$/, "", date)

            count = split(message[i], word, " ")

            if (message[i] ~ /^checkout: moving from /) {
                branch = word[count]

                if (!(branch in slot)) {
                    slot[branch] = ++slots
                    label[slots] = branch
                }

                visited[slot[branch]] = date
                continue
            }

            if (message[i] ~ /^Branch: renamed /) {
                old = word[3]
                new = word[5]
                sub(/^refs\/heads\//, "", old)
                sub(/^refs\/heads\//, "", new)

                if (old in slot) {
                    id = slot[old]
                    delete slot[old]
                    slot[new] = id
                    label[id] = new
                }
            }
        }

        for (id = 1; id <= slots; id++) {
            if (id in visited) {
                print visited[id] "\t" label[id]
            }
        }
    }
    '
)

# A branch is dated by its last checkout, falling back to its last commit for
# branches that have never been checked out under the name they carry now.
MERGED=$(
    awk -F'\t' '
    FNR == NR {
        if ($2 != "") {
            visited[$2] = 1
        }

        print
        next
    }

    !($2 in visited)
    ' <(printf '%s\n' "$CHECKOUT_HISTORY") <(printf '%s\n' "$LOCAL_BRANCHES") |
    grep -v '^[[:space:]]*$' |
    LC_ALL=C sort -r
)

BRANCH_HISTORY=$(
    awk -F'\t' -v current="$CURRENT_BRANCH" '
    FNR == NR {
        exists[$2] = 1
        next
    }

    !($2 in exists) || ($2 in seen) {
        next
    }

    {
        seen[$2] = 1
        order[++rows] = $2
        stamp[$2] = $1

        if (length($2) > width) {
            width = length($2)
        }
    }

    END {
        format = "%s %-" width "s | %s\n"

        for (i = 1; i <= rows; i++) {
            printf format, (order[i] == current ? "●" : "○"), order[i], stamp[order[i]]
        }
    }
    ' <(printf '%s\n' "$LOCAL_BRANCHES") <(printf '%s\n' "$MERGED")
)

if [ -z "$BRANCH_HISTORY" ]; then
    echo "Info: No checkout history found."
    exit 0
fi

echo ""
echo "Current branch: $CURRENT_BRANCH"
echo "ENTER = checkout branch"
echo "ESC   = cancel"
echo ""

SELECTED=$(
    echo "$BRANCH_HISTORY" |
    fzf \
        --height=80% \
        --layout=reverse \
        --border \
        --prompt="Branch History > "
)

if [ -z "$SELECTED" ]; then
    echo "Cancelled."
    exit 0
fi

TARGET_BRANCH=$(echo "$SELECTED" | awk '{print $2}')

if [ "$TARGET_BRANCH" = "$CURRENT_BRANCH" ]; then
    echo "Already on branch: $CURRENT_BRANCH"
    exit 0
fi

git checkout "$TARGET_BRANCH"
