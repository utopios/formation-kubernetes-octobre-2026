# TP 2 — Enquête « qui a fait quoi ? » dans le cluster TrackR

Module 2 — Architecture. Durée : 40 minutes (bonus : 10 minutes). En binôme de préférence.

## Contexte

Lundi, 8 h. La nuit a été agitée sur **TrackR**, l'application de suivi de colis de **Logivia**. La supervision a levé plusieurs alertes, mais elle ne voit que des **symptômes** : un lot qui ne démarre pas, des Pods qui apparaissent et disparaissent, une configuration qui change, un cache qui redémarre.

La responsable d'exploitation vous transmet le journal de supervision et vous écrit :

> « Avant de toucher à quoi que ce soit, je veux savoir, pour chaque alerte, **quel composant de Kubernetes a agi** et **sur quelle preuve** vous l'affirmez. Pas d'intuition : une valeur lue dans le cluster. Ensuite seulement, remettez TrackR en conformité avec le cahier des charges. »

Vous ne referez pas la démo : vous allez vous servir de ce qu'elle a montré (rôle de chaque composant, événements, objets stockés dans etcd) pour mener une enquête sur des faits que vous n'avez pas provoqués vous-même.

## Le cahier des charges de TrackR (extrait)

| Objet | Exigence |
|---|---|
| `trackr-api` | 2 réplicas, tous prêts |
| ConfigMap `trackr-api-config` | `LOG_LEVEL` à `info` en production |
| `trackr-export` | le lot d'export tourne en permanence ; besoin mesuré par l'équipe : **480 Mi** de mémoire |
| LimitRange `trackr-limites` | règle de l'équipe plateforme : à conserver telle quelle |

## Règles du jeu

- Travaillez dans le namespace `trackr` (le formateur peut vous en attribuer un autre).
- **Enquêtez d'abord, corrigez ensuite.** Certaines preuves sont écrasées par vos propres corrections : relevez-les avant.
- Une **preuve** est une donnée lue dans le cluster : un champ d'objet, un événement et son émetteur, une ligne de journal, une clé d'etcd. « C'est forcément le scheduler » n'est pas une preuve.
- Pour chaque situation, nommez **un** composant parmi : API Server, etcd, scheduler, controller-manager (en précisant **lequel de ses contrôleurs**), kubelet, kube-proxy, runtime. Quand un client (un humain, un outil, un script) est à l'origine d'une demande, donnez aussi son nom.
- Observation seulement côté control plane et nœuds : aucune modification de `/etc/kubernetes/manifests`, aucun label ni taint sur les nœuds.
- Ne lisez pas `code/tp/tp-02/scenario.sh` avant la fin : en production, personne ne vous donne le script de l'incident.

## Étape 1 — Rejouer la nuit (5 min)

Depuis la racine du dépôt :

```bash
bash code/tp/tp-02/scenario.sh
cp code/tp/tp-02/reponses-modele.txt reponses.txt
cat journal-astreinte.txt
```

Le script repart d'un état propre dans `trackr` (il supprime puis recrée les objets du TP, y compris le `trackr-api` de la démo) et dure environ 45 secondes. Avec un autre namespace : `NS=trackr-<votre-nom> bash code/tp/tp-02/scenario.sh`.

Après la ligne de livraison, le journal liste six alertes : dans l'ordre, les situations A, B, C, D, F, puis l'audit qualité de la situation E. Les noms de Pods du journal sont ceux de **votre** cluster.

## Étape 2 — Mener l'enquête (25 min)

Pour chaque situation, répondez aux questions, puis complétez `reponses.txt` (une ligne `composant`, une ligne `preuve`, et une ligne `client` pour C et D) et le tableau de fin de document.

### Situation A — Le lot `trackr-export` ne démarre pas

Quel composant refuse de faire démarrer le Pod ? Pour quelle raison exacte, nœud par nœud ? Pourquoi le control plane lui-même n'est-il pas candidat ?

<details><summary>Indice 1</summary>

Regardez à quelle étape du parcours du Pod on s'est arrêté : a-t-il un nœud ? Un conteneur a-t-il seulement été créé ?

</details>

<details><summary>Indice 2</summary>

Les événements d'un objet portent leur émetteur. Affichez-les avec des colonnes choisies : `kubectl get events -o custom-columns=...` avec les champs `.reason`, `.reportingComponent` et `.message`.

</details>

<details><summary>Indice 3</summary>

Comparez la demande de ressources du conteneur (`kubectl explain pod.spec.containers.resources`) avec la mémoire allouable des nœuds (`.status.allocatable` des Nodes).

</details>

### Situation B — Un Pod `trackr-api` a été remplacé

Le journal donne le nom du Pod disparu et celui du Pod apparu. Quel composant a **créé** le nouveau Pod, et à partir de quelle information ? Quel composant a **arrêté** les conteneurs de l'ancien ? Pouvez-vous savoir **qui** a demandé la suppression ?

<details><summary>Indice 1</summary>

Un Pod créé par un humain et un Pod créé par un contrôleur ne portent pas les mêmes métadonnées. Cherchez à qui appartient le nouveau Pod.

</details>

<details><summary>Indice 2</summary>

Champs utiles : `.metadata.ownerReferences` et `.metadata.managedFields` (option `--show-managed-fields` de `kubectl get -o yaml`). Les événements de l'ancien Pod existent encore, même si le Pod a disparu : filtrez-les avec `--field-selector involvedObject.name=...`.

</details>

<details><summary>Indice 3</summary>

