# Rapport de prise en main — cluster TrackR

Auteur : ............ Date : ............ Poste : Docker / Podman, architecture : ............

Pour chaque ligne : la commande utilisée (pas sa sortie complète) et la conclusion en une phrase.

## 1. Accès de l'équipe

| Élément | Valeur |
|---|---|
| Fichier livré | `equipe.kubeconfig` |
| Contexte `lab-trackr` : serveur, namespace | |
| Contexte `recette` : serveur, namespace, cluster cible | |
| Comment bascule-t-on de l'un à l'autre ? | |
| Ce fichier est-il un secret ? Pourquoi ? | |

## 2. Compatibilité des versions

| Élément | Valeur |
|---|---|
| Version de kubectl | |
| Version du serveur (lab / recette) | |
| Plage de kubectl supportée pour ce serveur | |
| Conclusion | |

## 3. Santé du cluster de lab

| Point de contrôle | Commande | Constat |
|---|---|---|
| Nœuds (nombre, état, version, runtime) | | |
| API server (prêt, etcd joignable) | | |
| Composants du control-plane | | |
| DNS du cluster (Pods, Service, adresse) | | |
| Métriques (facultatif) | | |

## 4. Test de fumée

| Élément | Valeur |
|---|---|
| Fichier du test | |
| Ce que le test prouve (maillons de la chaîne) | |
| Résultat (extrait des logs du client) | |
| Durée totale | |

## 5. Questions d'exploitation kubeadm

**Q1 — Capacité en Pods d'un nœud worker** : valeur, fichier lu par le kubelet, origine de ce fichier, procédure de modification pour tous les nœuds.

**Q2 — Nom `api.logivia.lab`** : accepté ou non (preuve), noms et IP acceptés aujourd'hui, origine de `localhost` / `127.0.0.1`, procédure d'ajout.

## 6. Réserves et points à surveiller
