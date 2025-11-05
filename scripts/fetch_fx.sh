#!/usr/bin/env bash
# scripts/fetch_fx.sh
# Fetch Wise FX quotes for (G20 + SGD) currencies in both directions and publish JSON.

set -o pipefail

# ---------- Config ----------
API_BASE="${WISE_API_BASE:-https://api.transferwise.com}"
: "${WISE_TOKEN?Need env WISE_TOKEN set (GitHub Secret WISE_TOKEN)}"

# G20 currencies (EU=EUR) + SGD
# Override with env: CURRENCIES="USD,GBP,..." if you want fewer.
CURRENCIES_CSV="${CURRENCIES:-AUD,ARS,BRL,CAD,CNY,EUR,INR,IDR,JPY,MXN,RUB,SAR,ZAR,KRW,TRY,GBP,USD,SGD}"
IFS=',' read -r -a CCYS <<< "$CURRENCIES_CSV"

# Amount grid (override with AMOUNTS env if you like)
AMOUNTS_CSV="${AMOUNTS:-10,100,1000,10000,100000,1000000}"
IFS=',' read -r -a AMOUNTS <<< "$AMOUNTS_CSV"

# Modes to quote (payIn is fixed at BALANCE for fair comparison)
MODES=("BALANCE" "BANK_TRANSFER")

# Gentle throttle to avoid rate limits (ms); override with REQ_DELAY_MS
REQ_DELAY_MS="${REQ_DELAY_MS:-120}"
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN {printf "%.3f", ms/1000.0}')

OUTDIR="data"
OUTFILE="${OUTDIR}/latest.json"
TMPFILE="$(mktemp)"

mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Using API base: ${API_BASE}"
echo "Currencies: ${CURRENCIES_CSV}"
echo "Amounts: ${AMOUNTS_CSV}"
echo "Modes: ${MODES[*]}"
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
echo "Total pairs: ${#PAIRS[@]}  (currencies=${#CCYS[@]})"

# ---------- Fetch ----------
ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for pair in "${PAIRS[@]}"; do
  IFS=: read -r SRC TGT <<< "$pair"

  for amt in "${AMOUNTS[@]}"; do
    for MODE in "${MODES[@]}"; do
      body=$(jq -n \
        --arg src "$SRC" \
        --arg tgt "$TGT" \
        --argjson amt "$amt" \
        --argjson profile "$PROFILE_ID" \
        --arg mode "$MODE" \
        '{profile: $profile, sourceCurrency: $src, targetCurrency: $tgt,
          sourceAmount: $amt, payOut: $mode, preferredPayIn: "BALANCE"}')

      resp="$(curl -sS -X POST "${API_BASE}/v3/quotes" "${CURL_AUTH[@]}" -d "$body" || true)"
      sleep "$sleep_secs"

      # If API error, record a stub row
      if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' >/dev/null 2>&1; then
        echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"${MODE}\",\"targetAmount\":null,\"fee_total\":null,\"status\":\"error\",\"mode\":\"${MODE}\",\"src\":\"${SRC}\",\"tgt\":\"${TGT}\",\"amount\":${amt},\"midTarget\":null,\"fee_bps\":null,\"fee_bps_vs_mid\":null,\"rounding_bps\":null,\"pair\":\"${SRC}->${TGT}\"}" >> "$TMPFILE"
        continue
      fi

      # Build numeric row; compute fee_bps from the fee (robust to rounding)
      row=$(echo "$resp" | jq -c \
        --arg ts "$ts_iso" --arg src "$SRC" --arg tgt "$TGT" --argjson amt "$amt" --arg mode "$MODE" '
          (try (.rate|tonumber) catch null) as $rate
          | (
              (.paymentOptions // [])
              | map(select(.payIn=="BALANCE" and .payOut==$mode))
              | (.[0] // {})
            ) as $opt
          | (try ($opt.targetAmount // $opt.target.amount | tonumber) catch null) as $tgtAmt
          | (try ($opt.fee.total | tonumber) catch null) as $feeTot

          # Mid outcome and an effective (unrounded) target based on fee
          | ( ($rate // 0) * $amt ) as $mid
          | ( ($amt - ($feeTot // 0)) * ($rate // 0) ) as $effTarget

          # Primary metric (use this for plotting)
          | ( if $amt > 0  then ($feeTot / $amt) * 10000 else null end ) as $bps_fee

          # Diagnostics (optional): fee vs mid recomputed; rounding impact bps
          | ( if $mid > 0  then (1 - ($effTarget / $mid)) * 10000 else null end ) as $bps_mid
          | ( if ($mid > 0 and $tgtAmt != null)
              then ( ($tgtAmt - $effTarget) / $mid ) * 10000
              else null
            end ) as $round_bps

          | {
              ts: $ts,
              sourceCurrency: $src,
              targetCurrency: $tgt,
              sourceAmount: $amt,
              rate: $rate,
              payIn:  ($opt.payIn  // "BALANCE"),
              payOut: ($opt.payOut // $mode),
              targetAmount: $tgtAmt,
              fee_total:    $feeTot,
              status: ( if ($rate != null and $feeTot != null) then "ok" else "incomplete" end ),

              # Website helpers / aliases
              mode: ($opt.payOut // $mode),
              src:  $src,
              tgt:  $tgt,
              amount: $amt,
              midTarget: $mid,

              fee_bps: $bps_fee,            # <-- plot this
              fee_bps_vs_mid: $bps_mid,     # diag
              rounding_bps: $round_bps,     # diag
              pair: ($src + "->" + $tgt),

              # convenience for tolerant front-ends
              x: $amt,
              y: $bps_fee
            }')

      echo "$row" >> "$TMPFILE"
    done
  done
done

# ---------- Write ----------
jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE"

if [[ ! -s "$OUTFILE" ]]; then
  echo "Error: ${OUTFILE} missing or empty"
  exit 1
fi

rows_total="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
rows_valid="$(jq '[.[] | select(.fee_bps != null)] | length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows_total} rows (${rows_valid} points)"
exit 0
