#!/usr/bin/env bash
# Integration test: the default harness launches Pi and submits its prompt.
set -euo pipefail

ROOT="${WORKTREE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TMP="$(mktemp -d)"
SESSION="pi-harness-test-$$"
ACCEPTED_SESSION="pi-harness-accepted-test-$$"
WINDOW="issue-test-$$"
TARGET="$SESSION:0"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux kill-session -t "$ACCEPTED_SESSION" 2>/dev/null || true
  rm -rf "$TMP"
  rm -f "/tmp/harness-pi-harness-test-$$.sh"
}
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pi" <<'RUBY'
#!/usr/bin/env ruby
STDOUT.sync = true
if ARGV.include?("--help")
  puts "fake Pi"
  exit 0
end
File.write(ENV.fetch("PI_ARGS_LOG"), ARGV.join("\n"))
if ENV["PI_MODE"] == "accepted"
  puts "0.3%/1.0M fake Pi"
  STDIN.each_line do |line|
    File.write(ENV.fetch("PI_UNEXPECTED_PASTE_LOG"), line)
  end
  sleep 60
end
puts "0.0%/ fake Pi"
input = ""
STDIN.each_line do |line|
  input << line
  next unless line.include?("second line")

  File.write(ENV.fetch("PI_PROMPT_LOG"), input)
  puts "↑1 fake Pi primed"
  break
end
sleep 60
RUBY

cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env sh
echo "Claude must not launch by default" >&2
exit 99
SH
chmod +x "$TMP/bin/pi" "$TMP/bin/claude"

printf 'TEST PROMPT\nsecond line\n' > "$TMP/pr_context.md"
cat > "$TMP/.worktree-session.json" <<JSON
{
  "worktree_path": "$TMP",
  "tmux_target": "$TARGET",
  "tmux_window": "$WINDOW",
  "remote_control": "pi-harness-test-$$",
  "type": "issue"
}
JSON

tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$TMP" \
  "env PATH='$TMP/bin':\"$PATH\" PI_ARGS_LOG='$TMP/pi-args.log' PI_PROMPT_LOG='$TMP/pi-prompt.log' bash --noprofile --norc"

(
  cd "$TMP"
  PATH="$TMP/bin:$PATH" TMUX="${TMUX:-test}" "$ROOT/bin/worktree" harness
)

grep -q 'TEST PROMPT' "$TMP/pi-prompt.log"
grep -q 'second line' "$TMP/pi-prompt.log"
grep -qx -- '--exclude-tools' "$TMP/pi-args.log"
grep -qx -- 'edit,write' "$TMP/pi-args.log"
echo "PASS: default harness launched Pi and submitted the complete prompt"

# A provider error can leave nonzero context usage without token counters.
# That state is already primed; another paste would duplicate the prompt.
rm -f "$TMP/pi-prompt.log"
tmux kill-session -t "$SESSION"
tmux new-session -d -s "$ACCEPTED_SESSION" -n "$WINDOW" -c "$TMP" \
  "env PATH='$TMP/bin':\"$PATH\" PI_MODE=accepted PI_ARGS_LOG='$TMP/pi-args.log' PI_UNEXPECTED_PASTE_LOG='$TMP/unexpected-paste.log' bash --noprofile --norc"
TARGET=$(tmux display-message -p -t "$ACCEPTED_SESSION" '#{session_name}:#{window_index}')
ruby -rjson -e \
  'path = ARGV[0]; session = JSON.parse(File.read(path)); session["tmux_target"] = ARGV[1]; File.write(path, JSON.pretty_generate(session))' \
  "$TMP/.worktree-session.json" "$TARGET"

(
  cd "$TMP"
  PATH="$TMP/bin:$PATH" TMUX="${TMUX:-test}" "$ROOT/bin/worktree" harness
)

[ ! -e "$TMP/unexpected-paste.log" ]
echo "PASS: nonzero context usage without token counters counts as primed"
