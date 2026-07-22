#!/usr/bin/env bash
# Flush auth lockouts so a test account can sign in again.
#
# WHY THE OLD (email-only) VERSION DIDN'T WORK: the app's "Too many attempts" message is the
# backend `rate_limited` 429 (AuthViewModel), returned from fixed-window `rl:*` KV buckets:
#   rl:otp:email:<email>  4/hour   (keyed by email — deletable by address)
#   rl:otp:ip:<ip>        20/hour  (keyed by IP     — NOT derivable from an email)
#   rl:otp:dev:<device>   6/day    (keyed by device — NOT derivable from an email)  ← usual culprit
#   rl:verify:ip:<ip>     30/hour  (verify path)
# Deleting the email key alone leaves the IP/device buckets tripped. So this purges EVERY
# `rl:*` (all rate-limit buckets) plus pending `otp:*` / `sotp:*` OTP state. It does NOT touch
# `apprefresh:*` (refresh tokens) or `stupl:*`, so signed-in users stay signed in.
#
# Dev tool: it resets rate limits for ALL users, which is fine pre-launch. Run from anywhere.
set -uo pipefail
cd "$(dirname "$0")/../catalyst_worker" || exit 1

BINDING=SESSIONS

# 1) Targeted per-email keys (fast; also clears the pending sign-in OTP state `otp:<email>`).
for addr in "shivanggulati817@gmail.com" "shivigulati.08@gmail.com" "shivangclicks@gmail.com"; do
  for k in "otp:$addr" "rl:otp:email:$addr" "rl:magic:email:$addr" "rl:sotp:email:$addr"; do
    npx wrangler kv key delete "$k" --binding="$BINDING" --remote 2>/dev/null || true
  done
done

# 2) The real fix: purge every rate-limit + pending-OTP key by prefix (covers the IP/device
#    buckets that can't be reached by email). List → extract names → delete each.
for prefix in "rl:" "otp:" "sotp:"; do
  npx wrangler kv key list --binding="$BINDING" --remote --prefix "$prefix" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{for(const{name}of JSON.parse(s||"[]"))console.log(name)}catch{}})' \
    | while IFS= read -r key; do
        [ -n "$key" ] && npx wrangler kv key delete "$key" --binding="$BINDING" --remote 2>/dev/null || true
      done
done

echo "✅ Flushed all rate-limit + OTP lockouts (rl: / otp: / sotp:). Sign-in codes can be requested again."
