# TP 4 — Configurer les pods TrackR

Module 4 — Configuration des pods et des conteneurs. Durée indicative : 50 minutes.

## Contexte

L'équipe d'exploitation de Logivia prépare la mise en production de TrackR. Les premiers essais ont révélé trois problèmes : le cache Redis perd tous les colis suivis à chaque redémarrage de son pod, les deux réplicas de l'API se retrouvent parfois sur le même nœud, et personne ne sait combien de CPU et de mémoire réserver. Votre mission : écrire les manifestes de TrackR avec des ressources dimensionnées, une configuration externalisée, un cache persistant et un placement maîtrisé.

Briques à déployer dans le namespace `trackr` :

| Brique | Image | Port |
|---|---|---|
| `trackr-cache` | `redis:7.4-alpine` | 6379 |
| `trackr-api` | `ghcr.io/stefanprodan/podinfo:6.9.2` | 9898 |
| `trackr-front` | `ghcr.io/stefanprodan/podinfo:6.9.2` | 9898 |

Utilisez les labels `app.kubernetes.io/name: <brique>` et `app.kubernetes.io/part-of: trackr` sur tous les objets.

## Prérequis

- Cluster de lab démarré (`kubectl get nodes` affiche 3 nœuds `Ready`).
- metrics-server opérationnel (`kubectl top nodes` répond).
- Un répertoire de travail, par exemple `~/tp04/`, pour vos fichiers YAML.

```bash
kubectl create namespace trackr
kubectl config set-context --current --namespace=trackr
```

## Étape 1 — Externaliser la configuration (8 min)

Créez un fichier `config.yaml` contenant :

1. Une ConfigMap `trackr-config` avec trois clés destinées à devenir des variables d'environnement :
   - `PODINFO_UI_MESSAGE` = `TrackR - suivi des colis Logivia`
   - `PODINFO_UI_COLOR` = `#438ecc`
   - `PODINFO_LEVEL` = `info`
2. Une seconde ConfigMap `trackr-fichiers` avec une clé `trackr.properties` contenant trois lignes : `zone=europe-ouest`, `retention.jours=30`, `alertes.retard.heures=48`.
3. Un Secret `trackr-api-secrets` de type `Opaque` avec une clé `API_TOKEN` (valeur de votre choix). Utilisez `stringData` pour saisir la valeur en clair.

Appliquez, puis affichez la valeur stockée du jeton, d'abord brute, puis décodée.

Question : pourquoi deux ConfigMaps plutôt qu'une ? (Indice : pensez à ce que fera `envFrom` à l'étape 3.)

## Étape 2 — Un cache Redis persistant (10 min)

Créez `cache.yaml` contenant :

1. Un PersistentVolumeClaim `trackr-cache-data` : 1 Gi, mode d'accès `ReadWriteOnce`, StorageClass `standard`.
2. Un Deployment `trackr-cache` à 1 réplica, stratégie `Recreate`, qui lance `redis-server --appendonly yes` et monte le PVC sur `/data`.
   - requests : 50m CPU, 64 Mi ; limits : 250m CPU, 128 Mi.
3. Un Service `trackr-cache` sur le port 6379.

Appliquez puis observez immédiatement `kubectl get pvc`. Notez le statut du PVC avant et après le démarrage du pod, et le nœud choisi.

Vérification de la persistance :

```bash
kubectl exec deploy/trackr-cache -- redis-cli SET colis:LGV-1042 "en transit - Lyon"
kubectl delete pod -l app.kubernetes.io/name=trackr-cache
kubectl rollout status deploy/trackr-cache
kubectl exec deploy/trackr-cache -- redis-cli GET colis:LGV-1042
```

Questions :

- Pourquoi la stratégie `Recreate` plutôt que `RollingUpdate` avec un volume `ReadWriteOnce` ?
- Que deviennent le PV et les données si l'on supprime le PVC ? (Regardez la colonne `RECLAIMPOLICY` de `kubectl get sc`.)

## Étape 3 — L'API : ressources, configuration, init container (12 min)

Créez `api.yaml` avec un Deployment `trackr-api` à 2 réplicas et un Service `trackr-api` (port 9898).

Le conteneur `api` :

- image podinfo, commande `./podinfo`, arguments `--port=9898` et `--cache-server=tcp://trackr-cache:6379` ;
- toutes les clés de `trackr-config` en variables d'environnement (`envFrom`) ;
- la variable `API_TOKEN` lue dans le Secret (`secretKeyRef`) ;
- la ConfigMap `trackr-fichiers` montée dans `/etc/trackr/config`, le Secret monté dans `/etc/trackr/secrets` avec `defaultMode: 0440` ;
- requests : 50m CPU, 32 Mi ; limits : 250m CPU, 64 Mi ;
- readinessProbe HTTP sur `/readyz`.

