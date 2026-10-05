#!/usr/bin/env bash
# TP 1 - Verification de la fiche de besoin "trackr-front en recette"
# Usage : bash code/tp/tp-01-verifier.sh            (namespace trackr)
#         NS=trackr-m01 bash code/tp/tp-01-verifier.sh
# Attention : la derniere verification supprime un Pod du front pour tester
# l'auto-reparation (comme le ferait une panne). Dependances : kubectl, jq.
set -u

NS="${NS:-trackr}"
OK=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); OK=$((OK + 1)); echo "[OK] $1"; }
ko() { TOTAL=$((TOTAL + 1)); echo "[KO] $1"; }
check() { if [ "$1" = "1" ]; then ok "$2"; else ko "$3"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq est requis"; exit 2; }

echo "Verification de la fiche de besoin trackr-front (namespace $NS)"
echo

DEP=$(kubectl get deployment trackr-front -n "$NS" -o json 2>/dev/null || echo '{}')
SVC=$(kubectl get service trackr-front -n "$NS" -o json 2>/dev/null || echo '{}')

# 1. Deployment et image
R=$(echo "$DEP" | jq -r '[.spec.template.spec.containers[]?.image] | index("ghcr.io/stefanprodan/podinfo:6.9.2") != null | if . then 1 else 0 end')
check "$R" "V1 [E1] Deployment trackr-front avec l'image podinfo:6.9.2" \
           "V1 [E1] aucun Deployment trackr-front utilisant l'image ghcr.io/stefanprodan/podinfo:6.9.2"

# 2. Deux exemplaires prets
R=$(echo "$DEP" | jq -r 'if (.spec.replicas // 0) == 2 and (.status.readyReplicas // 0) == 2 then 1 else 0 end')
check "$R" "V2 [E2] deux exemplaires demandes et prets (2/2)" \
           "V2 [E2] le front doit tourner en exactement 2 exemplaires prets"

# 3. Conteneur front, port 9898 nomme http
R=$(echo "$DEP" | jq -r '[.spec.template.spec.containers[]? | select(.name=="front") | .ports[]? | select(.containerPort==9898 and .name=="http")] | if length==1 then 1 else 0 end')
check "$R" "V3 [E3] conteneur front, port 9898 nomme http" \
           "V3 [E3] le conteneur doit s'appeler front et declarer le port 9898 sous le nom http"

# 4. Etiquettes du Deployment et des Pods
LBL='(.app=="trackr" and .tier=="front" and .env=="recette")'
R=$(echo "$DEP" | jq -r "if ((.metadata.labels // {}) | $LBL) and ((.spec.template.metadata.labels // {}) | $LBL) then 1 else 0 end")
check "$R" "V4 [E4] Deployment et Pods etiquetes app/tier/env" \
           "V4 [E4] le Deployment ET ses Pods doivent porter app=trackr, tier=front, env=recette"

# 5. Service ClusterIP, port 80, etiquete
R=$(echo "$SVC" | jq -r "if (.spec.type // \"\")==\"ClusterIP\" and ([.spec.ports[]?.port] | index(80) != null) and ((.metadata.labels // {}) | $LBL) then 1 else 0 end")
check "$R" "V5 [E4 E5] Service trackr-front ClusterIP sur le port 80, etiquete" \
           "V5 [E4 E5] il faut un Service trackr-front de type ClusterIP, port 80, etiquete app/tier/env"

# 6. Le Service vise le port par son nom
R=$(echo "$SVC" | jq -r '[.spec.ports[]? | select(.port==80 and .targetPort=="http")] | if length==1 then 1 else 0 end')
check "$R" "V6 [E6] le Service vise le port nomme http" \
           "V6 [E6] le port 80 du Service doit viser le port des Pods par son nom, pas par son numero"

# 7. Le Service ne sert que le front de recette
EPS=$(kubectl get endpointslices -n "$NS" -l kubernetes.io/service-name=trackr-front -o json 2>/dev/null || echo '{}')
READY_PODS=$(echo "$EPS" | jq -r '[.items[]?.endpoints[]? | select(.conditions.ready==true) | .targetRef.name] | unique | .[]')
R=0
if [ -n "$READY_PODS" ] && [ "$(echo "$READY_PODS" | wc -l | tr -d ' ')" -ge 2 ]; then
  R=1
  for p in $READY_PODS; do
    L=$(kubectl get pod "$p" -n "$NS" -o jsonpath='{.metadata.labels.tier}/{.metadata.labels.env}' 2>/dev/null)
    [ "$L" = "front/recette" ] || R=0
  done
fi
check "$R" "V7 [E7] le Service distribue vers au moins 2 Pods, tous du front de recette" \
           "V7 [E7] le Service doit avoir au moins 2 Pods prets derriere lui, et uniquement des Pods du front de recette"

# 8. Joignable sous le nom trackr-front, port 80
H=$(kubectl get --raw "/api/v1/namespaces/$NS/services/trackr-front:80/proxy/healthz" 2>/dev/null | jq -r '.status? // empty' 2>/dev/null)
check "$([ "$H" = "OK" ] && echo 1 || echo 0)" "V8 [E5] http://trackr-front:80/healthz repond OK" \
           "V8 [E5] le front ne repond pas sur le Service trackr-front, port 80, chemin /healthz"

# 9. (E8) Survit a la perte d'un Pod (test reel)
R=0
VICTIME=$(kubectl get pods -n "$NS" -l app=trackr,tier=front,env=recette -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.ownerReferences[]?.kind=="ReplicaSet") | select(.metadata.ownerReferences[0].name | startswith("trackr-front-")) | .metadata.name] | .[0] // empty')
if [ -n "$VICTIME" ] && [ "$(echo "$DEP" | jq -r '.status.readyReplicas // 0')" = "2" ]; then
  echo "     (test de panne : suppression du Pod $VICTIME, attente du retour a 2/2...)"
  kubectl delete pod "$VICTIME" -n "$NS" --wait=false >/dev/null 2>&1
  for _ in $(seq 1 60); do
    sleep 1
    N=$(kubectl get pods -n "$NS" -l app=trackr,tier=front,env=recette -o json \
      | jq -r --arg v "$VICTIME" '[.items[] | select(.metadata.name != $v) | select(.metadata.deletionTimestamp == null) | select(.metadata.ownerReferences[]?.kind=="ReplicaSet") | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length')
    if [ "$N" = "2" ]; then R=1; break; fi
  done
fi
check "$R" "V9 [E8] apres la perte d'un Pod, le front revient seul a 2 exemplaires prets" \
           "V9 [E8] le front ne survit pas a la perte d'un Pod (aucun remplacant automatique en 60 s)"

echo
echo "Score : $OK/$TOTAL"
