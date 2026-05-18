#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Azure CLI on Windows and adds it to the system PATH.

.DESCRIPTION
    DISCLAIMER: This script is provided as an EXAMPLE ONLY and is NOT a supported service
    offering. It is provided under the MIT License on an "AS-IS" basis, without warranty
    of any kind, express or implied. Use at your own risk.

    Downloads and installs the latest Azure CLI MSI for Windows x64,
    adds it to the system and session PATH, and verifies the installation.

.NOTES
    Must be run as Administrator (for MSI install and system PATH modification).
#>

# Ensure TLS 1.2 for downloads from aka.ms / Microsoft endpoints
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Set variables
$downloadUrl = "https://aka.ms/installazurecliwindowsx64"
$installerPath = "$env:TEMP\AzureCLI.msi"
$azureCliPath = "${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin"

Write-Host "Azure CLI Installation Script" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan

# Download Azure CLI installer
Write-Host "`nDownloading Azure CLI installer..." -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    Write-Host "Download completed successfully." -ForegroundColor Green
} catch {
    Write-Host "Error downloading installer: $_" -ForegroundColor Red
    exit 1
}

# Install Azure CLI
Write-Host "`nInstalling Azure CLI..." -ForegroundColor Yellow
try {
    Start-Process msiexec.exe -Wait -ArgumentList "/I $installerPath /quiet" -NoNewWindow
    Write-Host "Installation completed successfully." -ForegroundColor Green
} catch {
    Write-Host "Error during installation: $_" -ForegroundColor Red
    exit 1
}

# Add to PATH if not already present
Write-Host "`nChecking PATH environment variable..." -ForegroundColor Yellow
$machinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
$currentSessionPath = $env:Path

# Add to system PATH
if ($machinePath -notlike "*$azureCliPath*") {
    Write-Host "Adding Azure CLI to system PATH..." -ForegroundColor Yellow
    try {
        [Environment]::SetEnvironmentVariable(
            "Path",
            "$machinePath;$azureCliPath",
            [EnvironmentVariableTarget]::Machine
        )
        Write-Host "Azure CLI added to system PATH successfully." -ForegroundColor Green
    } catch {
        Write-Host "Error adding to system PATH: $_" -ForegroundColor Red
        Write-Host "You may need to run this script as Administrator." -ForegroundColor Yellow
    }
} else {
    Write-Host "Azure CLI is already in system PATH." -ForegroundColor Green
}

# Add to current session PATH
if ($currentSessionPath -notlike "*$azureCliPath*") {
    Write-Host "Adding Azure CLI to current session PATH..." -ForegroundColor Yellow
    $env:Path += ";${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin"; 
    Set-Alias az "${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd" -Scope Global
    Write-Host "Azure CLI added to current session successfully." -ForegroundColor Green
    Write-Host "You can now use 'az' commands in this session!" -ForegroundColor Cyan
} else {
    Write-Host "Azure CLI is already in current session PATH." -ForegroundColor Green
}

# Clean up installer
Write-Host "`nCleaning up..." -ForegroundColor Yellow
Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

# Verify installation
Write-Host "`nVerifying installation..." -ForegroundColor Yellow
try {
    # Update PATH for current session to ensure az is available
    $env:Path = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    
    $azVersion = az --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nAzure CLI installed successfully!" -ForegroundColor Green
        Write-Host "Version information:" -ForegroundColor Cyan
        Write-Host $azVersion
    } else {
        Write-Host "Installation completed but verification failed." -ForegroundColor Yellow
        Write-Host "Try running 'az --version' manually." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Could not verify installation immediately." -ForegroundColor Yellow
    Write-Host "Try running 'az --version' manually." -ForegroundColor Yellow
}

Write-Host "`nInstallation process completed!" -ForegroundColor Green
Write-Host "You can now use 'az' commands in this terminal session!" -ForegroundColor Cyan