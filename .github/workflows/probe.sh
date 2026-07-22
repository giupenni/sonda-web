#!/usr/bin/env bash
# Sonda sintetica "AdsBot-like" per sicilyactive.com — v2
# Novità v2: tempi per stadio (DNS / TCP / TLS / TTFB) e IP contattato su ogni
# richiesta, endpoint health a tre livelli (statico / PHP / Drupal).
# Il formato di results/log.csv resta IDENTICO alla v1: la serie continua.

set -u

BASE="https://www.sicilyactive.com"

# ── Bersagli: prima i due health (da creare sul server), poi le landing ──────
PAGES=(
  "/static-health.txt"
  "/php-health.php"
  "/en/alcantara-gorges"
  "/en/excursions/godfather-tour-messina-port"
  "/en/alcantara-river-temperature-august-what-expect-and-why-avoid-peak-hours"
)

UA_CHROME="Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
UA_ADSBOT="Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.7871.114 Mobile Safari/537.36 (compatible; AdsBot-Google-Mobile; +http://www.google.com/mobile/adsbot.html)"

# -w condiviso: rc lo aggiunge la shell; qui codice, tempi per stadio, ip
WFMT="%{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{remote_ip}"

STAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p results
OUT="results/log.csv"
[ -f "$OUT" ] || echo "timestamp,profile,page,total,ok,http_fail,conn_fail,max_time_s" > "$OUT"

# Riga per richiesta: "rc http_code t_tot t_dns t_tcp t_tls t_ttfb ip url"
fetch_one() {
  local url="$1"
  local line rc
  line=$(curl -s -o /dev/null -A "$PROBE_UA" \
         --connect-timeout 5 --max-time 15 \
         -w "$PROBE_WFMT" "$url" 2>/dev/null)
  rc=$?
  echo "$rc ${line:-000 0 0 0 0 0 -} $url" >> "$PROBE_RES"
}
export -f fetch_one

for profile in chrome adsbot; do
  if [ "$profile" = "chrome" ]; then UA="$UA_CHROME"; else UA="$UA_ADSBOT"; fi

  for page in "${PAGES[@]}"; do
    TMP=$(mktemp) ; RES=$(mktemp)
    export PROBE_UA="$UA" PROBE_RES="$RES" PROBE_WFMT="$WFMT"

    # 1) La pagina stessa (o l'endpoint health)
    html=$(curl -s -A "$UA" --connect-timeout 5 --max-time 20 \
           -w "\n@@$WFMT" "$BASE$page" 2>/dev/null)
    prc=$?
    meta=$(printf '%s' "$html" | tail -n1 | sed 's/^@@//')
    body=$(printf '%s' "$html" | sed '$d')
    echo "$prc ${meta:-000 0 0 0 0 0 -} $BASE$page" >> "$RES"

    # 2) Asset same-host estratti dall'HTML (per gli health non ce ne sono: ok)
    printf '%s' "$body" \
      | grep -oE '(src|href)="[^"]+"' | cut -d'"' -f2 \
      | grep -E '\.(css|js|png|jpe?g|webp|svg|woff2?|ttf|ico)(\?[^"]*)?$' \
      | sed -E "s|^//|https://|; s|^/|$BASE/|" \
      | grep "^$BASE" | sort -u | head -45 > "$TMP"

    # 3) Raffica parallela (12 connessioni simultanee)
    if [ -s "$TMP" ]; then
      xargs -P 12 -I{} bash -c 'fetch_one "$1"' _ {} < "$TMP"
    fi

    # 4) Aggregazione (stesse colonne della v1)
    total=$(wc -l < "$RES" | tr -d ' ')
    conn_fail=$(awk '$1 != 0' "$RES" | wc -l | tr -d ' ')
    http_fail=$(awk '$1 == 0 && $2 !~ /^(200|301|302|304)$/' "$RES" | wc -l | tr -d ' ')
    ok=$(( total - conn_fail - http_fail ))
    max_t=$(awk '{ if ($3+0 > m) m = $3+0 } END { printf "%.2f", m }' "$RES")

    echo "$STAMP,$profile,$page,$total,$ok,$http_fail,$conn_fail,$max_t" >> "$OUT"

    # 5) Dettaglio forense quando qualcosa va storto:
    #    rc  http  t_tot  t_dns  t_tcp  t_tls  t_ttfb  ip  url
    #    rc=6 DNS | rc=7 conn rifiutata | rc=28 timeout | rc=35 TLS
    #    con rc=28: t_tcp=0 → morto nel TCP; t_tcp>0 e t_tls=0 → morto nel TLS;
    #    t_tls>0 e t_ttfb=0 → connesso ma mai risposto.
    if [ "$conn_fail" -gt 0 ] || [ "$http_fail" -gt 0 ]; then
      DFILE="results/detail-$(date -u +%Y%m%d).txt"
      {
        echo "== $STAMP $profile $page =="
        echo "#rc http t_tot t_dns t_tcp t_tls t_ttfb ip url"
        awk '$1 != 0 || $2 !~ /^(200|301|302|304)$/' "$RES"
      } >> "$DFILE"
    fi

    rm -f "$TMP" "$RES"
    sleep 2
  done
done

echo "Probe v2 completata: $STAMP"
tail -n 10 "$OUT"
