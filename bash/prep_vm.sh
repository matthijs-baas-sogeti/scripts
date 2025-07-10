#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/c/Tools"
VERSION_STORE="$INSTALL_DIR/.versions"
PATH_ADDITION="$INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
mkdir -p "$VERSION_STORE"

echo "Installing/updating tools to $INSTALL_DIR"

# Add C:\Tools to Windows user PATH if missing
function add_to_windows_path() {
  local current_path
  current_path=$(reg.exe query "HKCU\Environment" /v Path 2>/dev/null | grep "Path" | awk -F "    " '{print $NF}' || echo "")

  if [[ ":$current_path:" != *":$INSTALL_DIR:"* ]]; then
    echo "Adding $INSTALL_DIR to Windows user PATH..."
    reg.exe add "HKCU\Environment" /v Path /d "${current_path};${INSTALL_DIR}" /f >/dev/null
    echo "You may need to log off and log back in to see PATH changes."
  else
    echo "$INSTALL_DIR is already in Windows user PATH."
  fi
}

add_to_windows_path

function get_stored_version() {
  local tool=$1
  local file="$VERSION_STORE/$tool.version"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo ""
  fi
}

function set_stored_version() {
  local tool=$1 version=$2
  echo "$version" > "$VERSION_STORE/$tool.version"
}

function get_current_version() {
  local cmd=$1 pattern=${2:-'([0-9]+\.[0-9]+\.[0-9]+)'}
  if ! command -v "$cmd" &>/dev/null; then
    echo "not-installed"
    return
  fi
  local ver
  ver=$("$cmd" version 2>&1 | grep -Eo "$pattern" | head -1 || true)
  if [[ -z "$ver" ]]; then
    ver=$("$cmd" --version 2>&1 | grep -Eo "$pattern" | head -1 || true)
  fi
  if [[ -z "$ver" ]]; then
    echo "unknown"
  else
    echo "$ver"
  fi
}

function get_latest_github_version() {
  local repo=$1
  curl -s "https://api.github.com/repos/$repo/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")' | sed 's/^v//'
}

function download_and_extract() {
  local url=$1
  local dest=$2
  local subpath=${3:-}

  local tmpzip="/tmp/tool.zip"
  rm -f "$tmpzip"
  curl -L --fail -o "$tmpzip" "$url"

  local extract_dir="/tmp/tool-extract"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  unzip -q -o "$tmpzip" -d "$extract_dir"

  if [[ -n "$subpath" ]]; then
    local exe
    exe=$(find "$extract_dir/$subpath" -type f -iname "*.exe" | head -1)
  else
    local exe
    exe=$(find "$extract_dir" -type f -iname "*.exe" | head -1)
  fi

  if [[ -z "$exe" ]]; then
    echo "No .exe found inside extracted archive from $url at path $subpath"
    exit 1
  fi

  cp "$exe" "$dest"
  echo "Installed or updated $dest"

  rm -rf "$extract_dir"
  rm -f "$tmpzip"
}

function download_exe() {
  local url=$1
  local dest=$2

  curl -L --fail -o "$dest" "$url"
  echo "Downloaded executable $dest"
}

function kill_process() {
  local name=$1
  if tasklist | grep -iq "$name"; then
    echo "Stopping running process $name..."
    taskkill //IM "$name.exe" //F || true
    sleep 2
  fi
}

