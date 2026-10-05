# TP 1 — Mettre trackr-front en recette

Module 1 — Introduction à Kubernetes · Durée : 30 minutes · En autonomie ou en binôme

## Contexte

L'API de TrackR, l'application de suivi de colis de Logivia, tourne déjà dans l'environnement de recette. C'est maintenant au tour de l'interface web, **`trackr-front`**. Lucie Marchand, responsable de l'équipe web, vous transmet la fiche de besoin ci-dessous.

> **Fiche de besoin FB-112 — Front TrackR en recette**
>
> | # | Exigence |
> |---|---|
> | E1 | Le front utilise l'image `ghcr.io/stefanprodan/podinfo:6.9.2` ; l'application écoute sur le port 9898 (`/healthz` répond `{"status": "OK"}`). |
> | E2 | Il tourne en **2 exemplaires**, prêts en permanence. |
> | E3 | Le conteneur s'appelle `front` ; son port 9898 porte le nom `http`. |
> | E4 | **Tous** les objets du front, et les Pods qu'ils créent, portent les étiquettes `app=trackr`, `tier=front`, `env=recette`. |
> | E5 | Les autres briques le joignent **dans le cluster** sous le nom `trackr-front`, sur le **port 80**. Pas d'exposition hors du cluster. |
> | E6 | Ce point d'accès vise le port de l'application **par son nom**, pas par son numéro : nous changerons peut-être de port plus tard. |
> | E7 | Le point d'accès ne distribue le trafic qu'aux Pods du **front de recette**, rien d'autre. |
> | E8 | La perte d'un Pod ne doit demander **aucune intervention** : le front revient seul à 2 exemplaires. |
>
> Attention : l'équipe a laissé tourner dans le namespace une ancienne maquette du front. Elle ne doit pas recevoir de trafic, et vous ne devez pas la supprimer (elle sert encore aux ergonomes).

Vous avez vu en démonstration le déploiement de `trackr-api`. Ici, personne ne vous donne les manifestes : à vous de les écrire.

## Règles du jeu

- Travaillez dans le namespace `trackr`, dans un dossier personnel (par exemple `~/tp-01/`).
- Tout doit être **déclaratif** : vos objets sont décrits dans un ou plusieurs fichiers YAML appliqués avec `kubectl apply`. Un collègue doit pouvoir rejouer vos fichiers sur un autre cluster.
- Les fichiers de `code/tp/tp-01/` sont fournis : ne les modifiez pas.
- Le script de vérification vous dit quelles exigences sont satisfaites, pas comment les satisfaire. Lancez-le aussi souvent que vous voulez.

## Mise en place (2 min)

Cluster de lab démarré (`code/lab/lab-up.sh`, ou `LAB_PROVIDER=podman ./lab-up.sh`), contexte `kind-k8s-formation`. Depuis la racine du dépôt :

```bash
kubectl create namespace trackr --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n trackr -f code/tp/tp-01/existant.yaml
bash code/tp/tp-01-verifier.sh
```

Le script affiche une ligne `[OK]` ou `[KO]` par exigence, puis un score. Au départ, tout est `[KO]`. La dernière vérification (V9) supprime réellement un Pod de votre front pour tester l'exigence E8 : c'est voulu.

> Le script demande `jq`. Pour un autre namespace : `NS=mon-ns bash code/tp/tp-01-verifier.sh`.

## Mission 1 — Livrer le front conforme à la fiche (15 min)

Écrivez vos manifestes, appliquez-les, et itérez jusqu'à obtenir **9/9** au script.

Avant de lancer le script, vérifiez vous-même l'exigence E5 depuis un Pod client éphémère (`busybox:1.37`) situé dans le namespace : il doit obtenir `{"status": "OK"}` en appelant le front par son nom.

<details><summary>Indice 1 — Quels objets ?</summary>

Relisez la fiche en vous demandant, pour chaque exigence, quel objet Kubernetes la porte. Deux types d'objets suffisent : un qui maintient un nombre de Pods identiques, un qui leur donne un nom et une adresse stables dans le cluster.

</details>

<details><summary>Indice 2 — Pourquoi E7 échoue-t-il ?</summary>

