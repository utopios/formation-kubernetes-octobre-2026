# TP 5 — Déployer TrackR complet, sans interruption

**Module** : 5 — Déploiement et exécution des applications
**Durée** : 60 minutes
**Pré-requis** : cluster de lab démarré (`kubectl get nodes` montre 3 nœuds `Ready`), metrics-server installé (`kubectl top nodes` répond), port 30080 libre sur votre poste.

## Contexte

Logivia veut mettre TrackR en production. L'équipe d'exploitation impose quatre exigences :

1. les trois briques (`trackr-cache`, `trackr-api`, `trackr-front`) tournent dans le namespace `trackr`, chacune derrière un Service ;
2. le front est accessible depuis votre poste sur `http://localhost:30080` ;
3. une mise à jour ne doit provoquer **aucune erreur** visible par les utilisateurs, et une mauvaise version doit pouvoir être annulée en une commande ;
4. l'API doit absorber les pics de charge automatiquement, entre 2 et 6 réplicas.

Vous rédigez les manifestes dans un répertoire de travail `~/tp05/`. Images : `redis:7.4-alpine`, `ghcr.io/stefanprodan/podinfo:6.9.2` (port 9898, routes `/healthz`, `/readyz`, `/api/info`, `/cache/{clé}`), `busybox:1.37` pour les clients de test.

Astuce : `kubectl create deployment ... --dry-run=client -o yaml` et `kubectl create service ... --dry-run=client -o yaml` produisent des squelettes à compléter. `kubectl explain deployment.spec.strategy` documente chaque champ.

## Étape 1 — Namespace et cache (5 min)

1. Créez le namespace `trackr`. Pour ne pas répéter `-n trackr`, vous pouvez faire `kubectl config set-context --current --namespace=trackr` (pensez à revenir à `default` à la fin du TP).
2. Écrivez `10-trackr-cache.yaml` : un Deployment `trackr-cache` (1 réplica, label `app: trackr-cache`, stratégie `Recreate`, requests 50m / 64Mi, limits 250m / 128Mi, readinessProbe `exec` qui lance `redis-cli ping`) et un Service ClusterIP `trackr-cache` sur le port 6379.
3. Appliquez-le et vérifiez que le Pod est `1/1 Running`.

Question : pourquoi la stratégie `Recreate` est-elle préférable pour un Redis unique ?

## Étape 2 — API et front (10 min)

1. Écrivez `20-trackr-api.yaml` : Deployment `trackr-api`, 2 réplicas, commande `./podinfo --port=9898 --level=info --cache-server=tcp://trackr-cache:6379`, port nommé `http`, requests 100m / 64Mi, limits 500m / 128Mi, et un Service ClusterIP `trackr-api` (port 9898).
2. Écrivez `30-trackr-front.yaml` : Deployment `trackr-front`, 2 réplicas, commande `./podinfo --port=9898 --level=info --backend-url=http://trackr-api:9898/echo`, variables `PODINFO_UI_COLOR=#438ecc` et `PODINFO_UI_MESSAGE=TrackR - Logivia`, et un Service **NodePort** `trackr-front` avec `nodePort: 30080`.
3. Ajoutez sur les deux Deployments l'annotation `kubernetes.io/change-cause` (« TrackR API 6.9.2 initiale », « TrackR front 6.9.2 initiale »).
4. Appliquez, attendez `kubectl rollout status`, puis testez :

```bash
curl -s http://localhost:30080/api/info
curl -s -X POST -d '{"colis":"LGV-2001","statut":"en tournée"}' http://localhost:30080/api/echo
kubectl -n trackr run client --image=busybox:1.37 --restart=Never --rm -i --quiet -- sh -c \
  'wget -qO- --post-data=en-livraison http://trackr-api:9898/cache/LGV-2001; wget -qO- http://trackr-api:9898/cache/LGV-2001; echo'
kubectl -n trackr exec deploy/trackr-cache -- redis-cli KEYS '*'
```

