# TP 3 — Préparer les accès de l'équipe TrackR

Module 3 — Installation · Durée : 30 minutes · En autonomie ou en binôme

## Contexte

Le cluster qui accueillera TrackR, l'application de suivi de colis de Logivia, vient d'être installé. Avant d'y ouvrir l'accès aux développeurs, Karim Benali, responsable de l'équipe plateforme, vous envoie ce ticket.

> **Ticket PLAT-207 — Accès de l'équipe TrackR et recette du cluster**
>
> | # | Exigence |
> |---|---|
> | E1 | Un fichier `equipe.kubeconfig` **distinct** de votre `~/.kube/config`, **autonome** : on doit pouvoir le transmettre tel quel, il ne fait référence à aucun fichier de votre poste. |
> | E2 | Un contexte `lab-trackr` vers le cluster de lab, avec `trackr` comme namespace par défaut. |
> | E3 | Un contexte `recette`, avec `recette` comme namespace par défaut, et ce namespace existe. Niveau 1 : même cluster que `lab-trackr`. **Niveau 2 (souhaité)** : un cluster kind mono-nœud `trackr-recette`, créé à partir d'un fichier de configuration que vous écrivez. |
> | E4 | Le fichier livré s'ouvre sur le contexte `lab-trackr`. |
> | E5 | Le kubectl de l'équipe est **compatible** avec les serveurs des deux contextes. |
> | E6 | Un **test de fumée** que vous écrivez, déposé dans `trackr` et étiqueté `role=smoke-test` : une application d'au moins deux Pods prêts, sur **deux nœuds différents** ; un Service devant eux ; un **Job** client qui joint ce Service par son **nom DNS complet** et se termine en succès. |
> | E7 | Un **rapport de santé** du cluster de lab (nœuds, API server, composants, DNS, test de fumée, versions) et la réponse à **deux questions d'exploitation kubeadm** (mission 3). |
>
> Merci de ne rien modifier sur le control-plane du cluster de lab : il sert à toute l'équipe.

La démonstration vous a montré ce que kubeadm écrit sur le disque et comment se construit un cluster. Ici, personne ne vous donne les commandes : à vous de les choisir.

## Règles du jeu

- Travaillez dans un dossier personnel, par exemple `~/tp-03/`. Votre `~/.kube/config` ne doit **pas** être modifié par ce TP.
- Écrivez vos fichiers (configuration kind, manifestes du test de fumée) : un collègue doit pouvoir les rejouer.
- Le script de vérification contrôle E1 à E6. Le rapport (E7) est relu par le formateur.
- Avec **Podman** : préfixez les commandes kind par `KIND_EXPERIMENTAL_PROVIDER=podman` et remplacez `docker exec` par `podman exec`.

## Mise en place (3 min)

