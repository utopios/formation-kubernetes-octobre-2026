# Solution — TP 2 : Explorer l'architecture du cluster TrackR


Manifestes utilisés (complets dans `code/manifests/module-02/`) :

```yaml
# trackr-api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trackr-api
  labels:
    app.kubernetes.io/name: trackr-api
    app.kubernetes.io/part-of: trackr
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: trackr-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: trackr-api
        app.kubernetes.io/part-of: trackr
    spec:
      containers:
        - name: api
          image: ghcr.io/stefanprodan/podinfo:6.9.2
          ports:
            - containerPort: 9898
```

```yaml
# trackr-api-trop-gourmand.yaml (bonus)
apiVersion: v1
kind: Pod
metadata:
  name: trackr-api-gourmand
  labels:
    app.kubernetes.io/name: trackr-api-gourmand
    app.kubernetes.io/part-of: trackr
spec:
  containers:
    - name: api
      image: ghcr.io/stefanprodan/podinfo:6.9.2
      resources:
        requests:
          cpu: "64"
```

```yaml
# trackr-api-service.yaml (bonus)
apiVersion: v1
kind: Service
metadata:
  name: trackr-api
  labels:
    app.kubernetes.io/part-of: trackr
spec:
  selector:
    app.kubernetes.io/name: trackr-api
  ports:
    - name: http
      port: 9898
      targetPort: 9898
```

---

## Étape 1 — Inventaire

```console
$ kubectl get pods -n kube-system -o wide
NAME                                                  READY   STATUS    RESTARTS   AGE   IP           NODE
coredns-7d764666f9-vdwcd                              1/1     Running   0          13m   10.244.0.3   k8s-formation-control-plane
coredns-7d764666f9-ztlpc                              1/1     Running   0          13m   10.244.0.2   k8s-formation-control-plane
etcd-k8s-formation-control-plane                      1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
kindnet-kfspp                                         1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
kindnet-l7gvc                                         1/1     Running   0          13m   10.89.2.6    k8s-formation-worker2
kindnet-mkpmj                                         1/1     Running   0          13m   10.89.2.4    k8s-formation-worker
kube-apiserver-k8s-formation-control-plane            1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
kube-controller-manager-k8s-formation-control-plane   1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
kube-proxy-4hqhg                                      1/1     Running   0          13m   10.89.2.4    k8s-formation-worker
kube-proxy-7svj8                                      1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
kube-proxy-7w225                                      1/1     Running   0          13m   10.89.2.6    k8s-formation-worker2
kube-scheduler-k8s-formation-control-plane            1/1     Running   0          13m   10.89.2.5    k8s-formation-control-plane
metrics-server-5db8b86858-brzxf                       1/1     Running   0          6m    10.244.1.5   k8s-formation-worker

$ kubectl get daemonsets,deployments -n kube-system
NAME                        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
daemonset.apps/kindnet      3         3         3       3            3           kubernetes.io/os=linux   54m
daemonset.apps/kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   54m

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/coredns          2/2     2            2           54m
deployment.apps/metrics-server   1/1     1            1           53m
```

| Composant | Nœud(s) | IP | Lancement |
|---|---|---|---|
| kube-apiserver | control-plane | du nœud | static Pod |
| etcd | control-plane | du nœud | static Pod |
| kube-scheduler | control-plane | du nœud | static Pod |
| kube-controller-manager | control-plane | du nœud | static Pod |
| kube-proxy | les 3 nœuds | du nœud | DaemonSet |
| coredns | control-plane (sur ce lab) | de Pod | Deployment (2 réplicas) |

