# 1. Download and install Azure CLI, should always be latest
$ProgressPreference = 'Continue'

Write-Host "Step 1: Downloading Azure CLI installer..."
Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindowsx64" -OutFile ".\AzureCLI.msi"

Write-Host "Step 2: Installing Azure CLI silently..."
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'

Write-Host "Step 3: Cleaning up installer file..."
Remove-Item .\AzureCLI.msi

Write-Host "Azure CLI installation complete.`n"

# v2 removed user creation as that is not possible

# 4. Download kubelogin from GitHub (asset + unzip)
$headers = @{ "User-Agent" = "PowerShell" }
Write-Host "Step 7: Downloading latest kubelogin release..."
$kubeloginApi = "https://api.github.com/repos/Azure/kubelogin/releases/latest"
$kubeloginRelease = Invoke-RestMethod -Uri $kubeloginApi -Headers $headers
$kubeloginAsset = $kubeloginRelease.assets | Where-Object { $_.name -like "*kubelogin-win-amd64.zip*" } | Select-Object -First 1

if ($kubeloginAsset) {
    $fileName = $kubeloginAsset.name
    $tempPath = "$env:TEMP\$fileName"
    Invoke-WebRequest -Uri $kubeloginAsset.browser_download_url -OutFile $tempPath -UseBasicParsing

    Write-Host "Extracting kubelogin zip and copying binaries to System32..."
    $extractPath = "$env:TEMP\$($fileName -replace '\.zip$', '')"
    Expand-Archive -Path $tempPath -DestinationPath $extractPath -Force
    Get-ChildItem -Path $extractPath -Recurse -File | ForEach-Object {
        Copy-Item $_.FullName -Destination "C:\Windows\System32" -Force
    }
    Remove-Item $tempPath -Force
    Remove-Item $extractPath -Recurse -Force
    Write-Host "kubelogin installation complete.`n"
} else {
    Write-Host "kubelogin asset not found! Skipping.`n"
}

# 5. Download argocd.exe by constructing URL manually with tag_name
Write-Host "Step 8: Downloading latest argocd executable..."
$argoApi = "https://api.github.com/repos/argoproj/argo-cd/releases/latest"
$argoRelease = Invoke-RestMethod -Uri $argoApi -Headers $headers
$argoVersion = $argoRelease.tag_name
$argocdFileName = "argocd-windows-amd64.exe"
$argocdUrl = "https://github.com/argoproj/argo-cd/releases/download/$argoVersion/$argocdFileName"
$argocdTemp = "$env:TEMP\$argocdFileName"
$argocdDest = "C:\Windows\System32\argocd.exe"

Invoke-WebRequest -Uri $argocdUrl -OutFile $argocdTemp -UseBasicParsing
Copy-Item $argocdTemp -Destination $argocdDest -Force
Remove-Item $argocdTemp -Force
Write-Host "argocd installation complete.`n"

# 6. Download kubectl using stable.txt
Write-Host "Step 9: Downloading latest stable kubectl..."
$kubectlVersion = Invoke-RestMethod -Uri "https://cdn.dl.k8s.io/release/stable.txt"
$kubectlUrl = "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe"
$kubectlDest = "C:\Windows\System32\kubectl.exe"
$kubectlTemp = "$env:TEMP\kubectl.exe"

Invoke-WebRequest -Uri $kubectlUrl -OutFile $kubectlTemp -UseBasicParsing
Copy-Item $kubectlTemp -Destination $kubectlDest -Force
Remove-Item $kubectlTemp -Force
Write-Host "kubectl installation complete.`n"

# 7. Verify installed versions
Write-Host "Step 10: Verifying installed versions..."

Write-Host "`naz version:"
az version

Write-Host "`nkubelogin version:"
kubelogin --version

Write-Host "`nargocd version:"
argocd version

Write-Host "`nkubectl version:"
kubectl version --client

Write-Host "`nAll steps completed successfully."
