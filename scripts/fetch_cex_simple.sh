#!/usr/bin/env bash
# scripts/fetch_cex_simple.sh
# v1 — Simplest USD -> USDC -> GBP path on Kraken using public REST.
# Computes effective cost (bps) as VWAP path vs path mid. No fiat fees, no taker schedule applied.

set -euo pipefail

KRAKEN_BASE="${KRAKEN_BASE:-https://api.kraken.com}"
REQ_DELAY_MS="${CEX_REQ_DELAY_MS:-200}"
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN{printf "%.3f", ms/1000.0}')

# Amount ladder (USD source) — small set for v1
USD_ANCHORS_CSV="${USD_ANCHORS:-1000,10000,100000,1000000}"
IFS=',' read -r -a AMOUNTS_USD <<< "$USD_ANCHORS_CSV"

OUTDIR="data"
OUTFILE="${OUTDIR}/cex_simple.json"
TMPFILE="$(mktemp)"
mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Kraken base: $KRAKEN_BASE"
echo "USD ladder: $USD_ANCHORS_CSV (v1)"
echo "Assumptions: taker-like fills via VWAP, NO explicit exchange/fiat fees."

# ---- Helpers ---------------------------------------------------------------

kraken_get() { curl -sS "$KRAKEN_BASE$1${2:+?$2}"; }

discover_pairs() {
  local json="$(kraken_get /0/public/AssetPairs)"
  USDCUSD_PAIR=$(echo "$json" | jq -r '
    .result | to_entries
    | map(select(.value.wsname? == "USDC/USD")) | (.[0].key // empty)')
  USDCGBP_PAIR=$(echo "$json" | jq -r '
    .result | to_entries
    | map(select(.value.wsname? == "USDC/GBP")) | (.[0].key // empty)')
  if [[ -z "${USDCUSD_PAIR:-}" || -z "${USDCGBP_PAIR:-}" ]]; then
    echo "Error: Could not find USDC/USD or USDC/GBP on Kraken."
    exit 1
  fi

  local tick
  tick="$(kraken_get /0/public/Ticker "pair=${USDCUSD_PAIR},${USDCGBP_PAIR}")"
  MID_USDCUSD=$(echo "$tick" | jq -r --arg p "$USDCUSD_PAIR" \
    '.result[$p] | ((.a[0]|tonumber + .b[0]|tonumber)/2)')
  MID_USDCGBP=$(echo "$tick" | jq -r --arg p "$USDCGBP_PAIR" \
    '.result[$p] | ((.a[0]|tonumber + .b[0]|tonumber)/2)')

  if [[ -z "${MID_USDCUSD:-}" || -z "${MID_USDCGBP:-}" ]]; then
    echo "Error: Could not compute mids from Ticker."
    exit 1
  fi
}

fetch_depth() {
  local pair="$1" count="${2:-1000}"
  kraken_get /0/public/Depth "pair=${pair}&count=${count}"
}

# CSV helpers (price,volume). We sort to be extra safe:
# - asks ascending by price
# - bids descending by price
book_to_csv() {
  local json="$1" side="$2" pair="$3"
  if [[ "$side" == "asks" ]]; then
    echo "$json" \
      | jq -r --arg p "$pair" '.result[$p].asks[] | "\(.0),\(.1)"' \
      | sort -t, -k1,1g
  else
    echo "$json" \
      | jq -r --arg p "$pair" '.result[$p].bids[] | "\(.0),\(.1)"' \
      | sort -t, -k1,1gr
  fi
}

# VWAP: buy base with quote (walk asks)
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

# VWAP: sell base for quote (walk bids)
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

# ---- Go --------------------------------------------------------------------

discover_pairs
sleep "$sleep_secs"

DEPTH_USDCUSD="$(fetch_depth "$USDCUSD_PAIR" 1000)"
sleep "$sleep_secs"
DEPTH_USDCGBP="$(fetch_depth "$USDCGBP_PAIR" 1000)"

# Guard: ensure we have at least 1 level each
if [[ "$(echo "$DEPTH_USDCUSD" | jq -r --arg p "$USDCUSD_PAIR" '.result[$p].asks|length')" == "0" ]]; then
  echo "Error: empty asks on USDC/USD"; exit 1
fi
if [[ "$(echo "$DEPTH_USDCGBP" | jq -r --arg p "$USDCGBP_PAIR" '.result[$p].bids|length')" == "0" ]]; then
  echo "Error: empty bids on USDC/GBP"; exit 1
fi

ASKS_USDCUSD="$(mktemp)"   # for USD -> USDC (buy base with USD)
BIDS_USDCGBP="$(mktemp)"   # for USDC -> GBP (sell base for GBP)
book_to_csv "$DEPTH_USDCUSD" asks "$USDCUSD_PAIR" > "$ASKS_USDCUSD"
book_to_csv "$DEPTH_USDCGBP" bids "$USDCGBP_PAIR" > "$BIDS_USDCGBP"

# ❗ Correct path mid: (GBP per USDC) / (USD per USDC) = GBP per USD
MID_PATH_USD_GBP=$(awk -v usd_per_usdc="$MID_USDCUSD" -v gbp_per_usdc="$MID_USDCGBP" \
  'BEGIN{printf "%.10f", gbp_per_usdc / usd_per_usdc}')

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for A_USD in "${AMOUNTS_USD[@]}"; do
  # Leg 1: USD -> USDC (asks)
  read USDC_recv USD_spent < <(vwap_buy_base_with_quote "$A_USD" "$ASKS_USDCUSD")

  # Leg 2: USDC -> GBP (bids)
  read GBP_recv USDC_used < <(vwap_sell_base_for_quote "$USDC_recv" "$BIDS_USDCGBP")

  # Benchmark mid target
  MID_TARGET=$(awk -v a="$A_USD" -v m="$MID_PATH_USD_GBP" 'BEGIN{printf "%.10f", a*m}')

  # Effective bps vs mid (our "fee")
  BPS_TOTAL=$(awk -v mid="$MID_TARGET" -v eff="$GBP_recv" \
    'BEGIN{if(mid>0) printf "%.10f", (1.0 - eff/mid)*10000; else print "null"}')

  # Underfill flag (book too shallow)
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