Sous Windows PowerShell : `curl.exe -s http://localhost:30080/api/info`.

5. Combien de ReplicaSets voyez-vous (`kubectl get rs`) ? Comment s'appelle chacun, et d'où vient son suffixe ?

## Étape 3 — Mise à l'échelle manuelle et DNS (5 min)

1. Passez `trackr-front` à 4 réplicas avec `kubectl scale`, observez l'EndpointSlice du Service (`kubectl get endpointslices -l kubernetes.io/service-name=trackr-front`), puis revenez à 2.
2. Depuis un Pod busybox lancé dans le namespace `default`, appelez l'API TrackR. Quel nom DNS fonctionne ? Lequel échoue ?

## Étape 4 — Mise à jour sans interruption (15 min)

1. Ajoutez sur `trackr-api` et `trackr-front` :
   - une stratégie `RollingUpdate` avec `maxSurge: 1` et `maxUnavailable: 0` ;
   - une `readinessProbe` HTTP sur `/readyz` (période 3 s, 2 échecs) et une `livenessProbe` HTTP sur `/healthz` (période 10 s) ;
   - pour l'API seulement, une `startupProbe` HTTP sur `/healthz` qui laisse jusqu'à 60 s au démarrage.
2. Dans un second terminal, lancez une boucle de mesure (300 requêtes, une toutes les 0,1 s) :

```bash
for i in $(seq 1 300); do curl -s -o /dev/null -m 1 -w '%{http_code}\n' http://localhost:30080/healthz; sleep 0.1; done > mesure.txt
```

PowerShell : `1..300 | % { try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 http://localhost:30080/healthz).StatusCode } catch { 'ERR' }; Start-Sleep -Milliseconds 100 } > mesure.txt`

3. Pendant la boucle, faites deux mises à jour successives du front (`set image` vers `6.9.1`, puis `set env PODINFO_UI_COLOR='#2f9e5f'`), en renseignant chaque fois `change-cause`. Comptez les codes : `sort mesure.txt | uniq -c`.
4. Avez-vous obtenu des 503 ? Expliquez-les (indice : que fait podinfo quand il reçoit SIGTERM, et combien de temps faut-il à kube-proxy pour retirer un Pod ?). Ajoutez un hook `lifecycle.preStop` qui attend 5 s, puis refaites la mesure.

## Étape 5 — Mauvaise version et rollback (10 min)

1. Déployez le tag inexistant `6.9.99` sur le front (avec un `change-cause`). Lancez `kubectl rollout status --timeout=45s`.
2. Quel est l'état des Pods ? Quel événement explique l'échec ? TrackR répond-il toujours sur `http://localhost:30080` ? Pourquoi ?
3. Annulez avec `kubectl rollout undo`. Observez `kubectl rollout history` : quelle révision a disparu et pourquoi ?
4. Revenez à la toute première version avec `--to-revision`. Lisez l'avertissement affiché par kubectl : que devez-vous faire dans votre dépôt Git ?

## Étape 6 — HPA sous charge (10 min)

1. Écrivez `40-trackr-api-hpa.yaml` : HPA `autoscaling/v2` sur `trackr-api`, 2 à 6 réplicas, cible 60 % de CPU, fenêtre de stabilisation à la baisse de 60 s. Appliquez et vérifiez `kubectl get hpa` (la valeur `<unknown>` doit disparaître en moins d'une minute).
2. Générez de la charge avec `code/manifests/module-05/demo/generateur-charge.yaml` (4 Pods busybox × 6 boucles `wget`).
3. Relevez toutes les 15 s la ligne de `kubectl get hpa trackr-api` pendant 2 à 3 minutes. À quel moment le nombre de réplicas change-t-il ? Vérifiez la formule ⌈réplicas × CPU mesuré / CPU cible⌉ avec vos valeurs.
4. Supprimez le générateur. Combien de temps faut-il pour revenir à 2 réplicas ? Pourquoi est-ce plus long que la fenêtre de 60 s ?

