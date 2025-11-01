#!/usr/bin/env bash
set -euo pipefail

: "${WISE_TOKEN:?WISE_TOKEN not set}"
PROFILE_ID="${PROFILE_ID:-14878042}"
API="https://api.transferwise.com/v3/quotes"

AMOUNTS=(10 100 1000 10000 100000 1000000)
PAIRS=("USD:SGD" "USD:GBP" "GBP:USD" "EUR:USD" "USD:JPY" "SGD:GBP" "EUR:SGD")

tmp="$(mktemp)"
echo "[" > "$tmp"
first=1
now_ts="$(date -u +%s)"

for pair in "${PAIRS[@]}"; do
  IFS=":" read -r SRC TGT <<< "$pair"
  for amt in "${AMOUNTS[@]}"; do
    for MODE in BALANCE BANK_TRANSFER; do
      payload=$(jq -nc --argjson profile "$PROFILE_ID" --arg src "$SRC" --arg tgt "$TGT" --argjson a "$amt" --arg payOut "$MODE" \
        '{profile:$profile, sourceCurrency:$src, targetCurrency:$tgt, sourceAmount:$a, payOut:$payOut}')

      resp=$(curl -sS -X POST "$API" \
        -H "Authorization: Bearer $WISE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")

      rate=$(echo "$resp" | jq -r '.rate // empty')
      fee=$(echo "$resp" | jq -r --arg m "$MODE" '(.paymentOptions[]? | select(.payIn=="BALANCE" and .payOut==$m) | .fee.total) // empty')
      recv=$(echo "$resp" | jq -r --arg m "$MODE" '(.paymentOptions[]? | select(.payIn=="BALANCE" and .payOut==$m) | .targetAmount) // empty')

      [[ -z "${rate:-}" || -z "${fee:-}" || -z "${recv:-}" ]] && continue

      mid_recv=$(awk -v a="$amt" -v r="$rate" 'BEGIN{printf "%.6f", a*r}')
      bps=$(awk -v m="$mid_recv" -v t="$recv" 'BEGIN{ if(m>0){printf "%.2f", (1 - t/m)*10000}else{print "NaN"} }')

      row=$(jq -nc --arg ts "$now_ts" --arg src "$SRC" --arg tgt "$TGT" --arg mode "$MODE" \
                  --argjson amount "$amt" --argjson rate "$rate" \
                  --argjson fee "$fee" --argjson recv "$recv" \
                  --argjson mid "$mid_recv" --arg bps "$bps" '
        {
          ts: ($ts|tonumber),
          src: $src, tgt: $tgt, mode: $mode,
          amount: $amount,
          rate: $rate,
          fee_source: $fee,
          recv_target: $recv,
          mid_target: $mid,
          fee_bps_vs_mid: ($bps|tonumber?)
        }')

      if [[ $first -eq 1 ]]; then first=0; else echo "," >> "$tmp"; fi
      echo "$row" >> "$tmp"
    done
  done
done
echo "]" >> "$tmp"

mkdir -p data
mv "$tmp" data/latest.json

day=$(date -u +%F)
mkdir -p data/history
jq -c '.[]' data/latest.json >> "data/history/$day.jsonl"

echo "Wrote data/latest.json and data/history/$day.jsonl"
