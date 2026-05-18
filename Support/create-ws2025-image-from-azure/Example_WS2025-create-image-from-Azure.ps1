
<#
.SYNOPSIS
    Downloads a Windows Server 2025 Datacenter VHD from Azure Marketplace and imports it
    into Azure Stack Hub as a platform image.

.DESCRIPTION
    DISCLAIMER: This script is provided as an EXAMPLE ONLY and is NOT a supported service
    offering. It is provided under the MIT License on an "AS-IS" basis, without warranty
    of any kind, express or implied. Use at your own risk.

    This script performs the following steps:
      1. Installs the required PowerShell modules (Az, AzureStack).
      2. Logs into public Azure via Azure CLI and finds the latest WS2025 Gen1 image.
      3. Creates a managed disk from that marketplace image, then exports the VHD using AzCopy.
      4. Connects to Azure Stack Hub, uploads the VHD to a storage account.
      5. Registers the VHD as a platform image in the Azure Stack Hub marketplace.

.NOTES
    Prerequisites:
      - Azure CLI installed (see _Pre-req_Install_AzCLI.ps1)
      - Run as Administrator
      - Azure Stack Hub admin access
      - Sufficient disk space for the VHD download (~30 GB for full disk, ~10 GB for small disk)

    Adjust the parameters below to match your environment before running.

.PARAMETER CleanAzModules
    If specified, uninstalls every existing Az.*, Azs.* and Azure* PowerShell module on the
    machine before installing the 2020-09-01-hybrid profile. WARNING: this affects every
    PowerShell session on this workstation, not just this script. Off by default.

.PARAMETER ClearAzCliAccount
    If specified, runs 'az account clear' which removes ALL cached Azure CLI sessions on
    this machine before logging in. Off by default.

.PARAMETER AzureLocation
    Azure (public cloud) region used to create the temporary managed disk. Default: eastus.
#>
[CmdletBinding()]
param(
    [switch]$CleanAzModules,
    [switch]$ClearAzCliAccount,
    [string]$AzureLocation = 'eastus'
)

#region ========================== PARAMETERS - EDIT THESE ==========================

# --- Azure (public cloud) settings ---
$AzureResourceGroup        = "ws2025-image-rg"          # Resource group in Azure to create the temp disk
$AzureDiskName             = "WindowsServer-2025"        # Name for the temporary managed disk in Azure

# --- Local download settings ---
$VhdDownloadPath           = "C:\VHDs\WS2025-datacenter.vhd"  # Local path to save the downloaded VHD

# --- Azure Stack Hub settings ---
$EnvironmentName           = "AzureStackEnv"             # Name for the Az environment registration
$AdminArmEndpoint          = "https://adminmanagement.<region>.<fqdn>"  # Azure Stack Hub admin ARM endpoint
$TenantID                  = "<your-aad-tenant-id>"      # Azure AD tenant ID for your Azure Stack Hub
$HubLocation               = "<your-hub-region>"         # Azure Stack Hub region (e.g., "local", "redmond")
$StorageEndpointDnsSuffix  = "<region>.<fqdn>"           # External domain suffix (e.g., "local.azurestack.external")
$KeyVaultDnsSuffix         = "vault.$StorageEndpointDnsSuffix"

# Azure Stack Hub credentials (service admin)
$ServiceAdminUserName      = "<service-admin-upn>"       # e.g., admin@contoso.onmicrosoft.com
# Prompt for the password interactively (do NOT hard-code passwords)
$ServiceAdminCredential    = Get-Credential -UserName $ServiceAdminUserName -Message "Enter Azure Stack Hub Service Admin password"

# Azure Stack Hub storage settings
$HubResourceGroup          = "ws2025-image-rg"           # Resource group on Azure Stack Hub for the storage account
$HubStorageAccountName     = "ws2025vhds"                # Storage account name on Azure Stack Hub (3-24 lowercase alphanumeric)