Depuis la racine du dépôt, montez le cluster de lab (s'il existe déjà, le script le signale et poursuit), créez le namespace et préparez votre dossier :

```bash
code/lab/lab-up.sh                         # Podman : LAB_PROVIDER=podman code/lab/lab-up.sh
kubectl create namespace trackr --dry-run=client -o yaml | kubectl apply -f -
mkdir -p ~/tp-03 && cp code/tp/tp-03/rapport-sante-modele.md ~/tp-03/rapport-sante.md
KCFG=~/tp-03/equipe.kubeconfig bash code/tp/tp-03-verifier.sh
```

Le script affiche une ligne `[OK]` ou `[KO]` par exigence, puis un score sur 12. Au départ, tout est `[KO]`. Il demande `kubectl` et `jq`. Autres paramètres : `NS` (namespace de `lab-trackr`, défaut `trackr`) et `NS_RECETTE` (défaut `recette`).

## Mission 1 — Le kubeconfig de l'équipe (10 min)

Construisez `~/tp-03/equipe.kubeconfig` conforme à E1 à E5. Montrez que vous savez **basculer** d'un contexte à l'autre et lister les namespaces par défaut de chaque contexte. Notez dans le rapport les versions client et serveur, et la plage de versions de kubectl autorisée.

<details><summary>Indice 1 — Partir de quoi ?</summary>

kind sait vous **donner** le kubeconfig d'un cluster sans toucher au vôtre. Toutes les commandes `kubectl config` acceptent `--kubeconfig <fichier>` (ou la variable `KUBECONFIG`) : travaillez toujours sur votre fichier d'équipe, jamais sur `~/.kube/config`.

</details>

<details><summary>Indice 2 — Niveau 2 : le cluster de recette</summary>

Écrivez un fichier `kind: Cluster` (`apiVersion: kind.x-k8s.io/v1alpha4`) avec un seul nœud et la même image que le lab. Ne recopiez pas les `extraPortMappings` du lab : le port 30080 de votre poste est déjà pris. `kind create cluster` accepte lui aussi `--kubeconfig` : utilisez-le pour ne pas toucher à votre configuration. Il reste ensuite à **fusionner** deux fichiers en un seul.

</details>

<details><summary>Indice 3 — Commandes et options utiles</summary>

`kind get kubeconfig`, `kubectl config rename-context`, `set-context --namespace`, `use-context`, `get-contexts`. Pour fusionner : `KUBECONFIG=fichier1:fichier2 kubectl config view --flatten` (sous Windows hors WSL, le séparateur est `;`). `--flatten` embarque les certificats au lieu de chemins de fichiers. Compatibilité : `kubectl version` et la politique d'écart de version (« version skew policy ») de la documentation Kubernetes.

</details>

## Mission 2 — Rapport de santé et test de fumée (10 min)

1. Remplissez la section 3 du rapport : pour chaque point de contrôle, **votre** commande et votre constat. Un « tout va bien » sans preuve ne compte pas.
2. Écrivez votre test de fumée (E6) dans `~/tp-03/smoke-test.yaml`, appliquez-le **avec le contexte `lab-trackr`**, sans préciser de namespace, puis relevez dans les logs du Job la preuve que la requête a traversé le DNS et le Service.
3. Relancez le script de vérification.

Contraintes : images `ghcr.io/stefanprodan/podinfo:6.9.2` (port 9898, `/readyz`, `/api/info`) et `busybox:1.37` uniquement.

<details><summary>Indice 1 — Que doit prouver un test de fumée ?</summary>

Chaque maillon franchi : le scheduler place les Pods, le CNI les relie (y compris d'un nœud à l'autre), kube-proxy fait suivre le trafic du Service, CoreDNS résout le nom. Un client qui appelle plusieurs fois le Service et affiche le nom du Pod qui répond prouve beaucoup en une seule sortie.

</details>

<details><summary>Indice 2 — Santé de l'API server et des composants</summary>

L'API server expose des points de contrôle (`/livez`, `/readyz`) lisibles avec `kubectl get --raw` ; le paramètre `verbose` détaille chaque vérification, dont etcd. Les composants du control-plane sont des Pods statiques de `kube-system`. Le DNS du cluster, c'est un Deployment et un Service de `kube-system`.

</details>

<details><summary>Indice 3 — Le Job échoue au premier essai ?</summary>

Un Job lancé en même temps que l'application peut s'exécuter avant que les Pods soient prêts. Regardez `kubectl get pods` : le Job a-t-il retenté ? Pensez à `backoffLimit`, ou attendez la fin du déploiement (`rollout status`) avant de créer le Job. Le nom DNS complet d'un Service est `<service>.<namespace>.svc.cluster.local`.

</details>

## Mission 3 — Deux questions d'exploitation kubeadm (7 min)

Le cluster de lab a été construit par kubeadm (via kind). Répondez dans la section 5 du rapport, **preuves à l'appui** (commande et extrait de sortie). Lecture seule sur le cluster de lab.

**Q1 — Capacité des nœuds.** Le futur nœud worker de TrackR accueillera des Pods de batch nombreux. Combien de Pods au maximum un nœud worker du lab peut-il accueillir ? Dans quel fichier, sur le nœud, le kubelet lit-il sa configuration, et pourquoi la valeur n'y figure-t-elle pas ? D'où kubeadm a-t-il tiré ce fichier, et comment changer la valeur **pour tous les nœuds** sans éditer chaque fichier à la main ?

**Q2 — Un nom pour l'API.** L'équipe réseau veut publier l'API sous le nom `api.logivia.lab`. Le certificat actuel de l'API server l'accepte-t-il ? Prouvez-le **sans** modifier le DNS ni `/etc/hosts`. Quels noms et adresses accepte-t-il aujourd'hui, et où kubeadm a-t-il trouvé `localhost` et `127.0.0.1` ? Décrivez la procédure kubeadm pour ajouter le nom.

<details><summary>Indice 1 — Où chercher</summary>

Q1 : la capacité d'un nœud est dans son statut (`kubectl get node -o yaml`). Le service systemd du kubelet indique les options qu'il reçoit (`systemctl cat kubelet` dans le nœud). Q2 : un certificat X.509 liste les noms acceptés dans son extension « Subject Alternative Name ».

</details>

<details><summary>Indice 2 — La configuration stockée dans le cluster</summary>

kubeadm range sa configuration dans deux ConfigMaps de `kube-system` : l'une pour le cluster (ClusterConfiguration), l'autre pour les kubelets. Comparez-les à ce que vous trouvez sur le disque du nœud. Côté client, kubectl peut **forcer le nom attendu** du serveur TLS sans toucher au DNS.

</details>

<details><summary>Indice 3 — Noms précis</summary>

Q1 : `/var/lib/kubelet/config.yaml`, ConfigMap `kubelet-config`, champ `maxPods`, `kubeadm upgrade node phase kubelet-config`. Q2 : `openssl x509 -noout -ext subjectAltName`, `kubectl --tls-server-name`, ConfigMap `kubeadm-config`, champ `apiServer.certSANs`, `kubeadm init phase certs apiserver`. Documentation : « Reconfiguring a kubeadm cluster ».

</details>

Interdit sur le cluster de lab : `kubeadm reset`, `init`, `upgrade apply`, `certs renew`, toute modification de `/etc/kubernetes` ou des ConfigMaps kubeadm.

## Pour aller plus loin (si vous avez fini en avance)

Uniquement sur votre cluster `trackr-recette` (niveau 2) :

- appliquez réellement votre procédure Q2, puis prouvez que `api.logivia.lab` est maintenant accepté ;
- appliquez votre procédure Q1 avec une valeur de 50 Pods et vérifiez la nouvelle capacité du nœud.

## Livrables

- `~/tp-03/equipe.kubeconfig`, votre fichier de configuration kind (niveau 2) et `~/tp-03/smoke-test.yaml` ;
- `~/tp-03/rapport-sante.md` complété ;
- la sortie du script : **12/12**.

## Nettoyage

Supprimez les ressources étiquetées `role=smoke-test` du namespace `trackr` (gardez le namespace pour la suite) et, si vous l'avez créé, le cluster `trackr-recette`. `equipe.kubeconfig` contient une clé d'administrateur : ne le laissez pas traîner dans un dossier partagé.
