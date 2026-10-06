# TP 3 — Solution  : préparer les accès de l'équipe TrackR


Fichiers de la solution (ne pas les déposer dans `code/`) :

- `solutions/tp/tp-03-kind-recette.yaml` : cluster de recette mono-nœud ;
- `solutions/tp/tp-03-smoke-test.yaml` : test de fumée (Deployment, Service, Job).

## Démarche attendue

1. Partir de `kind get kubeconfig`, jamais de `~/.kube/config`.
2. Niveau 2 : écrire un fichier kind mono-nœud sans `extraPortMappings`, créer le cluster avec `--kubeconfig` séparé, fusionner avec `--flatten`.
3. Renommer les contextes, fixer les namespaces par défaut, créer le namespace `recette` du côté du contexte `recette`, finir sur `lab-trackr`.
4. Comparer client et serveur (`kubectl version`) : écart de ±1 mineure.
5. Rapport de santé avec preuves, test de fumée écrit à la main, lancé après le déploiement (ou avec `backoffLimit`).
6. Questions kubeadm : trouver l'information sur le disque du nœud ET dans les ConfigMaps de `kube-system`, et expliquer le lien entre les deux.

## Vérificateur : état de départ

```console
$ KCFG=~/tp-03/equipe.kubeconfig bash code/tp/tp-03-verifier.sh
Kubeconfig contrôlé : ./equipe.kubeconfig — namespaces attendus : trackr (lab-trackr), recette (recette)

[KO] Le fichier kubeconfig d'équipe existe et kubectl sait le lire
[KO] Le kubeconfig est autonome (au moins deux contextes, aucun chemin de fichier local)
[KO] Le contexte lab-trackr existe et son namespace par défaut est trackr
[KO] Le contexte lab-trackr atteint le cluster de lab k8s-formation
[KO] Le contexte recette existe et son namespace par défaut est recette
[KO] Le contexte recette répond et le namespace recette existe de son côté
[KO] Le contexte courant du fichier livré est lab-trackr
[KO] kubectl est dans l'écart de version supporté pour les deux contextes
[KO] Des Pods applicatifs du test de fumée (role=smoke-test) sont prêts sur au moins deux nœuds distincts
[KO] Un Service du test de fumée (role=smoke-test) a au moins deux points de terminaison prêts
[KO] Un Job du test de fumée (role=smoke-test) s'est terminé avec succès
[KO] Le Job du test de fumée joint le Service par son nom DNS complet

Score : 0/12
```

## Mission 1 — Kubeconfig de l'équipe

Fichier kind du cluster de recette (`tp-03-kind-recette.yaml`) :

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: trackr-recette
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6445          # facultatif : sans cette ligne, kind choisit un port libre
nodes:
  - role: control-plane
    image: kindest/node:v1.35.0
```

```console
$ cd ~/tp-03
$ kind create cluster --config kind-recette.yaml --kubeconfig ./recette.kubeconfig
...
Set kubectl context to "kind-trackr-recette"
$ kind get kubeconfig --name k8s-formation > lab.kubeconfig
$ KUBECONFIG=lab.kubeconfig:recette.kubeconfig kubectl config view --flatten > equipe.kubeconfig
$ export KUBECONFIG=$PWD/equipe.kubeconfig
$ kubectl config rename-context kind-k8s-formation lab-trackr
Context "kind-k8s-formation" renamed to "lab-trackr".
$ kubectl config rename-context kind-trackr-recette recette
Context "kind-trackr-recette" renamed to "recette".
$ kubectl config set-context lab-trackr --namespace trackr
Context "lab-trackr" modified.
$ kubectl config set-context recette --namespace recette
Context "recette" modified.
$ kubectl config use-context recette
Switched to context "recette".
$ kubectl create namespace recette
namespace/recette created
$ kubectl config use-context lab-trackr
Switched to context "lab-trackr".
$ kubectl config get-contexts
CURRENT   NAME         CLUSTER              AUTHINFO             NAMESPACE
*         lab-trackr   kind-k8s-formation   kind-k8s-formation   trackr
          recette      kind-trackr-recette  kind-trackr-recette  recette