Pour la dernière question : une suppression n'écrit rien dans l'objet (il n'existe plus). Quel mécanisme de l'API Server, désactivé par défaut, garderait l'auteur de chaque requête ?

</details>

### Situation C — `trackr-api` est passé à 4 Pods

Quel **client** a demandé 4 réplicas, par quelle porte de l'API, et à quelle heure ? Quel **contrôleur** a ensuite transformé cette demande en un ReplicaSet à 4 Pods ?

<details><summary>Indice 1</summary>

L'API Server garde, dans chaque objet, la liste des clients qui ont écrit chaque champ.

</details>

<details><summary>Indice 2</summary>

Lisez `.metadata.managedFields` du Deployment : pour chaque entrée, `manager`, `operation`, `subresource` et les champs possédés. Une entrée n'a pas d'horodatage : trouvez l'heure ailleurs.

</details>

<details><summary>Indice 3</summary>

L'heure et le contrôleur sont dans l'événement `ScalingReplicaSet` du Deployment.

</details>

### Situation D — La ConfigMap `trackr-api-config` a changé

Quel client a modifié quel champ, et quand ? Quel composant a validé puis enregistré cette écriture ? Les Pods `trackr-api` qui tournent actuellement utilisent-ils la nouvelle valeur ? Prouvez-le.

<details><summary>Indice 1</summary>

Même méthode qu'en C, sur un autre objet. La valeur livrée est encore lisible dans l'annotation `kubectl.kubernetes.io/last-applied-configuration`.

</details>

<details><summary>Indice 2</summary>

Une ConfigMap n'a pas de contrôleur : aucun événement n'est émis. Le seul composant qui écrit dans etcd est celui qui a reçu la requête.

</details>

<details><summary>Indice 3</summary>

Pour la dernière question : une variable injectée par `envFrom` est lue au démarrage du conteneur. Comparez l'heure de la modification avec l'âge des Pods, puis vérifiez avec `kubectl exec ... -- env`.

</details>

### Situation E — Des limites que personne n'a écrites

Le manifeste livré de `trackr-api` ne contient aucune section `resources`, mais ses Pods ont des requests et des limits. Quel composant les a ajoutées, et à quel moment de la création du Pod ?

<details><summary>Indice 1</summary>

Le contrôleur ReplicaSet a envoyé un Pod sans limites. Entre sa requête et l'écriture dans etcd, l'API Server fait passer la requête par plusieurs étapes.

</details>

<details><summary>Indice 2</summary>

Les annotations du Pod gardent une trace de l'étape qui a modifié la requête. Cherchez aussi quel objet du namespace porte ces valeurs.

</details>

### Situation F — `trackr-cache` a été injoignable

Le journal donne le nom du Pod. A-t-il été remplacé, comme en B, ou est-ce autre chose ? Quel composant a remis le cache en service ? Le processus a-t-il planté ou s'est-il arrêté proprement ?

<details><summary>Indice 1</summary>

Comparez le nom, l'UID et l'âge du Pod avec l'heure de l'alerte. Puis regardez l'état des conteneurs dans `.status.containerStatuses`.

</details>

<details><summary>Indice 2</summary>

`restartCount` et `lastState` disent ce qui est arrivé au conteneur précédent ; `kubectl logs --previous` donne ses dernières lignes. Les événements du Pod, avec leur compteur (`.count`), leur émetteur et leur nœud (`.reportingInstance`), racontent la suite.

</details>

## Étape 3 — Remettre TrackR en conformité (7 min)

Une fois **toutes** vos preuves relevées, corrigez le namespace pour respecter le cahier des charges, sans supprimer la LimitRange ni toucher aux nœuds. Choisissez vous-même les commandes (`set`, `scale`, `patch`, `edit` ou un manifeste corrigé).

Après chaque correction, vérifiez que le composant concerné a bien réagi : le lot d'export écrit-il dans ses journaux ? Combien de Pods `trackr-api` reste-t-il, et lesquels ?

## Étape 4 — Prouver (3 min)

```bash
bash code/tp/tp-02-verifier.sh
```

Avec un autre namespace ou un autre emplacement de réponses : `NS=trackr-<votre-nom> REPONSES=chemin/reponses.txt bash code/tp/tp-02-verifier.sh`. Le script contrôle l'état du namespace et lit vos réponses de façon tolérante (casse, tirets, formulation libre). Objectif : `Score : 13/13`.

## Bonus — Trois témoins de plus (10 min)

1. **G.** Le Service `trackr-api` connaît les adresses des Pods. Quel contrôleur tient cette liste à jour ? Preuve : un label et un propriétaire sur l'objet qui la porte.
2. **H.** La ClusterIP de `trackr-api` n'est attribuée à aucune interface réseau. Quel composant la rend joignable, et dans quel mode fonctionne-t-il sur le lab ? Trouvez une preuve **sur un nœud worker** qu'il a resynchronisé ses règles après vos corrections (indice : il expose des métriques sur le port 10249 du nœud).
3. **I.** Dans etcd (lecture seule), retrouvez la clé de `trackr-api-config`. Comparez son `mod_revision` au `resourceVersion` de l'objet, et expliquez la valeur de `version`.

## Livrable

Le tableau ci-dessous et votre `reponses.txt`, à présenter en 2 minutes au groupe : une situation au choix, la preuve, et la commande qui l'a donnée.

| Situation | Composant (et contrôleur) | Client à l'origine | Preuve tirée du cluster |
|---|---|---|---|
| A — export ne démarre pas | | — | |
| B — Pod remplacé | | | |
| C — 4 Pods | | | |
| D — ConfigMap modifiée | | | |
| E — limites ajoutées | | — | |
| F — cache injoignable | | — | |

## Nettoyage

La LimitRange du TP s'appliquerait à tous les Pods des modules suivants : supprimez les objets du TP.

```bash
kubectl delete -n trackr -f code/tp/tp-02/trackr-nuit.yaml
rm -f journal-astreinte.txt
```
