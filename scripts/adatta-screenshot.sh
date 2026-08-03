#!/bin/bash
#
# Adatta le catture schermo dell'iPhone alle misure che App Store Connect
# pretende, riconoscendo da sé verticale e orizzontale.
#
# Serve perché nessun iPhone produce nativamente una misura accettata:
# il 17 Pro cattura a 1206x2622, e nessuno slot vuole quel numero.
#
#   iPhone 17 Pro verticale    1206 x 2622  ->  1242 x 2688   (6,5")
#   iPhone 17 Pro orizzontale  2622 x 1206  ->  2688 x 1242
#
# ⚠️ LE MISURE RICHIESTE CAMBIANO. Ad agosto 2026 lo slot obbligatorio era il
# 6,5" (1242x2688 / 1284x2778); poco prima era il 6,9". **Guarda i pixel che la
# pagina di caricamento ti chiede** e, se non corrispondono, cambia TARGET_W e
# TARGET_H qui sotto: è l'unica cosa da toccare.
#
# Fra due misure valide conviene quella che richiede meno ingrandimento —
# 1242x2688 costa il 3% partendo dal 17 Pro, 1284x2778 il 6,5%.
#
# Uso:  ./scripts/adatta-screenshot.sh cartella-con-le-catture
#       -> crea cartella-con-le-catture/appstore/ con le versioni adattate.
#       Gli originali non vengono modificati.

set -euo pipefail

# Bersaglio in verticale; in orizzontale i due numeri si scambiano.
TARGET_W=1242
TARGET_H=2688

SRC="${1:-.}"
OUT="$SRC/appstore"
mkdir -p "$OUT"

shopt -s nullglob nocaseglob
FILES=("$SRC"/*.png "$SRC"/*.jpg "$SRC"/*.jpeg)
if [ ${#FILES[@]} -eq 0 ]; then
    echo "Nessuna immagine in '$SRC'."
    exit 1
fi

fallite=0

for f in "${FILES[@]}"; do
    [ "$(dirname "$f")" = "$OUT" ] && continue

    w=$(sips -g pixelWidth  "$f" | awk '/pixelWidth/  {print $2}')
    h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
    name=$(basename "$f")

    if [ "$w" -lt "$h" ]; then
        tw=$TARGET_W; th=$TARGET_H
    else
        tw=$TARGET_H; th=$TARGET_W
    fi

    dest="$OUT/$name"
    cp "$f" "$dest"

    # Si ingrandisce sul lato che richiede il fattore maggiore, così l'altro
    # resta in eccesso e non si scoprono bordi vuoti; poi si ritaglia al
    # centro. Niente `--resampleHeightWidth` diretto: quello forza entrambe le
    # misure e deforma l'immagine invece di ritagliarla.
    if [ $(( tw * h )) -gt $(( th * w )) ]; then
        sips --resampleWidth  "$tw" "$dest" >/dev/null
    else
        sips --resampleHeight "$th" "$dest" >/dev/null
    fi
    sips -c "$th" "$tw" "$dest" >/dev/null

    nw=$(sips -g pixelWidth  "$dest" | awk '/pixelWidth/  {print $2}')
    nh=$(sips -g pixelHeight "$dest" | awk '/pixelHeight/ {print $2}')
    printf '%-40s %sx%s -> %sx%s' "$name" "$w" "$h" "$nw" "$nh"
    if [ "$nw" -eq "$tw" ] && [ "$nh" -eq "$th" ]; then
        echo "  ok"
    else
        echo "  ⚠️ MISURA SBAGLIATA"
        fallite=$((fallite + 1))
    fi
done

echo
echo "Pronti in: $OUT"
[ "$fallite" -gt 0 ] && { echo "$fallite file non hanno la misura attesa."; exit 1; }
exit 0