$ kubectl config view --minify -o jsonpath='{..namespace}'
trackr
$ kubectl --context recette config view --minify | grep server
    server: https://127.0.0.1:6445
```

Création du cluster mono-nœud mesurée : 13 s (image déjà présente). Avec Podman : `KIND_EXPERIMENTAL_PROVIDER=podman` devant `kind create` et `kind get kubeconfig`.

Niveau 1 (même cluster), à la place de la création du cluster kind :

```console
$ kind get kubeconfig --name k8s-formation > equipe.kubeconfig
$ export KUBECONFIG=$PWD/equipe.kubeconfig
$ kubectl config rename-context kind-k8s-formation lab-trackr
$ kubectl config set-context lab-trackr --namespace trackr
$ kubectl config set-context recette --cluster kind-k8s-formation --user kind-k8s-formation --namespace recette
Context "recette" created.
$ kubectl create namespace recette
```

(rejoué avec `NS_RECETTE=trackr-m03-recette` : 12/12.)

Compatibilité des versions :

```console
$ kubectl version
Client Version: v1.36.1
Kustomize Version: v5.8.1
Server Version: v1.35.0
$ kubectl --context recette version
Client Version: v1.36.1
Kustomize Version: v5.8.1
Server Version: v1.35.0
```

Plage supportée pour un serveur v1.35 : kubectl 1.34, 1.35 ou 1.36 (±1 mineure). Le fichier est un secret : il contient la clé privée d'un certificat client du groupe `kubeadm:cluster-admins` (vu en démo), donc les pleins pouvoirs sur les deux clusters.

## Mission 2 — Rapport de santé et test de fumée

Preuves attendues (extraits réels) :

```console
$ kubectl get nodes -o wide
NAME                          STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...   KERNEL-VERSION            CONTAINER-RUNTIME
k8s-formation-control-plane   Ready    control-plane   9h    v1.35.0   10.89.2.5     ...   6.11.3-200.fc40.aarch64   containerd://2.2.0
k8s-formation-worker          Ready    <none>          9h    v1.35.0   10.89.2.4     ...   6.11.3-200.fc40.aarch64   containerd://2.2.0
k8s-formation-worker2         Ready    <none>          9h    v1.35.0   10.89.2.6     ...   6.11.3-200.fc40.aarch64   containerd://2.2.0
$ kubectl get --raw='/readyz?verbose' | grep -E 'ping|etcd|check'
[+]ping ok
[+]etcd ok
[+]etcd-readiness ok
readyz check passed
$ kubectl get pods -n kube-system
coredns-7d764666f9-vdwcd                              1/1  Running  0  k8s-formation-control-plane
coredns-7d764666f9-ztlpc                              1/1  Running  0  k8s-formation-control-plane
etcd-k8s-formation-control-plane                      1/1  Running  0  k8s-formation-control-plane
kube-apiserver-k8s-formation-control-plane            1/1  Running  0  k8s-formation-control-plane
kube-controller-manager-k8s-formation-control-plane   1/1  Running  0  k8s-formation-control-plane
kube-scheduler-k8s-formation-control-plane            1/1  Running  0  k8s-formation-control-plane
...   (kindnet et kube-proxy : un par nœud, metrics-server)
$ kubectl -n kube-system get deploy coredns ; kubectl -n kube-system get svc kube-dns
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           9h
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   9h
$ kubectl top nodes
NAME                          CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-formation-control-plane   82m          2%       839Mi           14%
k8s-formation-worker          107m         2%       430Mi           7%
k8s-formation-worker2         66m          1%       394Mi           6%
```

`kubectl get componentstatuses` répond encore (`Healthy`) mais affiche `Warning: v1 ComponentStatus is deprecated in v1.19+` : accepter la réponse si le stagiaire le signale, préférer `/readyz?verbose` et l'état des Pods statiques.

Test de fumée (`tp-03-smoke-test.yaml`) :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-web
  labels: {role: smoke-test}
spec:
  replicas: 2
  selector:
    matchLabels: {app: smoke-web}
  template:
    metadata:
      labels: {app: smoke-web, role: smoke-test}
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.9.2
          ports: [{containerPort: 9898}]
          readinessProbe:
            httpGet: {path: /readyz, port: 9898}
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-web
  labels: {role: smoke-test}
spec:
  selector: {app: smoke-web}
  ports: [{port: 9898, targetPort: 9898}]
---
apiVersion: batch/v1
kind: Job
metadata:
  name: smoke-client
  labels: {role: smoke-test}
spec:
  backoffLimit: 2
  template:
    metadata:
      labels: {role: smoke-test}
    spec:
      restartPolicy: Never
      containers:
        - name: client
          image: busybox:1.37
          command: ["sh", "-c"]
          args:
            - |
              set -e
              CIBLE=smoke-web.trackr.svc.cluster.local
              nslookup "$CIBLE"
              for i in 1 2 3 4 5 6; do
                wget -qO- "http://$CIBLE:9898/api/info" | grep '"hostname"'
              done
              echo "TEST DE FUMEE OK"
```

