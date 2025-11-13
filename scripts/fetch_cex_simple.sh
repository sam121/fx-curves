#!/usr/bin/env bash
# scripts/fetch_cex_simple.sh
# USD -> USDC -> GBP on Kraken using public depth + your real taker fees.
# Outputs book-only bps vs composed mid, and final bps including actual taker fees.

set -euo pipefail

KRAKEN_BASE="${KRAKEN_BASE:-https://api.kraken.com}"
REQ_DELAY_MS="${CEX_REQ_DELAY_MS:-200}"
sleep_secs=$(awk -v ms="$REQ_DELAY_MS" 'BEGIN{printf "%.3f", ms/1000.0}')

# Small ladder (override with USD_ANCHORS env)
USD_ANCHORS_CSV="${USD_ANCHORS:-1000,10000,100000,1000000}"
IFS=',' read -r -a AMOUNTS_USD <<< "$USD_ANCHORS_CSV"

OUTDIR="data"
OUTFILE="${OUTDIR}/cex_simple.json"
TMPFILE="$(mktemp)"
mkdir -p "$OUTDIR"
: > "$TMPFILE"

echo "Kraken base: $KRAKEN_BASE"
echo "USD ladder: $USD_ANCHORS_CSV"
echo "Assumptions: taker-like fills via VWAP; using YOUR actual taker fees from private API."

# ---------- auth helpers (required for fees) ----------
: "${KRAKEN_API_KEY?Set KRAKEN_API_KEY in your env}"
: "${KRAKEN_API_SECRET?Set KRAKEN_API_SECRET (base64) in your env}"

nonce_ms() { echo "$(($(date +%s)*1000))"; }  # portable ms nonce

b64dec() {
  # stdin -> decoded
  if base64 --help 2>&1 | grep -q -- '-d'; then base64 -d
  else base64 -D
  fi
}

kraken_get()  { curl -sS "$KRAKEN_BASE$1${2:+?$2}"; }
kraken_post() { curl -sS -H "API-Key: $KRAKEN_API_KEY" -H "API-Sign: $3" -d "$2" "$KRAKEN_BASE$1"; }

sign_private() {
  # args: path postdata
  local path="$1" postdata="$2" n; n="$(nonce_ms)"
  local msg="$n$postdata"
  local shasum; shasum=$(printf "%s" "$msg" | openssl dgst -binary -sha256)
  local binsec; binsec=$(printf "%s" "$KRAKEN_API_SECRET" | b64dec | od -An -tx1 | tr -d ' \n')
  # build (path + sha256) as binary
  local pre; pre=$( { printf "%s" "$path"; cat <<<"$shasum"; } | openssl dgst -binary -sha512 -mac HMAC -macopt "hexkey:$binsec" | base64 )
  echo "$n" "$pre"
}

json_must_be_object() {
  local payload="$1" hint="$2"
  echo "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || {
    echo "Error: non-JSON/object from Kraken ($hint). First 200 bytes:"
    echo "$payload" | head -c 200; echo
    exit 1
  }
}

