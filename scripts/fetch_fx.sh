#!/usr/bin/env bash
# scripts/fetch_fx.sh
# Fetch Wise FX quotes for G20 currencies (both directions) and publish JSON for the website.

set -o pipefail

# ---------- Config ----------
API_BASE="${WISE_API_BASE:-https://api.transferwise.com}"
: "${WISE_TOKEN?Need env WISE_TOKEN set (GitHub Secret WISE_TOKEN)}"

# G20 currency codes (EU is EUR). Override with CURRENCIES="USD,GBP,..." if you want fewer.
CURRENCIES_CSV="${CURRENCIES:-AUD,ARS,BRL,CAD,CNY,EUR,INR,IDR,JPY,MXN,RUB,SAR,ZAR,KRW,TRY,GBP,USD}"
IFS=',' read -r -a CCYS <<< "$CURRENCIES_CSV"

# Amount grid
AMOUNTS=(10 100 1000 10000 100000 1000000)

# Throttle between requests (ms). Increase if you hit API rate limits.
REQ_DELAY_MS="${REQ_DELAY_MS:-120}"

OUTDIR="data"
OUTFILE="${OUTDIR}/latest.json"
TMPFILE="$(mktemp)"

mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Using API base: ${API_BASE}"
echo "Currencies: ${CURRENCIES_CSV}"
echo "Amounts: ${AMOUNTS[*]}"
echo "Throttle: ${REQ_DELAY_MS} ms/request"

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

# Build all ordered pairs A->B (A!=B)
declare -a PAIRS=()
for a in "${CCYS[@]}"; do
  for b in "${CCYS[@]}"; do
    [[ "$a" == "$b" ]] && continue
    PAIRS+=("$a:$b")
  done
done
echo "Total pairs to try: ${#PAIRS[@]}  (currencies=${#CCYS[@]})"
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN {printf "%.3f", ms/1000.0}')

# ---------- Fetch ----------
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
total=0; ok_points=0

for pair in "${PAIRS[@]}"; do
  IFS=: read -r SRC TGT <<< "$pair"
  for amt in "${AMOUNTS[@]}"; do
    total=$((total+1))
    body=$(jq -n \
      --arg src "$SRC" \
      --arg tgt "$TGT" \
      --argjson amt "$amt" \
      --argjson profile "$PROFILE_ID" \
      '{profile: $profile, sourceCurrency: $src, targetCurrency: $tgt,
        sourceAmount: $amt, payOut: "BALANCE", preferredPayIn: "BALANCE"}')

    resp="$(curl -sS -X POST "${API_BASE}/v3/quotes" "${CURL_AUTH[@]}" -d "$body" || true)"

    # Optional gentle throttle
    sleep "$sleep_secs"

    if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' >/dev/null 2>&1; then
      echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"BALANCE\",\"targetAmount\":null,\"fee_total\":null,\"mode\":\"BALANCE\",\"src\":\"${SRC}\",\"tgt\":\"${TGT}\",\"amount\":${amt},\"midTarget\":null,\"fee_bps\":null,\"pair\":\"${SRC}->${TGT}\",\"status\":\"error\"}" >> "$TMPFILE"
      continue
    fi

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
        | ( ($rate // 0) * $amt ) as $mid
        | ( if (($rate // 0) > 0 and ($tgtAmt // 0) > 0)
            then (1 - ($tgtAmt / ($mid))) * 10000
            else null end
          ) as $bps
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
            status: ( if ($rate != null and $tgtAmt != null) then "ok" else "incomplete" end ),

            # website helpers
            mode: ($opt.payOut // "BALANCE"),
            src:  $src,
            tgt:  $tgt,
            amount: $amt,
            midTarget: $mid,
            fee_bps: $bps,
            pair: ($src + "->" + $tgt)
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
echo "Wrote ${OUTFILE} with ${rows_total} rows (${rows_valid} valid points) from ${#PAIRS[@]} pairs x ${#AMOUNTS[@]} amounts"

# Keep job green unless the file is empty.
exit 0
