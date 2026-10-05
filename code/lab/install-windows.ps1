#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installe les prerequis de la formation Kubernetes sur Windows 10/11 (x86_64).

.DESCRIPTION
  - WSL2 et une distribution Ubuntu (ou -WslDistro), avec kubectl, kind, helm, jq et git a l'interieur
  - Docker Desktop, Git (Git Bash pour lab-up.sh), Helm, jq      : via winget
  - kubectl v1.35.0 et kind v0.31.0                               : binaires officiels, empreinte SHA256 verifiee
  - minikube (optionnel, -WithMinikube)
  - completion kubectl dans le profil PowerShell

  Le script est idempotent : un outil deja present est conserve.
  Premier passage : WSL2 + Ubuntu sont installes, redemarrer, ouvrir Ubuntu une fois pour
  creer le compte Linux, puis relancer le script : il installe alors les outils dans Ubuntu.
  kustomize est integre a kubectl (kubectl kustomize / kubectl apply -k).

.EXAMPLE
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\install-windows.ps1
  .\install-windows.ps1 -WithMinikube
  .\install-windows.ps1 -SkipDocker      # Docker/Podman deja installe
  .\install-windows.ps1 -SkipWsl         # ne pas creer de distribution WSL
  .\install-windows.ps1 -WslDistro Ubuntu-24.04
#>
[CmdletBinding()]
param(
  [switch]$SkipDocker,
  [switch]$SkipWsl,
  [string]$WslDistro = 'Ubuntu',
  [switch]$WithMinikube,
  [string]$InstallDir = "$env:ProgramFiles\k8s-formation\bin"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest beaucoup plus rapide sans barre de progression
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$KubectlVersion = 'v1.35.0'
$KindVersion    = 'v0.31.0'
$RebootNeeded   = $false
$WslReady       = $false
$env:WSL_UTF8   = '1'   # sortie de wsl.exe en UTF-8 (sinon UTF-16 illisible pour PowerShell)

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    !!  $msg" -ForegroundColor Yellow }

function Update-SessionPath {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-Winget($id, $command) {
  if ($command -and (Get-Command $command -ErrorAction SilentlyContinue)) {
    Write-Ok "$id deja present ($command)"
    return
  }
  winget install --exact --id $id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  # -1978335189 = deja installe, pas de mise a jour disponible
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    throw "Echec de l'installation winget de $id (code $LASTEXITCODE)"
  }
  Write-Ok "$id installe"
}

function Get-VerifiedBinary($url, $sha256Url, $dest) {
  $tmp = "$dest.download"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
  # Le fichier d'empreinte contient soit "hash", soit "hash  nom-du-fichier"
  $expected = ((Invoke-WebRequest -Uri $sha256Url -UseBasicParsing).Content.ToString().Trim() -split '\s+')[0]
  $actual = (Get-FileHash -Algorithm SHA256 $tmp).Hash
  if ($actual -ne $expected.ToUpper()) {
    Remove-Item $tmp -Force
    throw "Empreinte SHA256 invalide pour $url (attendu $expected, obtenu $actual)"
  }
  Move-Item -Force $tmp $dest
  Write-Ok "$(Split-Path $dest -Leaf) verifie (SHA256)"
}

# ---------------------------------------------------------------------------
Write-Step 'Verification du poste'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  throw "Architecture $env:PROCESSOR_ARCHITECTURE non supportee : le lab demande un poste x86_64."
}
$cpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($cpu -lt 4) { Write-Warn2 "$cpu vCPU detectes (4 minimum recommandes)" } else { Write-Ok "$cpu vCPU" }
if ($ram -lt 8) { Write-Warn2 "$ram Go de RAM detectes (8 Go minimum recommandes)" } else { Write-Ok "$ram Go de RAM" }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "winget introuvable : installer 'App Installer' depuis le Microsoft Store puis relancer le script."
}
Write-Ok 'winget disponible'

# ---------------------------------------------------------------------------
Write-Step 'WSL2 (backend de Docker Desktop)'
wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
  if ($SkipWsl) { wsl.exe --install --no-distribution } else { wsl.exe --install -d $WslDistro --no-launch }
  $RebootNeeded = $true
  Write-Warn2 'WSL2 installe : un redemarrage sera necessaire'
} else {
  wsl.exe --update *> $null
  Write-Ok 'WSL2 deja present (mis a jour)'

  if (-not $SkipWsl) {
    Write-Step "Distribution WSL $WslDistro"
    # Une distribution n'apparait dans "wsl -l -q" qu'apres son premier lancement (creation du compte Linux)
    $registered = @(wsl.exe -l -q) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($registered -notcontains $WslDistro) {
      wsl.exe --install -d $WslDistro --no-launch
      if ($LASTEXITCODE -ne 0) { throw "Echec de l'installation de la distribution $WslDistro (code $LASTEXITCODE)" }
      Write-Warn2 "$WslDistro installee : l'ouvrir une fois (menu Demarrer) pour creer le compte Linux, puis relancer ce script"
    } else {
      Write-Ok "$WslDistro presente"
      Write-Step "Outils de la formation dans $WslDistro (kubectl $KubectlVersion, kind $KindVersion, helm, jq, git)"
      $bash = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates jq git bash-completion >/dev/null
cd /tmp
curl -fsSLo kubectl "https://dl.k8s.io/release/__KUBECTL__/bin/linux/amd64/kubectl"
echo "$(curl -fsSL https://dl.k8s.io/release/__KUBECTL__/bin/linux/amd64/kubectl.sha256)  kubectl" | sha256sum --check
install -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSLo kind-linux-amd64 "https://github.com/kubernetes-sigs/kind/releases/download/__KIND__/kind-linux-amd64"
curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/__KIND__/kind-linux-amd64.sha256sum" | sha256sum --check
install -m 0755 kind-linux-amd64 /usr/local/bin/kind
rm -f kubectl kind-linux-amd64
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
kubectl completion bash > /etc/bash_completion.d/kubectl
'@
      $bash = ($bash -replace "`r", '').Replace('__KUBECTL__', $KubectlVersion).Replace('__KIND__', $KindVersion)
      # Passage en base64 : evite les problemes de guillemets et de fins de ligne CRLF
      $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
      wsl.exe -d $WslDistro -u root -- bash -c "echo $b64 | base64 -d | bash"
      if ($LASTEXITCODE -ne 0) { throw "Echec de l'installation des outils dans $WslDistro (code $LASTEXITCODE)" }
      $WslReady = $true
      Write-Ok "outils installes dans $WslDistro"
    }
  }
}