Comparez les étiquettes de la maquette (`--show-labels`) avec le sélecteur de votre point d'accès. Combien d'adresses voyez-vous dans ses EndpointSlices ? Un sélecteur est un ET logique entre toutes ses étiquettes.

</details>

<details><summary>Indice 3 — Champs utiles</summary>

`kubectl explain deployment.spec.selector`, `kubectl explain pod.spec.containers.ports.name` et `kubectl explain service.spec.ports.targetPort`. Le sélecteur d'un Deployment ne peut plus être modifié après sa création : si vous devez le changer, supprimez le Deployment et réappliquez votre fichier.

</details>

## Mission 2 — Comprendre ce que vous avez construit (10 min)

Répondez aux trois questions dans le tableau de fin, en notant à chaque fois la commande qui vous a donné la réponse.

**Q1 — Inventaire de la recette.** Avec un **seul** sélecteur d'étiquettes, listez tous les objets de l'environnement de recette du namespace (Pods, Services, Deployments, ReplicaSets). Combien en comptez-vous, et à quelles briques appartiennent-ils ? Un des objets listés porte `env=recette` alors que vous ne l'avez jamais écrit dans vos fichiers : lequel, et d'où vient son étiquette ? Écrivez ensuite un sélecteur qui ne retourne **que** les Pods du front qui ne sont **pas** en recette.

**Q2 — L'intrus.** Un développeur pressé ajoute à la main un Pod portant exactement les étiquettes du front de recette :

```bash
kubectl apply -n trackr -f code/tp/tp-01/pod-intrus.yaml
```

- Combien d'adresses le point d'accès `trackr-front` distribue-t-il maintenant ? Que dit le Deployment (`READY`) ?
- Depuis un Pod client, envoyez une douzaine de requêtes sur `http://trackr-front/api/info` et relevez le champ `hostname` des réponses. L'intrus répond-il ?
- Expliquez : pourquoi le Service le prend-il, alors que le Deployment l'ignore ?

**Q3 — Deux suppressions.** Supprimez l'intrus, puis un des Pods de votre Deployment. Pour chacun, observez ce qui se passe dans les secondes qui suivent (Pods et EndpointSlices). Pourquoi un seul des deux revient-il ?

<details><summary>Indice Q1</summary>

`kubectl get all` accepte l'option `-l`. Pour le second sélecteur, les opérateurs `!=` et `notin` existent.

</details>

<details><summary>Indice Q2</summary>

Regardez les étiquettes des Pods créés par le Deployment avec `--show-labels`, puis le sélecteur de son ReplicaSet. Comparez avec les étiquettes de l'intrus. Pour savoir qui « possède » un Pod : `kubectl get pod <nom> -o yaml`, champ `metadata.ownerReferences`.

</details>

<details><summary>Indice Q3</summary>

Un Service ne crée ni ne surveille de Pods : il se contente de suivre ceux qui correspondent à son sélecteur. Qui, dans le namespace, a un état désiré à faire respecter ?

</details>

## Pour aller plus loin (si vous avez fini en avance)

- Recréez l'intrus avec `kubectl run`, mêmes étiquettes, port 9898 déclaré **sans nom**. Reçoit-il du trafic ? Regardez la colonne `PORTS` des EndpointSlices et faites le lien avec l'exigence E6.
- Ouvrez un `kubectl port-forward` vers le Service `trackr-front` et affichez la page dans votre navigateur. Rechargez plusieurs fois : le nom d'hôte change-t-il ? Comparez avec la question Q2.

## Livrable

1. Vos manifestes YAML (un ou plusieurs fichiers), et la sortie du script à **9/9**.
2. Le tableau ci-dessous complété.

| Question | Commande(s) utilisée(s) | Réponse et explication |
|---|---|---|
| Q1 — objets de la recette | | |
| Q1 — front hors recette | | |
| Q2 — l'intrus | | |
| Q3 — deux suppressions | | |

## Nettoyage

Supprimez vos objets **à partir de vos fichiers**, puis l'état de départ fourni. Conservez le namespace `trackr`.

```bash
kubectl delete -n trackr -f code/tp/tp-01/existant.yaml
```
