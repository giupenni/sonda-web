#!/usr/bin/env bash
# Sonda sintetica "AdsBot-like" per sicilyactive.com
# Per ogni pagina bersaglio: scarica l'HTML, estrae gli asset (CSS/JS/font/immagini)
# e li richiede in raffica parallela (max 45 asset, 12 connessioni simultanee),
# replicando il profilo di carico di una verifica AdsBot (~50 req in pochi secondi).
# Due profili UA per distinguere comportamenti dipendenti dallo User-Agent.
# Esiti in results/log.csv; dettaglio per-richiesta solo quando ci sono fallimenti.

set -u

BASE="https://www.sicilyactive.com"

# ── Pagine bersaglio: modifica liberamente questa lista ──────────────────────
PAGES=(
  "/en/alcantara-gorges"
  "/en/excursions/godfather-tour-messina-port"
  "/en/alcantara-river-temperature-august-what-expect-and-why-avoid-peak-hours"
)

UA_CHROME="Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
UA_ADSBOT="Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.7871.114 Mobile Safari/537.36 (compatible; AdsBot-Google-Mobile; +http://www.google.com/mobile/adsbot.html)"

STAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p results
OUT="results/log.csv"
[ -f "$OUT" ] || echo "timestamp,profile,page,total,ok,http_fail,conn_fail,max_time_s" > "$OUT"

# Una singola richiesta: registra "curl_rc http_code time_total url"
fetch_one() {
  local url="$1"
  local line rc
  line=$(curl -s -o /dev/null -A "$PROBE_UA" \
         --connect-timeout 5 --max-time 15 \
         -w "%{http_code} %{time_total}" "$url" 2>/dev/null)
  rc=$?
  echo "$rc ${line:-000 0} $url" >> "$PROBE_RES"
}
export -f fetch_one

for profile in chrome adsbot; do
  if [ "$profile" = "chrome" ]; then UA="$UA_CHROME"; else UA="$UA_ADSBOT"; fi

  for page in "${PAGES[@]}"; do
    TMP=$(mktemp) ; RES=$(mktemp)
    export PROBE_UA="$UA" PROBE_RES="$RES"

    # 1) La pagina stessa
    html=$(curl -s -A "$UA" --connect-timeout 5 --max-time 20 \
           -w "\n@@%{http_code} %{time_total}" "$BASE$page" 2>/dev/null)
    prc=$?
    meta=$(printf '%s' "$html" | tail -n1 | sed 's/^@@//')
    body=$(printf '%s' "$html" | sed '$d')
    echo "$prc ${meta:-000 0} $BASE$page" >> "$RES"

    # 2) Asset same-host estratti dall'HTML (advagg css/js, immagini, font)
    printf '%s' "$body" \
      | grep -oE '(src|href)="[^"]+"' | cut -d'"' -f2 \
      | grep -E '\.(css|js|png|jpe?g|webp|svg|woff2?|ttf|ico)(\?[^"]*)?$' \
      | sed -E "s|^//|https://|; s|^/|$BASE/|" \
      | grep "^$BASE" | sort -u | head -45 > "$TMP"

    # 3) Raffica parallela (12 connessioni simultanee)
    if [ -s "$TMP" ]; then
      xargs -P 12 -I{} bash -c 'fetch_one "$1"' _ {} < "$TMP"
    fi

    # 4) Aggregazione
    total=$(wc -l < "$RES" | tr -d ' ')
    conn_fail=$(awk '$1 != 0' "$RES" | wc -l | tr -d ' ')
    http_fail=$(awk '$1 == 0 && $2 !~ /^(200|301|302|304)$/' "$RES" | wc -l | tr -d ' ')
    ok=$(( total - conn_fail - http_fail ))
    max_t=$(awk '{ if ($3+0 > m) m = $3+0 } END { printf "%.2f", m }' "$RES")

    echo "$STAMP,$profile,$page,$total,$ok,$http_fail,$conn_fail,$max_t" >> "$OUT"

    # 5) Dettaglio solo se qualcosa è andato storto
    if [ "$conn_fail" -gt 0 ] || [ "$http_fail" -gt 0 ]; then
      DFILE="results/detail-$(date -u +%Y%m%d).txt"
      {
        echo "== $STAMP $profile $page =="
        awk '$1 != 0 || $2 !~ /^(200|301|302|304)$/' "$RES"
      } >> "$DFILE"
    fi

    rm -f "$TMP" "$RES"
    sleep 2
  done
done

echo "Probe completata: $STAMP"
tail -n 6 "$OUT"
