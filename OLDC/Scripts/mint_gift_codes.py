#!/usr/bin/env python3
"""
Mint Catalyst gift codes (comped access) — perpetual or capped.

Deliberately EMITS SQL rather than executing it. You review what you're about to run,
then pipe it to wrangler yourself. Minting entitlement is not something a script should
do behind your back, and the npm/npx shim on this Mac is currently broken anyway
(aheadFeatures §13), so a script that shelled out to wrangler would fail confusingly.

USAGE
  # 10 perpetual comps, dry run (prints SQL + the codes)
  python3 Scripts/mint_gift_codes.py --count 10 --perpetual

  # 25 comps of 90 days each, written to files
  python3 Scripts/mint_gift_codes.py --count 25 --days 90 --note "Launch giveaway" --out ./comps

  # then, after reading the SQL:
  cd catalyst_worker && npx wrangler d1 execute catalyst-db --remote --file=../comps.sql

WHY 15-DAY MULTIPLES
  Comps are sold in 15-day units. Enforced here, again in the Worker, and a third time by a
  CHECK constraint on `gift_codes` — a malformed length should be unable to REACH the database,
  not merely unlikely to be typed.
"""

import argparse
import csv
import secrets
import sys
import time
from pathlib import Path

# Matches the Worker's `refId` alphabet: no I and no O, because those are what get misread
# when a code is read aloud over a call or retyped from a screenshot.
#
# NOTE: this alphabet still contains L and U, contrary to what Formrules 12.43 claims. Kept
# IDENTICAL to the Worker on purpose — a code minted from a different alphabet than the one
# the app validates against would be rejected at redemption for no visible reason.
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

CODE_LEN = 12          # 32^12 ≈ 1.2e18 — guessing is not a threat model at this length
DAY_UNIT = 15


def make_code() -> str:
    """Cryptographically random, not `random` — these are bearer tokens for a paid product."""
    return "".join(secrets.choice(ALPHABET) for _ in range(CODE_LEN))


def sql_escape(s: str) -> str:
    return s.replace("'", "''")


TUTORIAL = """
Catalyst — gift code minter
───────────────────────────────────────────────────────────────────────────────
Mints comped access codes. Prints SQL for you to review, then you run it.
Nothing touches the database from here.

COMMON RECIPES

  10 lifetime codes, just show me the SQL
    python3 Scripts/mint_gift_codes.py --count 10 --perpetual

  25 codes worth 90 days each, saved to files
    python3 Scripts/mint_gift_codes.py --count 25 --days 90 \\
        --note "Launch giveaway" --out ./comps

  One 15-day code for a support case
    python3 Scripts/mint_gift_codes.py --count 1 --days 15 \\
        --note "Refund goodwill — ticket 412"

  A conference code 200 people can redeem, expires end of August
    python3 Scripts/mint_gift_codes.py --count 1 --days 180 \\
        --max-redemptions 200 --redeem-by 2026-08-31 --out ./conf

THEN RUN IT
    cd catalyst_worker
    npx wrangler d1 execute catalyst-db --remote --file=../comps.sql

FLAGS
  --count N            how many codes to mint                      (required)
  --perpetual          codes grant a lifetime licence     (this or --days)
  --days N             capped comp; MUST be a multiple of 15
  --note "…"           why they were issued; stored, shown to support
  --redeem-by DATE     last day the code can be REDEEMED (YYYY-MM-DD).
                       Not how long the Pro lasts — that's --days.
  --max-redemptions N  how many people may redeem EACH code   (default 1)
  --out PATH           write PATH.sql + PATH.csv instead of printing

WORTH KNOWING
  · --days must be a multiple of 15. 30, 45, 90, 180 are fine; 20 is refused.
  · --perpetual and --days are mutually exclusive. Pick one.
  · Codes are 12 random chars, no I or O (they get misread aloud).
  · The .csv is the shareable list. The .sql is what you run.
  · There is no un-mint. Once redeemed, a code has granted a licence.
  · Comped licences get NO invoice — nothing was paid.

Run with --help for the terse version.
"""


