#!/usr/bin/env bash
# Scan guard: every shell script in the repository parses under CI's /bin/bash (bash 3.2), and no `${…}` default or
# error message holds a lone apostrophe.
#
# Why (docs/bugfixes/2026-11-27-feed-writer-apostrophe-never-parsed.md): scripts/write-update-feed.sh, which writes each
# release's update feed, reached main unable to run. An apostrophe in a `${2:?…}` message opened a single quote that
# swallowed the next lines, `fi` included. Checks run most scripts, so most parse errors turn some check red; a release
# tool, a smoke or a pipeline run only by hand is never parsed until someone needs it.
#
# 1. Which files: `git ls-files` (tracked, plus new files not yet added, minus ignored ones): every `.sh` file and every
#    file whose first line is a bash or sh shebang. No fixed list: a script is covered from the day it is added.
# 2. Each one parses under `/bin/bash -n`, the shell check-all.sh and CI run scripts with. Known blind spot: bash 3.2
#    parses what is inside `$( … )` only when it runs, so a syntax error in there passes here.
# 3. No lone apostrophe in the word of `${name:-…}`, `${name:=…}`, `${name:?…}` or `${name:+…}` (with or without the
#    colon). Bash 3.2 and 5 both read it as the start of a single-quoted string, even inside double quotes. With one
#    such apostrophe the script doesn't parse (2 catches it); with two, it parses and silently takes everything between
#    them as one string: an assignment, a message, a `fi`. Rule 2 can't see that, so this scan looks for the apostrophe
#    itself. Fine: one inside a nested "…", an escaped \' (printed with its backslash), a pair ('…') in one expansion.
#    Known blind spots: an expansion spread over several lines, a `${` nested inside the word.
set -euo pipefail
cd "$(dirname "$0")/.."

# Perl programs go in quoted heredocs: not one character passes through the shell (the shell traps case, trap 5).
# Prints each file that is a shell script. Reads only the first bytes of a file (binary files included).
read -r -d '' PICK <<'PERL' || true
for my $file (@ARGV) {
  next unless -f $file;
  if ($file =~ /\.sh\z/) { print "$file\n"; next }
  open(my $fh, '<', $file) or next;
  my $head = '';
  read($fh, $head, 256);
  close $fh;
  print "$file\n" if $head =~ m{\A#![ \t]*(?:/usr/bin/env[ \t]+(?:-\S+[ \t]+)*)?(?:\S*/)?(?:ba)?sh(?:[ \t\r\n]|\z)};
}
PERL

# A line with a lone apostrophe in the word of ${name:-…} / := / :? / :+ (comment lines skipped). The word's loop
# takes plain characters, escapes, "…" and paired '…' possessively, so a paired quote is never re-read as a lone one.
read -r -d '' LONE <<'PERL' || true
next if /^\s*#/;
print "$ARGV:$.: $_" if /\$\{[A-Za-z0-9_]+(?:\[[^\]]*\])?:?[-=?+](?:[^}'"\\]|\\.|"(?:[^"\\]|\\.)*"|'[^'}]*')*+'/;
close ARGV if eof;
PERL

FILES=()
while IFS= read -r file; do
  FILES+=("${file}")
done < <(git ls-files -z --cached --others --exclude-standard | xargs -0 perl -e "${PICK}" | LC_ALL=C sort -u)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "✗ shell-syntax: found no shell script at all (an empty scan is a false green)" >&2
  exit 1
fi

FAILED=0
PARSE=""
for file in "${FILES[@]}"; do
  if ! errors="$(/bin/bash -n "${file}" 2>&1)"; then
    PARSE="${PARSE}${file}:"$'\n'"${errors}"$'\n'
  fi
done
if [ -n "${PARSE}" ]; then
  echo "✗ shell-syntax: these scripts don't parse under /bin/bash -n (bash 3.2, the shell CI and check-all.sh use):" >&2
  printf '%s' "${PARSE}" | sed 's/^/    /' >&2
  FAILED=1
fi

LONE_HITS="$(perl -ne "${LONE}" "${FILES[@]}")"
if [ -n "${LONE_HITS}" ]; then
  echo "✗ shell-syntax: a lone apostrophe in a \${name:-…} / \${name:?…} word opens a single quote, even inside double quotes" >&2
  echo "  (one: the script doesn't parse; two: it parses and runs everything between them as one string). Reword it:" >&2
  printf '%s\n' "${LONE_HITS}" | sed 's/^/    /' >&2
  FAILED=1
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ shell-syntax: ${#FILES[@]} shell scripts parse under /bin/bash -n; no lone apostrophe in a \${…} word"
