#!/bin/bash
# Fails when app code sets an animation's duration with a number instead of a Tokens.Motion role
# (DESIGN.md › Motion). Durations live in Zigzag/Design/Tokens.swift; everything else names a role.
#
#   scripts/check-motion.sh            checks Zigzag/
#   scripts/check-motion.sh <dir>...   checks those folders instead
#
# The one exception is the download: its flight into the button and its progress ring keep their own timing.
# Allow a line by adding its file and a piece of its text to ALLOWED below, with the reason.
set -euo pipefail
cd "$(dirname "$0")/.."

dirs=("$@")
[ ${#dirs[@]} -eq 0 ] && dirs=(Zigzag)

# file|text on the line
ALLOWED=(
  # The download's progress ring: it follows the download, not a role.
  "Zigzag/Sidebar/SidebarView.swift|ease.duration = downloading ?"
)

# Where a duration is set: Core Animation, AppKit's animation context, a transaction, a Curve, or the duration
# argument of the house helpers.
pattern='(\.duration[[:space:]]*=|setAnimationDuration\(|Curve\(duration:|perceptualDuration:|(easeAnimation|springAnimation|glide|fade|fadeIn|fadeOut|setColor|set\(backgroundColor|setEdgeToEdge)\(.*duration:)'

failed=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  text=${rest#*:}
  [ "$file" = "Zigzag/Design/Tokens.swift" ] && continue
  # What's set: from the duration to the end of the expression. Multiplying a role (`* debugSlowdown`, `* 0.7`) is
  # fine; a number standing on its own isn't. 0 means instant, which is no animation at all.
  value=$(printf '%s\n' "$text" | perl -ne '
    if (/(?:\.duration\s*=|setAnimationDuration\(|Curve\(duration:|perceptualDuration:|duration:)\s*(.*)$/) {
      my $v = $1;
      $v =~ s/,.*$//;                      # the next argument (a delay) is not the duration
      $v =~ s/[*\/]\s*[0-9.]+//g;           # a role scaled
      $v =~ s/\b[A-Za-z_][A-Za-z0-9_.]*\b//g; # names
      print $v;
    }')
  printf '%s' "$value" | grep -qE '(^|[^0-9.])([1-9][0-9]*(\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)' || continue
  allowed=0
  for entry in "${ALLOWED[@]}"; do
    [ "$file" = "${entry%%|*}" ] && [[ "$text" == *"${entry#*|}"* ]] && allowed=1
  done
  [ $allowed -eq 1 ] && continue
  echo "$file:$line: a raw animation duration; use a Tokens.Motion role:$text"
  failed=1
done < <(grep -rnE "$pattern" --include='*.swift' "${dirs[@]}" || true)

if [ $failed -ne 0 ]; then
  echo "Animation durations come from Tokens.Motion's roles (DESIGN.md › Motion)." >&2
  exit 1
fi
echo "Motion: every animation uses a Tokens.Motion role."