#endregion ==========================================================================

# ==================================================================================
# Step 1: Install required PowerShell modules
# ==================================================================================
Write-Host "`n[Step 1] Installing required PowerShell modules..." -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Install-Module PowershellGet -MinimumVersion 2.2.3 -Repository PSGallery -Force -ErrorAction SilentlyContinue

if ($CleanAzModules) {
    Write-Host "  -CleanAzModules specified: uninstalling existing Az / Azs / Azure modules (this affects ALL PowerShell sessions on this machine)..." -ForegroundColor Yellow
    Get-Module -Name Azure* -ListAvailable | Uninstall-Module -Force -Verbose -ErrorAction Continue
    Get-Module -Name Azs.* -ListAvailable | Uninstall-Module -Force -Verbose -ErrorAction Continue
    Get-Module -Name Az.* -ListAvailable | Uninstall-Module -Force -Verbose -ErrorAction Continue
} else {
    Write-Host "  Skipping module cleanup (re-run with -CleanAzModules if you need a clean reinstall)." -ForegroundColor DarkGray
}

Install-Module -Name Az.BootStrapper -Repository PSGallery -Force
Install-AzProfile -Profile 2020-09-01-hybrid -Force
Install-Module -Name AzureStack -RequiredVersion 2.4.0

Get-Module -Name "Az*" -ListAvailable
Get-Module -Name "Azs*" -ListAvailable

Import-Module -Name Az -Force -DisableNameChecking | Out-Null

# ==================================================================================
# Step 2: Log into public Azure and find the latest WS2025 Gen1 image
# ==================================================================================
Write-Host "`n[Step 2] Logging into public Azure and finding WS2025 image..." -ForegroundColor Cyan

if ($ClearAzCliAccount) {
    Write-Host "  -ClearAzCliAccount specified: clearing all cached Azure CLI sessions on this machine..." -ForegroundColor Yellow
    az account clear
}
az login --use-device-code
az account show

# Find all Windows Server 2025 images (Gen1 only, no Upgrade SKUs)
Write-Host "Querying Azure Marketplace for Windows Server 2025 images (this can take up to a minute)..." -ForegroundColor Yellow
$images = az vm image list --all `
        --publisher MicrosoftWindowsServer `
        --offer WindowsServer `
        --output json | ConvertFrom-Json

$filteredImages = $images | Where-Object {
    $_.sku -like "*2025*" -and $_.sku -inotlike "*Upgrade*"
}

$gen1Images = $filteredImages | Where-Object {
    $_.sku -notlike "*-g2" -and
    $_.sku -notlike "*-gen2" -and
    $_.sku -inotlike "*azure-edition*"   # Azure Edition SKUs are not supported on Azure Stack Hub
}

# Group by SKU and pick the latest version of each
$latestBySku = $gen1Images | Group-Object -Property sku | ForEach-Object {
    $_.Group | Sort-Object version -Descending | Select-Object -First 1
} | Sort-Object sku

if (-not $latestBySku -or $latestBySku.Count -eq 0) {
    throw "No Windows Server 2025 Gen1 images found in the Azure Marketplace."
}

# Display available images and prompt the user to choose
Write-Host "`nAvailable Windows Server 2025 Gen1 images:" -ForegroundColor Yellow
Write-Host ("-" * 80) -ForegroundColor DarkGray
for ($i = 0; $i -lt $latestBySku.Count; $i++) {
    $img = $latestBySku[$i]
    Write-Host "  [$($i + 1)]  $($img.sku)  (version $($img.version))" -ForegroundColor White
}
Write-Host ("-" * 80) -ForegroundColor DarkGray

do {
    $choice = Read-Host "`nEnter the number of the image to download (1-$($latestBySku.Count))"
    $choiceIndex = $choice -as [int]
} while ($choiceIndex -lt 1 -or $choiceIndex -gt $latestBySku.Count)

