#!/usr/bin/env bash
#
# bench.sh — protocole de mesure llama.cpp sur Apple Silicon
#
# Usage :
#   ./bench.sh ggml-org/gemma-3-12b-it-GGUF        (dépôt Hugging Face)
#   ./bench.sh ~/chemin/vers/modele.gguf           (fichier local)
#
# Produit deux fichiers JSON dans ~/llm-bench-m5pro/data/ et affiche
# un résumé : débit, efficacité mémoire, régime établi du prefill.
#

set -euo pipefail   # arrêt à la première erreur, variable non définie = erreur

# ---------------------------------------------------------------- paramètres

BANDWIDTH=307       # Go/s — bande passante théorique de la machine
REPS_PP=30          # répétitions prefill : assez pour atteindre le régime établi
REPS_TG=5           # répétitions génération : déjà stable, inutile d'en faire plus
N_SUSTAINED=10      # nb de dernières répétitions retenues comme régime établi

LLAMA_DIR="$HOME/llama.cpp"
BENCH="$LLAMA_DIR/build/bin/llama-bench"
CLI="$LLAMA_DIR/build/bin/llama-cli"
OUTDIR="$HOME/llm-bench-m5pro/data"

# ------------------------------------------------------------- vérifications

if [ $# -ne 1 ]; then
  echo "Usage : $0 <dépôt-hf | chemin.gguf>" >&2
  exit 1
fi

for tool in "$BENCH" "$CLI"; do
  [ -x "$tool" ] || { echo "Introuvable : $tool" >&2; exit 1; }
done

command -v jq >/dev/null || { echo "jq manquant : brew install jq" >&2; exit 1; }

mkdir -p "$OUTDIR"

# ------------------------------------------------- résolution du modèle

TARGET="$1"

if [ -f "$TARGET" ]; then
  # Cas 1 : chemin local fourni directement
  MODEL="$TARGET"
else
  # Cas 2 : dépôt Hugging Face — on télécharge si absent, puis on cherche
  # le .gguf dans le cache. Le -n 1 limite la génération à un token :
  # on ne veut que le téléchargement, pas une conversation.
  echo "→ Récupération de $TARGET"
  "$CLI" -hf "$TARGET" -p ok -n 1 -no-cnv >/dev/null 2>&1 || true

  # Le cache HF nomme les dossiers models--org--depot
  CACHE_DIR="$HOME/.cache/huggingface/hub/models--${TARGET//\//--}"
  [ -d "$CACHE_DIR" ] || { echo "Cache introuvable : $CACHE_DIR" >&2; exit 1; }

  # On exclut mmproj-* : c'est la tour vision, pas un modèle de langage
  MODEL=$(find "$CACHE_DIR" -name "*.gguf" ! -name "mmproj*" | head -1)
  [ -n "$MODEL" ] || { echo "Aucun .gguf trouvé dans $CACHE_DIR" >&2; exit 1; }
fi

NAME=$(basename "$MODEL" .gguf)
PP_JSON="$OUTDIR/${NAME}-pp512.json"
TG_JSON="$OUTDIR/${NAME}-tg128.json"

echo "→ Modèle : $NAME"
echo "→ Taille  : $(ls -lLh "$MODEL" | awk '{print $5}')"
echo

# ---------------------------------------------------------------- mesures

# Deux invocations séparées, pas une seule : on a vérifié le 28 juillet que
# prefill et génération n'interagissent pas (H2 réfutée). Les découpler
# permet un nombre de répétitions adapté à chacun.

echo "→ Prefill (pp512, $REPS_PP répétitions)…"
"$BENCH" -m "$MODEL" -p 512 -n 0 -r "$REPS_PP" -o json > "$PP_JSON" 2>/dev/null

echo "→ Génération (tg128, $REPS_TG répétitions)…"
"$BENCH" -m "$MODEL" -p 0 -n 128 -r "$REPS_TG" -o json > "$TG_JSON" 2>/dev/null

# ----------------------------------------------------------------- résumé

SIZE_GB=$(jq -r '.[0].model_size / 1e9' "$TG_JSON")
PARAMS=$(jq -r '.[0].model_n_params / 1e9' "$TG_JSON")

TG=$(jq -r '.[0].avg_ts' "$TG_JSON")
TG_SD=$(jq -r '.[0].stddev_ts' "$TG_JSON")

PP_MEAN=$(jq -r '.[0].avg_ts' "$PP_JSON")

# Régime établi : moyenne des N dernières répétitions, calculée depuis les
# durées brutes. La moyenne globale inclut le transitoire de montée en
# fréquence et sous-estime le débit réel soutenu.
PP_SUST=$(jq -r --argjson n "$N_SUSTAINED" '
  .[0] | .n_prompt as $np
  | (.samples_ns[-$n:] | map($np / (. / 1e9)) | add / length)
' "$PP_JSON")

# Plafond mémoire : chaque token relit tout le fichier de poids.
CEILING=$(echo "$BANDWIDTH $SIZE_GB" | awk '{printf "%.1f", $1/$2}')
EFF=$(echo "$TG $CEILING" | awk '{printf "%.0f", 100*$1/$2}')

printf '\n'
printf '  %-22s %s\n' "modèle"            "$NAME"
printf '  %-22s %.1f G params, %.2f Go\n' "taille" "$PARAMS" "$SIZE_GB"
printf '\n'
printf '  %-22s %.1f t/s  (±%.1f)\n'      "génération tg128" "$TG" "$TG_SD"
printf '  %-22s %.0f t/s\n'               "plafond théorique" "$CEILING"
printf '  %-22s %s %%\n'                  "efficacité mémoire" "$EFF"
printf '\n'
printf '  %-22s %.0f t/s\n'               "prefill (moyenne)" "$PP_MEAN"
printf '  %-22s %.0f t/s\n'               "prefill (soutenu)" "$PP_SUST"
printf '\n'
printf '  JSON : %s\n' "$OUTDIR/${NAME}-*.json"
printf '\n'