# ---------- market discovery ----------
discover_pairs() {
  local json="$(kraken_get /0/public/AssetPairs)"
  json_must_be_object "$json" "AssetPairs"
  USDCUSD_PAIR=$(echo "$json" | jq -r '.result | to_entries | map(select(.value.wsname=="USDC/USD")) | (.[0].key // empty)')
  USDCGBP_PAIR=$(echo "$json" | jq -r '.result | to_entries | map(select(.value.wsname=="USDC/GBP")) | (.[0].key // empty)')
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

top_mid_from_depth() {
  local json="$1"
  echo "$json" | jq -r '
    .result | to_entries | .[0].value as $b
    | (( ($b.asks[0][0]|tonumber) + ($b.bids[0][0]|tonumber) ) / 2)
  '
}

# ---------- your actual taker fees ----------
get_taker_fees() {
  local path="/0/private/TradeVolume"
  local pairs="pair=${USDCUSD_PAIR},${USDCGBP_PAIR}&fee-info=true"
  local n sig; read -r n sig < <(sign_private "$path" "$pairs")
  local post="nonce=$n&$pairs"
  local resp; resp="$(kraken_post "$path" "$post" "$sig")"
  json_must_be_object "$resp" "TradeVolume"
  # percent -> bps (1% = 100 bps). Kraken returns strings like "0.26" (percent).
  TAKER_PCT_USDCUSD=$(echo "$resp" | jq -r --arg p "$USDCUSD_PAIR" '.result.fees[$p].fee // empty')
  TAKER_PCT_USDCGBP=$(echo "$resp" | jq -r --arg p "$USDCGBP_PAIR" '.result.fees[$p].fee // empty')
  if [[ -z "${TAKER_PCT_USDCUSD:-}" || -z "${TAKER_PCT_USDCGBP:-}" ]]; then
    echo "Error: TradeVolume did not return fee percents for required pairs."
    echo "$resp" | jq -r '.'
    exit 1
  fi
  TAKER_BPS_USD_USDC=$(awk -v p="$TAKER_PCT_USDCUSD" 'BEGIN{printf "%.10f", p*100}')
  TAKER_BPS_USDC_GBP=$(awk -v p="$TAKER_PCT_USDCGBP" 'BEGIN{printf "%.10f", p*100}')
}

# ---------- VWAP helpers ----------
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

ASKS_USDCUSD="$(mktemp)"
BIDS_USDCGBP="$(mktemp)"
book_to_csv "$DEPTH_USDCUSD" asks > "$ASKS_USDCUSD"
book_to_csv "$DEPTH_USDCGBP" bids > "$BIDS_USDCGBP"

MID_USDCUSD="$(top_mid_from_depth "$DEPTH_USDCUSD")"  # USD per USDC
MID_USDCGBP="$(top_mid_from_depth "$DEPTH_USDCGBP")"  # GBP per USDC
MID_PATH_USD_GBP=$(awk -v usd_per_usdc="$MID_USDCUSD" -v gbp_per_usdc="$MID_USDCGBP" \
  'BEGIN{printf "%.10f", gbp_per_usdc / usd_per_usdc}')

# fetch your actual taker fees
get_taker_fees
echo "Taker bps: USDC/USD=${TAKER_BPS_USD_USDC}, USDC/GBP=${TAKER_BPS_USDC_GBP}"

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for A_USD in "${AMOUNTS_USD[@]}"; do
  # Leg 1: USD -> USDC
  read USDC_recv USD_spent < <(vwap_buy_base_with_quote "$A_USD" "$ASKS_USDCUSD")
  # Leg 2: USDC -> GBP
  read GBP_recv  USDC_used < <(vwap_sell_base_for_quote "$USDC_recv" "$BIDS_USDCGBP")

  # Book-only bps vs composed mid
  MID_TARGET=$(awk -v a="$A_USD" -v m="$MID_PATH_USD_GBP" 'BEGIN{printf "%.10f", a*m}')
  BPS_BOOK=$(awk -v mid="$MID_TARGET" -v eff="$GBP_recv" \
    'BEGIN{if(mid>0) printf "%.10f", (1.0 - eff/mid)*10000; else print "null"}')

  # Apply actual taker fees multiplicatively to flow:
  # Kraken charges fees in the asset you receive.
  # Buy USDC with USD: fee reduces USDC. Sell USDC for GBP: fee reduces GBP.
  FEE1_PCT=$(awk -v bps="$TAKER_BPS_USD_USDC" 'BEGIN{printf "%.10f", bps/10000}')
  FEE2_PCT=$(awk -v bps="$TAKER_BPS_USDC_GBP" 'BEGIN{printf "%.10f", bps/10000}')
  GBP_final=$(awk -v g="$GBP_recv" -v f1="$FEE1_PCT" -v f2="$FEE2_PCT" \
    'BEGIN{printf "%.10f", g * (1.0 - f1) * (1.0 - f2)}')

  BPS_FINAL=$(awk -v mid="$MID_TARGET" -v eff="$GBP_final" \
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
    --argjson gbp_out_book "$GBP_recv" \
    --argjson bps_book "$BPS_BOOK" \
    --argjson taker_bps_usd_usdc "$TAKER_BPS_USD_USDC" \
    --argjson taker_bps_usdc_gbp "$TAKER_BPS_USDC_GBP" \
    --argjson gbp_out_final "$GBP_final" \
    --argjson bps_total_final "$BPS_FINAL" \
    --arg underfilled "$UNDERFILLED" \
    '{
      ts:$ts, rail:$rail, venue:$venue, path:$path,
      src:$src, tgt:$tgt, amount:$amount,
      mid_path:$mid_path,
      gbp_out_book:$gbp_out_book, bps_vs_mid_book:$bps_book,
      taker_bps_usd_usdc:$taker_bps_usd_usdc, taker_bps_usdc_gbp:$taker_bps_usdc_gbp,
      gbp_out_final:$gbp_out_final, bps_total_final:$bps_total_final,
      underfilled:($underfilled=="true"),
      status:"ok"
    }' >> "$TMPFILE"
done

jq -s '.' "$TMPFILE" > "$OUTFILE" 2>/dev/null || true
rm -f "$TMPFILE" "$ASKS_USDCUSD" "$BIDS_USDCGBP"

rows="$(jq 'length' "$OUTFILE" 2>/dev/null || echo 0)"
echo "Wrote ${OUTFILE} with ${rows} rows -> ${OUTFILE}"
exit 0
