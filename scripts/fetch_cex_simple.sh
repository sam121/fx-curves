#!/usr/bin/env bash
# scripts/fetch_cex_simple.sh
# USD -> USDC -> GBP on Kraken via public REST.
# VWAP path vs composed mid (bps). No fiat on/off or exchange fee schedules.

set -euo pipefail

KRAKEN_BASE="${KRAKEN_BASE:-https://api.kraken.com}"
REQ_DELAY_MS="${CEX_REQ_DELAY_MS:-200}"
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN{printf "%.3f", ms/1000.0}')

# Small ladder for quick runs (override with USD_ANCHORS env)
USD_ANCHORS_CSV="${USD_ANCHORS:-1000,10000,100000,1000000}"
IFS=',' read -r -a AMOUNTS_USD <<< "$USD_ANCHORS_CSV"

OUTDIR="data"
OUTFILE="${OUTDIR}/cex_simple.json"
TMPFILE="$(mktemp)"
mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Kraken base: $KRAKEN_BASE"
echo "USD ladder: $USD_ANCHORS_CSV"
echo "Assumptions: taker-like fills via VWAP, NO explicit exchange/fiat fees."

kraken_get() { curl -sS "$KRAKEN_BASE$1${2:+?$2}"; }

json_must_be_object() {
  local payload="$1" hint="$2"
  echo "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "Error: non-JSON/object from Kraken ($hint). First 200 bytes:"
    echo "$payload" | head -c 200; echo
    exit 1
  }
}

