# RUN AS ADMINISTRATOR
# This script does the following:

# Checks installed versions of Terraform, kubectl, argocd, kubelogin, and Azure CLI
# Gets latest versions from GitHub or Microsoft
# Downloads and installs or updates missing/outdated tools to C:\Tools
# Extracts executables from ZIPs (handles kubelogin’s nested folder)
# Stores installed versions to prevent redundant downloads
# Adds C:\Tools to system PATH if needed
# Stops running tool processes before updating
# Makes tools available immediately in current session

$ErrorActionPreference = 'Stop'
$installPath = "C:\Tools"

# Create C:\Tools if it doesn't exist
if (-Not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath | Out-Null
    Write-Host "📁 Created directory: $installPath"
}

# Add C:\Tools to system PATH if not present
$existingPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
if (-not ($existingPath -split ";" | Where-Object { $_ -ieq $installPath })) {
    [Environment]::SetEnvironmentVariable("Path", "$existingPath;$installPath", [EnvironmentVariableTarget]::Machine)
    Write-Host "🔧 Added $installPath to system PATH (you may need to restart your shell)."
}

function Get-StoredVersion {
    param($ToolName)
    $versionFile = Join-Path $installPath "$ToolName.version"
    if (Test-Path $versionFile) {
        return (Get-Content $versionFile -Raw).Trim()
    }
    return $null
}

function Set-StoredVersion {
    param($ToolName, $Version)
    $versionFile = Join-Path $installPath "$ToolName.version"
    $Version | Out-File -FilePath $versionFile -Encoding utf8
}

function Get-CurrentVersion {
    param (
        [string]$Command,
        [string]$Pattern = '([\d\.]+)'
    )
    try {
        return (& $Command --version 2>&1 | Select-String -Pattern $Pattern | Select-Object -First 1).Matches[0].Groups[1].Value
    } catch {
        return "not-installed"
    }
}

function Get-GitHubLatestVersion {
    param (
        [string]$Repo
    )
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    $response = Invoke-RestMethod -Uri $url -Headers @{'User-Agent' = 'PowerShell'}
    return $response.tag_name.TrimStart('v')
}

function Get-KubeloginDownloadUrl {
    $repo = "Azure/kubelogin"
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    $response = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }

    foreach ($asset in $response.assets) {
        if ($asset.name -ieq "kubelogin-win-amd64.zip") {
            return @{ url = $asset.browser_download_url; type = "zip" }
        }
    }
    throw "Could not find kubelogin-win-amd64.zip asset in latest kubelogin release."
}

function Download-And-Extract-Exe {
    param (
        [string]$ZipUrl,
        [string]$TargetExe,
        [string]$SubPathInZip = ""
    )
    Write-Host "Downloading ZIP from $ZipUrl"
    $tmp = "$env:TEMP\tool.zip"
    $extractPath = "$env:TEMP\tool-extract"

    Remove-Item $tmp -ErrorAction SilentlyContinue -Force
    Remove-Item $extractPath -ErrorAction SilentlyContinue -Recurse -Force

    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $tmp -UseBasicParsing
    } catch {
        throw "Failed to download $ZipUrl. Error: $_"
    }

    try {
        Expand-Archive -Path $tmp -DestinationPath $extractPath -Force
    } catch {
        throw "Failed to extract ZIP $tmp. Error: $_"
    }

    if ([string]::IsNullOrEmpty($SubPathInZip)) {
        $exe = Get-ChildItem -Path $extractPath -Filter "*.exe" -Recurse | Select-Object -First 1
    } else {
        $exe = Get-ChildItem -Path (Join-Path $extractPath $SubPathInZip) -Filter "*.exe" -Recurse | Select-Object -First 1
    }

    if (-not $exe) {
        throw "No .exe found inside extracted archive from $ZipUrl at path $SubPathInZip"
    }

    try {
        Copy-Item -Path $exe.FullName -Destination $TargetExe -Force
        Write-Host "✅ Installed or Updated: $TargetExe"
    } catch {
        throw "Failed to copy $($exe.FullName) to $TargetExe. Error: $_"
    }

    Remove-Item $tmp -Force
    Remove-Item $extractPath -Recurse -Force
}

function Download-And-Place-Exe {
    param (
        [string]$Url,
        [string]$TargetExe
    )
    Write-Host "Downloading EXE from $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $TargetExe -UseBasicParsing
        Write-Host "✅ Installed or Updated: $TargetExe"
    } catch {
        throw "Failed to download EXE from $Url. Error: $_"
    }
}

