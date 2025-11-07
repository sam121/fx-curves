#!/usr/bin/env bash
# scripts/fetch_fx.sh
# Fetch Wise FX quotes (G20 + SGD) both directions. Amounts are built
# from USD anchors ($10 … $10M) converted & nicely rounded in each source.
# Fee bps is computed from fee_total / sourceAmount * 10,000 (rounding-proof).

set -o pipefail

API_BASE="${WISE_API_BASE:-https://api.transferwise.com}"
: "${WISE_TOKEN?Need env WISE_TOKEN set (GitHub Secret WISE_TOKEN)}"

# G20 + SGD (override with: CURRENCIES="USD,GBP,...")
CURRENCIES_CSV="${CURRENCIES:-AUD,ARS,BRL,CAD,CNY,EUR,INR,IDR,JPY,MXN,RUB,SAR,ZAR,KRW,TRY,GBP,USD,SGD}"
IFS=',' read -r -a CCYS <<< "$CURRENCIES_CSV"

# USD anchor ladder -> denser 10k–100k + 10M
USD_ANCHORS_CSV="${USD_ANCHORS:-10,100,1000,5000,10000,15000,20000,30000,40000,50000,60000,80000,100000,200000,300000,500000,1000000,2000000,5000000,10000000}"
IFS=',' read -r -a USD_ANCHORS <<< "$USD_ANCHORS_CSV"

MODES=("BALANCE" "BANK_TRANSFER")   # payIn fixed to BALANCE for fair comparison
MAX_USD_NOTIONAL="${MAX_USD_NOTIONAL:-10000000}"  # skip if source*mid(USD) > cap
REQ_DELAY_MS="${REQ_DELAY_MS:-120}"               # gentle throttle
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN {printf "%.3f", ms/1000.0}')

OUTDIR="data"; OUTFILE="${OUTDIR}/latest.json"; TMPFILE="$(mktemp)"
mkdir -p "$OUTDIR"; : > "$TMPFILE"

echo "Using API base: ${API_BASE}"
echo "Currencies: ${CURRENCIES_CSV}"
echo "USD anchors: ${USD_ANCHORS_CSV}"
echo "Modes: ${MODES[*]}"
echo "Throttle: ${REQ_DELAY_MS} ms"
echo "USD notional cap: ${MAX_USD_NOTIONAL}"

CURL_AUTH=(-H "Authorization: Bearer ${WISE_TOKEN}" -H "Content-Type: application/json")

get_profile_id() {
  curl -sS "${API_BASE}/v1/profiles" "${CURL_AUTH[@]}" \
  | jq -r 'if type=="array" and length>0 then .[0].id else empty end'
}
PROFILE_ID="$(get_profile_id)"
if [[ -z "$PROFILE_ID" || "$PROFILE_ID" == "null" ]]; then
  echo "Error: could not resolve Wise profile ID"; exit 1
fi

# 429-aware request wrapper
request_with_backoff() {
  local url="$1"; shift
  local tries=6 backoff=1
  while (( tries-- > 0 )); do
    local hdr="$(mktemp)" body="$(mktemp)" code
    code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$url" "$@")
    if [[ "$code" == "429" ]]; then
      local ra; ra=$(awk -F': *' 'tolower($1)=="retry-after"{print $2}' "$hdr" | tr -d '\r' | head -1)
      sleep "${ra:-$backoff}"; (( backoff = backoff*2 ))
    else
      cat "$body"; rm -f "$hdr" "$body"; return 0
    fi
    rm -f "$hdr" "$body"
  done
  return 1
}

# Helper to pick a "nice" rounding step for a positive number
nice_step() {
  awk -v v="$1" 'function ceil(x){return (x==int(x))?x:int(x)+1}
    BEGIN{
      if (v<100)      s=1;
      else if (v<1e3) s=10;
      else if (v<1e4) s=100;
      else if (v<1e5) s=1000;
      else if (v<1e6) s=10000;
      else if (v<1e7) s=100000;
      else            s=1000000;
      print s;
    }'
}

# Round up to the chosen step
round_up_to_step() {
  local val="$1" step="$2"
  awk -v v="$val" -v s="$step" 'function ceil(x){return (x==int(x))?x:int(x)+1}
    BEGIN{printf "%.0f", ceil(v/s)*s}'
}

# Prefetch SRC->USD mid rates (for ladder conversion and capping)
declare -A RATE_TO_USD
for SRC in "${CCYS[@]}"; do
  if [[ "$SRC" == "USD" ]]; then RATE_TO_USD["$SRC"]=1; continue; fi
  body=$(jq -n --argjson profile "$PROFILE_ID" --arg src "$SRC" --arg tgt "USD" --argjson amt 1000 \
          '{profile:$profile, sourceCurrency:$src, targetCurrency:$tgt, sourceAmount:$amt, payOut:"BALANCE"}')
  resp="$(request_with_backoff "${API_BASE}/v3/quotes" -X POST "${CURL_AUTH[@]}" -d "$body" || true)"
  RATE_TO_USD["$SRC"]="$(echo "$resp" | jq -r 'try (.rate|tonumber) catch empty')"
  sleep "$sleep_secs"
done

# Build ordered pairs A->B
declare -a PAIRS=()
for a in "${CCYS[@]}"; do
  for b in "${CCYS[@]}"; do
    [[ "$a" == "$b" ]] && continue
    PAIRS+=("$a:$b")
  done
done
echo "Total pairs: ${#PAIRS[@]}"

