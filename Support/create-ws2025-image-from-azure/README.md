> **Disclaimer:** This is provided as an **example only** and is **not a supported service offering**. It is provided under the [MIT License](https://opensource.org/licenses/MIT) on an **"as-is" basis, without warranty of any kind**, express or implied. Use at your own risk.

# Windows Server 2025 Image for Azure Stack Hub

Scripts to download a **Windows Server 2025 Datacenter** GEN1 VHD from the Azure Marketplace and register it as a platform image in **Azure Stack Hub**.

## Overview

Azure Stack Hub operators who cannot use the built-in Marketplace syndication (e.g., disconnected or partially-connected environments) can use these scripts to manually obtain and import the WS2025 image.

### Workflow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  PUBLIC AZURE                                                                   │
│                                                                                 │
│  Step 1 ─ Install Az & AzureStack PowerShell modules                            │
│                                                                                 │
│  Step 2 ─ Log in via Azure CLI (device-code flow)                               │
│           Query Marketplace for latest WS2025 Gen1 image URN                    │
│                                                                                 │
│  Step 3 ─ Create a temporary managed disk from the Marketplace image            │
│           Grant read access → generate SAS URL                                  │
│           Download the VHD to the local machine using AzCopy                    │
│           Revoke disk access                                                    │
│                              │                                                  │
└──────────────────────────────┼──────────────────────────────────────────────────┘
                               │  Save VHD file on local disk, and transfer
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  AZURE STACK HUB (Admin ARM Endpoint)                                           │
│                                                                                 │
│  Step 4 ─ Register the Hub environment & connect as Service Admin               │
│                                                                                 │
│  Step 5 ─ Create a storage account on the Hub Admin                             │
│           Upload the VHD with Add-AzVhd                                         │
│                                                                                 │
│  Step 6 ─ Register the VHD as a platform image (Add-AzsPlatformImage)           │
│           Verify the image appears in the Hub Marketplace                       │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

| Step | Environment | What happens | Tools used |
|------|-------------|-------------|------------|
| **1** | Local machine | Installs the required PowerShell modules (`Az` 2020-09-01-hybrid profile, `AzureStack 2.4.0`). | `Install-Module` |
| **2** | Public Azure | Logs in via Azure CLI with device-code auth, then queries the Marketplace for the latest **Windows Server 2025 Datacenter Gen1** image URN (excluding Gen2 & Upgrade SKUs). | `az login`, `az vm image list` |
| **3** | Public Azure → Local | Creates a temporary **managed disk** from the Marketplace image, grants read access to obtain a SAS URL, and downloads the disk as a fixed-size VHD using **AzCopy v10**. Revokes disk access when done. | `az disk create`, `az disk grant-access`, AzCopy |
| **4** | Azure Stack Hub | Registers the Hub's Admin ARM endpoint as a PowerShell environment and authenticates as the **Service Admin**. | `Add-AzEnvironment`, `Connect-AzAccount` |
| **5** | Azure Stack Hub | Creates a resource group and storage account on the Hub, then uploads the local VHD using `Add-AzVhd`. | `New-AzStorageAccount`, `Add-AzVhd` |
| **6** | Azure Stack Hub | Registers the uploaded VHD as a **platform image** (publisher: `MicrosoftWindowsServer`, offer: `WindowsServer`, SKU: `2025-Datacenter`) and verifies it is available in the Hub Marketplace for tenant use. | `Add-AzsPlatformImage`, `Get-AzsPlatformImage` |

## Prerequisites

| Requirement | Details |
|---|---|
| **OS** | Windows (scripts use PowerShell 5.1+) |
| **Azure CLI** | Required for marketplace image discovery and disk operations. Install with `_Pre-req_Install_AzCLI.ps1`. |
| **Azure subscription** | Needed temporarily to create a managed disk from the marketplace image. |
| **Azure Stack Hub admin access** | Service Admin credentials and the Admin ARM endpoint. |
| **Disk space** | ~30 GB for the full-disk VHD, ~10 GB for small-disk. |
| **PowerShell modules** | Installed automatically by the script: `Az` (2020-09-01-hybrid profile), `AzureStack 2.4.0`. |

> [!IMPORTANT]
> **Service Admin authentication (no MFA).**
> The script uses `Connect-AzAccount -Credential`, which **does not support MFA or Conditional Access**. Use a Service Admin account that is exempt from MFA, or modify Step 4 to use interactive `Connect-AzAccount -Environment $EnvironmentName -Tenant $TenantID` (drop `-Credential`).

> [!IMPORTANT]
> **Hub admin endpoint certificate must be trusted.**
> Step 4 calls `Invoke-RestMethod` against the Hub admin ARM endpoint. If that endpoint uses an internal CA / self-signed certificate that is not trusted on the workstation, the call will fail. Import the Hub's CA certificate into the workstation's Trusted Root store before running the script.

## Scripts

### `_Pre-req_Install_AzCLI.ps1`

Installs Azure CLI on Windows and adds it to the system PATH. Run this first if Azure CLI is not already installed.

```powershell
# Run as Administrator
.\_Pre-req_Install_AzCLI.ps1
```

### `Example_WS2025-create-image-from-Azure.ps1`

Main script that performs the full end-to-end workflow. **Before running**, open the script and update the parameters in the `PARAMETERS` section at the top:

| Parameter | Description | Example |
|---|---|---|
| `$AzureResourceGroup` | Temp resource group in Azure for the managed disk | `ws2025-image-rg` |
| `$VhdDownloadPath` | Local path to save the VHD | `C:\VHDs\WS2025-datacenter.vhd` |
| `$AdminArmEndpoint` | Azure Stack Hub admin ARM endpoint | `https://adminmanagement.local.azurestack.external` |
| `$TenantID` | Azure AD tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `$HubLocation` | Azure Stack Hub region name | `local` |
| `$StorageEndpointDnsSuffix` | External domain suffix | `local.azurestack.external` |
| `$ServiceAdminUserName` | Service admin UPN | `admin@contoso.onmicrosoft.com` |
| `$HubResourceGroup` | Resource group on the Hub for storage | `ws2025-image-rg` |
| `$HubStorageAccountName` | Storage account name on the Hub | `ws2025vhds` |

```powershell
# Run as Administrator
.\Example_WS2025-create-image-from-Azure.ps1
```

The script will prompt for the service admin password interactively.

**Optional switches:**

| Switch | Effect |
|---|---|
| `-CleanAzModules` | Uninstalls every existing `Az.*` / `Azs.*` / `Azure*` PowerShell module before installing the hybrid profile. **Off by default** because this affects every PowerShell session on the workstation, not just this script. Use only when you need a clean reinstall. |
| `-ClearAzCliAccount` | Runs `az account clear` before login, removing all cached Azure CLI sessions on the machine. **Off by default.** |
| `-AzureLocation <region>` | Public-Azure region used to create the temporary managed disk. Defaults to `eastus`. |

## VM Licensing & Billing (ARM `LicenseType`)

This section covers **billing**: how Microsoft meters and charges for the Windows Server VM. It is controlled by the `LicenseType` ARM property on the VM resource, set **per-VM** at deployment time (and changeable later with stop/deallocate + `Update-AzVM`). It is **not** part of the platform image.

> **Note:** Azure Stack Hub is considered **on-premises hardware** for licensing purposes. Azure Hybrid Use Benefit (AHUB) is **not required** to use your own Windows Server licenses on Azure Stack Hub (see the [Azure Stack Hub Licensing Guide](https://go.microsoft.com/fwlink/?LinkId=2273601&clcid=0x409) FAQ).

### Pay-as-you-use billing model

In the pay-as-you-use model, Azure Stack Hub meters each VM and reports usage to Azure Commerce. The `LicenseType` property controls which meter is used:

| `LicenseType` value | Meter used | When to use |
|---|---|---|
| *Not set* (default) | **Windows Server VM meter** — Windows license cost is included in the per-vCPU/min rate. | You do not have your own Windows Server licenses. |
| `"Windows_Server"` | **Base VM meter** only — lower rate, no Windows license cost included. | You are bringing your own on-premises Windows Server licenses covering all physical cores in the Azure Stack Hub region. |

**Default (Windows Server PAYG VM meter):**

```powershell
# No LicenseType — Windows license included in billing
New-AzVM -ResourceGroupName "myRG" -Name "myVM" `
    -Image "MicrosoftWindowsServer:WindowsServer:2025-Datacenter:latest" `
    -Location "local" `
    -Credential (Get-Credential)
```

**Using your own Windows Server license (Base VM meter):**

```powershell
# LicenseType = "Windows_Server" — bring your own license, billed at Base VM rate
New-AzVM -ResourceGroupName "myRG" -Name "myVM" `
    -Image "MicrosoftWindowsServer:WindowsServer:2025-Datacenter:latest" `
    -LicenseType "Windows_Server" `
    -Location "local" `
    -Credential (Get-Credential)
```

**ARM Template (under `Microsoft.Compute/virtualMachines` properties):**

```json
{
  "type": "Microsoft.Compute/virtualMachines",
  "properties": {
    "licenseType": "Windows_Server",
    ...
  }
}
```

**Update an existing VM:**

```powershell
$vm = Get-AzVM -ResourceGroupName "myRG" -Name "myVM"
$vm.LicenseType = "Windows_Server"
Update-AzVM -ResourceGroupName "myRG" -VM $vm
```

> **Important:** When bringing your own Windows Server licenses, you must have enough Windows Server core licenses to cover **all physical cores** in the Azure Stack Hub region, regardless of how many Windows Server VMs are actually deployed. All cores must be covered with the **same edition** — all Datacenter **or** all Standard — because a VM can be scheduled on any node in the region (Datacenter is recommended for heavily virtualised workloads). Volume Licensing customers must also hold sufficient **Windows Server CALs** for the use case.

### Capacity billing model

In the capacity model, Windows Server guest licenses are **not included** in the annual per-core subscription fee. You must have separate Windows Server Volume Licensing (VL) licenses covering all physical cores in the Azure Stack Hub region. The `LicenseType` property has no billing effect in this model since usage is not reported to Azure Commerce.

For official information, refer to the [Azure Stack Hub Licensing, Packaging & Pricing Guide](https://go.microsoft.com/fwlink/?LinkId=2273601&clcid=0x409).

> [!IMPORTANT]
> **`LicenseType` (billing) and KMS (activation) are two separate, independent concerns.**
>
> - `LicenseType` controls **billing** — which meter Azure Commerce uses for the VM.
> - **KMS** controls **activation** — how the guest OS proves it is genuine.
>
> A VM can be PAYG-billed and KMS-activated, **or** BYOL-billed and KMS-activated. The activation method does not change the meter, and the meter does not change activation. They never need to "match".

## Guest OS Activation (KMS)

This section covers **guest OS activation**: how the Windows Server 2025 guest OS proves it is genuine. Activation lives **inside the guest OS**, completely outside ARM. It has **no** effect on billing, does not talk to ARM, and does not read `LicenseType`.

**KMS activation is required** for Windows Server 2025 guest VMs on Azure Stack Hub:

- **AVMA** (Automatic Virtual Machine Activation) is **not supported** for Windows Server 2025 guests on Azure Stack Hub.
- The **Azure-hosted KMS endpoints** used by public Azure marketplace images are not reachable/applicable on Hub.
- **MAK** keys can be used but are typically reserved for one-off / disconnected scenarios.

Ensure your environment has access to a reachable **KMS host** (e.g., an on-premises KMS server) so that WS2025 VMs can activate after deployment.

### Billing and activation are independent — supported combinations

Any supported activation method works with **either** billing model. The activation host (KMS / MAK) does not query ARM and has no knowledge of `LicenseType`; the Azure Commerce meter has no knowledge of how the OS activated. Pick the billing model and activation method **independently**, based on what you have available:

| `LicenseType` (billing) | Activation method | Supported on Hub? | Typical use |
|---|---|---|---|
| *unset* — **PAYG** (Windows Server VM meter) | **On-prem KMS** | ✅ Yes | **Most common** — Windows licence is in the meter; on-prem KMS handles the activation handshake. No region-wide licensing obligation. |
| *unset* — **PAYG** | **MAK** | ✅ Yes | Works, but uses up a MAK activation count for no commercial benefit; rarely the right choice. |
| *unset* — **PAYG** | **AVMA** | ❌ No | AVMA is not supported for WS2025 guests on Hub. |
| *unset* — **PAYG** | **Azure-hosted KMS** | ❌ No | Public-Azure KMS endpoints are not reachable from Hub. |
| `Windows_Server` — **BYOL** (Base VM meter) | **On-prem KMS** | ✅ Yes | Standard BYOL pattern; requires region-wide WS Datacenter/Standard licensing (all physical cores, same edition). |
| `Windows_Server` — **BYOL** | **MAK** | ✅ Yes | Useful for disconnected or one-off scenarios. |
| `Windows_Server` — **BYOL** | **AVMA** | ❌ No | AVMA is not supported for WS2025 guests on Hub. |

> **Key point:** "PAYG with on-prem KMS" is a **fully supported, normal configuration** — and it is the right default for tenants who do not want to commit to BYOL's all-physical-cores licensing obligation. Activating via KMS does **not** make the VM "BYOL", and it does **not** mean you are double-paying. Under PAYG, the Windows Server licence entitlement is provided by the meter you are paying; KMS is only the technical handshake that confirms the OS is genuine.

> **Important — KMS is activation, not licensing:** Using KMS to activate Windows Server 2025 VMs does **not** remove or bypass any licensing obligation you have for Windows Server. KMS is only an **activation mechanism** — it confirms the OS is genuine and enables full functionality, but it does not grant a licence entitlement. The licensing obligation depends on your billing model:
>
> - **PAYG** (`LicenseType` unset, Windows Server VM meter) — the Windows Server licence is included in the per-vCPU meter; no separate Windows Server licences are required.
> - **BYOL** (`LicenseType="Windows_Server"`, Base VM meter) — you must hold valid Windows Server licences (e.g., Datacenter or Standard) covering **every physical core** in the Azure Stack Hub region, per the [Hub Licensing Guide](https://go.microsoft.com/fwlink/?LinkId=2273601&clcid=0x409).
> - **Capacity model** — Windows Server guest licences are **not** included in the capacity fee; separate Volume Licensing covering every physical core is required.
>
> KMS activation succeeding does not, on its own, prove you are correctly licensed under any of these models.

### Common conflations between billing and activation

These two axes are frequently mixed up. The table below maps the symptom to the actual cause and the (incorrect) conclusion that often follows:

| Symptom | Real cause | Category | Wrong conclusion |
|---|---|---|---|
| WS2025 VM won't activate after deploy | No KMS host reachable | Activation | "BYOL is broken on Hub" |
| Bill shows full Windows VM rate despite owning licences | Forgot `LicenseType=Windows_Server` | Billing | "PAYG and BYOL can't mix" |
| Marketplace image deployed on Hub doesn't auto-activate | Azure KMS endpoint not present on Hub | Activation | "The PAYG image is incompatible with BYOL" |
| `LicenseType` flipped but bill unchanged for a day | Usage meters batch / VM still running old state | Billing | "Mixing modes confuses the meter" |

None of these are "PAYG vs BYOL can't coexist" — they are either an **activation** problem or a **`LicenseType` configuration** problem.

## Notes

- The script downloads **AzCopy v10** automatically — no manual installation needed.
- Only **Gen1** (non-Gen2) images are selected, as Azure Stack Hub requires Gen1 VHDs.
- After the image is registered, it appears in the Azure Stack Hub Marketplace and can be used by tenant subscriptions to create VMs.
- To clean up the temporary Azure resources after the VHD is downloaded, delete the resource group specified in `$AzureResourceGroup`.

## License

MIT License

Copyright (c) 2025-2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.**