function Install-Or-Update-Tool {
    param (
        [string]$Name,
        [string]$Cmd,
        [string]$Repo,
        [string]$PlatformFilter,
        [string]$Mode
    )

    $exePath = Join-Path $installPath "$Name.exe"
    $storedVersion = Get-StoredVersion -ToolName $Name
    Write-Host "`n🔍 Checking $Name..."

    $current = Get-CurrentVersion -Command $Cmd
    $latest = Get-GitHubLatestVersion -Repo $Repo

    Write-Host "$Name current: $current, latest: $latest, stored: $storedVersion"

    if (($current -eq "not-installed" -and -not $storedVersion) -or
        ($latest -ne $storedVersion)) {

        Write-Host "⬆️ Installing or updating $Name..."

        if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
            Write-Host "⚠️ Detected running $Name process. Stopping it to update..."
            Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
        }

        if ($Name -eq "terraform") {
            $url = "https://releases.hashicorp.com/terraform/$latest/terraform_${latest}_windows_amd64.zip"
            Download-And-Extract-Exe -ZipUrl $url -TargetExe $exePath
        }
        elseif ($Name -eq "kubectl") {
            $url = "https://dl.k8s.io/release/v$latest/bin/windows/amd64/kubectl.exe"
            Download-And-Place-Exe -Url $url -TargetExe $exePath
        }
        elseif ($Name -eq "kubelogin") {
            $dlInfo = Get-KubeloginDownloadUrl
            if ($dlInfo.type -eq "zip") {
                Download-And-Extract-Exe -ZipUrl $dlInfo.url -TargetExe $exePath -SubPathInZip "bin\windows_amd64"
            } else {
                Download-And-Place-Exe -Url $dlInfo.url -TargetExe $exePath
            }
        }
        elseif ($Mode -eq "zip") {
            $url = "https://github.com/$Repo/releases/latest/download/${Name}_${latest}_$PlatformFilter"
            Download-And-Extract-Exe -ZipUrl $url -TargetExe $exePath
        }
        elseif ($Mode -eq "exe") {
            $url = "https://github.com/$Repo/releases/latest/download/$PlatformFilter"
            Download-And-Place-Exe -Url $url -TargetExe $exePath
        }

        Set-StoredVersion -ToolName $Name -Version $latest
    }
    else {
        Write-Host "✅ $Name is up to date."
    }
}

function Install-Or-Update-AzureCLI {
    Write-Host "`n🔍 Checking Azure CLI..."

    try {
        $current = & az version | ConvertFrom-Json | Select-Object -ExpandProperty azure-cli
    } catch {
        $current = "not-installed"
    }

    $head = Invoke-WebRequest -Uri "https://aka.ms/InstallAzureCliWindows" -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue
    $location = $head.Headers["Location"]

    if ($location -match "azure-cli-([\d\.]+)\.msi") {
        $latest = $Matches[1]
        Write-Host "Azure CLI current: $current, latest: $latest"

        if ($current -eq "not-installed" -or $current -ne $latest) {
            Write-Host "⬆️ Installing or updating Azure CLI..."

            if (Get-Process -Name "az" -ErrorAction SilentlyContinue) {
                Write-Host "⚠️ Detected running az process. Stopping it to update..."
                Get-Process -Name "az" -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 2
            }

            $msi = "$env:TEMP\azurecli.msi"
            Invoke-WebRequest -Uri $location -OutFile $msi
            Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
            Remove-Item $msi
            Write-Host "✅ Azure CLI installed or updated to $latest"
        } else {
            Write-Host "✅ Azure CLI is up to date."
        }
    } else {
        Write-Warning "⚠️ Could not resolve Azure CLI version from redirect."
    }
}

# === Run all tools ===
Install-Or-Update-Tool -Name "terraform" -Cmd "terraform" -Repo "hashicorp/terraform" -PlatformFilter "windows_amd64.zip" -Mode "zip"
Install-Or-Update-Tool -Name "kubectl"  -Cmd "kubectl"  -Repo "kubernetes/kubernetes" -PlatformFilter "kubectl.exe" -Mode "exe"
Install-Or-Update-Tool -Name "argocd"   -Cmd "argocd"   -Repo "argoproj/argo-cd"       -PlatformFilter "argocd-windows-amd64.exe" -Mode "exe"
Install-Or-Update-Tool -Name "kubelogin"-Cmd "kubelogin"-Repo "Azure/kubelogin"        -PlatformFilter "win-amd64.zip" -Mode "zip"

Install-Or-Update-AzureCLI

# Make tools immediately available in current session
$env:Path += ";$installPath"