$selectedImage = $latestBySku[$choiceIndex - 1]
Write-Host "`nSelected image: $($selectedImage.urn)" -ForegroundColor Green

# ==================================================================================
# Step 3: Create a managed disk from the marketplace image and export VHD
# ==================================================================================
Write-Host "`n[Step 3] Creating managed disk and exporting VHD..." -ForegroundColor Cyan

az group create -n $AzureResourceGroup -l $AzureLocation --output none 2>$null

az disk create `
  -g $AzureResourceGroup `
  -n $AzureDiskName `
  --image-reference $selectedImage.urn

$diskAccess = az disk grant-access `
  --duration-in-seconds 3600 `
  --access-level Read `
  --name $AzureDiskName `
  --resource-group $AzureResourceGroup `
  -o json | ConvertFrom-Json

# Download AzCopy (recommended over Invoke-WebRequest for large files)
$azcopyFolder = Join-Path $env:TEMP "azcopy"
if (Test-Path $azcopyFolder) {
    Remove-Item $azcopyFolder -Recurse -Force
}
New-Item -Path $azcopyFolder -ItemType Directory | Out-Null
$azcopyZipFile = Join-Path $azcopyFolder "AzCopy.zip"
Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile $azcopyZipFile
Expand-Archive -Path $azcopyZipFile -DestinationPath $azcopyFolder -Force
$azCopyExe = (Get-ChildItem -Path $azcopyFolder -Recurse | Where-Object { $_.Name -eq "azcopy.exe" }).FullName
if (-not $azCopyExe -or -not (Test-Path $azCopyExe)) {
    throw "Failed to download or locate azcopy executable."
}

# Ensure the download directory exists
$vhdDir = Split-Path $VhdDownloadPath -Parent
if (-not (Test-Path $vhdDir)) { New-Item -Path $vhdDir -ItemType Directory -Force | Out-Null }

Write-Host "Downloading VHD to $VhdDownloadPath (this may take a while)..." -ForegroundColor Yellow
& $azCopyExe cp $diskAccess.accessSas $VhdDownloadPath

# Revoke disk access and clean up Azure resources
az disk revoke-access -g $AzureResourceGroup -n $AzureDiskName
Write-Host "VHD downloaded successfully." -ForegroundColor Green

# Prompt to delete the temporary Azure resources to avoid ongoing costs
$cleanup = Read-Host "`nDelete the temporary resource group '$AzureResourceGroup' in Azure to avoid costs? (Y/N)"
if ($cleanup -ieq 'Y') {
    Write-Host "Deleting resource group '$AzureResourceGroup'..." -ForegroundColor Yellow
    az group delete -n $AzureResourceGroup --yes --no-wait --output none
    Write-Host "Resource group deletion initiated (running in background)." -ForegroundColor Green
} else {
    Write-Host "Skipped. Remember to delete resource group '$AzureResourceGroup' manually to avoid costs." -ForegroundColor Yellow
}

# ==================================================================================
# Step 4: Connect to Azure Stack Hub
# ==================================================================================
Write-Host "`n[Step 4] Connecting to Azure Stack Hub..." -ForegroundColor Cyan

$hubEnvironment = Get-AzEnvironment -Name $EnvironmentName
if ($hubEnvironment) {
    Remove-AzEnvironment -Name $EnvironmentName
}

$response = Invoke-RestMethod "${AdminArmEndpoint}/metadata/endpoints?api-version=1.0"
Write-Host "  ARM endpoint:      $AdminArmEndpoint"
Write-Host "  Gallery endpoint:  $($response.galleryEndpoint)"

