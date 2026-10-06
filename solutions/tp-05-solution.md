# TP 5 — Solution : déployer TrackR complet

Les manifestes de référence sont dans `code/manifests/module-05/trackr/` (état final, avec preStop). Toutes les sorties ci-dessous viennent du lab (kind v1.35, 3 nœuds) ; noms de Pods, IP et âges varient.

## Étape 1 — Namespace et cache

`10-trackr-cache.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trackr-cache
  labels: {app: trackr-cache, app.kubernetes.io/part-of: trackr}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: trackr-cache}
  template:
    metadata:
      labels: {app: trackr-cache, app.kubernetes.io/part-of: trackr}
    spec:
      containers:
        - name: redis
          image: redis:7.4-alpine
          ports:
            - {name: redis, containerPort: 6379}
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 250m, memory: 128Mi}
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            periodSeconds: 5
          livenessProbe:
            tcpSocket: {port: redis}
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: trackr-cache
spec:
  type: ClusterIP
  selector: {app: trackr-cache}
  ports:
    - {name: redis, port: 6379, targetPort: redis}
```

Réponse : `Recreate` arrête l'ancien Redis avant de démarrer le nouveau. Avec `RollingUpdate`, deux Redis indépendants coexisteraient quelques secondes derrière le même Service et les écritures seraient réparties entre deux caches différents. Avec un volume `ReadWriteOnce` (module 4), le second Pod pourrait même rester bloqué faute de pouvoir monter le volume.

## Étape 2 — API et front

