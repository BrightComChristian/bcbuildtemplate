﻿Param(
    [Parameter(Mandatory = $true)]
    [string] $artifactsFolder,

    [Parameter(Mandatory = $true)]
    [string] $appFolders,
    
    [Parameter(Mandatory = $true)]
    [string] $branchName,

    [Parameter(Mandatory = $false)]
    [string] $buildProjectFolder = $ENV:BUILD_REPOSITORY_LOCALPATH
    
)

Write-Host "Deploying branch ${branchName}..."
$settings = (Get-Content ((Get-ChildItem -Path $buildProjectFolder -Filter "build-settings.json" -Recurse).FullName) -Encoding UTF8 | Out-String | ConvertFrom-Json)
$deployment = $settings.deployments | Where-Object { $_.branch -eq $branchName }
if ($deployment) {

    $deploymentType = $deployment.DeploymentType

    $artifactsFolder = (Get-Item $artifactsFolder).FullName
    Write-Host "Folder: $artifactsFolder"

    Sort-AppFoldersByDependencies -appFolders $appFolders.Split(',') -baseFolder $artifactsFolder -WarningAction SilentlyContinue | ForEach-Object {
        
        $appFolder = $_
        Write-Host "Deploying ${appFolder} to ${deploymentType}"
        $appFile = (Get-Item (Join-Path $artifactsFolder "$appFolder\*.app")).FullName
        $appJsonFile = (Get-Item (Join-Path $artifactsFolder "$appFolder\app.json")).FullName
        $appJson = Get-Content $appJsonFile | ConvertFrom-Json

        if ($deploymentType -eq "AzureVM") {
            $azureVM = $deployment.DeployToName
            Write-Host "Connecting to ${azureVM}"

            . (Join-Path $PSScriptRoot "SessionFunctions.ps1")
        
            $useSession = $true
            try { 
                $myip = ""; $myip = (Invoke-WebRequest -Uri http://ifconfig.me/ip).Content
                $targetip = (Resolve-DnsName $azureVM).IP4Address
                if ($myip -eq $targetip) {
                    $useSession = $false
                }
            }
            catch { }
        
            $vmSession = $null
            $tempAppFile = ""
            try {
        
                if ($useSession) {
                    $vmSession = New-DeploymentRemoteSession -HostName $azureVM -Credential $vmCredential
                    $tempAppFile = CopyFileToSession -session $vmSession -localFile $appFile
                    $sessionArgument = @{ "Session" = $vmSession }
                }
                else {
                    $tempAppFile = $appFile
                    $sessionArgument = @{ }
                }
        
                Invoke-Command @sessionArgument -ScriptBlock { Param($containerName, $appFile, $credential)
                    $ErrorActionPreference = "Stop"
        
                    $appExists = $false
                    $apps = Get-BCContainerAppInfo $containerName -tenantSpecificProperties | Sort-Object -Property Name
                    Write-Host "Extensions:"
                    $apps | % {
                        Write-Host " - $($_.Name) v$($_.version) installed=$($_.isInstalled)"
                        if ($_.publisher -eq $appJson.publisher -and $_.name -eq $appjson.name -and $_.appid -eq $appjson.id) {
                            UnPublish-BCContainerApp -containerName $containerName -appName $_.name -publisher $_.publisher -version $_.Version -unInstall -force
                            $appExists = $true
                        }
                    }

                    Publish-BCContainerApp -containerName $containerName -appFile $appFile -skipVerification -sync -scope Tenant -SkipVerification
                    if ($appExists) {
                        Start-BCContainerAppDataUpgrade -containerName $containerName -appName $appJson.name -appVersion $appJson.version
                    }

                    Install-BCContainerApp -containerName $containerName -appName $appJson.name -appVersion $appJson.version
        
                } -ArgumentList $containerName, $tempAppFile, $credential
            }
            catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
                throw "Could not connect to $azureVM. Maybe port 5986 (WinRM) is not open for your IP address $myip"
            }
            finally {
                if ($vmSession) {
                    if ($tempAppFile) {
                        try { RemoveFileFromSession -session $vmSession -filename $tempAppFile } catch {}
                    }
                    Remove-PSSession -Session $vmSession
                }
            }
        }
        elseif ($deploymentType -eq "onlineTenant") {
            $apiBaseUrl = $deployment.apiBaseUrl
            $baseUrl = $apiBaseUrl.TrimEnd('/')
            Write-Host "Base Url: $baseurl"
            
            # Get company id (of any company in the tenant)​
            $companiesResponse = Invoke-WebRequest -Uri "$baseUrl/v1.0/companies" -Credential $credential
            $companiesContent = $companiesResponse.Content
            $companyId = (ConvertFrom-Json $companiesContent).value[0].id
        
            Write-Host "CompanyId $companyId"
            
            # Get existing extensions
            $getExtensions = Invoke-WebRequest `
                -Method Get `
                -Uri "$baseUrl/microsoft/automation/v1.0/companies($companyId)/extensions" `
                -Credential $credential
            
            $extensions = (ConvertFrom-Json $getExtensions.Content).value | Sort-Object -Property DisplayName
            
            Write-Host "Extensions:"
            $extensions | % { Write-Host " - $($_.DisplayName) v$($_.versionMajor).$($_.versionMinor) installed=$($_.isInstalled)" }
            
            # Publish and install extension
            Write-Host "Publishing and installing $appFolder"
            Invoke-WebRequest `
                -Method Patch `
                -Uri "$baseUrl/microsoft/automation/v1.0/companies($companyId)/extensionUpload(0)/content" `
                -Credential $credential `
                -ContentType "application/octet-stream" `
                -Headers @{"If-Match" = "*" } `
                -InFile $appFile | Out-Null
            
            Write-Host ""
            Write-Host "Deployment status:"
            
            # Monitor publishing progress
            $inprogress = $true
            $completed = $false
            $errCount = 0
            while ($inprogress) {
                Start-Sleep -Seconds 5
                try {
                    $extensionDeploymentStatusResponse = Invoke-WebRequest `
                        -Method Get `
                        -Uri "$baseUrl/microsoft/automation/v1.0/companies($companyId)/extensionDeploymentStatus" `
                        -Credential $credential
                    $extensionDeploymentStatuses = (ConvertFrom-Json $extensionDeploymentStatusResponse.Content).value
                    $inprogress = $false
                    $completed = $true
                    $extensionDeploymentStatuses | Where-Object { $_.publisher -eq $appJson.publisher -and $_.name -eq $appJson.name -and $_.appVersion -eq $appJson.version } | % {
                        Write-Host " - $($_.name) $($_.appVersion) $($_.operationType) $($_.status)"
                        if ($_.status -eq "InProgress") { $inProgress = $true }
                        if ($_.status -ne "Completed") { $completed = $false }
                    }
                    $errCount = 0
                }
                catch {
                    if ($errCount++ -gt 3) {
                        $inprogress = $false
                    }
                }
            }
            if (!$completed) {
                throw "Unable to publish app"
            }
        }
        elseif ($deploymentType -eq "container" -and ($deployment.DeployToTenants).Count -eq 0) {
            $containerName = $deployment.DeployToName
            Write-Host "Container deployment to ${containerName}"
        
            $ErrorActionPreference = "Stop"
            Write-Host "Container deployment to ${containerName}"
            Publish-BCContainerApp -containerName $containerName -tenant $containerTenant -appFile $appFile -skipVerification -scope Global
            
            Invoke-ScriptInBcContainer -containerName $containerTenant -scriptblock {
                Param($appJson)
                $ServerInstance = (Get-NAVServerInstance | Where-Object -Property Default -EQ True).ServerInstance

                foreach ($Tenant in (Get-NAVTenant -ServerInstance $ServerInstance).Id) {                                      
                    $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $appJson.Name
                    foreach ($app in $apps | Sort-Object -Property Version) {
                        Write-Host "Investigating app $($app.Name) v$($app.version) installed=$($app.isInstalled)"
                        $NewApp = $apps | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -GT $app.version                            
                        if ($NewApp) {
                            if (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $Newapp.Name | Where-Object -Property Version -LT $Newapp.Version | Where-Object -Property IsInstalled -EQ $true) {
                                Write-Host "upgrading app $($app.Name) v$($app.Version) to v$($NewApp.Version) in tenant $($Tenant)"
                                Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                                Start-NAVAppDataUpgrade -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                            }
                            else {
                                Write-Host "Newer App is available"
                            }
                        }
                        elseif (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -EQ $app.Version | Where-Object -Property IsInstalled -EQ $false) {
                            Write-Host "installing app $($app.Name) v$($app.Version) in tenant $($Tenant)"
                            Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                            Install-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                        }                   
                    }

                    $allTenantsApps = @()
                    foreach ($Tenant in (Get-NAVTenant -ServerInstance $ServerInstance).Id) {                                    
                        $allTenantsApps += Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties -Name $appJson.Name | Where-Object -Property IsInstalled -EQ $true
                    }
                        
                    $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Name $appJson.Name
                    foreach ($app in $apps | Sort-Object -Property Version) {
                        $NoOfApps = @($apps | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -GT $app.Version).Count
                        $NoOfInstalledApps = @($allTenantsApps | Where-Object -Property Version -EQ $app.Version).Count
                        if ($NoOfApps -gt 0 -and $NoOfInstalledApps -eq 0) {
                            Write-Host "Unpublishing old app $($app.Name) $($app.Version)"
                            try {
                                Unpublish-NAVApp -ServerInstance $ServerInstance -Name $app.Name -Publisher $app.Publisher -Version $app.Version
                            }
                            catch {
                                Write-Host "Unable to unpublish $($app.Name) v$($app.Version)"
                            }
                        }
                    }
                } -argumentList $appjson            
            }
        }
        elseif ($deploymentType -eq "container") {
            $containerName = $deployment.DeployToName
            $Tenants = $deployment.DeployToTenants
            Write-Host "Container deployment to ${containerName}"
    
            $ErrorActionPreference = "Stop"
            foreach ($containerTenant in $Tenants) {
                try {
                    Write-Host "Deploying to ${containerName}\${containerTenant}"
                    Publish-BCContainerApp -containerName $containerName -tenant $containerTenant -appFile $appFile -skipVerification -sync -scope Tenant
                    $installedApp = Get-BCContainerAppInfo -containerName $containerName -Name $appJson.Name -tenant $containerTenant -tenantSpecificProperties | Where-Object -Property IsInstalled -EQ True
                    if ($installedApp) {
                        Start-BcContainerAppDataUpgrade -containerName $containerName -tenant $containerTenant -appName $appJson.Name -appVersion $appjson.version 
                    }
                    else {
                        Install-BCContainerApp -containerName $containerName -tenant $containerTenant -appName $appJson.Name -appVersion $appjson.version
                    }
                    $apps = Get-BCContainerAppInfo -containerName $containerName -tenant $containerTenant -tenantSpecificProperties | Where-Object -Property Scope -EQ Tenant | Where-Object -Property Name -EQ $appJson.Name
                    foreach ($app in $apps | Sort-Object -Property Version) {
                        Write-Host "Checking installation status for app $($app.Name) $($app.Version)"
                        $NoOfNewerApps = @($apps | Where-Object -Property Version -GT $app.Version).Count
                        $IsInstalled = ($apps | Where-Object -Property Version -EQ $app.Version).IsInstalled
                        Write-Host "No. of newer apps: ${NoOfNewerApps}"
                        Write-Host "Installed: ${IsInstalled}"
                        if ($NoOfNewerApps -gt 0 -and $IsInstalled -eq $false) {
                            Write-Host "Unpublishing old app $($app.Name) $($app.Version)"
                            try {
                                UnPublish-BCContainerApp -containerName $containerName -Name $app.Name -Publisher $app.Publisher -Version $app.Version -tenant $containerTenant
                            }
                            catch {
                                Write-Host "Unable to unpublish $($app.Name) v$($app.Version)"
                            }
                        }
                    }
                }
                catch {
                    throw "Could not publish $($appJson.name) to ${containerName}\${containerTenant}"
                }
                finally { } 
            }
        
        }

        elseif ($deploymentType -eq "host" -and ($deployment.DeployToTenants).Count -eq 0) {
            $VM = $deployment.DeployToName
            if ($deployment.InstallNewApps) {
                $installNewApps = $true
            }
            else {
                $installNewApps = $false
            }
            Write-Host "Host deployment to ${VM}"
            . (Join-Path $PSScriptRoot "SessionFunctions.ps1")
    
            $useSession = $true
            try { 
                $myip = ""; $myip = (Invoke-WebRequest -Uri http://ifconfig.me/ip).Content
                $targetip = (Resolve-DnsName $VM).IP4Address
                if ($myip -eq $targetip) {
                    $useSession = $false
                }
            }
            catch { }
    
            $vmSession = $null
            $tempAppFile = ""
            try {
    
                if ($useSession) {
                    $vmSession = New-DeploymentRemoteSession -HostName $VM
                    $tempAppFile = CopyFileToSession -session $vmSession -localFile $appFile
                    $sessionArgument = @{ "Session" = $vmSession }
                }
                else {
                    $tempAppFile = $appFile
                    $sessionArgument = @{ }
                }
    
                Invoke-Command @sessionArgument -ScriptBlock { Param($appFile, $DeployToInstance, $installNewApps)
                    $ErrorActionPreference = "Stop"
    
                    if ([String]::IsNullOrEmpty($DeployToInstance)) {
                        $modulePath = Get-Item 'C:\Program Files\Microsoft Dynamics 365 Business Central\*\Service\NavAdminTool.ps1'
                        Import-Module $modulePath | Out-Null
                        $ServerInstance = (Get-NAVServerInstance | Where-Object -Property Default -EQ True).ServerInstance
                    }
                    else {
                        $ServicePath = (Get-WmiObject win32_service | Where-Object { $_.Name -eq "MicrosoftDynamicsNavServer`$${DeployToInstance}" } | Select-Object Name, DisplayName, @{Name = "Path"; Expression = { $_.PathName.split('"')[1] } }).Path
                        $modulePath = Get-Item (Join-Path (Split-Path -Path $ServicePath -Parent) 'NavAdminTool.ps1')
                        Import-Module $modulePath | Out-Null
                        $ServerInstance = $DeployToInstance
                    }
                    
                    $CurrentApp = Get-NAVAppInfo -Path $appFile

                    Write-Host "Publishing v$($CurrentApp.Version)"    
                    Publish-NAVApp -ServerInstance $ServerInstance -Path $appFile -Scope Global -SkipVerification
                
                    foreach ($Tenant in (Get-NAVTenant -ServerInstance $ServerInstance).Id) {                                      
                        $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $CurrentApp.Name
                        foreach ($app in $apps | Sort-Object -Property Version) {
                            Write-Host "Investigating app $($app.Name) v$($app.version) installed=$($app.isInstalled)"
                            $NewApp = $apps | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -GT $app.version                            
                            if ($NewApp) {
                                if (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $Newapp.Name | Where-Object -Property Version -LT $Newapp.Version | Where-Object -Property IsInstalled -EQ $true) {
                                    Write-Host "upgrading app $($app.Name) v$($app.Version) to v$($NewApp.Version) in tenant $($Tenant)"
                                    Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                                    Start-NAVAppDataUpgrade -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                                }
                                else {
                                    Write-Host "Newer App is available"
                                }
                            }
                            elseif ($installNewApps -and (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -EQ $app.Version | Where-Object -Property IsInstalled -EQ $false)) {
                                Write-Host "installing app $($app.Name) v$($app.Version) in tenant $($Tenant)"
                                Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                                Install-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                            }                   
                        }
                    
                        $allTenantsApps = @()
                        foreach ($Tenant in (Get-NAVTenant -ServerInstance $ServerInstance).Id) {
                            $allTenantsApps += Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties -Name $CurrentApp.Name | Where-Object -Property IsInstalled -EQ $true
                        }
                        $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Name $CurrentApp.Name | Where-Object -Property Scope -EQ Global
                        foreach ($app in $apps | Sort-Object -Property Version) {
                            $NoOfApps = @($apps | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -GT $app.Version).Count
                            $NoOfInstalledApps = @($allTenantsApps | Where-Object -Property Version -EQ $app.Version).Count
                            if ($NoOfApps -gt 0 -and $NoOfInstalledApps -eq 0) {
                                Write-Host "Unpublishing old app $($app.Name) $($app.Version)"
                                try {
                                    Unpublish-NAVApp -ServerInstance $ServerInstance -Name $app.Name -Publisher $app.Publisher -Version $app.Version
                                }
                                catch {
                                    Write-Host "Unable to unpublish $($app.Name) v$($app.Version)"
                                }
                            }
                        }
                    }
                } -ArgumentList $tempAppFile, $deployment.DeployToInstance, $installNewApps
            }
            catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
                throw "Could not connect to $VM. Maybe port 5985 (WinRM) is not open for your IP address $myip"
            }
            finally {
                if ($vmSession) {
                    if ($tempAppFile) {
                        try { RemoveFileFromSession -session $vmSession -filename $tempAppFile } catch {}
                    }
                    Remove-PSSession -Session $vmSession
                }
            }
        
        }
        elseif ($deploymentType -eq "host") {
            $VM = $deployment.DeployToName
            $Tenants = $deployment.DeployToTenants
            if ($deployment.InstallNewApps) {
                $installNewApps = $true
            }
            else {
                $installNewApps = $false
            }
            Write-Host "Host deployment to ${VM}"
            . (Join-Path $PSScriptRoot "SessionFunctions.ps1")
    
            $useSession = $true
            try { 
                $myip = ""; $myip = (Invoke-WebRequest -Uri http://ifconfig.me/ip).Content
                $targetip = (Resolve-DnsName $VM).IP4Address
                if ($myip -eq $targetip) {
                    $useSession = $false
                }
            }
            catch { }
    
            $vmSession = $null
            $tempAppFile = ""
            try {
    
                if ($useSession) {
                    $vmSession = New-DeploymentRemoteSession -HostName $VM
                    $tempAppFile = CopyFileToSession -session $vmSession -localFile $appFile
                    $sessionArgument = @{ "Session" = $vmSession }
                }
                else {
                    $tempAppFile = $appFile
                    $sessionArgument = @{ }
                }
    
                Invoke-Command @sessionArgument -ScriptBlock { Param($Tenants, $appFile, $DeployToInstance, $installNewApps)
                    $ErrorActionPreference = "Stop"
    
                    if ([String]::IsNullOrEmpty($DeployToInstance)) {
                        $modulePath = Get-Item 'C:\Program Files\Microsoft Dynamics 365 Business Central\*\Service\NavAdminTool.ps1'
                        Import-Module $modulePath | Out-Null
                        $ServerInstance = (Get-NAVServerInstance | Where-Object -Property Default -EQ True).ServerInstance
                    }
                    else {
                        $ServicePath = (Get-WmiObject win32_service | Where-Object { $_.Name -eq "MicrosoftDynamicsNavServer`$${DeployToInstance}" } | Select-Object Name, DisplayName, @{Name = "Path"; Expression = { $_.PathName.split('"')[1] } }).Path
                        $modulePath = Get-Item (Join-Path (Split-Path -Path $ServicePath -Parent) 'NavAdminTool.ps1')
                        Import-Module $modulePath | Out-Null
                        $ServerInstance = $DeployToInstance
                    }
                    $CurrentApp = Get-NAVAppInfo -Path $appFile

                    foreach ($Tenant in $Tenants) {
                        Write-Host "Publishing $($CurrentApp.Name) (${appFile}) to ${Tenant}"
                        Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $CurrentApp.Name | Where-Object -Property IsInstalled -EQ $false | ForEach-Object {
                            Write-Host "Removing unused app v$($_.Version)"
                            try {
                                Unpublish-NAVApp -ServerInstance $ServerInstance -Name $_.Name -Publisher $_.Publisher -Version $_.Version -Tenant $Tenant
                            }
                            catch {
                                Write-Host "Unable to unpublish $($app.Name) v$($app.Version)"
                            }
                        }
                        Write-Host "Publishing v$($CurrentApp.Version)"    
                        Publish-NAVApp -ServerInstance $ServerInstance -Path $appFile -Tenant $Tenant -Scope Tenant -SkipVerification
            
                        $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $CurrentApp.Name
                        foreach ($app in $apps | Sort-Object -Property Version) {
                            Write-Host "Investigating app $($app.Name) v$($app.version) installed=$($app.isInstalled)"
                            $NewApp = $apps | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -GT $app.version                            
                            if ($NewApp) {
                                if (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $Newapp.Name | Where-Object -Property Version -LT $Newapp.Version | Where-Object -Property IsInstalled -EQ $true) {
                                    Write-Host "upgrading app $($app.Name) v$($app.Version) to v$($NewApp.Version) in tenant $($Tenant)"
                                    Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                                    Start-NAVAppDataUpgrade -ServerInstance $ServerInstance -Tenant $Tenant -Name $NewApp.Name -Version $NewApp.Version -Force
                                }
                                else {
                                    Write-Host "Newer App is available"
                                }
                            }
                            elseif ($installNewApps -and (Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $app.Name | Where-Object -Property Version -EQ $app.Version | Where-Object -Property IsInstalled -EQ $false)) {
                                Write-Host "installing app $($app.Name) v$($app.Version) in tenant $($Tenant)"
                                Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                                Install-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $app.Name -Version $app.Version -Force
                            }                   
                        }
                        $apps = Get-NAVAppInfo -ServerInstance $ServerInstance -Tenant $Tenant -TenantSpecificProperties | Where-Object -Property Name -EQ $CurrentApp.Name
                        foreach ($app in $apps | Sort-Object -Property Version) {
                            Write-Host "Checking installation status for app $($app.Name) $($app.Version)"
                            $NoOfNewerApps = @($apps | Where-Object -Property Version -GT $app.Version).Count
                            $IsInstalled = ($apps | Where-Object -Property Version -EQ $app.Version).IsInstalled
                            Write-Host "No. of newer apps: ${NoOfNewerApps}"
                            Write-Host "Installed: ${IsInstalled}"    
                            if ($NoOfApps -gt 0 -or $installedApp -ne $null) {
                                Write-Host "Unpublishing old app $($app.Name) $($app.Version)"
                                try {
                                    Unpublish-NAVApp -ServerInstance $ServerInstance -Name $app.Name -Publisher $app.Publisher -Version $app.Version -Tenant $Tenant
                                }
                                catch {
                                    Write-Host "Unable to unpublish $($app.Name) v$($app.Version)"
                                }
                            }
                        }         
                    }
                } -ArgumentList $Tenants, $tempAppFile, $deployment.DeployToInstance, $installNewApps
            }
            catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
                throw "Could not connect to $VM. Maybe port 5985 (WinRM) is not open for your IP address $myip"
            }
            finally {
                if ($vmSession) {
                    if ($tempAppFile) {
                        try { RemoveFileFromSession -session $vmSession -filename $tempAppFile } catch {}
                    }
                    Remove-PSSession -Session $vmSession
                }
            }
        
        }        
    }
}
