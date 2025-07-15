#RUN AS ADMINISTRATOR
# This script will skip the MS Edge first launch config
# it will always show the bookmark bar
# it will add 3 shortcuts to the portal, argocd and grafana
# 

# Prompt user for prerequisites
$prereq = Read-Host @"
Before running this script, please ensure:
- You are running this script as Administrator.
- Microsoft Edge has been launched at least once to create the user profile.

Have you completed these steps? (Y/N)
"@

if (-not ($prereq -match '^[Yy]$')) {
    Write-Host "Please complete the prerequisites before running this script. Exiting." -ForegroundColor Red
    exit
}

# Ask user to pick environment
Write-Host "Choose an environment to configure bookmarks and AKS settings:"
Write-Host "1) dev"
Write-Host "2) tst"
Write-Host "3) acc"
Write-Host "4) prd"

$envChoice = Read-Host "Enter 1, 2, 3, or 4"

switch ($envChoice) {
    '1' {
        $env = 'dev'
        $resourceGroup = '<fill-in-rg>'
        $clusterName = '<fill-in-aks-name>'
    }
    '2' {
        $env = 'tst'
        $resourceGroup = '<fill-in-rg>'
        $clusterName = '<fill-in-aks-name>'
    }
    '3' {
        $env = 'acc'
        $resourceGroup = '<fill-in-rg>'
        $clusterName = '<fill-in-aks-name>'
    }
    '4' {
        $env = 'prd'
        $resourceGroup = '<fill-in-rg>'
        $clusterName = '<fill-in-aks-name>'
    }
    default {
        Write-Host "Invalid choice, exiting." -ForegroundColor Red
        exit
    }
}

# Configure Edge policies
$edgePoliciesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
Write-Host "Applying Edge policy registry settings to disable first run experience and show favorites bar..."

if (-Not (Test-Path $edgePoliciesPath)) {
    New-Item -Path $edgePoliciesPath -Force | Out-Null
}

Set-ItemProperty -Path $edgePoliciesPath -Name "HideFirstRunExperience" -Value 1 -Type DWord
Set-ItemProperty -Path $edgePoliciesPath -Name "ShowFavoritesBar" -Value 1 -Type DWord

Write-Host "Registry configuration complete.`n"

# Define bookmarks path
$bookmarksPath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
$profilePath = Split-Path $bookmarksPath

# Wait for Edge profile to be created
Write-Host "Waiting for Edge user profile to be created..."
while (-Not (Test-Path $profilePath)) {
    Start-Sleep -Seconds 3
}

# Create bookmarks file if it doesn't exist
if (-Not (Test-Path $bookmarksPath)) {
    Write-Host "Creating default bookmarks file..."
    $defaultBookmarks = @{
        roots = @{
            bookmark_bar = @{
                children = @()
                name = "Bookmarks Bar"
                type = "folder"
            }
            other = @{
                children = @()
                name = "Other Bookmarks"
                type = "folder"
            }
            synced = @{
                children = @()
                name = "Mobile Bookmarks"
                type = "folder"
            }
        }
        version = 1
    }
    $defaultBookmarks | ConvertTo-Json -Depth 10 | Set-Content -Path $bookmarksPath -Encoding UTF8
    Write-Host "Bookmarks file created."
}

# Load bookmarks JSON
$bookmarksJson = Get-Content $bookmarksPath -Raw | ConvertFrom-Json

# Add environment-specific bookmarks
$newBookmarks = @(
    @{ name = "ArgoCD"; type = "url"; url = "https://argocd.shaks.$env.<url>/" },
    @{ name = "Grafana"; type = "url"; url = "https://grafana.shaks.$env.<url>/" },
    @{ name = "Azure portal"; type = "url"; url = "https://portal.azure.com/" }
)

Write-Host "Adding bookmarks to the favorites bar..."

# Ensure 'children' array exists
if (-not $bookmarksJson.roots.bookmark_bar.PSObject.Properties.Name -contains 'children') {
    $bookmarksJson.roots.bookmark_bar | Add-Member -MemberType NoteProperty -Name 'children' -Value @()
}

foreach ($bookmark in $newBookmarks) {
    $bookmarksJson.roots.bookmark_bar.children += $bookmark
}

$bookmarksJson | ConvertTo-Json -Depth 10 | Set-Content -Path $bookmarksPath -Encoding UTF8

Write-Host "`nEdge bookmarks configuration complete." -ForegroundColor Green

# Ask for Azure login
$response = Read-Host "Do you want to login with az login? (Y/N)"

if ($response -match '^[Yy]$') {
    Write-Host "Launching Azure login popup..."
    $loginResult = az login 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Azure login failed. Exiting." -ForegroundColor Red
        exit
    }

    Write-Host "Azure login succeeded."

    # Ask whether to continue with AKS credentials and kubelogin
    $aksResponse = Read-Host "Do you want to download AKS credentials and run kubelogin? (Y/N)"

    if ($aksResponse -match '^[Yy]$') {
        Write-Host "Downloading AKS credentials for environment: $env..."
        az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing

        Write-Host "Converting kubeconfig to use Azure CLI with kubelogin..."
        kubelogin convert-kubeconfig -l azurecli

        Write-Host "AKS credentials configured successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Skipping AKS credentials and kubelogin setup."
    }
}
else {
    Write-Host "Skipping Azure CLI login and AKS configuration."
}