# Build per-source amount ladders from USD anchors
declare -A AMOUNTS_FOR_SRC
for SRC in "${CCYS[@]}"; do
  rate_usd="${RATE_TO_USD[$SRC]}"
  declare -a AMTS=()
  if [[ -n "$rate_usd" && "$rate_usd" != "0" ]]; then
    for usd in "${USD_ANCHORS[@]}"; do
      # src_amount ≈ USD / (SRC->USD rate)
      raw=$(awk -v u="$usd" -v r="$rate_usd" 'BEGIN{printf "%.6f", u/r}')
      step="$(nice_step "$raw")"
      amt="$(round_up_to_step "$raw" "$step")"
      AMTS+=("$amt")
    done
  else
    # Fallback to a generic ladder if we couldn't prefetch a rate
    AMTS=(10 100 1000 5000 10000 15000 20000 30000 40000 50000 60000 80000 100000 200000 300000 500000 1000000 2000000 5000000 10000000)
  fi
  # de-dupe + sort
  ladder="$(printf "%s\n" "${AMTS[@]}" | sort -n | uniq | tr '\n' ',' | sed 's/,$//')"
  AMOUNTS_FOR_SRC["$SRC"]="$ladder"
done

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for pair in "${PAIRS[@]}"; do
  IFS=: read -r SRC TGT <<< "$pair"
  rate_usd="${RATE_TO_USD[$SRC]}"

  IFS=',' read -r -a AMTS <<< "${AMOUNTS_FOR_SRC[$SRC]}"
  for amt in "${AMTS[@]}"; do
    # Skip if USD notional exceeds cap (when rate known)
    if [[ -n "$rate_usd" && "$rate_usd" != "0" ]]; then
      usd_notional=$(awk -v a="$amt" -v r="$rate_usd" 'BEGIN{printf "%.6f", a*r}')
      awk -v u="$usd_notional" -v cap="$MAX_USD_NOTIONAL" 'BEGIN{ if (u>cap) exit 1 }' || continue
    fi

    for MODE in "${MODES[@]}"; do
      body=$(jq -n --argjson profile "$PROFILE_ID" --arg src "$SRC" --arg tgt "$TGT" \
                 --argjson amt "$amt" --arg mode "$MODE" \
                 '{profile:$profile, sourceCurrency:$src, targetCurrency:$tgt,
                   sourceAmount:$amt, payOut:$mode, preferredPayIn:"BALANCE"}')

      resp="$(request_with_backoff "${API_BASE}/v3/quotes" -X POST "${CURL_AUTH[@]}" -d "$body" || true)"
      sleep "$sleep_secs"

      if [[ -z "$resp" ]] || echo "$resp" | jq -e '.errors? // empty' >/dev/null 2>&1; then
        echo "{\"ts\":\"${ts_iso}\",\"sourceCurrency\":\"${SRC}\",\"targetCurrency\":\"${TGT}\",\"sourceAmount\":${amt},\"rate\":null,\"payIn\":\"BALANCE\",\"payOut\":\"${MODE}\",\"targetAmount\":null,\"fee_total\":null,\"status\":\"error\",\"mode\":\"${MODE}\",\"src\":\"${SRC}\",\"tgt\":\"${TGT}\",\"amount\":${amt},\"midTarget\":null,\"fee_bps\":null,\"pair\":\"${SRC}->${TGT}\"}" >> "$TMPFILE"
        continue
      fi

      row=$(echo "$resp" | jq -c --arg ts "$ts_iso" --arg src "$SRC" --arg tgt "$TGT" \
                          --argjson amt "$amt" --arg mode "$MODE" '
        (try (.rate|tonumber) catch null) as $rate
        | ((.paymentOptions // [])
           | map(select(.payIn=="BALANCE" and .payOut==$mode))
           | (.[0] // {})) as $opt
        | (try ($opt.targetAmount // $opt.target.amount | tonumber) catch null) as $tgtAmt
        | (try ($opt.fee.total | tonumber) catch null) as $feeTot
        | (($rate // 0) * $amt) as $mid
        | (($amt - ($feeTot // 0)) * ($rate // 0)) as $effTarget
        | (if $amt>0 then ($feeTot / $amt) * 10000 else null end) as $bps_fee
        | (if $mid>0 then (1 - ($effTarget/$mid)) * 10000 else null end) as $bps_mid
        | (if ($mid>0 and $tgtAmt!=null) then (($tgtAmt - $effTarget)/$mid)*10000 else null end) as $round_bps
        | {
            ts:$ts, sourceCurrency:$src, targetCurrency:$tgt, sourceAmount:$amt,
            rate:$rate, payIn:($opt.payIn//"BALANCE"), payOut:($opt.payOut//$mode),
            targetAmount:$tgtAmt, fee_total:$feeTot,
            status:( if ($rate!=null and $feeTot!=null) then "ok" else "incomplete" end ),

            mode:($opt.payOut//$mode), src:$src, tgt:$tgt, amount:$amt, midTarget:$mid,
            fee_bps:$bps_fee, fee_bps_vs_mid:$bps_mid, rounding_bps:$round_bps,
            pair: ($src + "->" + $tgt), x:$amt, y:$bps_fee
          }')
      echo "$row" >> "$TMPFILE"
    done
  done
done

jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE"

[[ ! -s "$OUTFILE" ]] && { echo "Error: ${OUTFILE} missing or empty"; exit 1; }

rows_total="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
rows_valid="$(jq '[.[] | select(.fee_bps != null)] | length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows_total} rows (${rows_valid} points)"
exit 0