```console
$ kubectl apply -f smoke-test.yaml
deployment.apps/smoke-web created
service/smoke-web created
job.batch/smoke-client created
$ kubectl rollout status deploy/smoke-web --timeout=120s
deployment "smoke-web" successfully rolled out
$ kubectl wait --for=condition=complete job/smoke-client --timeout=120s
job.batch/smoke-client condition met
$ kubectl get pods -o wide
NAME                        READY   STATUS      RESTARTS   AGE   IP             NODE
smoke-client-7tpkb          0/1     Completed   0          3s    10.244.1.182   k8s-formation-worker
smoke-client-f89zb          0/1     Error       0          14s   10.244.1.181   k8s-formation-worker
smoke-web-5dcb4cfb5-k7p7l   1/1     Running     0          14s   10.244.1.180   k8s-formation-worker
smoke-web-5dcb4cfb5-qmgdx   1/1     Running     0          14s   10.244.2.21    k8s-formation-worker2
$ kubectl logs smoke-client-f89zb | tail -1
wget: can't connect to remote host (10.96.208.15): Connection refused
$ kubectl logs smoke-client-7tpkb
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	smoke-web.trackr.svc.cluster.local
Address: 10.96.208.15

  "hostname": "smoke-web-5dcb4cfb5-k7p7l",
  "hostname": "smoke-web-5dcb4cfb5-k7p7l",
  "hostname": "smoke-web-5dcb4cfb5-qmgdx",
  "hostname": "smoke-web-5dcb4cfb5-qmgdx",
  "hostname": "smoke-web-5dcb4cfb5-qmgdx",
  "hostname": "smoke-web-5dcb4cfb5-k7p7l",
TEST DE FUMEE OK
$ kubectl get endpointslices -l kubernetes.io/service-name=smoke-web
NAME              ADDRESSTYPE   PORTS   ENDPOINTS                  AGE
smoke-web-h6zc2   IPv4          9898    10.244.2.21,10.244.1.180   14s
```

Lecture : le premier essai du Job (créé en même temps que les Pods) a échoué, aucun Pod n'étant encore prêt ; le second a réussi grâce à `backoffLimit`. C'est un bon sujet de discussion : un test de fumée doit attendre que sa cible soit prête. Les réponses alternent entre deux Pods sur deux nœuds : scheduler, CNI inter-nœuds, kube-proxy et CoreDNS sont validés en une seule sortie. Job complet en 14 s.

## Mission 3 — Questions kubeadm

### Q1 — Capacité en Pods d'un nœud worker

```console
$ kubectl get node k8s-formation-worker -o jsonpath='{.status.capacity.pods}'
110
$ docker exec k8s-formation-worker systemctl cat kubelet | grep -E 'CONFIG_ARGS=|EnvironmentFile'
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
$ docker exec k8s-formation-worker grep -E 'cgroupDriver|staticPodPath|maxPods' /var/lib/kubelet/config.yaml
cgroupDriver: systemd
staticPodPath: /etc/kubernetes/manifests
$ kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | head -3
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
```