`20-trackr-api.yaml` (état final, incluant les ajouts de l'étape 4) :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trackr-api
  labels: {app: trackr-api, app.kubernetes.io/part-of: trackr}
  annotations:
    kubernetes.io/change-cause: "TrackR API 6.9.2 initiale"
spec:
  replicas: 2
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  selector:
    matchLabels: {app: trackr-api}
  template:
    metadata:
      labels: {app: trackr-api, app.kubernetes.io/part-of: trackr}
    spec:
      containers:
        - name: api
          image: ghcr.io/stefanprodan/podinfo:6.9.2
          command: [./podinfo, --port=9898, --level=info, --cache-server=tcp://trackr-cache:6379]
          ports:
            - {name: http, containerPort: 9898}
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits: {cpu: 500m, memory: 128Mi}
          startupProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: {path: /readyz, port: http}
            periodSeconds: 3
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "5"]
          livenessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 10
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: trackr-api
spec:
  type: ClusterIP
  selector: {app: trackr-api}
  ports:
    - {name: http, port: 9898, targetPort: http}
```

`30-trackr-front.yaml` (état final) :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trackr-front
  labels: {app: trackr-front, app.kubernetes.io/part-of: trackr}
  annotations:
    kubernetes.io/change-cause: "TrackR front 6.9.2 initiale"
spec:
  replicas: 2
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  selector:
    matchLabels: {app: trackr-front}
  template:
    metadata:
      labels: {app: trackr-front, app.kubernetes.io/part-of: trackr}
    spec:
      containers:
        - name: front
          image: ghcr.io/stefanprodan/podinfo:6.9.2
          command: [./podinfo, --port=9898, --level=info, --backend-url=http://trackr-api:9898/echo]
          env:
            - {name: PODINFO_UI_COLOR, value: "#438ecc"}
            - {name: PODINFO_UI_MESSAGE, value: "TrackR - Logivia"}
          ports:
            - {name: http, containerPort: 9898}
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits: {cpu: 250m, memory: 128Mi}
          readinessProbe:
            httpGet: {path: /readyz, port: http}
            periodSeconds: 3
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "5"]
          livenessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 10
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: trackr-front
spec:
  type: NodePort
  selector: {app: trackr-front}
  ports:
    - {name: http, port: 9898, targetPort: http, nodePort: 30080}
```

Sorties obtenues :

```text
$ kubectl apply -f 10-trackr-cache.yaml -f 20-trackr-api.yaml -f 30-trackr-front.yaml
deployment.apps/trackr-cache created
service/trackr-cache created
deployment.apps/trackr-api created
service/trackr-api created
deployment.apps/trackr-front created
service/trackr-front created

$ kubectl rollout status deploy/trackr-api --timeout=120s && kubectl rollout status deploy/trackr-front --timeout=120s
Waiting for deployment "trackr-api" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "trackr-api" rollout to finish: 1 of 2 updated replicas are available...
deployment "trackr-api" successfully rolled out
deployment "trackr-front" successfully rolled out

$ curl -s http://localhost:30080/api/info | grep -E 'hostname|version|color|message'
  "hostname": "trackr-front-56cbc84b9-4q6d7",
  "version": "6.9.2",
  "color": "#438ecc",
  "message": "TrackR - Logivia",

$ curl -s -X POST -d '{"colis":"LGV-2001","statut":"en tournée"}' http://localhost:30080/api/echo
[
  "{\"colis\":\"LGV-2001\",\"statut\":\"en tournée\"}"
]
$ kubectl run client ... 'wget -qO- --post-data=en-livraison http://trackr-api:9898/cache/LGV-2001; wget -qO- http://trackr-api:9898/cache/LGV-2001; echo'
en-livraison
$ kubectl exec deploy/trackr-cache -- redis-cli KEYS '*'
LGV-2001

$ kubectl get rs
NAME                      DESIRED   CURRENT   READY   AGE
trackr-api-875747bdf      2         2         2       2s
trackr-cache-5fbdf64657   1         1         1       2s
trackr-front-56cbc84b9    2         2         2       2s
```

Réponse : trois ReplicaSets, un par Deployment. Le suffixe est le `pod-template-hash`, calculé sur le modèle de Pod : il change à chaque modification du template (même manifeste = même hash ; on retrouve `875747bdf` et `56cbc84b9` d'un déploiement à l'autre).

Si l'API reste `0/1` : vérifier que le Service `trackr-cache` existe (podinfo ne bloque pas sur Redis, mais `/readyz` reste OK) et que l'image est bien téléchargée (`kubectl describe pod`).

## Étape 3 — Mise à l'échelle manuelle et DNS

```text
$ kubectl scale deploy/trackr-front --replicas=4 && kubectl rollout status deploy/trackr-front && kubectl get deploy trackr-front
deployment.apps/trackr-front scaled
Waiting for deployment "trackr-front" rollout to finish: 2 of 4 updated replicas are available...
Waiting for deployment "trackr-front" rollout to finish: 3 of 4 updated replicas are available...
deployment "trackr-front" successfully rolled out
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
trackr-front   4/4     4            4           5s

$ kubectl get endpointslices -l kubernetes.io/service-name=trackr-front
NAME                 ADDRESSTYPE   PORTS   ENDPOINTS                                            AGE
trackr-front-6vd9g   IPv4          9898    10.244.1.145,10.244.2.217,10.244.1.146 + 1 more...   5s

$ kubectl scale deploy/trackr-front --replicas=2
```

DNS depuis le namespace `default` :

```text
$ kubectl -n default run dns --image=busybox:1.37 --restart=Never --rm -i --quiet -- sh -c \
   'nslookup trackr-api.trackr.svc.cluster.local | tail -3; wget -qO- http://trackr-api.trackr:9898/healthz; wget -qO- -T 2 http://trackr-api:9898/healthz || echo echec-nom-court-hors-namespace'
Name:	trackr-api.trackr.svc.cluster.local
Address: 10.96.8.239
{
  "status": "OK"
}
wget: bad address 'trackr-api:9898'
echec-nom-court-hors-namespace
```

`trackr-api.trackr` et le FQDN `trackr-api.trackr.svc.cluster.local` fonctionnent ; le nom court `trackr-api` échoue car la liste `search` du Pod commence par `default.svc.cluster.local`.

## Étape 4 — Mise à jour sans interruption

Mesure SANS preStop (readiness + `maxUnavailable: 0` déjà en place), deux mises à jour pendant la boucle :

```text
$ kubectl set image deploy/trackr-front front=ghcr.io/stefanprodan/podinfo:6.9.1
$ kubectl annotate deploy/trackr-front kubernetes.io/change-cause='Front : retour en 6.9.1 (test TP)' --overwrite
$ kubectl rollout status deploy/trackr-front
Waiting for deployment "trackr-front" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "trackr-front" rollout to finish: 1 old replicas are pending termination...
deployment "trackr-front" successfully rolled out
$ kubectl set env deploy/trackr-front PODINFO_UI_COLOR='#2f9e5f'
$ kubectl annotate deploy/trackr-front kubernetes.io/change-cause='Front : bandeau vert' --overwrite
$ kubectl rollout status deploy/trackr-front
...
deployment "trackr-front" successfully rolled out
$ sort mesure.txt | uniq -c
 295 200
   5 503
```

Explication : à la suppression d'un ancien Pod, deux choses partent en parallèle : le kubelet envoie SIGTERM au conteneur, et le contrôleur EndpointSlice retire le Pod, ce que kube-proxy répercute ensuite sur chaque nœud. podinfo passe immédiatement en mode arrêt et répond 503 ; pendant une fraction de seconde, kube-proxy lui envoie encore des requêtes. Le `preStop: sleep 5` retarde le SIGTERM de 5 s, le temps que le Pod sorte des règles.

Mesure AVEC preStop (même protocole, deux mises à jour) :

```text
$ sort mesure.txt | uniq -c
 300 200
```

La readinessProbe protège le **démarrage** (on n'envoie pas de trafic à un Pod qui n'est pas prêt), le preStop protège l'**arrêt**. Les deux sont nécessaires. Le graphique de la slide « Ce que voient les clients » montre l'effet de l'absence de readinessProbe : 69 erreurs en 7 s.

## Étape 5 — Mauvaise version et rollback

```text
$ kubectl set image deploy/trackr-front front=ghcr.io/stefanprodan/podinfo:6.9.99
$ kubectl annotate deploy/trackr-front kubernetes.io/change-cause='Front : 6.9.99 (erreur de tag)' --overwrite
$ kubectl rollout status deploy/trackr-front --timeout=45s
Waiting for deployment "trackr-front" rollout to finish: 1 out of 2 new replicas have been updated...
error: timed out waiting for the condition

$ kubectl get pods -l app=trackr-front
NAME                            READY   STATUS             RESTARTS   AGE
trackr-front-577bfc86f8-z92md   0/1     ImagePullBackOff   0          45s
trackr-front-76b766df7f-t6b6c   1/1     Running            0          78s
trackr-front-76b766df7f-v7h4c   1/1     Running            0          79s

$ kubectl get events --field-selector reason=Failed --sort-by=.lastTimestamp | tail -3
17s   Warning   Failed   pod/trackr-front-577bfc86f8-z92md   Error: ImagePullBackOff
4s    Warning   Failed   pod/trackr-front-577bfc86f8-z92md   Failed to pull image "ghcr.io/stefanprodan/podinfo:6.9.99": rpc error: code = NotFound desc = ... not found
4s    Warning   Failed   pod/trackr-front-577bfc86f8-z92md   Error: ErrImagePull

$ curl -s http://localhost:30080/api/info | grep -E 'version|color'
  "version": "6.9.1",
  "color": "#2f9e5f",
```

TrackR répond toujours : `maxSurge: 1` a créé un seul nouveau Pod, et `maxUnavailable: 0` interdit d'arrêter un ancien tant que le nouveau n'est pas prêt. Le rollout reste bloqué ; il passera en `ProgressDeadlineExceeded` après `progressDeadlineSeconds` (600 s par défaut), sans rollback automatique.

```text
$ kubectl rollout undo deploy/trackr-front
Warning: resource deployments/trackr-front was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
deployment.apps/trackr-front rolled back
$ kubectl rollout status deploy/trackr-front
deployment "trackr-front" successfully rolled out
$ kubectl rollout history deploy/trackr-front
REVISION  CHANGE-CAUSE
1         TrackR front 6.9.2 initiale
2         Front : retour en 6.9.1 (test TP)
4         Front : 6.9.99 (erreur de tag)
5         Front : bandeau vert
```

La révision 3 (« bandeau vert ») a disparu : `undo` a redéployé son modèle, qui devient la révision 5. Le ReplicaSet existant a été réutilisé (aucun nouveau Pod à télécharger : le rollback est immédiat).

```text
$ kubectl rollout undo deploy/trackr-front --to-revision=1
deployment.apps/trackr-front rolled back
$ curl -s http://localhost:30080/api/info | grep -E 'version|color'
  "version": "6.9.2",
  "color": "#438ecc",
$ kubectl rollout history deploy/trackr-front
REVISION  CHANGE-CAUSE
2         Front : retour en 6.9.1 (test TP)
4         Front : 6.9.99 (erreur de tag)
5         Front : bandeau vert
6         TrackR front 6.9.2 initiale
```

L'avertissement rappelle que `rollout undo` ne modifie ni l'annotation `last-applied-configuration` ni le dépôt Git : il faut corriger le manifeste (tag 6.9.2) et le committer, sinon le prochain `kubectl apply` ou la synchronisation GitOps redéploiera la mauvaise version.

## Étape 6 — HPA sous charge

`40-trackr-api-hpa.yaml` :

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: trackr-api
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: trackr-api}
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: 60}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

