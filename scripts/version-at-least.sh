#!/bin/zsh
# Succeeds when version $1 is at least $2, part by part as numbers: 0.10.0 comes after 0.9.2, and 0.5 equals 0.5.0.
# Usage: scripts/version-at-least.sh 0.5.0 0.4.2
set -eu
local -a a b
a=(${(s:.:)1})
b=(${(s:.:)2})
local count=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
for (( i = 1; i <= count; i++ )); do
  (( ${a[i]:-0} > ${b[i]:-0} )) && exit 0
  (( ${a[i]:-0} < ${b[i]:-0} )) && exit 1
done
exit 0
