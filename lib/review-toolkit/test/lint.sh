#!/usr/bin/env bash
# lint.sh: no-network checks for the review-toolkit wrappers. Every script parses, every
# refusal reason exits with its own code before any write, and the happy paths send exactly
# one POST. `gh` is a stub on PATH that serves fixtures from $FX and logs every call.
#   ./lib/review-toolkit/test/lint.sh
set -uo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '\033[32m  PASS  %s\033[0m\n' "$*"; pass=$((pass+1)); }
bad() { printf '\033[31m  FAIL  %s\033[0m\n' "$*"; fail=$((fail+1)); }
expect() { # label, expected-exit, cmd…
  local label="$1" want="$2"; shift 2
  local out rc; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (exit $rc)"; else bad "$label: exit $rc, wanted $want: $(printf '%s' "$out" | tail -1)"; fi
}
says() { # label, regex, cmd…
  local label="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qE "$pat"; then ok "$label"; else bad "$label: no match for /$pat/ in: $(printf '%s' "$out" | tail -1)"; fi
}

FX="$(mktemp -d "${TMPDIR:-/tmp}/rt-lint.XXXXXX")"
trap 'rm -rf "${FX:?}"' EXIT
mkdir "$FX/bin" "$FX/compare" "$FX/link" "$FX/worklog"

# Isolate from any real config, kill switch and work log. Environment values win over the
# env file, so the fixture allowlists below are what the wrappers see.
export REVIEW_TOOLKIT_ENV="$T/example.env" FX MC_WORKLOG_DIR="$FX/worklog"
export AUTO_POST_KILL_SWITCH="$FX/auto-post.off" AUTO_POST_SELF="me" AUTO_POST_HEADER="Automated review"
export AUTO_POST_AUTHORS="alice, Bob" AUTO_POST_REPOS="o/r" AUTO_POST_MAX_REPLIES=2 AUTO_POST_TEAMS=""
unset MC_WORKLOG AUTO_POST_LABELS

# The stub: `gh api [flags] <path>` with --jq applied to the fixture the path maps to.
# POSTs log their --input body to $FX/posted and answer with an html_url.
cat > "$FX/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
[ "$1" = api ] || { echo "stub gh: unexpected $*" >&2; exit 1; }
shift
q=''; method=GET; path=''; input=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) q="$2"; shift ;;
    -X|--method) method="$2"; shift ;;
    --input) input="$2"; shift ;;
    --paginate) ;;
    -*) echo "stub gh: unexpected flag $1" >&2; exit 1 ;;
    *) path="$1" ;;
  esac
  shift
done
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ "$method" = POST ]; then
  if [ "$input" = - ]; then cat > "$FX/posted"; else cp "$input" "$FX/posted"; fi
  echo "POST $path" >> "$FX/writes"
  out='{"html_url":"https://github.example/o/r/pull/7#posted"}'