$hubAdminEnvironmentParams = @{
    Name                                     = $EnvironmentName
    ActiveDirectoryEndpoint                  = $response.authentication.loginEndpoint.TrimEnd('/') + "/"
    ActiveDirectoryServiceEndpointResourceId = $response.authentication.audiences[0]
    ResourceManagerEndpoint                  = $AdminArmEndpoint
    GalleryEndpoint                          = $response.galleryEndpoint
    GraphEndpoint                            = $response.graphEndpoint
    GraphAudience                            = $response.graphEndpoint
    EnableAdfsAuthentication                 = $response.authentication.loginEndpoint.TrimEnd("/").EndsWith("/adfs", [System.StringComparison]::OrdinalIgnoreCase)
    StorageEndpoint                          = $StorageEndpointDnsSuffix
    AzureKeyVaultDnsSuffix                   = $KeyVaultDnsSuffix
}
Add-AzEnvironment @hubAdminEnvironmentParams | Out-Null
$hubEnvironment = Get-AzEnvironment -Name $EnvironmentName

Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
Connect-AzAccount -Environment $EnvironmentName -Credential $ServiceAdminCredential -Tenant $TenantID
Write-Host "Connected to Azure Stack Hub." -ForegroundColor Green
Get-AzSubscription | Format-Table -Property SubscriptionId, Name, TenantId

# ==================================================================================
# Step 5: Upload VHD to Azure Stack Hub storage account
# ==================================================================================
Write-Host "`n[Step 5] Uploading VHD to Azure Stack Hub..." -ForegroundColor Cyan

New-AzResourceGroup -Name $HubResourceGroup -Location $HubLocation -Force | Out-Null

New-AzStorageAccount `
  -ResourceGroupName $HubResourceGroup `
  -Name $HubStorageAccountName `
  -Location $HubLocation `
  -SkuName Standard_LRS

$storageKeys = Get-AzStorageAccountKey -ResourceGroupName $HubResourceGroup -Name $HubStorageAccountName
$ctx = New-AzStorageContext -StorageAccountName $HubStorageAccountName -StorageAccountKey $storageKeys[0].Value

$osUri = "https://$HubStorageAccountName.blob.$StorageEndpointDnsSuffix/vhds/WS2025-datacenter.vhd"

Write-Host "Uploading VHD (this may take a while)..." -ForegroundColor Yellow
Add-AzVhd `
    -LocalFilePath $VhdDownloadPath `
    -ResourceGroupName $HubResourceGroup `
    -Destination $osUri

Write-Host "VHD uploaded successfully." -ForegroundColor Green

# ==================================================================================
# Step 6: Register as a platform image in Azure Stack Hub marketplace
# ==================================================================================
Write-Host "`n[Step 6] Registering platform image in Azure Stack Hub marketplace..." -ForegroundColor Cyan

$storageAccount = Get-AzStorageAccount -ResourceGroupName $HubResourceGroup -Name $HubStorageAccountName
$ctx = $storageAccount.Context
$containerName = "vhds"
$blobName = "WS2025-datacenter.vhd"
$sasToken = New-AzStorageBlobSASToken `
    -Container $containerName `
    -Blob $blobName `
    -Permission r `
    -ExpiryTime (Get-Date).AddHours(24) `
    -Context $ctx
$osSasUri = "$($ctx.BlobEndPoint)$containerName/$blobName$sasToken"

Add-AzsPlatformImage `
    -Location $HubLocation `
    -Publisher "MicrosoftWindowsServer" `
    -Offer "WindowsServer" `
    -Sku $selectedImage.sku `
    -Version $selectedImage.version `
    -OSType "Windows" `
    -OSUri $osSasUri

# Verify the image was registered
$platformImages = Get-AzsPlatformImage
$ws2025Image = $platformImages | Where-Object {
    $_.Publisher -eq "MicrosoftWindowsServer" -and
    $_.Offer -eq "WindowsServer" -and
    $_.Sku -eq $selectedImage.sku
}

if ($ws2025Image) {
    Write-Host "`nWindows Server 2025 ($($selectedImage.sku)) image registered successfully!" -ForegroundColor Green
    $ws2025Image | Format-List
} else {
    Write-Host "`nWarning: Image registration could not be verified." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Cyan
