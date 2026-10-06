#!/usr/bin/env bash
# TP 2 — Rejoue la « nuit d'astreinte » de TrackR dans un namespace.
# Usage : bash code/tp/tp-02/scenario.sh            (namespace trackr)
#         NS=trackr-m02 bash code/tp/tp-02/scenario.sh
# Le script ne fait que des opérations ordinaires via l'API (aucune modification
# du control plane). Il écrit le journal de supervision dans journal-astreinte.txt.
set -u
NS="${NS:-trackr}"
DIR="$(cd "$(dirname "$0")" && pwd)"
JOURNAL="${JOURNAL:-journal-astreinte.txt}"

horo() { date -u +%H:%M:%S; }
note() { echo "$(horo) UTC  $*" >> "$JOURNAL"; }
api_pods() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=trackr-api \
    --field-selector=status.phase!=Failed -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

echo "Préparation du namespace $NS (repart d'un état propre)..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" delete -f "$DIR/trackr-nuit.yaml" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n "$NS" delete events --all >/dev/null 2>&1

: > "$JOURNAL"
echo "Journal de supervision TrackR — namespace $NS" >> "$JOURNAL"
echo "(heures UTC ; les sondes ne voient que des symptômes, pas les causes)" >> "$JOURNAL"
echo >> "$JOURNAL"

echo "Livraison de la version du soir..."
kubectl -n "$NS" apply -f "$DIR/trackr-nuit.yaml" --field-manager=livraison-logivia >/dev/null
kubectl -n "$NS" rollout status deploy/trackr-api --timeout=180s >/dev/null
kubectl -n "$NS" rollout status deploy/trackr-cache --timeout=180s >/dev/null
note "Livraison terminée : trackr-api, trackr-cache, trackr-export, ConfigMap, Service."
sleep 5
note "Sonde : trackr-export n'a produit aucun export depuis la livraison."

# Situation B : un Pod de l'API disparaît.
AVANT="$(api_pods)"
VICTIME="$(echo "$AVANT" | head -1)"
kubectl -n "$NS" delete pod "$VICTIME" --wait=false >/dev/null
sleep 4
APRES="$(api_pods)"
NOUVEAU="$(comm -13 <(echo "$AVANT") <(echo "$APRES") | head -1)"
note "Sonde : le Pod $VICTIME ne répond plus. Un Pod $NOUVEAU est apparu."
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=trackr-api --timeout=120s >/dev/null 2>&1
sleep 6

# Situation C : le nombre de Pods de l'API change.
kubectl -n "$NS" patch deploy trackr-api --subresource=scale --type=merge \
  -p '{"spec":{"replicas":4}}' --field-manager=planificateur-nuit >/dev/null
sleep 4
note "Sonde : trackr-api compte maintenant $(api_pods | wc -l | tr -d ' ') Pods (2 prévus au cahier des charges)."
kubectl -n "$NS" rollout status deploy/trackr-api --timeout=180s >/dev/null
sleep 6

# Situation D : la configuration de l'API change.
kubectl -n "$NS" patch configmap trackr-api-config --type=merge \
  -p '{"data":{"LOG_LEVEL":"debug"}}' --field-manager=outil-support >/dev/null
note "Sonde : la ConfigMap trackr-api-config a changé (empreinte différente de la livraison)."
sleep 6

# Situation F : le cache redémarre.
CACHE="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=trackr-cache -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" exec "$CACHE" -- redis-cli shutdown nosave >/dev/null 2>&1
sleep 8
note "Sonde : trackr-cache a été injoignable quelques secondes, puis est revenu. Nom du Pod : $CACHE."

note "Audit qualité : les Pods trackr-api ont des limites CPU et mémoire, absentes du manifeste livré."
echo
echo "Scénario terminé. Journal écrit dans : $JOURNAL"
echo "À vous d'enquêter (namespace $NS)."