function install_or_update_tool() {
  local name=$1 cmd=$2 repo=$3 platformfilter=$4 mode=$5

  local exePath="$INSTALL_DIR/$name.exe"
  local storedVersion
  storedVersion=$(get_stored_version "$name")
  local currentVersion
  currentVersion=$(get_current_version "$cmd")
  local latestVersion
  latestVersion=$(get_latest_github_version "$repo")

  echo -e "\nChecking $name..."
  echo "Current version: $currentVersion, Latest: $latestVersion, Stored: $storedVersion"

  if [[ "$currentVersion" == "not-installed" || "$storedVersion" != "$latestVersion" ]]; then
    echo "Installing/updating $name to $latestVersion..."

    kill_process "$name"

    if [[ "$name" == "terraform" ]]; then
      local url="https://releases.hashicorp.com/terraform/${latestVersion}/terraform_${latestVersion}_windows_amd64.zip"
      download_and_extract "$url" "$exePath"
    elif [[ "$name" == "kubectl" ]]; then
      local url="https://dl.k8s.io/release/v${latestVersion}/bin/windows/amd64/kubectl.exe"
      download_exe "$url" "$exePath"
    elif [[ "$name" == "argocd" ]]; then
      local url="https://github.com/argoproj/argo-cd/releases/latest/download/argocd-windows-amd64.exe"
      download_exe "$url" "$exePath"
    elif [[ "$name" == "kubelogin" ]]; then
      local dlUrl
      dlUrl=$(curl -s "https://api.github.com/repos/Azure/kubelogin/releases/latest" | grep "kubelogin-win-amd64.zip" | grep -Po '"browser_download_url": "\K[^"]+')
      download_and_extract "$dlUrl" "$exePath" "bin/windows_amd64"
    elif [[ "$name" == "helm" ]]; then
      local url="https://get.helm.sh/helm-v${latestVersion}-windows-amd64.zip"
      download_and_extract "$url" "$exePath" "windows-amd64"
    elif [[ "$mode" == "exe" ]]; then
      local url="https://github.com/$repo/releases/latest/download/$platformfilter"
      download_exe "$url" "$exePath"
    elif [[ "$mode" == "zip" ]]; then
      local url="https://github.com/$repo/releases/latest/download/${name}_${latestVersion}_${platformfilter}"
      download_and_extract "$url" "$exePath"
    fi

    set_stored_version "$name" "$latestVersion"
  else
    echo "$name is up to date."
  fi
}

function install_or_update_azurecli() {
  echo -e "\nChecking Azure CLI..."

  local storedVersion
  storedVersion=$(get_stored_version "azurecli")

  local currentVersion="not-installed"
  if command -v az &>/dev/null; then
    currentVersion=$(az version --output json | grep -Po '"azure-cli":\s*"\K[0-9.]+' || echo "unknown")
  fi

  local location
  location=$(curl -sI https://aka.ms/InstallAzureCliWindows | grep -i "^location:" | tail -1 | awk '{print $2}' | tr -d '\r\n')

  if [[ "$location" =~ azure-cli-([0-9.]+)\.msi ]]; then
    local latest="${BASH_REMATCH[1]}"
    echo "Azure CLI current: $currentVersion, latest: $latest, stored: $storedVersion"

    if [[ "$currentVersion" == "not-installed" || "$storedVersion" != "$latest" ]]; then
      kill_process "az"

      echo "Installing/updating Azure CLI..."
      local msi="$HOME/AppData/Local/Temp/azurecli.msi"
      curl -L --fail -o "$msi" "$location"
      cmd.exe /c "msiexec /i \"$msi\" /quiet /norestart"
      rm -f "$msi"
      echo "Azure CLI installed or updated to $latest"
      set_stored_version "azurecli" "$latest"
    else
      echo "Azure CLI is up to date."
    fi
  else
    echo "Failed to determine latest Azure CLI version."
  fi
}

function install_or_update_docker_desktop() {
  echo -e "\nChecking Docker Desktop..."

  local dockerPath="/c/Program Files/Docker/Docker/Docker Desktop.exe"
  local currentVersion=""
  if [[ -f "$dockerPath" ]]; then
    currentVersion=$(powershell.exe -Command "(Get-Item '$dockerPath').VersionInfo.FileVersion" | tr -d '\r\n')
  fi

  # Latest stable download URL (static for now)
  local latestUrl="https://desktop.docker.com/win/stable/amd64/Docker%20Desktop%20Installer.exe"

  # No easy version query, so we skip version check and always download/install latest
  echo "Installing/updating Docker Desktop..."

  local installer="$HOME/AppData/Local/Temp/DockerDesktopInstaller.exe"
  curl -L --fail -o "$installer" "$latestUrl"

  echo "Running Docker Desktop installer silently..."
  cmd.exe /c "\"$installer\" install --quiet"

  rm -f "$installer"
  echo "Docker Desktop installed or updated."
}

# Now install/update all tools

install_or_update_tool "terraform" "terraform" "hashicorp/terraform" "" "zip"
install_or_update_tool "kubectl" "kubectl" "kubernetes/kubernetes" "kubectl.exe" "exe"
install_or_update_tool "argocd" "argocd" "argoproj/argo-cd" "argocd-windows-amd64.exe" "exe"
install_or_update_tool "kubelogin" "kubelogin" "Azure/kubelogin" "kubelogin-win-amd64.zip" "zip"
install_or_update_tool "helm" "helm" "helm/helm" "windows-amd64.zip" "zip"

install_or_update_azurecli
install_or_update_docker_desktop

echo -e "\nAll tools installed or updated in $INSTALL_DIR"
