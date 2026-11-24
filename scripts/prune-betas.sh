#!/bin/zsh
# Once a stable version ships, removes the GitHub pre-release pages of its betas and of older ones. Tags stay, so any
# beta's code can still be found. Usage: scripts/prune-betas.sh 0.9.4 [--dry-run]
set -eu
VERSION=$1
DRY=${2:-}
[[ "$VERSION" == <->.<->(.<->|) ]] || { echo "Usage: scripts/prune-betas.sh 0.9.4 [--dry-run]"; exit 1; }
HERE=${0:A:h}
gh release list --limit 1000 --json tagName,isPrerelease --jq '.[] | select(.isPrerelease) | .tagName' | while read -r tag; do
  [[ "$tag" == v*-beta.<-> ]] || continue
  base=${${tag#v}%-beta.*}
  zsh "$HERE/version-at-least.sh" "$VERSION" "$base" || continue
  if [[ "$DRY" == --dry-run ]]; then
    echo "Would remove the release page for $tag"
  else
    gh release delete "$tag" --yes
    echo "Removed the release page for $tag; the tag stays."
  fi
done