if (-not $SkipDocker) {
  Write-Step 'Docker Desktop'
  Install-Winget 'Docker.DockerDesktop' 'docker'
  # Docker Desktop exige que l'utilisateur soit membre du groupe docker-users
  try {
    Add-LocalGroupMember -Group 'docker-users' -Member "$env:USERDOMAIN\$env:USERNAME" -ErrorAction Stop
    Write-Ok "$env:USERNAME ajoute au groupe docker-users (effectif apres deconnexion)"
    $RebootNeeded = $true
  } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
    Write-Ok "$env:USERNAME deja membre de docker-users"
  } catch {
    Write-Warn2 "Ajout a docker-users impossible : $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------------------
Write-Step 'Git (Git Bash pour lab-up.sh / lab-down.sh), Helm, jq'
Install-Winget 'Git.Git'   'git'
Install-Winget 'Helm.Helm' 'helm'
Install-Winget 'jqlang.jq' 'jq'
if ($WithMinikube) { Install-Winget 'Kubernetes.minikube' 'minikube' }

# ---------------------------------------------------------------------------
Write-Step "kubectl $KubectlVersion et kind $KindVersion dans $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Get-VerifiedBinary "https://dl.k8s.io/release/$KubectlVersion/bin/windows/amd64/kubectl.exe" `
                   "https://dl.k8s.io/release/$KubectlVersion/bin/windows/amd64/kubectl.exe.sha256" `
                   "$InstallDir\kubectl.exe"
Get-VerifiedBinary "https://github.com/kubernetes-sigs/kind/releases/download/$KindVersion/kind-windows-amd64" `
                   "https://github.com/kubernetes-sigs/kind/releases/download/$KindVersion/kind-windows-amd64.sha256sum" `
                   "$InstallDir\kind.exe"

# Placer $InstallDir EN TETE du PATH machine : Docker Desktop fournit son propre kubectl.exe,
# qui ne doit pas masquer la version de la formation.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$parts = $machinePath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $InstallDir.TrimEnd('\')) }
[Environment]::SetEnvironmentVariable('Path', (@($InstallDir) + $parts) -join ';', 'Machine')
Update-SessionPath
Write-Ok "$InstallDir place en tete du PATH machine"

# ---------------------------------------------------------------------------
Write-Step 'Completion kubectl dans le profil PowerShell'
$marker = '# k8s-formation: kubectl completion'
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }
if (-not (Select-String -Path $PROFILE -SimpleMatch $marker -Quiet)) {
  Add-Content -Path $PROFILE -Value "`n$marker`nkubectl completion powershell | Out-String | Invoke-Expression"
  Write-Ok "ajoutee a $PROFILE"
} else {
  Write-Ok 'deja presente'
}

# ---------------------------------------------------------------------------
Write-Step 'Versions installees'
$checks = [ordered]@{
  'kubectl' = { kubectl version --client }
  'kind'    = { kind version }
  'helm'    = { helm version --short }
  'jq'      = { jq --version }
  'git'     = { git --version }
}
if (-not $SkipDocker) { $checks['docker'] = { docker --version } }
if ($WithMinikube)    { $checks['minikube'] = { minikube version --short } }
foreach ($name in $checks.Keys) {
  try   { $v = (& $checks[$name] 2>&1 | Select-Object -First 1); Write-Ok "$name : $v" }
  catch { Write-Warn2 "$name : introuvable dans cette session (ouvrir un nouveau terminal)" }
}
$kubectlPath = (Get-Command kubectl).Source
if ($kubectlPath -notlike "$InstallDir*") {
  Write-Warn2 "kubectl resolu vers $kubectlPath au lieu de $InstallDir\kubectl.exe : verifier le PATH utilisateur"
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($RebootNeeded) {
  Write-Host 'REDEMARRER le poste avant de continuer (WSL2 / groupe docker-users).' -ForegroundColor Yellow
}
if (-not $SkipWsl -and -not $WslReady) {
  Write-Host "Ouvrir $WslDistro une fois pour creer le compte Linux, puis RELANCER ce script pour y installer les outils." -ForegroundColor Yellow
}
Write-Host @"
Etapes suivantes :
  1. Lancer Docker Desktop et attendre "Engine running"
     - Settings > Resources : 4 vCPU et 6 Go de RAM minimum
     - Settings > Resources > WSL integration : activer $WslDistro
  2. Dans le terminal $WslDistro (recommande) ou dans Git Bash, depuis le dossier du lab :
       cd code/lab
       ./lab-up.sh
  3. Verifier : kubectl get nodes   (3 noeuds Ready)
"@ -ForegroundColor Cyan