def main() -> int:
    # No arguments at all → teach, don't scold. argparse's default is a two-line usage error,
    # which is useless the first time and mildly insulting the tenth.
    if len(sys.argv) == 1:
        print(TUTORIAL)
        return 0

    p = argparse.ArgumentParser(description="Mint Catalyst gift codes.")
    p.add_argument("--count", type=int, required=True, help="How many codes to mint.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--perpetual", action="store_true", help="Codes grant a lifetime licence.")
    g.add_argument("--days", type=int, help=f"Capped comp length; must be a multiple of {DAY_UNIT}.")
    p.add_argument("--note", default="", help="Why these were issued (stored, for support).")
    p.add_argument("--redeem-by", default="",
                   help="Redemption deadline, YYYY-MM-DD. Unrelated to how long the Pro lasts.")
    p.add_argument("--max-redemptions", type=int, default=1,
                   help="Redemptions allowed PER CODE (default 1).")
    p.add_argument("--out", default="", help="Write <out>.sql and <out>.csv instead of stdout.")
    args = p.parse_args()

    if args.count < 1 or args.count > 10000:
        print("error: --count must be between 1 and 10000", file=sys.stderr)
        return 2

    if args.days is not None:
        if args.days <= 0 or args.days % DAY_UNIT != 0:
            print(f"error: --days must be a positive multiple of {DAY_UNIT} "
                  f"(got {args.days}). Nearest valid: "
                  f"{max(DAY_UNIT, round(args.days / DAY_UNIT) * DAY_UNIT)}", file=sys.stderr)
            return 2

    if args.max_redemptions < 1:
        print("error: --max-redemptions must be at least 1", file=sys.stderr)
        return 2

    redeem_by = "NULL"
    if args.redeem_by:
        try:
            t = time.strptime(args.redeem_by, "%Y-%m-%d")
        except ValueError:
            print("error: --redeem-by must be YYYY-MM-DD", file=sys.stderr)
            return 2
        redeem_by = str(int(time.mktime(t)))

    now = int(time.time())
    days_sql = "NULL" if args.perpetual else str(args.days)
    note_sql = f"'{sql_escape(args.note)}'" if args.note else "NULL"

    # Codes are unique by construction here (a set), and `code` is the PRIMARY KEY, so a
    # collision with an ALREADY-MINTED code fails the INSERT loudly rather than silently
    # overwriting someone's unredeemed comp. That is the correct direction to fail.
    codes: set[str] = set()
    while len(codes) < args.count:
        codes.add(make_code())
    ordered = sorted(codes)

    lines = [
        "-- Catalyst gift codes",
        f"-- minted:  {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now))}",
        f"-- kind:    {'perpetual' if args.perpetual else f'capped, {args.days} days'}",
        f"-- count:   {args.count}",
        f"-- per-code redemptions: {args.max_redemptions}",
        "--",
        "-- Review before running. There is no un-mint: a redeemed code has granted a licence.",
        "",
        "BEGIN TRANSACTION;",
    ]
    for c in ordered:
        lines.append(
            "INSERT INTO gift_codes (code, days, created_at, redeem_by, max_redemptions, note) "
            f"VALUES ('{c}', {days_sql}, {now}, {redeem_by}, {args.max_redemptions}, {note_sql});"
        )
    lines.append("COMMIT;")
    sql = "\n".join(lines) + "\n"

    if args.out:
        base = Path(args.out)
        base.parent.mkdir(parents=True, exist_ok=True)
        sql_path = base.with_suffix(".sql")
        csv_path = base.with_suffix(".csv")
        sql_path.write_text(sql)
        with csv_path.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["code", "days", "max_redemptions", "note"])
            for c in ordered:
                w.writerow([c, "perpetual" if args.perpetual else args.days,
                            args.max_redemptions, args.note])
        print(f"wrote {sql_path}  ({args.count} codes)")
        print(f"wrote {csv_path}  ← the shareable list")
        print()
        print("Review the SQL, then:")
        print(f"  cd catalyst_worker && npx wrangler d1 execute catalyst-db --remote "
              f"--file=../{sql_path}")
    else:
        print(sql)
        print("-- codes:", ", ".join(ordered), file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