discover_pairs() {
  local json="$(kraken_get /0/public/AssetPairs)"
  json_must_be_object "$json" "AssetPairs"
  # Prefer wsname to identify the right markets
  USDCUSD_PAIR=$(echo "$json" | jq -r '
    .result | to_entries | map(select(.value.wsname? == "USDC/USD")) | (.[0].key // empty)')
  USDCGBP_PAIR=$(echo "$json" | jq -r '
    .result | to_entries | map(select(.value.wsname? == "USDC/GBP")) | (.[0].key // empty)')
  if [[ -z "${USDCUSD_PAIR:-}" || -z "${USDCGBP_PAIR:-}" ]]; then
    echo "Error: Could not find USDC/USD or USDC/GBP on Kraken."
    exit 1
  fi
}

fetch_depth() {
  local pair="$1" count="${2:-1000}"
  local j="$(kraken_get /0/public/Depth "pair=${pair}&count=${count}")"
  json_must_be_object "$j" "Depth $pair"
  echo "$j"
}

# Convert order book JSON to CSV "price,volume"
# Use the FIRST entry in .result (don’t depend on the exact key)
book_to_csv() {
  local json="$1" side="$2"
  if [[ "$side" == "asks" ]]; then
    echo "$json" | jq -r '
      .result | to_entries | .[0].value.asks[] | "\(.[0]),\(.[1])"
    ' | sort -t, -k1,1g
  else
    echo "$json" | jq -r '
      .result | to_entries | .[0].value.bids[] | "\(.[0]),\(.[1])"
    ' | sort -t, -k1,1gr
  fi
}

# Top-of-book mid (again don’t rely on the key name)
top_mid_from_depth() {
  local json="$1"
  echo "$json" | jq -r '
    .result | to_entries | .[0].value as $b
    | (( ($b.asks[0][0]|tonumber) + ($b.bids[0][0]|tonumber) ) / 2)
  '
}

# VWAP helpers
vwap_buy_base_with_quote() {
  local budget_quote="$1" asks_csv="$2"
  awk -F',' -v B="$budget_quote" '
    BEGIN{base=0; spent=0}
    {p=$1+0; q=$2+0; if (spent>=B) next;
     cost=p*q; rem=B-spent;
     if (cost<=rem) {base+=q; spent+=cost}
     else {part=rem/p; base+=part; spent+=rem}
    }
    END{printf "%.10f %.10f\n", base, spent}' "$asks_csv"
}

vwap_sell_base_for_quote() {
  local base_amt="$1" bids_csv="$2"
  awk -F',' -v BA="$base_amt" '
    BEGIN{recv=0; used=0}
    {p=$1+0; q=$2+0; if (used>=BA) next;
     rem=BA-used; take=(q<rem?q:rem);
     recv+=take*p; used+=take
    }
    END{printf "%.10f %.10f\n", recv, used}' "$bids_csv"
}

# ---------- Go ----------
discover_pairs
sleep "$sleep_secs"

DEPTH_USDCUSD="$(fetch_depth "$USDCUSD_PAIR" 1000)"
sleep "$sleep_secs"
DEPTH_USDCGBP="$(fetch_depth "$USDCGBP_PAIR" 1000)"

# quick sanity: have at least 1 level each
for which in "USDCUSD asks" "USDCUSD bids" "USDCGBP asks" "USDCGBP bids"; do
  pair=${which%% *}; side=${which##* }
  j="${pair/USDCUSD/$DEPTH_USDCUSD}"; j="${j/USDCGBP/$DEPTH_USDCGBP}" # not used, just to remind mapping
done

ASKS_USDCUSD="$(mktemp)"
BIDS_USDCGBP="$(mktemp)"
book_to_csv "$DEPTH_USDCUSD" asks > "$ASKS_USDCUSD"
book_to_csv "$DEPTH_USDCGBP" bids > "$BIDS_USDCGBP"

# Mids from top-of-book (no ticker key brittleness)
MID_USDCUSD="$(top_mid_from_depth "$DEPTH_USDCUSD")"  # USD per USDC
MID_USDCGBP="$(top_mid_from_depth "$DEPTH_USDCGBP")"  # GBP per USDC

# Composed mid (GBP per USD): (GBP/USDC) / (USD/USDC)
MID_PATH_USD_GBP=$(awk -v usd_per_usdc="$MID_USDCUSD" -v gbp_per_usdc="$MID_USDCGBP" \
  'BEGIN{printf "%.10f", gbp_per_usdc / usd_per_usdc}')

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for A_USD in "${AMOUNTS_USD[@]}"; do
  # Leg 1: USD -> USDC (buy base with USD on asks)
  read USDC_recv USD_spent < <(vwap_buy_base_with_quote "$A_USD" "$ASKS_USDCUSD")

  # Leg 2: USDC -> GBP (sell base for GBP on bids)
  read GBP_recv USDC_used < <(vwap_sell_base_for_quote "$USDC_recv" "$BIDS_USDCGBP")

  MID_TARGET=$(awk -v a="$A_USD" -v m="$MID_PATH_USD_GBP" 'BEGIN{printf "%.10f", a*m}')

  BPS_TOTAL=$(awk -v mid="$MID_TARGET" -v eff="$GBP_recv" \
    'BEGIN{if(mid>0) printf "%.10f", (1.0 - eff/mid)*10000; else print "null"}')

  UNDERFILLED=$(awk -v a="$A_USD" -v s="$USD_spent" 'BEGIN{print (s+1e-9<a)?"true":"false"}')

  jq -n \
    --arg ts "$ts_iso" \
    --arg rail "cex_simple" \
    --arg venue "kraken" \
    --arg path "USD->USDC->GBP" \
    --arg src "USD" --arg tgt "GBP" \
    --argjson amount "$A_USD" \
    --argjson mid_path "$MID_PATH_USD_GBP" \
    --argjson gbp_out "$GBP_recv" \
    --argjson bps_vs_mid "$BPS_TOTAL" \
    --arg underfilled "$UNDERFILLED" \
    --argjson taker_fee_bps_applied 0 \
    '{
      ts:$ts, rail:$rail, venue:$venue, path:$path,
      src:$src, tgt:$tgt, amount:$amount,
      mid_path:$mid_path, gbp_out:$gbp_out,
      bps_vs_mid:$bps_vs_mid,
      underfilled:($underfilled=="true"),
      taker_fee_bps_applied:$taker_fee_bps_applied,
      status:"ok"
    }' >> "$TMPFILE"
done

jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE" "$ASKS_USDCUSD" "$BIDS_USDCGBP"

rows="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows} rows -> ${OUTFILE}"
exit 0