Réponse attendue :

- **110 Pods** par nœud : `maxPods` n'est pas écrit dans `/var/lib/kubelet/config.yaml`, le kubelet applique donc sa valeur par défaut (110), visible dans `status.capacity.pods`.
- Le fichier est passé au kubelet par le drop-in systemd `10-kubeadm.conf` (`--config=/var/lib/kubelet/config.yaml`) ; les options propres au nœud (`--node-ip`…) sont dans `kubeadm-flags.env`.
- Origine : la ConfigMap `kube-system/kubelet-config`, écrite par `kubeadm init` et téléchargée par chaque nœud lors de `kubeadm join` (phase `kubelet-start`).
- Modifier pour tous les nœuds : éditer la ConfigMap `kubelet-config`, puis sur **chaque** nœud `kubeadm upgrade node phase kubelet-config` et redémarrer le kubelet (un nœud à la fois, après `drain`).

Procédure rejouée sur le cluster jetable (jamais sur le lab partagé) :

```console
# kubectl -n kube-system get cm kubelet-config -o yaml | sed '...ajout de maxPods: 50...' | kubectl apply -f -
configmap/kubelet-config configured
# kubeadm upgrade node phase kubelet-config
[patches] Applied patch of type "application/strategic-merge-patch+json" to target "kubeletconfiguration"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!
# grep maxPods /var/lib/kubelet/config.yaml
maxPods: 50
# systemctl restart kubelet ; kubectl get node m03-jetable-control-plane -o jsonpath='{.status.capacity.pods}'
50
```

À noter sur Podman rootless : `config.yaml` contient aussi `featureGates: KubeletInUserNamespace: true`, ajouté par kind pour ce mode ; il n'apparaît pas sur un poste Docker.

### Q2 — Le nom `api.logivia.lab`

Preuve sans DNS ni `/etc/hosts` :

```console
$ kubectl --tls-server-name api.logivia.lab get ns
Unable to connect to the server: tls: failed to verify certificate: x509: certificate is valid for k8s-formation-control-plane, kubernetes, kubernetes.default, kubernetes.default.svc, kubernetes.default.svc.cluster.local, localhost, not api.logivia.lab
$ docker exec k8s-formation-control-plane openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:k8s-formation-control-plane, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:localhost, IP Address:10.96.0.1, IP Address:10.89.2.5, IP Address:127.0.0.1
$ kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -A2 certSANs
  certSANs:
  - localhost
  - 127.0.0.1
```

Réponse attendue :

- Le nom est **refusé** : il n'est pas dans les SAN du certificat de l'API server.
- Noms acceptés : le nom du nœud, `kubernetes` et ses variantes `.default.svc.cluster.local`, `localhost` ; adresses : `10.96.0.1` (première adresse du réseau des Services, celle du Service `kubernetes`), l'IP du nœud, `127.0.0.1`.
- `localhost` et `127.0.0.1` viennent de `apiServer.certSANs` dans la ClusterConfiguration (ConfigMap `kubeadm-config`), que kind a renseignée : c'est pour cela que le kubeconfig de l'hôte (`https://127.0.0.1:<port>`) est accepté.
- Procédure (documentation « Reconfiguring a kubeadm cluster ») : ajouter le nom dans `certSANs`, déplacer `apiserver.crt` et `apiserver.key` hors de `/etc/kubernetes/pki` (kubeadm ne régénère pas un certificat existant), `kubeadm init phase certs apiserver --config <fichier>`, redémarrer le conteneur kube-apiserver, puis `kubeadm init phase upload-config kubeadm --config <fichier>` pour que la configuration stockée reste la référence. À refaire sur chaque control-plane.

Procédure rejouée sur le cluster jetable :