Ajoutez un init container `wait-cache` (busybox:1.37) qui boucle tant que `nc -z -w 2 trackr-cache 6379` échoue.

Appliquez et vérifiez :

```bash
kubectl exec deploy/trackr-api -c api -- sh -c 'env | grep -E "^(PODINFO_|API_TOKEN)"'
kubectl exec deploy/trackr-api -c api -- cat /etc/trackr/config/trackr.properties
kubectl exec deploy/trackr-api -c api -- cat /etc/trackr/secrets/API_TOKEN
kubectl logs deploy/trackr-api -c wait-cache
```

Si la lecture du fichier secret échoue avec `Permission denied`, cherchez sous quel utilisateur tourne podinfo (`kubectl exec ... -- id`) et quel champ du `securityContext` du pod permet de donner le groupe des volumes à ce processus.

## Étape 4 — Placement : répartir l'API et le front (8 min)

1. Ajoutez à `trackr-api` une **anti-affinité préférée** (poids 100) sur `kubernetes.io/hostname`, pour que les réplicas évitent de partager un nœud.
2. Créez `front.yaml` : Deployment `trackr-front` à 2 réplicas (podinfo, `--backend-url=http://trackr-api:9898/echo`, `envFrom` sur `trackr-config`, mêmes ressources que l'API) et Service `trackr-front`. Répartissez les réplicas avec une `topologySpreadConstraints` : `maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: DoNotSchedule`.
3. Affichez la répartition :

```bash
kubectl get pod -l app.kubernetes.io/part-of=trackr -o wide
```

4. Lancez plusieurs fois `kubectl rollout restart deploy/trackr-front` puis observez la répartition après chaque rollout. Restez-vous toujours à un pod par worker ? Consultez la documentation de `matchLabelKeys` et de `nodeTaintsPolicy`, corrigez la contrainte, puis recommencez.

## Étape 5 — Mesurer et vérifier la QoS (7 min)

1. Lancez un générateur de charge :

```bash
kubectl apply -f code/manifests/module-04/24-charge-trackr.yaml
```

2. Après une minute, relevez `kubectl top pod -l app.kubernetes.io/part-of=trackr` à trois reprises. Comparez aux requests et limits de chaque brique : vos valeurs sont-elles réalistes ? Faut-il en changer ?
3. Affichez la classe de QoS de chaque pod TrackR. Quelle modification ferait passer `trackr-cache` en `Guaranteed` ? Quel en serait l'intérêt ?

```bash
kubectl get pod -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,NOEUD:.spec.nodeName
```

## Étape 6 — Vérification finale (5 min)

```bash
kubectl run t --rm -i --restart=Never --image=busybox:1.37 -- sh -c \
  'wget -q -O /dev/null --post-data="en transit - Lyon" http://trackr-api:9898/cache/LGV-1042; \
   wget -q -O- http://trackr-api:9898/cache/LGV-1042'
kubectl delete pod -l app.kubernetes.io/name=trackr-cache
kubectl rollout status deploy/trackr-cache
# relancer la lecture : la valeur doit toujours être là
```

Critères de réussite :

- [ ] 5 pods TrackR `Running`, aucun redémarrage.
- [ ] Les 2 réplicas de l'API et les 2 réplicas du front sont sur deux workers différents, y compris après un `rollout restart`.
- [ ] La donnée `LGV-1042` survit à la suppression du pod Redis.
- [ ] L'API lit ses variables, son fichier de propriétés et son jeton.
- [ ] Vous savez expliquer la classe de QoS de chaque pod.

## Pour aller plus loin (facultatif)

- Étiquetez `k8s-formation-worker2` avec `disque=ssd` et forcez `trackr-cache` sur ce nœud avec un `nodeSelector`. Que se passe-t-il si le PV a déjà été créé sur l'autre worker ?
- Posez le taint `dedie=cache:NoSchedule` sur worker2 et ajoutez la toleration correspondante au cache. Retirez le taint et le label à la fin.
- Modifiez une valeur de `trackr-fichiers` et mesurez le délai avant que le fichier change dans le conteneur ; comparez avec la variable `PODINFO_UI_MESSAGE`.

## Nettoyage

```bash
kubectl delete -f code/manifests/module-04/24-charge-trackr.yaml --ignore-not-found
kubectl label node --all disque- dedie- 2>/dev/null
# garder le namespace trackr : il sert de base au module 5
```
