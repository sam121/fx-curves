#!/usr/bin/env bash
# scripts/fetch_fx.sh
# Fetch a small grid of Wise FX quotes and publish JSON for the website.

set -o pipefail

# ---------- Config ----------
API_BASE="${WISE_API_BASE:-https://api.transferwise.com}"
: "${WISE_TOKEN?Need env WISE_TOKEN set (GitHub Secret WISE_TOKEN)}"

# 4 pairs × 6 amounts = 24 rows
PAIRS=("GBP:USD" "USD:JPY" "SGD:USD" "EUR:USD")
AMOUNTS=(10 100 1000 10000 100000 1000000)

# Where the workflow writes
OUTDIR="data"
OUTFILE="${OUTDIR}/latest.json"

# Where the website reads
SITE_OUTDIR="docs/data"
SITE_OUTFILE="${SITE_OUTDIR}/latest.json"

TMPFILE="$(mktemp)"
mkdir -p "$OUTDIR" "$SITE_OUTDIR"
: > "$TMPFILE"

echo "Using API base: ${API_BASE}"

# ---------- Headers ----------
CURL_AUTH=(-H "Authorization: Bearer ${WISE_TOKEN}" -H "Content-Type: application/json")

# ---------- Helpers ----------
get_profile_id() {
  curl -sS "${API_BASE}/v1/profiles" "${CURL_AUTH[@]}" \
  | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}

PROFILE_ID="$(get_profile_id)"
if [[ -z "$PROFILE_ID" || "$PROFILE_ID" == "null" ]]; then
  echo "Error: could not resolve Wise profile ID via GET /v1/profiles"
  diag="$(curl -sS "${API_BASE}/v1/profiles" "${CURL_AUTH[@]}" | jq 'if type=="array" then {"type":"array","len":length} else {"type":type, "keys":(keys? // [])} end' 2>/dev/null || true)"
  [[ -n "$diag" ]] && echo "Profiles response shape: $diag"
  exit 1
fi

# ---------- Fetch ----------
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for pair in "${PAIRS[@]}"; do
  IFS=: read -r SRC TGT <<< "$pair"
  for amt in "${AMOUNTS[@]}"; do
    body=$(jq -n \
      --arg src "$SRC" \
      --arg tgt "$TGT" \
      --argjson amt "$amt" \
      --argjson profile "$PROFILE_ID" \
      '{profile: $profile, sourceCurrency: $src, targetCurrency: $tgt,
        sourceAmount: $amt, payOut: "BALANCE", preferredPayIn: "BALANCE"}')

    resp="$(curl -sS -X POST "${API_BASE}/v3/quotes" "${CURL_AUTH[@]}" -d "$body" || true)"

    # Record explicit error row if the API errored
    if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' >/dev/null 2>&1; then
      echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"BALANCE\",\"targetAmount\":null,\"fee_total\":null,\"mode\":\"BALANCE\",\"src\":\"${SRC}\",\"tgt\":\"${TGT}\",\"amount\":${amt},\"midTarget\":null,\"fee_bps\":null,\"status\":\"error\"}" >> "$TMPFILE"
      continue
    fi

    # Build a row with numeric types (cast strings -> numbers safely)
    row=$(echo "$resp" | jq -c \
      --arg ts "$ts_iso" --arg src "$SRC" --arg tgt "$TGT" --argjson amt "$amt" '
        (try (.rate|tonumber) catch null) as $rate
        | (
            (.paymentOptions // [])
            | map(select(.payIn=="BALANCE" and .payOut=="BALANCE"))
            | (.[0] // {})
          ) as $opt
        | (try ($opt.targetAmount // $opt.target.amount | tonumber) catch null) as $tgtAmt
        | (try ($opt.fee.total | tonumber) catch null) as $feeTot
        | {
            ts: $ts,
            sourceCurrency: $src,
            targetCurrency: $tgt,
            sourceAmount: $amt,
            rate: $rate,
            payIn:  ($opt.payIn  // "BALANCE"),
            payOut: ($opt.payOut // "BALANCE"),
            targetAmount: $tgtAmt,
            fee_total:    $feeTot,
            # extras for the website
            mode: ($opt.payOut // "BALANCE"),
            src:  $src,
            tgt:  $tgt,
            amount: $amt,
            midTarget: ( ($rate // 0) * $amt ),
            fee_bps: (
              if (($rate // 0) > 0 and ($tgtAmt // 0) > 0)
              then (1 - ($tgtAmt / (($rate) * $amt))) * 10000
              else null
              end
            ),
            status: ( if ($rate != null and $tgtAmt != null) then "ok" else "incomplete" end )
          }')

    echo "$row" >> "$TMPFILE"
  done
done

# ---------- Write & publish ----------
jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE"

if [[ ! -s "$OUTFILE" ]]; then
  echo "Error: ${OUTFILE} missing or empty"
  exit 1
fi

rows_total="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
rows_valid="$(jq '[.[] | select(.fee_bps != null)] | length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows_total} rows (${rows_valid} valid fee_bps points)"

# Copy to site dir for GitHub Pages
cp "$OUTFILE" "$SITE_OUTFILE"
echo "Copied $OUTFILE -> $SITE_OUTFILE"

# Warn if low, but do NOT fail the job
MIN_ROWS=${MIN_ROWS:-10}
if (( rows_total < MIN_ROWS )); then
  echo "Warning: Only ${rows_total} rows (< ${MIN_ROWS}). Continuing so downstream steps can run."
fi

exit 0