```console
# kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /root/kubeadm.yaml
# (ajout de « - api.logivia.lab » sous certSANs)
# mkdir -p /root/ancien && mv /etc/kubernetes/pki/apiserver.{crt,key} /root/ancien/
# kubeadm init phase certs apiserver --config /root/kubeadm.yaml
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [api.logivia.lab kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local localhost m03-jetable-control-plane] and IPs [10.96.0.1 10.89.2.28 127.0.0.1]
# crictl ps --name kube-apiserver -q | xargs crictl stop
# kubeadm init phase upload-config kubeadm --config /root/kubeadm.yaml
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
$ kubectl --context recette --tls-server-name api.logivia.lab get ns recette
NAME      STATUS   AGE
recette   Active   98s
```

## Vérificateur : solution

```console
$ KCFG=~/tp-03/equipe.kubeconfig bash code/tp/tp-03-verifier.sh
Kubeconfig contrôlé : /home/.../tp-03/equipe.kubeconfig — namespaces attendus : trackr (lab-trackr), recette (recette)

[OK] Le fichier kubeconfig d'équipe existe et kubectl sait le lire
[OK] Le kubeconfig est autonome (au moins deux contextes, aucun chemin de fichier local)
[OK] Le contexte lab-trackr existe et son namespace par défaut est trackr
[OK] Le contexte lab-trackr atteint le cluster de lab k8s-formation
[OK] Le contexte recette existe et son namespace par défaut est recette
[OK] Le contexte recette répond et le namespace recette existe de son côté
[OK] Le contexte courant du fichier livré est lab-trackr
[OK] kubectl est dans l'écart de version supporté pour les deux contextes
[OK] Des Pods applicatifs du test de fumée (role=smoke-test) sont prêts sur au moins deux nœuds distincts
[OK] Un Service du test de fumée (role=smoke-test) a au moins deux points de terminaison prêts
[OK] Un Job du test de fumée (role=smoke-test) s'est terminé avec succès
[OK] Le Job du test de fumée joint le Service par son nom DNS complet

Score : 12/12
```

Score intermédiaire observé (kubeconfig terminé, test de fumée pas encore écrit) : 8/12.

## Erreurs fréquentes et déblocage

| Symptôme | Cause probable | Piste à donner |
|---|---|---|
| `~/.kube/config` modifié, contextes `lab-trackr` dans la config perso | `kubectl config` lancé sans `--kubeconfig` ni `KUBECONFIG` | Travailler avec `export KUBECONFIG=~/tp-03/equipe.kubeconfig` ; nettoyer avec `kubectl config delete-context` |
| `[KO]` autonome | Fusion sans `--flatten` (chemins vers des fichiers), ou kubeconfig minikube | `kubectl config view --flatten` embarque les certificats |
| `kind create` échoue : `port is already allocated` | `extraPortMappings` 30080 recopié du lab, ou `apiServerPort` déjà pris | Retirer le mapping, laisser kind choisir le port de l'API |
| `[KO]` recette répond | Namespace `recette` créé sur le mauvais cluster (contexte courant `lab-trackr`) | Basculer sur `recette` avant `create namespace`, ou `--context recette` |
| Le Job reste en `Error` | Job lancé avant que les Pods soient prêts, `backoffLimit: 0` | `rollout status` avant le Job, ou `backoffLimit` |
| Les deux Pods sur le même nœud | Placement du scheduler (rare avec 2 workers vides) | Supprimer un Pod ou passer à 3 réplicas ; la répartition forcée (anti-affinité) est au module 4 |
| `[KO]` nom DNS complet | Job qui appelle `smoke-web` tout court | Le ticket exige `<service>.<namespace>.svc.cluster.local` : c'est ce qu'on teste du DNS |
| Q1 répondue « 110 lu dans config.yaml » | Valeur absente du fichier | Faire chercher `maxPods` : valeur par défaut du kubelet |
| Q2 : le stagiaire modifie `/etc/hosts` | Réflexe naturel | `--tls-server-name` teste le certificat sans toucher au DNS |

## Nettoyage (rejoué)

```console
$ kubectl delete deploy,svc,job -l role=smoke-test
$ kind delete cluster --name trackr-recette --kubeconfig ./recette.kubeconfig
Deleting cluster "trackr-recette" ...
Deleted nodes: ["trackr-recette-control-plane"]
$ rm -f lab.kubeconfig recette.kubeconfig
```


