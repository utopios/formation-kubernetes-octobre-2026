#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installe les prerequis de la formation Kubernetes sur Windows 10/11 (x86_64).

.DESCRIPTION
  - WSL2 (backend de Docker Desktop)
  - Docker Desktop, Git (Git Bash pour lab-up.sh), Helm, jq      : via winget
  - kubectl v1.35.0 et kind v0.31.0                               : binaires officiels, empreinte SHA256 verifiee
  - minikube (optionnel, -WithMinikube)
  - completion kubectl dans le profil PowerShell

  Le script est idempotent : un outil deja present est conserve.
  kustomize est integre a kubectl (kubectl kustomize / kubectl apply -k).

.EXAMPLE
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\install-windows.ps1
  .\install-windows.ps1 -WithMinikube
  .\install-windows.ps1 -SkipDocker      # Docker/Podman deja installe
#>
[CmdletBinding()]
param(
  [switch]$SkipDocker,
  [switch]$WithMinikube,
  [string]$InstallDir = "$env:ProgramFiles\k8s-formation\bin"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest beaucoup plus rapide sans barre de progression
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$KubectlVersion = 'v1.35.0'
$KindVersion    = 'v0.31.0'
$RebootNeeded   = $false

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
if (-not $SkipDocker) {
  Write-Step 'WSL2 (backend de Docker Desktop)'
  wsl.exe --status *> $null
  if ($LASTEXITCODE -ne 0) {
    wsl.exe --install --no-distribution
    $RebootNeeded = $true
    Write-Warn2 'WSL2 installe : un redemarrage sera necessaire'
  } else {
    wsl.exe --update *> $null
    Write-Ok 'WSL2 deja present (mis a jour)'
  }

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
Write-Host @'
Etapes suivantes :
  1. Lancer Docker Desktop et attendre "Engine running"
     (Settings > Resources : 4 vCPU et 6 Go de RAM minimum).
  2. Ouvrir Git Bash dans le dossier du lab :
       cd code/lab
       ./lab-up.sh
  3. Verifier : kubectl get nodes   (3 noeuds Ready)
'@ -ForegroundColor Cyan