Question 3 : le kubelet et containerd sont des **services systemd** du nœud. Ils doivent tourner **avant** tout Pod (c'est le kubelet qui démarre les static Pods), ils ne peuvent donc pas être eux-mêmes des Pods.

## Étape 2 — Static Pods

```console
$ docker exec k8s-formation-control-plane ls -l /etc/kubernetes/manifests
-rw-------. 1 root root 2616 Oct  4 20:36 etcd.yaml
-rw-------. 1 root root 4013 Oct  4 20:36 kube-apiserver.yaml
-rw-------. 1 root root 3552 Oct  4 20:36 kube-controller-manager.yaml
-rw-------. 1 root root 1776 Oct  4 20:36 kube-scheduler.yaml

$ docker exec k8s-formation-control-plane grep -n staticPodPath /var/lib/kubelet/config.yaml
54:staticPodPath: /etc/kubernetes/manifests
```

| Paramètre | Valeur sur le lab | Source |
|---|---|---|
| Port HTTPS de l'API | 6443 | `--secure-port=6443` (kube-apiserver.yaml) |
| Adresse d'etcd | `https://127.0.0.1:2379` | `--etcd-servers` |
| Modes d'autorisation | Node, RBAC | `--authorization-mode=Node,RBAC` |
| Plage des Services | 10.96.0.0/16 | `--service-cluster-ip-range` |
| Plage des Pods | 10.244.0.0/16 | `--cluster-cidr` (kube-controller-manager.yaml) |
| Données etcd | /var/lib/etcd | `--data-dir` (etcd.yaml) |

Question 4 : `--leader-elect=true`. La trace est un objet **Lease** par composant :

```console
$ kubectl get leases -n kube-system
NAME                                   HOLDER                                                                      AGE
apiserver-w4j2ayijzswtvwgz5kmnmecm4i   apiserver-w4j2ayijzswtvwgz5kmnmecm4i_cd9556e6-eaab-4342-945f-e30f34cc58db   15m
kube-controller-manager                k8s-formation-control-plane_e2df46f6-f0c2-4cf6-b2f7-583e7947565d            15m
kube-scheduler                         k8s-formation-control-plane_450de4c6-8126-49a5-a38f-b646bf223a43            15m
```

Avec plusieurs control planes, une seule instance du scheduler et du controller-manager détient le Lease et travaille ; les autres attendent.

## Étape 3 — Santé de l'API Server

```console
$ kubectl get --raw '/livez?verbose'
[+]ping ok
[+]log ok
[+]etcd ok
...
livez check passed
$ kubectl get --raw '/livez?verbose' | grep -c '^\[+\]'
32
$ kubectl get --raw '/readyz?verbose' | tail -2
[+]shutdown ok
readyz check passed
```

32 vérifications sur le lab ; celle d'etcd est `[+]etcd ok`.

Accès anonyme :

```console
$ curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:64842/livez
200
$ curl -sk https://127.0.0.1:64842/api/v1/namespaces/trackr/pods
{
  "kind": "Status",
  "status": "Failure",
  "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" in API group \"\" in the namespace \"trackr\"",
  "reason": "Forbidden",
  "code": 403
}
```

Sans certificat, la requête est **authentifiée** comme `system:anonymous`. Les sondes de santé sont autorisées à tous (rôle `system:public-info-viewer`) ; la liste des Pods est **refusée par l'autorisation** RBAC : 403 et non 401.

## Étape 4 — Chronométrer le déploiement

Requêtes HTTP (`-v=6`, filtrées) :

```text
GET  /openapi/v3?timeout=32s                                      200 OK         4 ms
GET  /openapi/v3/apis/apps/v1?hash=...                            200 OK         1 ms
GET  /apis/apps/v1/namespaces/trackr/deployments/trackr-api       404 Not Found  1 ms
GET  /api/v1/namespaces/trackr                                    200 OK         1 ms
POST /apis/apps/v1/namespaces/trackr/deployments?fieldManager=kubectl-client-side-apply&fieldValidation=Strict   201 Created  2 ms
```

`kubectl apply` télécharge le schéma OpenAPI (validation côté client), **cherche** l'objet : 404 signifie qu'il n'existe pas encore, donc `apply` fait un **POST** de création. S'il avait existé, on aurait vu un PATCH.

Ordre des événements et composants responsables :

| Raison | Objet | Composant |
|---|---|---|
| ScalingReplicaSet | deployment/trackr-api | contrôleur Deployment (kube-controller-manager) |
| SuccessfulCreate (x2) | replicaset/trackr-api-754dc48f79 | contrôleur ReplicaSet (kube-controller-manager) |
| Scheduled (x2) | pod/... | kube-scheduler |
| Pulling, Pulled, Created, Started | pod/... | kubelet du nœud, via containerd |

Horodatages (précision à la seconde) :

```console
$ kubectl get events -n trackr \
    -o custom-columns=HEURE:.firstTimestamp,RAISON:.reason,OBJET:.involvedObject.name \
    --sort-by=.firstTimestamp
HEURE                  RAISON              OBJET
2026-10-04T20:51:22Z   Scheduled           trackr-api-754dc48f79-v4zp7
2026-10-04T20:51:22Z   Pulled              trackr-api-754dc48f79-5fjzw
2026-10-04T20:51:22Z   Created             trackr-api-754dc48f79-5fjzw
2026-10-04T20:51:22Z   Started             trackr-api-754dc48f79-5fjzw
2026-10-04T20:51:22Z   ScalingReplicaSet   trackr-api
2026-10-04T20:51:22Z   Scheduled           trackr-api-754dc48f79-5fjzw
2026-10-04T20:51:22Z   SuccessfulCreate    trackr-api-754dc48f79
2026-10-04T20:51:22Z   SuccessfulCreate    trackr-api-754dc48f79
2026-10-04T20:51:22Z   Pulling             trackr-api-754dc48f79-v4zp7
2026-10-04T20:51:55Z   Created             trackr-api-754dc48f79-v4zp7
2026-10-04T20:51:55Z   Pulled              trackr-api-754dc48f79-v4zp7
2026-10-04T20:51:56Z   Started             trackr-api-754dc48f79-v4zp7
```

| Pod | Nœud | Scheduled | Pulling / Pulled | Started | Durée |
|---|---|---|---|---|---|
| ...-5fjzw | worker2 | 20:51:22 | image déjà présente | 20:51:22 | < 1 s |
| ...-v4zp7 | worker | 20:51:22 | 20:51:22 → 20:51:55 | 20:51:56 | 34 s |

Mesure plus fine du formateur (événements horodatés à la milliseconde) : control plane entre 61 et 81 ms, Pod A démarré à 0,55 s, Pod B à 34,05 s ; message `Successfully pulled image ... in 33.497s ... Image size: 31319663 bytes`.

Question 6 : non. L'écart vient du **téléchargement de l'image**, réalisé par le kubelet et containerd sur chaque nœud : le nœud qui avait déjà l'image démarre en moins d'une seconde. Si les stagiaires obtiennent deux démarrages rapides, l'image était déjà en cache partout (module 1).

## Étape 5 — etcd

```console
$ kubectl -n kube-system exec etcd-k8s-formation-control-plane -- etcdctl \
    --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key version
etcdctl version: 3.6.6
API version: 3.6
```

Ci-dessous, `etcdctl ...` désigne la même commande avec les certificats.

```console
$ etcdctl ... member list -w table
| 25336558eea45674 | started | k8s-formation-control-plane | https://10.89.2.5:2380 | https://10.89.2.5:2379 | false |
```

Un seul membre : quorum = 1, **aucune panne tolérée**. Il faudrait 3 membres pour en tolérer une.

```console
$ etcdctl ... get /registry/deployments/trackr --prefix --keys-only
/registry/deployments/trackr/trackr-api
$ etcdctl ... get /registry/pods/trackr --prefix --keys-only
/registry/pods/trackr/trackr-api-754dc48f79-5fjzw
/registry/pods/trackr/trackr-api-754dc48f79-v4zp7
```

Schéma : `/registry/<ressource>/<namespace>/<nom>`.

```console
$ etcdctl ... get /registry/deployments/trackr/trackr-api | strings | head -6
/registry/deployments/trackr/trackr-api
apps/v1
Deployment
trackr-api
trackr"
...
```

La valeur est encodée en **Protobuf** (binaire, préfixe `k8s`), format compact choisi par l'API Server ; seules quelques chaînes sont reconnaissables.

```console
$ etcdctl ... get /registry/deployments/trackr/trackr-api -w json   (métadonnées)
create_revision: 2182   mod_revision: 2420   version: 6
```

`version` est le nombre d'écritures sur cette clé depuis sa création (6 une minute après la création : création + mises à jour du statut par le contrôleur Deployment). `create_revision` et `mod_revision` sont des numéros de révision globaux du cluster etcd.

## Étape 6 — Kubelet et containerd

```console
$ kubectl get pods -n trackr -o wide
NAME                          READY   STATUS    RESTARTS   AGE   IP            NODE
trackr-api-754dc48f79-lxdpj   1/1     Running   0          38m   10.244.2.24   k8s-formation-worker2
trackr-api-754dc48f79-v4zp7   1/1     Running   0          40m   10.244.1.6    k8s-formation-worker

$ docker exec k8s-formation-worker systemctl status kubelet --no-pager
● kubelet.service - kubelet: The Kubernetes Node Agent
     Loaded: loaded (/etc/systemd/system/kubelet.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-10-04 20:37:02 UTC; 13min ago
   Main PID: 197 (kubelet)
             └─197 /usr/bin/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --config=/var/lib/kubelet/config.yaml --node-ip=10.89.2.4 ...
```

Fichier de configuration : `/var/lib/kubelet/config.yaml` (identité auprès de l'API : `/etc/kubernetes/kubelet.conf`).

```console
$ docker exec k8s-formation-worker crictl ps --name api --namespace trackr
CONTAINER       IMAGE           CREATED          STATE     NAME   ATTEMPT   POD ID          POD                           NAMESPACE
e9916fdcec341   662a7df19540e   39 minutes ago   Running   api    0         f16f361b15ddb   trackr-api-754dc48f79-v4zp7   trackr

$ docker exec k8s-formation-worker crictl version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  v2.2.0
RuntimeApiVersion:  v1
```

Piège : sans `--namespace`, `crictl ps --name api` montre aussi les conteneurs `api` des autres namespaces présents sur le nœud.

## Étape 7 — Réconciliation

```text
trackr-api-754dc48f79-5fjzw   1/1     Terminating         0          89s
trackr-api-754dc48f79-lxdpj   0/1     Pending             0          0s
trackr-api-754dc48f79-lxdpj   0/1     Pending             0          0s    k8s-formation-worker2
trackr-api-754dc48f79-lxdpj   0/1     ContainerCreating   0          0s    k8s-formation-worker2
trackr-api-754dc48f79-lxdpj   1/1     Running             0          1s    k8s-formation-worker2
```

Le **contrôleur ReplicaSet** a vu (via watch) qu'il n'y avait plus qu'un Pod correspondant au sélecteur alors que `spec.replicas` vaut 2 : il en a créé un nouveau, que le scheduler a placé. Mesuré : remplaçant créé 59 ms après la suppression, Running 830 ms après.

Suppression du ReplicaSet :

```console
$ kubectl delete rs -n trackr -l app.kubernetes.io/name=trackr-api --wait=false
replicaset.apps "trackr-api-754dc48f79" deleted from trackr namespace
$ kubectl get rs,pods -n trackr
NAME                                    DESIRED   CURRENT   READY   AGE
replicaset.apps/trackr-api-754dc48f79   2         2         2       3s

NAME                              READY   STATUS        RESTARTS   AGE
pod/trackr-api-754dc48f79-72r6k   1/1     Running       0          3s
pod/trackr-api-754dc48f79-dzk6f   1/1     Running       0          3s
pod/trackr-api-754dc48f79-lxdpj   1/1     Terminating   0          38m
pod/trackr-api-754dc48f79-v4zp7   1/1     Terminating   0          40m
```

Deux boucles de réconciliation s'enchaînent : le **ramasse-miettes** (garbage collector) supprime les Pods dont le propriétaire a disparu, le **contrôleur Deployment** recrée un ReplicaSet (même nom, car le suffixe est un hash du template), qui recrée 2 Pods.

## Bonus

```console
$ kubectl apply -n trackr -f trackr-api-trop-gourmand.yaml
pod/trackr-api-gourmand created
$ kubectl get pod trackr-api-gourmand -n trackr
NAME                  READY   STATUS    RESTARTS   AGE
trackr-api-gourmand   0/1     Pending   0          5s
$ kubectl describe pod trackr-api-gourmand -n trackr | sed -n '/Events:/,$p'
  Warning  FailedScheduling  4s (x2 over 5s)  default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Lecture : sur 3 nœuds, aucun ne passe le **filtrage**. Le control plane est écarté par son taint `node-role.kubernetes.io/control-plane:NoSchedule`, les 2 workers par manque de CPU allouable (64 CPU demandés). La **préemption** (évincer des Pods moins prioritaires) ne servirait à rien. Le Pod reste `Pending` ; le scheduler retentera à chaque changement du cluster.

```console
$ kubectl apply -n trackr -f trackr-api-service.yaml
service/trackr-api created
$ kubectl get svc,endpointslices -n trackr
NAME                 TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/trackr-api   ClusterIP   10.96.141.141   <none>        9898/TCP   5s

NAME                                              ADDRESSTYPE   PORTS   ENDPOINTS                AGE
endpointslice.discovery.k8s.io/trackr-api-bvwqk   IPv4          9898    10.244.1.6,10.244.2.24   5s

$ docker exec k8s-formation-worker iptables-save -t nat | grep "trackr/trackr-api"
-A KUBE-SEP-4CIWRTAMPXUFIXV6 -s 10.244.1.6/32 -m comment --comment "trackr/trackr-api:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-4CIWRTAMPXUFIXV6 -p tcp -m comment --comment "trackr/trackr-api:http" -m tcp -j DNAT --to-destination 10.244.1.6:9898
-A KUBE-SEP-4IDFLEQNRF7XJRXI -s 10.244.2.24/32 -m comment --comment "trackr/trackr-api:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-4IDFLEQNRF7XJRXI -p tcp -m comment --comment "trackr/trackr-api:http" -m tcp -j DNAT --to-destination 10.244.2.24:9898
-A KUBE-SERVICES -d 10.96.141.141/32 -p tcp -m comment --comment "trackr/trackr-api:http cluster IP" -m tcp --dport 9898 -j KUBE-SVC-ONPYCELVNNCQ4NAD
-A KUBE-SVC-ONPYCELVNNCQ4NAD ! -s 10.244.0.0/16 -d 10.96.141.141/32 -p tcp ... -j KUBE-MARK-MASQ
-A KUBE-SVC-ONPYCELVNNCQ4NAD -m comment --comment "trackr/trackr-api:http -> 10.244.1.6:9898" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-4CIWRTAMPXUFIXV6
-A KUBE-SVC-ONPYCELVNNCQ4NAD -m comment --comment "trackr/trackr-api:http -> 10.244.2.24:9898" -j KUBE-SEP-4IDFLEQNRF7XJRXI
```

- Répartition : la chaîne `KUBE-SVC-...` envoie vers le premier endpoint avec une **probabilité 0,5** ; le reste (50 %) tombe sur la règle suivante, sans condition. Avec N endpoints, les probabilités valent 1/N, 1/(N-1)… jusqu'à 1 : chaque Pod reçoit la même part.
- Traduction : `DNAT --to-destination 10.244.x.x:9898` dans chaque chaîne `KUBE-SEP-...`.

## Pour aller plus loin

```console
$ kubectl get leases -n kube-node-lease
NAME                          HOLDER                        AGE
k8s-formation-control-plane   k8s-formation-control-plane   15m
k8s-formation-worker          k8s-formation-worker          15m
k8s-formation-worker2         k8s-formation-worker2         15m
$ kubectl get lease k8s-formation-worker -n kube-node-lease -o jsonpath='{.spec.renewTime} {.spec.leaseDurationSeconds}'
2026-10-04T20:52:31.128724Z 40
```

Chaque kubelet renouvelle son Lease (durée 40 s) : c'est le battement de cœur que le contrôleur Node surveille. `kubectl get --raw /apis` liste 21 groupes d'API sur le lab.


