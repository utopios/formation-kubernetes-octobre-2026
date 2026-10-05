#!/usr/bin/env bash
# Installe les outils manquants (Linux / WSL2 Ubuntu), cree le cluster de lab k8s-formation
# et installe metrics-server.
# Fonctionne avec Docker (defaut) ou Podman : LAB_PROVIDER=podman ./lab-up.sh
# Sur Linux (Debian, Ubuntu, WSL2) : installe si besoin Docker Engine (ou Podman), kubectl et kind.
# Sur macOS / Git Bash : verifie seulement la presence des outils (voir README.md).
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT")"

KUBECTL_VERSION=v1.35.0
KIND_VERSION=v0.31.0
PROVIDER="${LAB_PROVIDER:-docker}"
if [ "$PROVIDER" = "podman" ]; then export KIND_EXPERIMENTAL_PROVIDER=podman; fi

SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Architecture $(uname -m) non supportee." >&2; exit 1 ;;
esac
IS_WSL=false; if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=true; fi

# --- Installation des outils (Linux avec apt uniquement) ---------------------
can_install() { [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null; }

need() {  # need <commande> : echoue proprement si l'outil manque et ne peut pas etre installe
  if ! command -v "$1" >/dev/null; then
    echo "$1 introuvable : l'installer en suivant code/lab/README.md." >&2
    exit 1
  fi
}

install_base() {
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    echo "==> Installation de curl, jq, git"
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq git bash-completion >/dev/null
  fi
}

install_docker() {
  if docker info >/dev/null 2>&1; then return; fi
  if ! command -v docker >/dev/null; then
    if $IS_WSL && [ -e "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe" ]; then
      echo "Docker Desktop est installe sous Windows mais pas visible dans cette distribution." >&2
      echo "Docker Desktop > Settings > Resources > WSL integration : activer cette distribution, puis relancer." >&2
      exit 1
    fi
    echo "==> Installation de Docker Engine"
    curl -fsSL https://get.docker.com | $SUDO sh
  fi
  # Demarrer le demon (WSL sans systemd : pas de demarrage automatique)
  if ! $SUDO docker info >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start
    for _ in $(seq 1 30); do $SUDO docker info >/dev/null 2>&1 && break; sleep 1; done
  fi
  # Acces sans sudo : ajout au groupe docker, puis relance du script avec ce groupe
  if ! docker info >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
    if ! id -nG | grep -qw docker; then
      $SUDO usermod -aG docker "$USER"
      echo "==> $USER ajoute au groupe docker, relance du script avec ce groupe"
      exec sg docker -c "$(printf '%q' "$SCRIPT")"
    fi
  fi
}

install_podman() {
  if command -v podman >/dev/null; then return; fi
  echo "==> Installation de Podman"
  $SUDO apt-get update -qq
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman >/dev/null
}

install_kubectl() {
  if command -v kubectl >/dev/null; then return; fi
  echo "==> Installation de kubectl $KUBECTL_VERSION"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  echo "$(curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl.sha256")  $tmp/kubectl" | sha256sum --check --quiet
  $SUDO install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  $SUDO mkdir -p /etc/bash_completion.d
  kubectl completion bash | $SUDO tee /etc/bash_completion.d/kubectl >/dev/null
  rm -rf "$tmp"
}

install_kind() {
  if command -v kind >/dev/null && kind version | grep -q "kind $KIND_VERSION "; then return; fi
  echo "==> Installation de kind $KIND_VERSION"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSLo "$tmp/kind-linux-$ARCH" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH"
  (cd "$tmp" && curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH.sha256sum" | sha256sum --check --quiet)
  $SUDO install -m 0755 "$tmp/kind-linux-$ARCH" /usr/local/bin/kind
  rm -rf "$tmp"
}

if can_install; then
  install_base
  if [ "$PROVIDER" = "podman" ]; then install_podman; else install_docker; fi
  install_kubectl
  install_kind
fi
need "$PROVIDER"; need kubectl; need kind; need curl
if [ "$PROVIDER" = "docker" ] && ! docker info >/dev/null 2>&1; then
  echo "Le moteur Docker ne repond pas : demarrer Docker Desktop (ou le service docker) puis relancer." >&2
  exit 1
fi
echo "Outils : $(kind version) / kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion 2>/dev/null || echo '?')"

# --- Cluster ------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx k8s-formation; then
  echo "Le cluster k8s-formation existe deja."
  # Cluster arrete (redemarrage du poste) : relancer ses conteneurs
  for node in $(kind get nodes --name k8s-formation); do "$PROVIDER" start "$node" >/dev/null; done
else
  kind create cluster --config kind-config.yaml
fi
kubectl config use-context kind-k8s-formation
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# metrics-server (kubectl top, HPA). Sur kind, les certificats kubelet sont auto-signes.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
if ! kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- --kubelet-insecure-tls; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

kubectl get nodes -o wide
echo "Lab pret."
