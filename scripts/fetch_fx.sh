#!/usr/bin/env bash
set -euo pipefail

: "${WISE_TOKEN:?WISE_TOKEN not set}"
API="https://api.transferwise.com/v3/quotes"

# small set for debug
AMOUNTS=(10 100 1000)
PAIRS=("USD:EUR" "USD:GBP" "USD:SGD" "GBP:USD")

tmp="$(mktemp)"; echo "[" > "$tmp"; first=1
now_ts="$(date -u +%s)"; rows=0

for pair in "${PAIRS[@]}"; do
  IFS=":" read -r SRC TGT <<< "$pair"
  for amt in "${AMOUNTS[@]}"; do
    for MODE in BALANCE BANK_TRANSFER; do
      # NOTE: no 'profile' field; let Wise default to the token’s default profile
      payload=$(jq -nc --arg src "$SRC" --arg tgt "$TGT" --argjson a "$amt" --arg payOut "$MODE" \
        '{sourceCurrency:$src, targetCurrency:$tgt, sourceAmount:$a, payOut:$payOut}')

      # don’t use -f; always capture body + status code
      CODE=$(curl -sS -o /tmp/resp.json -w '%{http_code}' -X POST "$API" \
        -H "Authorization: Bearer $WISE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload") || true

      if [[ "$CODE" != 2* ]]; then
        echo "HTTP $CODE for $SRC->$TGT $MODE $amt; first 200 chars of body:" >&2
        head -c 200 /tmp/resp.json 2>/dev/null || true
        echo >&2
        continue
      fi

      resp=$(cat /tmp/resp.json)
      rate=$(echo "$resp" | jq -r '.rate // empty')

      # Fallbacks: BALANCE+MODE → any BALANCE → any option (cheapest)
      opt=$(echo "$resp" | jq -c --arg m "$MODE" '
        ( [ .paymentOptions[]? | select(.payIn=="BALANCE" and .payOut==$m) ] | (length>0 and (min_by(.fee.total))) ) //
        ( [ .paymentOptions[]? | select(.payIn=="BALANCE") ] | (length>0 and (min_by(.fee.total))) ) //
        ( [ .paymentOptions[]? ] | (length>0 and (min_by(.fee.total))) ) // empty
      ')

      [[ -z "${rate:-}" || -z "${opt:-}" ]] && continue

      fee=$(echo "$opt"  | jq -r '.fee.total // empty')
      recv=$(echo "$opt" | jq -r '.targetAmount // empty')
      [[ -z "${fee:-}" || -z "${recv:-}" ]] && continue

      mid_recv=$(awk -v a="$amt" -v r="$rate" 'BEGIN{printf "%.6f", a*r}')
      bps=$(awk -v m="$mid_recv" -v t="$recv" 'BEGIN{ if(m>0){printf "%.2f", (1 - t/m)*10000}else{print "NaN"} }')

      row=$(jq -nc --arg ts "$now_ts" --arg src "$SRC" --arg tgt "$TGT" --arg mode "$MODE" \
                  --argjson amount "$amt" --argjson rate "$rate" \
                  --argjson fee "$fee" --argjson recv "$recv" \
                  --argjson mid "$mid_recv" --arg bps "$bps" '
        { ts: ($ts|tonumber), src:$src, tgt:$tgt, mode:$mode,
          amount:$amount, rate:$rate, fee_source:$fee,
          recv_target:$recv, mid_target:$mid, fee_bps_vs_mid: ($bps|tonumber?) }')

      [[ $first -eq 1 ]] && first=0 || echo "," >> "$tmp"
      echo "$row" >> "$tmp"
      rows=$((rows+1))
    done
  done
done

echo "]" >> "$tmp"
mkdir -p data
mv "$tmp" data/latest.json

day=$(date -u +%F)
mkdir -p data/history
jq -c '.[]' data/latest.json >> "data/history/$day.jsonl"

echo "Wrote data/latest.json with $rows rows"
[[ $rows -eq 0 ]] && { echo "No rows produced" >&2; exit 2; }
