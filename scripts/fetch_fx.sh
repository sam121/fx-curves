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

# Where the workflow expects the file:
OUTDIR="data"
OUTFILE="${OUTDIR}/latest.json"

# Where the website (GitHub Pages) reads from:
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

    # If the API returns nothing or an error structure, record an error row.
    if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' >/dev/null 2>&1; then
      echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"BALANCE\",\"targetAmount\":null,\"fee_total\":null,\"mode\":\"BALANCE\",\"src\":\"${SRC}\",\"tgt\":\"${TGT}\",\"amount\":${amt},\"midTarget\":null,\"fee_bps\":null,\"status\":\"error\"}" >> "$TMPFILE"
      continue
    fi

    # Extract BALANCE→BALANCE option if present and materialize fields the site expects
    row=$(echo "$resp" | jq -c --arg ts "$ts_iso" --arg src "$SRC" --arg tgt "$TGT" --argjson amt "$amt" '
      {
        ts: $ts,
        sourceCurrency: $src,
        targetCurrency: $tgt,
        sourceAmount: $amt,
        rate: (.rate // null),
        pick: (
          (.paymentOptions // [])
          | map(select(.payIn=="BALANCE" and .payOut=="BALANCE"))
          | (.[0] // {})
          | { payIn, payOut,
              targetAmount: (.targetAmount // .target.amount // null),
              fee_total: (.fee.total // null)
            }
        )
      }
      | {
          ts,
          sourceCurrency, targetCurrency, sourceAmount, rate,
          payIn:  ( .pick.payIn  // "BALANCE"),
          payOut: ( .pick.payOut // "BALANCE"),
          targetAmount: ( .pick.targetAmount // null),
          fee_total:    ( .pick.fee_total    // null),
          # extra fields for the website
          mode: ( .pick.payOut // "BALANCE"),
          src:  $src,
          tgt:  $tgt,
          amount: $amt,
          midTarget: ( ( (.rate // 0) * ($amt // 0) ) ),
          fee_bps: (
            if ((.rate // 0) * ($amt // 0)) > 0 and (.targetAmount // 0) > 0
            then (1 - (.targetAmount / ((.rate) * ($amt)))) * 10000
            else null end
          ),
          status: "ok"
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

rows="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows} rows"

# Copy to the site folder so GitHub Pages can serve it
cp "$OUTFILE" "$SITE_OUTFILE"
echo "Copied $OUTFILE -> $SITE_OUTFILE"

# Warn if low, but do NOT fail the job
MIN_ROWS=${MIN_ROWS:-10}
if (( rows < MIN_ROWS )); then
  echo "Warning: Only ${rows} rows (< ${MIN_ROWS}). Continuing so downstream steps can run."
fi

exit 0