```text
$ kubectl apply -f 40-trackr-api-hpa.yaml
horizontalpodautoscaler.autoscaling/trackr-api created
$ sleep 30; kubectl get hpa trackr-api
NAME         REFERENCE               TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
trackr-api   Deployment/trackr-api   cpu: 1%/60%   2         6         2          30s
$ kubectl apply -f code/manifests/module-05/demo/generateur-charge.yaml
deployment.apps/generateur-charge created
$ for i in $(seq 1 10); do kubectl get hpa trackr-api --no-headers; sleep 15; done
trackr-api   Deployment/trackr-api   cpu: 1%/60%     2     6     2     32s
trackr-api   Deployment/trackr-api   cpu: 1%/60%     2     6     2     47s
trackr-api   Deployment/trackr-api   cpu: 44%/60%    2     6     2     62s
trackr-api   Deployment/trackr-api   cpu: 141%/60%   2     6     2     77s
trackr-api   Deployment/trackr-api   cpu: 131%/60%   2     6     5     92s
trackr-api   Deployment/trackr-api   cpu: 83%/60%    2     6     5     107s
trackr-api   Deployment/trackr-api   cpu: 63%/60%    2     6     5     2m3s
trackr-api   Deployment/trackr-api   cpu: 63%/60%    2     6     5     2m18s
trackr-api   Deployment/trackr-api   cpu: 64%/60%    2     6     5     2m33s
trackr-api   Deployment/trackr-api   cpu: 65%/60%    2     6     5     2m48s
$ kubectl top pods -l app=trackr-api
NAME                          CPU(cores)   MEMORY(bytes)
trackr-api-646b48648c-47x2d   63m          24Mi
trackr-api-646b48648c-7z974   63m          24Mi
trackr-api-646b48648c-dhbfw   63m          24Mi
trackr-api-646b48648c-dn86n   63m          24Mi
trackr-api-646b48648c-mv5v7   61m          24Mi
$ kubectl describe hpa trackr-api | sed -n '/Events:/,$p'
  Warning  FailedGetResourceMetric       2m48s  horizontal-pod-autoscaler  failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
  Normal   SuccessfulRescale             108s   horizontal-pod-autoscaler  New size: 5; reason: cpu resource utilization (percentage of request) above target
```

Calcul : ⌈2 × 141 / 60⌉ = ⌈4,7⌉ = 5. Une fois à 5 réplicas, le CPU moyen redescend à 63 % : l'écart avec 60 % reste dans la tolérance de 10 %, donc pas de 6e réplica. Les valeurs dépendent du nombre de cœurs de la machine (le lab du formateur : VM Podman de 4 vCPU) ; sur un poste plus puissant, augmenter le nombre de Pods du générateur.

Retour à 2 réplicas (mesure complète, `mesures/hpa.csv`) : charge supprimée à +210 s, CPU encore à 62-66 % jusqu'à +270 s, puis 5 % à +286 s ; 4 réplicas à +317 s, 2 à +332 s, soit environ 2 minutes. Trois délais s'additionnent : les Pods busybox mettent 30 s à mourir (le shell PID 1 ignore SIGTERM, le kubelet attend le délai de grâce de 30 s), metrics-server agrège sur 15 s, puis l'HPA attend la fenêtre de stabilisation de 60 s avant de réduire.

L'événement `FailedGetResourceMetric` du début est normal : metrics-server n'a pas encore de mesure pour des Pods créés depuis moins de 15 à 30 s.