else
  case "$path" in
    user) out='{"login":"me-from-api"}' ;;
    repos/o/r/pulls/7) out="$(cat "$FX/pr.json")" ;;
    repos/o/r/pulls/7/reviews) out="$(cat "$FX/reviews.json")" ;;
    repos/o/r/pulls/7/comments) out="$(cat "$FX/comments.json")" ;;
    repos/o/r/pulls/comments/*)
      out="$(jq --argjson id "${path##*/}" '.[] | select(.id == $id)' "$FX/comments.json")"
      [ -n "$out" ] || nf ;;
    repos/o/r/compare/*)
      base="${path#repos/o/r/compare/}"; base="${base%%...*}"
      [ -f "$FX/compare/$base" ] || nf
      out="$(cat "$FX/compare/$base")" ;;
    *) nf ;;
  esac
fi
if [ -n "$q" ]; then printf '%s' "$out" | jq -r "$q"; else printf '%s\n' "$out"; fi
STUB
chmod +x "$FX/bin/gh"
export PATH="$FX/bin:$PATH"

reset() { rm -f "$FX/calls" "$FX/writes" "$FX/posted" "$FX/compare/"* "$FX/worklog/"*; rm -f "$AUTO_POST_KILL_SWITCH"; }
no_write() { if [ -s "$FX/writes" ]; then bad "$1: wrote $(tr '\n' ';' < "$FX/writes")"; else ok "$1"; fi; }

echo "syntax"
for f in "$T"/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done

echo "never resolves threads"
if grep -nE 'resolveReviewThread|graphql|minimizeComment' "$T/review-reply.sh" >/dev/null; then
  bad "review-reply.sh mentions a thread-resolving API"
else ok "review-reply.sh has no thread-resolving API call"; fi

# --- review-post --------------------------------------------------------------------------
echo "review-post: arguments and payload"
HEAD=abc1234def5678abc1234def5678abc1234def56
# pr_fixture <author> <head sha> <requested logins, space-sep> [requested team slugs, space-sep]
pr_fixture() {
  jq -n --arg a "$1" --arg h "$2" --arg req "$3" --arg teams "${4:-}" \
    '{user:{login:$a, type:"User"}, head:{sha:$h, ref:"feature"}, state:"open",
      html_url:"https://github.example/o/r/pull/7",
      requested_reviewers:[$req | split(" ")[] | select(. != "") | {login:.}],
      requested_teams:[$teams | split(" ")[] | select(. != "") | {slug:., name:("Team " + .)}]}' > "$FX/pr.json"
}
# reviews_fixture <login:commit …>
reviews_fixture() {
  jq -n --arg r "$1" '[$r | split(" ")[] | select(. != "") | split(":") | {user:{login:.[0]}, commit_id:.[1], state:"COMMENTED"}]' > "$FX/reviews.json"
}
payload() { # payload <file> [jq filter applied to the good payload]
  jq -n --arg h "$HEAD" '{head_sha:$h, body:"Overall looks fine.",
    comments:[{path:"a.rb", line:3, side:"RIGHT", body:"**must-fix:** nil check"},
              {path:"a.rb", line:9, body:"nit: spacing"},
              {path:"b.rb", line:1, body:"[question] why this order?"}]}' | jq "${2:-.}" > "$1"
}
good() { reset; pr_fixture alice "$HEAD" "me carol"; reviews_fixture "carol:$HEAD me:0000000"; payload "$FX/p.json"; }
rp() { "$T/review-post.sh" "$@"; }

good
expect "review-post: no args"                2 rp
expect "review-post: unknown flag"           2 rp o/r 7 "$FX/p.json" --bogus
expect "review-post: bad pr number"          2 rp o/r seven "$FX/p.json"
expect "review-post: bad repo"               2 rp just-a-name 7 "$FX/p.json"
expect "review-post: missing payload file"   2 rp o/r 7 "$FX/nope.json"
expect "review-post: bad verdict"            2 rp o/r 7 "$FX/p.json" --verdict maybe
payload "$FX/bad.json" 'del(.head_sha)'
expect "review-post: payload without head sha" 2 rp o/r 7 "$FX/bad.json"
printf 'not json' > "$FX/bad.json"
expect "review-post: payload not json"       2 rp o/r 7 "$FX/bad.json"
no_write "review-post: argument errors write nothing"

echo "review-post: refusals"
good; touch "$AUTO_POST_KILL_SWITCH"
expect "review-post: kill switch"            10 rp o/r 7 "$FX/p.json"
[ ! -s "$FX/calls" ] && ok "review-post: kill switch refuses before any gh call" || bad "review-post: kill switch made calls: $(tr '\n' ';' < "$FX/calls")"
good
expect "review-post: repo not allowlisted"   11 rp x/y 7 "$FX/p.json"
good
expect "review-post: empty repo allowlist refuses" 11 env AUTO_POST_REPOS= "$T/review-post.sh" o/r 7 "$FX/p.json"
good; pr_fixture mallory "$HEAD" "me"
expect "review-post: author not allowlisted" 12 rp o/r 7 "$FX/p.json"
good
expect "review-post: empty author allowlist refuses" 12 env AUTO_POST_AUTHORS= "$T/review-post.sh" o/r 7 "$FX/p.json"
good; pr_fixture bob "$HEAD" "me"
expect "review-post: allowlist match is case-insensitive and trims spaces" 0 rp o/r 7 "$FX/p.json" --dry-run
good; pr_fixture alice "$HEAD" "carol"
expect "review-post: self not a requested reviewer" 13 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.event = "APPROVE"'
expect "review-post: APPROVE in payload"     14 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.event = "REQUEST_CHANGES"'
expect "review-post: REQUEST_CHANGES in payload" 14 rp o/r 7 "$FX/p.json"
good
expect "review-post: --event APPROVE"        14 rp o/r 7 "$FX/p.json" --event APPROVE
good
expect "review-post: --approve"              14 rp o/r 7 "$FX/p.json" --approve
good
expect "review-post: --request-changes"      14 rp o/r 7 "$FX/p.json" --request-changes
good; payload "$FX/p.json" '.comments[1].body = "spacing is off"'
expect "review-post: inline comment without a category" 15 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.comments[1].body = "nits: spacing"'
expect "review-post: a label must be the whole word" 15 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.comments[1].body = "> \ud83e\udd16 Automated review\n\nThis looks wrong. issue: spacing"'
expect "review-post: prose before the label after a header" 15 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.comments[1].body = "> \ud83e\udd16 Automated review\n\n"'
expect "review-post: a header and nothing else" 15 rp o/r 7 "$FX/p.json"
good; payload "$FX/p.json" '.comments[1].body = "issue (blocking spacing"'
expect "review-post: unclosed decoration" 15 rp o/r 7 "$FX/p.json"
good
expect "review-post: AUTO_POST_LABELS narrows the label set" 15 env AUTO_POST_LABELS="nit, question" "$T/review-post.sh" o/r 7 "$FX/p.json" --dry-run
good
expect "review-post: AUTO_POST_LABELS with a non-word label" 2 env AUTO_POST_LABELS="nit,a.b" "$T/review-post.sh" o/r 7 "$FX/p.json" --dry-run
good; pr_fixture alice "$HEAD" "carol" "other-team"
expect "review-post: requested team not in AUTO_POST_TEAMS" 13 env AUTO_POST_TEAMS="my-team" "$T/review-post.sh" o/r 7 "$FX/p.json"
good; pr_fixture alice "$HEAD" "carol" "my-team"
expect "review-post: team request with AUTO_POST_TEAMS empty" 13 rp o/r 7 "$FX/p.json"
good; reviews_fixture "me:$HEAD"
expect "review-post: already reviewed this head" 16 rp o/r 7 "$FX/p.json"
good; pr_fixture alice "fff0000fff0000fff0000fff0000fff0000fff00" "me"
expect "review-post: head moved since the payload" 17 rp o/r 7 "$FX/p.json"
no_write "review-post: refusals write nothing"

echo "review-post: Conventional Comments labels and team requests"
for b in "issue: spacing" "nitpick: spacing" "**suggestion:** spacing" "issue (blocking): spacing" \
         "suggestion (non-blocking, security): spacing" "**issue (blocking):** spacing" "**Praise:** nice" \
         "[todo] spacing" "> \ud83e\udd16 Automated review by a bot\n\n**issue (blocking):** spacing" \
         "> header line one\n> header line two\n\n   \nnote: spacing"; do
  good; payload "$FX/p.json" ".comments[1].body = \"$b\""
  expect "review-post: label accepted: $(printf '%s' "$b" | tr '\n' ' ')" 0 rp o/r 7 "$FX/p.json" --dry-run
done
good; pr_fixture alice "$HEAD" "carol" "other-team My-Team"
expect "review-post: a requested team in AUTO_POST_TEAMS counts" 0 env AUTO_POST_TEAMS="x, my-team" "$T/review-post.sh" o/r 7 "$FX/p.json" --dry-run
no_write "review-post: label and team dry runs write nothing"

echo "review-post: dry run and post"
good
says "review-post: dry run prints the API call" 'POST repos/o/r/pulls/7/reviews' rp o/r 7 "$FX/p.json" --dry-run
no_write "review-post: dry run writes nothing"
[ -z "$(ls "$FX/worklog")" ] && ok "review-post: dry run logs nothing" || bad "review-post: dry run wrote a worklog line"
good
expect "review-post: posts" 0 rp o/r 7 "$FX/p.json" --verdict would-approve
[ "$(cat "$FX/writes" 2>/dev/null)" = "POST repos/o/r/pulls/7/reviews" ] && ok "review-post: exactly one POST" || bad "review-post: writes $(tr '\n' ';' < "$FX/writes" 2>/dev/null)"
jq -e --arg h "$HEAD" '.event == "COMMENT" and .commit_id == $h and (.comments | length) == 3 and (has("head_sha") | not)' "$FX/posted" >/dev/null \
  && ok "review-post: posts event COMMENT pinned to the head sha" || bad "review-post: posted $(jq -c . "$FX/posted" 2>/dev/null)"
if grep -q 'would-approve' "$FX/posted"; then bad "review-post: verdict leaked into the post"; else ok "review-post: verdict is not posted"; fi
wl="$(cat "$FX/worklog/"*.jsonl 2>/dev/null)"
printf '%s' "$wl" | jq -e 'select(.source == "review-post") | (.text | test("1 must-fix")) and (.text | test("1 nit")) and (.text | test("1 question"))
  and (.text | test("would-approve")) and (.text | test("#posted")) and .repo == "o/r"' >/dev/null \
  && ok "review-post: worklog line has counts, verdict and URL" || bad "review-post: worklog $wl"
good; payload "$FX/p.json" '.comments = [
  {path:"a.rb", line:1, body:"> \ud83e\udd16 Automated review\n\n**issue (blocking):** one"},
  {path:"a.rb", line:2, body:"issue (blocking, security): two"},
  {path:"a.rb", line:3, body:"issue (non-blocking): three"},
  {path:"a.rb", line:4, body:"suggestion: four"},
  {path:"a.rb", line:5, body:"**nitpick (non-blocking):** five"}]'
expect "review-post: posts Conventional Comments" 0 rp o/r 7 "$FX/p.json"
wl="$(cat "$FX/worklog/"*.jsonl 2>/dev/null)"
printf '%s' "$wl" | jq -e 'select(.source == "review-post") | .text | test("2 issue \\(blocking\\), 1 issue, 1 suggestion, 1 nitpick")' >/dev/null \
  && ok "review-post: worklog counts by label word and blocking flag" || bad "review-post: worklog $wl"
good
expect "review-post: AUTO_POST_SELF falls back to gh api user" 13 env -u AUTO_POST_SELF "$T/review-post.sh" o/r 7 "$FX/p.json"
grep -q '^api user' "$FX/calls" && ok "review-post: asked gh for the login" || bad "review-post: no gh api user call"

# --- review-reply -------------------------------------------------------------------------
echo "review-reply: arguments"
# comments_fixture: thread rooted at 100 (human), at 200 (bot by type), at 300 (bot by suffix),
# at 400 (human whose body carries an automated header). 101/102 are earlier replies by me.
comments_fixture() {
  jq -n --arg hdr "$AUTO_POST_HEADER" '[
    {id:100, in_reply_to_id:null, user:{login:"alice", type:"User"}, body:"why?", pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:101, in_reply_to_id:100, user:{login:"me", type:"User"}, body:($hdr + "\nfixed"), pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:103, in_reply_to_id:100, user:{login:"alice", type:"User"}, body:"thanks", pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:200, in_reply_to_id:null, user:{login:"reviewbot", type:"Bot"}, body:"lint", pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:300, in_reply_to_id:null, user:{login:"helper[bot]", type:"User"}, body:"lint", pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:400, in_reply_to_id:null, user:{login:"carol", type:"User"}, body:($hdr + "\nnit: x"), pull_request_url:"https://api.github.example/repos/o/r/pulls/7"},
    {id:500, in_reply_to_id:null, user:{login:"alice", type:"User"}, body:"other pr", pull_request_url:"https://api.github.example/repos/o/r/pulls/8"}
  ]' > "$FX/comments.json"
}
rgood() {
  reset; pr_fixture me "$HEAD" ""; comments_fixture
  printf '%s\n\nFixed in 1a2b3c4.\n' "$AUTO_POST_HEADER" > "$FX/body.md"
  echo '{"status":"ahead"}' > "$FX/compare/1a2b3c4"
}
rr() { "$T/review-reply.sh" "$@"; }

rgood
expect "review-reply: no args"               2 rr
expect "review-reply: unknown flag"          2 rr o/r 7 100 "$FX/body.md" --bogus
expect "review-reply: bad comment id"        2 rr o/r 7 abc "$FX/body.md"
expect "review-reply: missing body file"     2 rr o/r 7 100 "$FX/nope.md"
expect "review-reply: bad category"          2 rr o/r 7 100 "$FX/body.md" --category 'Fix It'
no_write "review-reply: argument errors write nothing"

echo "review-reply: refusals"
rgood; touch "$AUTO_POST_KILL_SWITCH"
expect "review-reply: kill switch"           10 rr o/r 7 100 "$FX/body.md"
[ ! -s "$FX/calls" ] && ok "review-reply: kill switch refuses before any gh call" || bad "review-reply: kill switch made calls"
rgood
expect "review-reply: repo not allowlisted"  11 rr x/y 7 100 "$FX/body.md"
rgood; pr_fixture alice "$HEAD" ""
expect "review-reply: not my PR"             12 rr o/r 7 100 "$FX/body.md"
rgood
expect "review-reply: comment does not exist" 18 rr o/r 7 999 "$FX/body.md"
rgood
expect "review-reply: comment is on another PR" 18 rr o/r 7 500 "$FX/body.md"
rgood; printf '%s\n\nFixed in 9f9f9f9.\n' "$AUTO_POST_HEADER" > "$FX/body.md"
expect "review-reply: cited sha unknown"     19 rr o/r 7 100 "$FX/body.md"
rgood; printf '%s\n\nFixed in 7e7e7e7.\n' "$AUTO_POST_HEADER" > "$FX/body.md"; echo '{"status":"diverged"}' > "$FX/compare/7e7e7e7"
expect "review-reply: cited sha not on the head branch" 19 rr o/r 7 100 "$FX/body.md"
rgood
expect "review-reply: bot root by account type" 20 rr o/r 7 200 "$FX/body.md"
rgood
expect "review-reply: bot root by [bot] suffix" 20 rr o/r 7 300 "$FX/body.md"
rgood; printf 'Fixed in 1a2b3c4.\n' > "$FX/body.md"
expect "review-reply: body without the header" 21 rr o/r 7 100 "$FX/body.md"
rgood; jq --arg hdr "$AUTO_POST_HEADER" '. + [{id:102, in_reply_to_id:100, user:{login:"me", type:"User"}, body:($hdr + "\nagain"), pull_request_url:"https://api.github.example/repos/o/r/pulls/7"}]' \
  "$FX/comments.json" > "$FX/c2.json" && mv "$FX/c2.json" "$FX/comments.json"
expect "review-reply: reply cap reached escalates" 30 rr o/r 7 100 "$FX/body.md"
says   "review-reply: escalation says so"     'escalate to a human' rr o/r 7 103 "$FX/body.md"
no_write "review-reply: refusals write nothing"

echo "review-reply: allowed and posted"
rgood
expect "review-reply: human root whose body carries a header is allowed" 0 rr o/r 7 400 "$FX/body.md" --dry-run
rgood; jq --arg hdr "$AUTO_POST_HEADER" '. + [{id:104, in_reply_to_id:100, user:{login:"me", type:"User"}, body:"manual reply", pull_request_url:"https://api.github.example/repos/o/r/pulls/7"}]' \
  "$FX/comments.json" > "$FX/c2.json" && mv "$FX/c2.json" "$FX/comments.json"
expect "review-reply: my replies without the header do not count" 0 rr o/r 7 100 "$FX/body.md" --dry-run
rgood
says "review-reply: dry run prints the API call" 'POST repos/o/r/pulls/7/comments/100/replies' rr o/r 7 103 "$FX/body.md" --dry-run
no_write "review-reply: dry run writes nothing"
rgood
expect "review-reply: posts" 0 rr o/r 7 103 "$FX/body.md" --category fix
[ "$(cat "$FX/writes" 2>/dev/null)" = "POST repos/o/r/pulls/7/comments/100/replies" ] && ok "review-reply: one POST to the thread root" || bad "review-reply: writes $(tr '\n' ';' < "$FX/writes" 2>/dev/null)"
jq -e --arg hdr "$AUTO_POST_HEADER" '.body | startswith($hdr)' "$FX/posted" >/dev/null && ok "review-reply: posts the body as given" || bad "review-reply: posted $(cat "$FX/posted" 2>/dev/null)"
wl="$(cat "$FX/worklog/"*.jsonl 2>/dev/null)"
printf '%s' "$wl" | jq -e 'select(.source == "review-reply") | (.text | test("fix")) and (.text | test("#posted")) and .repo == "o/r"' >/dev/null \
  && ok "review-reply: worklog line has category and URL" || bad "review-reply: worklog $wl"

echo "symlinked invocation"
ln -s "$T/review-post.sh" "$FX/link/review-post.sh"; ln -s "$T/review-reply.sh" "$FX/link/review-reply.sh"
good
expect "review-post through a symlink"  0 "$FX/link/review-post.sh" o/r 7 "$FX/p.json" --dry-run
rgood
expect "review-reply through a symlink" 0 "$FX/link/review-reply.sh" o/r 7 103 "$FX/body.md" --dry-run
ln -s "$T/review-env.sh" "$FX/link/review-env.sh"
[ "$(env -u REVIEW_TOOLKIT_ENV bash -c '. "$1"; echo "$RT_ENV_FILE"' _ "$FX/link/review-env.sh")" = "$T/review.env" ] \
  && ok "review.env is looked up next to the real file, not the symlink" || bad "review.env lookup through a symlink"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32m%s passed, 0 failed\033[0m\n' "$pass"; else printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
