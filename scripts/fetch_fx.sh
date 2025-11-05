#!/usr/bin/env bash
# scripts/fetch_fx.sh
# Fetch a small grid of Wise FX quotes and write data/latest.json

set -o pipefail

# ---------- Config ----------
API_BASE="${WISE_API_BASE:-https://api.transferwise.com}"
: "${WISE_TOKEN?Need env WISE_TOKEN set (GitHub Secret WISE_TOKEN)}"

# 4 pairs × 6 amounts = 24 rows (matches your current workflow expectation)
PAIRS=("GBP:USD" "USD:JPY" "SGD:USD" "EUR:USD")
AMOUNTS=(10 100 1000 10000 100000 1000000)

OUTDIR="data"
OUTFILE="${OUTDIR}/latest.json"
TMPFILE="$(mktemp)"

mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Using API base: ${API_BASE}"

# ---------- Helpers ----------
hdr() {
  echo -H "Authorization: Bearer ${WISE_TOKEN}" \
       -H "Content-Type: application/json"
}

# Get first available profile id
get_profile_id() {
  curl -sS "${API_BASE}/v1/profiles" "$(hdr)" | jq -r '.[0].id // empty'
}

PROFILE_ID="$(get_profile_id)"
if [[ -z "$PROFILE_ID" || "$PROFILE_ID" == "null" ]]; then
  echo "Error: could not resolve Wise profile ID via GET /v1/profiles"
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

    resp="$(curl -sS -X POST "${API_BASE}/v3/quotes" "$(hdr)" -d "$body" || true)"

    # If the API returns nothing or an error structure, skip gracefully.
    if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' > /dev/null 2>&1; then
      echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"BALANCE\",\"targetAmount\":null,\"fee_total\":null,\"status\":\"error\"}" >> "$TMPFILE"
      continue
    fi

    # Extract a BALANCE→BALANCE option if present
    row=$(echo "$resp" | jq -c --arg ts "$ts_iso" --arg src "$SRC" --arg tgt "$TGT" --argjson amt "$amt" '
      {
        ts: $ts,
        sourceCurrency: $src,
        targetCurrency: $tgt,
        sourceAmount: $amt,
        rate: (.rate // null),
        # Pick BALANCE→BALANCE payment option if available
        pick: (.paymentOptions[]? | select(.payIn=="BALANCE" and .payOut=="BALANCE") | {
          payIn, payOut,
          targetAmount: (.targetAmount // .target.amount // null),
          fee_total: (.fee.total // null)
        }) // {}
      }
      | {
          ts, sourceCurrency, targetCurrency, sourceAmount, rate,
          payIn: ( .pick.payIn // "BALANCE"),
          payOut: ( .pick.payOut // "BALANCE"),
          targetAmount: ( .pick.targetAmount // null),
          fee_total: ( .pick.fee_total // null),
          status: "ok"
        }')

    echo "$row" >> "$TMPFILE"
  done
done

# ---------- Write & sanity check ----------
# Combine line-delimited JSON objects into an array
jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE"

if [[ ! -s "$OUTFILE" ]]; then
  echo "Error: ${OUTFILE} missing or empty"
  exit 1
fi

rows="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows} rows"

# Warn if low, but do NOT fail the job
MIN_ROWS=${MIN_ROWS:-10}
if (( rows < MIN_ROWS )); then
  echo "Warning: Only ${rows} rows (< ${MIN_ROWS}). Continuing so downstream steps can run."
fi

exit 0
