﻿# Import all local functions dependencies
Get-Item (Join-Path -Path $PSScriptRoot -ChildPath 'functions\*.ps1') | 
    ForEach-Object {
        Write-Verbose ("Importing sub-module {0}." -f $_.FullName)
        . $_.FullName
    }

# Executes pre-DSCbootstrap scripts from module scripts folder
function Invoke-PreBootScript
{
    [CmdletBinding()]
    Param
    (
        # Hashtable that contains filename of the script to run and any parameters it requires: @{"script.ps1" = "-param test"}
        [hashtable] $Scripts
    )

    $ScriptPath = $(Join-Path -Path $PSScriptRoot -ChildPath "scripts")
    ForEach ($item in $scripts.GetEnumerator())
    {
        $Script = $item.Name
        $Parameters = $item.Value
        $FullScriptPath = $(Join-Path -Path $ScriptPath -ChildPath $Script)
        if (Test-Path $FullScriptPath)
        {
            Write-Verbose "Executing script: $script"
            & $FullScriptPath @Parameters
        }
        else
        {
            Write-Verbose "Script '$Script' was not found at $ScriptPath"
        }
    }
}

# For DSC Clients, takes $PullServerAddress and sets PullServerIP and PullServerName variables
# If PullServerAddress is an IP, PullServerName is derived from the CN on the PullServer endpoint certificate
function Get-PullServerInfo
{
    param
    (
        [string] $PullServerAddress,
        [int] $PullPort,
        [int] $SleepSeconds = 10
    )

    # Check if PullServeraddress is a hostname or IP
    if($PullServerAddress -match '[a-zA-Z]')
    {
        $PullServerName = $PullServerAddress
    }
    else
    {
        $PullServerAddress | Set-Variable -Name PullServerIP -Scope Global
        # Attempt to get the PullServer's hostname from the certificate attached to the endpoint. 
        # Will not proceed unless a CN name is found.
        $uri = "https://$PullServerAddress`:$PullServerPort"
        do
        {
            $webRequest = [Net.WebRequest]::Create($uri)
            try 
            {
                Write-Verbose "Attempting to connect to Pull server and retrieve its public certificate..."
                $webRequest.GetResponse()
            }
            catch 
            {
            }
            Write-Verbose "Retrieveing Pull Server Name from its certificate"
            $PullServerName = $webRequest.ServicePoint.Certificate.Subject -replace '^CN\=','' -replace ',.*$',''
            if( -not($PullServerName) )
            {
                Write-Verbose "Could not retrieved server name from certificate - sleeping for $SleepSeconds seconds..."
                Start-Sleep -Seconds $SleepSeconds
            }
        } while ( -not($PullServerName) )
    }
    return $PullServerName
}

<#
.Synopsis
   Encrypt DSC Automation settings.
.DESCRIPTION
   This function will encrypt the values within a hashtable object (-Settings) using an existing certificate and save the output on the file system.
.EXAMPLE
   Protect-DSCAutomationSettings -CertThumbprint <cert-thumbprint> -Settings <settings hashtable> -Path <output destination> -Verbose
#>
function Protect-DSCAutomationSettings 
{
    [CmdletBinding()]
    param
    (
        # Destination path for DSC Automation secure settings file
        [string]
        $Path = (Join-Path ([System.Environment]::GetEnvironmentVariable("defaultPath","Machine")) "DSCAutomationSettings.xml"),

        # Certificate hash with which to ecrypt the settigns
        [Parameter(Mandatory=$true)]
        [string]
        $CertThumbprint,

        # Contents of the settings file
        [Parameter(Mandatory=$true)]
        [hashtable]
        $Settings,

        # Force overwirte of existing settings file
        [Parameter(Mandatory=$false)]
        [switch]
        $Force = $false
    )

    # Create the certificate object whith which to secure the AES key
    $CertObject = Get-ChildItem Cert:\LocalMachine\My\$CertThumbprint

    # Create RNG Provider Object to help with AES key generation
    $rngProviderObject = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    
    # Generates a random AES encryption $key that is sized correctly
    $key = New-Object byte[](32)
    $rngProviderObject.GetBytes($key)
    
    # Process all Key/Value pairs in the supplied $settings hashtable and encrypt the value
    $DSCAutomationSettings = @{}
    $Settings.GetEnumerator() | Foreach {
        # Convert the current value ot secure string
        $SecureString = ConvertTo-SecureString -String $_.Value -AsPlainText -Force
    
        # Convert the secure string to an encrypted string, so we can save it to a file
        $encryptedSecureString = ConvertFrom-SecureString -SecureString $SecureString -Key $key

        # Encrypt the AES key we used earlier with the specified certificate
        $encryptedKey = $CertObject.PublicKey.Key.Encrypt($key,$true)
    
        # Populate the secure data object and add it to $Settings
        $result = @{
            $_.Name = @{
                "encrypted_data" = $encryptedSecureString;
                "encrypted_key"  = [System.Convert]::ToBase64String($encryptedKey);
                "thumbprint"     = [System.Convert]::ToBase64String([char[]]$CertThumbprint)
            }
        }
        $DSCAutomationSettings += $result
    }
    
    # Make a backup in case of there being an existing settings file - skip of Force switch set
    if ((Test-Path $Path) -and ($Force -ne $true))
    {
        Write-Verbose "Existing settings file found - making a backup..."
        $TimeDate = (Get-Date -Format ddMMMyyyy_hhmmss).ToString()
        Move-Item $Path -Destination ("$Path`-$TimeDate.bak") -Force
    }
    
    # Save the encrypted databag as a native PS hashtable object
    Write-Verbose "Saving encrypted settings file to $Path"
    Export-Clixml -InputObject $DSCAutomationSettings -Path $Path -Force
}

<#
.Synopsis
   Decrypt the encrypted DSCAutomation settings file values.
.DESCRIPTION
   This function will access the encrypted DSC Automation settings file, then use pull server's certificate to decrypt the AES key 
   for each setting value in order to generate and return a set of PSCredential objects.
.EXAMPLE
   Unprotect-DSCAutomationSettings
.EXAMPLE
   Unprotect-DSCAutomationSettings -Path 'C:\folder\file.xml'
#>
function Unprotect-DSCAutomationSettings
{
    [CmdletBinding()]
    param
    (
        # Source path for the secure settings file to override the default location
        [string]
        $Path = (Join-Path ([System.Environment]::GetEnvironmentVariable("defaultPath","Machine")) "DSCAutomationSettings.xml")
    )

    Write-Verbose "Importing the settings databag from $Path"
    If ( -not (Test-Path -Path $Path))
    {
        return $null
    }
    # Import the encrypted data file
    $EncrytedSettings = Import-Clixml -Path $Path
    # Create a hashtable object to hold the decrypted credentials
    $DecryptedSettings = New-Object 'System.Collections.Generic.Dictionary[string,pscredential]'
    if($EncrytedSettings -ne $null) 
    {
        # Process each set of values for each Key in the hashtable
        foreach ( $Name in $EncrytedSettings.GetEnumerator() )
        {
            $Item = $Name.Value
            # Convert Thumbprint value from Base64 to string
            $CertThumbprint = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($Item.thumbprint))
            # Retrieve the certificate used to encrypt the AES key used to encrypt the data
            $decryptCert = Get-ChildItem Cert:\LocalMachine\My\ | Where-Object { $_.Thumbprint -eq $CertThumbprint }
            If ( -not $decryptCert ) 
            {
                $Param = $Name.Name
                Write-Verbose "Certificate with Thumbprint $Thumbprint for $Param data could not be found. Skipping..."
                Continue
            }
            try
            {
                # Use the private key of certificate to decrypt the encryption key
                $key = $decryptCert.PrivateKey.Decrypt([System.Convert]::FromBase64String($item.encrypted_key), $true)
                # Use the key we just decrypted to convert the data to a secure string object
                $secString = ConvertTo-SecureString -String $item.encrypted_data -Key $key
            }
            finally
            {
                if ($key)
                {
                    # Overwrite $key variable with zeros to remove it fully from memory
                    [array]::Clear($key, 0, $key.Length)
                }
            }
            # Add the newly decrypted PSCredential object to the collection
            $DecryptedSettings[$Name.Name] = New-Object pscredential($Name.Name, $secString)
        }
    }
    return $DecryptedSettings
}

<#
.Synopsis
   Retrieve the decrypted string from an encrypted databag.
.DESCRIPTION
   Use Unprotect-DSCAutomationSettings to decrypt the databag and retrieve the plain-text value for the specified setting.
.EXAMPLE
   Get-DSCSettingValue 'LogName'
.EXAMPLE
   Get-DSCSettingValue -Key 'PullServerAddress' -Path 'C:\folder\file.xml'
.EXAMPLE
   Get-DSCSettingValue -Key 'LogName', 'GitRepoName'
.EXAMPLE
   Get-DSCSettingValue -ListAvailable
#>
function Get-DSCSettingValue
{
    [CmdletBinding(DefaultParameterSetName='GetValues')]
    Param
    (
        # Key help description
        [Parameter(ParameterSetName='GetValues', Mandatory=$true, Position=0)]
        [string[]]
        $Key,

        # Path help description
        [Parameter(Mandatory=$false)]
        [string]
        $Path,

        # List all available settings
        [Parameter(ParameterSetName='ListKeys', Mandatory=$true, Position=0)]
        [switch]
        $ListAvailable = $false
    )
    # Decrypt contents ofthe DSCAutomation configuration file
    if ($PSBoundParameters.ContainsKey('Path'))
    {
        $DSCSettings = Unprotect-DSCAutomationSettings -Path $Path
    }
    else
    {
        $DSCSettings = Unprotect-DSCAutomationSettings
    }

    if ($ListAvailable.IsPresent)
    {
        # Retrieve a list of all parameter names stored in configuration file
        $Result = @()
        foreach ($Item in $DSCSettings.Keys)
        {
            $Result += $Item
        }
    }
    else
    {
        # Retrieve the plain-text value for each setting that is part of $Key parameter
        $Result = @{}
        foreach ($Item in $Key)
        {
            if ($DSCSettings[$Item] -ne $null)
            {
                $Value = $DSCSettings[$Item].GetNetworkCredential().Password
                $Result[$Item] = $Value
            }
            else
            {
                $Result[$Item] = $null
            }
        }
    }
    return $Result
}

<#
.Synopsis
   Retrieve base64 encoded certificate key to pass to DSC clients for registration
.DESCRIPTION
   This cmdlet will access the Pull server's local certificate store, retrieve the registration certificate that is 
   generated at pull server build time and export this certificate as a Base64 string for use during new DSC client registration process.
.EXAMPLE
   Get-DSCClientRegistrationCert
.EXAMPLE
   Get-DSCClientRegistrationCert '<Custom Registration Certificate Name>'
#>
function Get-DSCClientRegistrationCert
{
    [CmdletBinding()]
    Param
    (
        # Name of the regstration certificate if different from default
        [string]
        $ClientRegCertName
    )
    # Try to identify the cert name if one was not provided
    if (-not ($PSBoundParameters.ContainsKey('ClientRegCertName')))
    {
        $ClientRegCertName = (Get-DSCSettingValue "ClientRegCertName").ClientRegCertName
    }
    
    $RegCertThumbprint = (Get-ChildItem -Path Cert:\LocalMachine\My\ | Where-Object -FilterScript {$_.Subject -eq "CN=$ClientRegCertName"}).Thumbprint

    $Cert = [System.Convert]::ToBase64String((Get-Item Cert:\LocalMachine\My\$RegCertThumbprint).Export('PFX', ''))

    return $Cert
}

<#
.Synopsis
   Initiate Pull server configuration sync
.DESCRIPTION
   Initiate a configuration sync and generate updated MOF file for Pull server. By default, it will access DSCAutomation Settings that were generated during bootstrap.
   Many parameters can be overriden if required.
.EXAMPLE
   Invoke-DSCPullConfigurationSync
.EXAMPLE
   Invoke-DSCPullConfigurationSync -UseLog
#>
function Invoke-DSCPullConfigurationSync
{
    [CmdletBinding()]
    Param
    (
        # Name of the DSC configuration file (normally Pull server config)
        [string]
        $PullServerConfig = (Get-DSCSettingValue "PullServerConfig").PullServerConfig,
        
        # DSC Automation install directory
        [string]
        $InstallPath = (Get-DSCSettingValue "InstallPath").InstallPath,
        
        # Name of the configuration git repository
        [string]
        $GitRepoName = (Get-DSCSettingValue "GitRepoName").GitRepoName,

        # Enable extra logging to the event log
        [switch]
        $UseLog = $false,

        # Name of the event log to use for logging
        [string]
        $LogName = (Get-DSCSettingValue "LogName").LogName,

        # Path to folder where t ostore the checksum file
        [string]
        $HashPath = $InstallPath,

        # Force pull server configuration generation
        [switch]
        $Force = $false
    )

    $LogSourceName = $MyInvocation.MyCommand.Name
    if (($UseLog) -and -not ([System.Diagnostics.EventLog]::SourceExists($LogSourceName)) ) 
    {
        [System.Diagnostics.EventLog]::CreateEventSource($LogSourceName, $LogName)
    }

    if ($UseLog) 
    {
        Write-Eventlog -LogName $LogName -Source $LogSourceName -EventID 2001 -EntryType Information -Message "Starting Configuration repo sync task"
    }

    # Ensure that we are using the most recent $path variable
    $env:path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    
    # Setup our path variables
    $ConfDir = Join-Path $InstallPath $GitRepoName
    $PullConf = Join-Path $ConfDir $PullServerConfig
    $GitDir = "$ConfDir\.git"

    # Delay Pull server conf regen until ongoing LCM run completes
    Write-Verbose "Checking LCM State..."
    $LCMStates = @("Idle","PendingConfiguration")
    $LCMtate = (Get-DscLocalConfigurationManager).LCMState
    if ($LCMStates -notcontains $LCMtate)
    {
        if ($UseLog)
        {
            Write-Eventlog -LogName $LogName -Source $LogSourceName -EventID 2002 -EntryType Information -Message "Waiting for LCM to go into idle state"
        }
        Do
        {
            $LCMtate = (Get-DscLocalConfigurationManager).LCMState
            Write-Verbose "LCM State is $LCMState "
            Sleep -Seconds 5
            $LCMtate = (Get-DscLocalConfigurationManager).LCMState
        } while ($LCMStates -notcontains $LCMtate)
    }
    Write-Verbose "Getting latest changes to configuration repository..."
    & git --git-dir=$GitDir pull

    $CurrentHash = (Get-FileHash $PullConf).hash
    $HashFilePath = (Join-Path $HashPath $($PullServerConfig,'hash' -join '.'))
    # if  $PullConf checksum does not match
    if( -not (Test-ConfigFileHash -file $PullConf -hash $HashFilePath) -or ($Force))
    {
        Write-Verbose "Executing Pull server DSC configuration..."
        & $PullConf
        Set-Content -Path $HashFilePath -Value (Get-FileHash -Path $PullConf).hash
    }
    else
    {
        Write-Verbose "Skipping pull server DSC script execution as it was not modified since previous run"
        if ($UseLog)
        {
            Write-Eventlog -LogName $LogName -Source $LogSourceName -EventID 2003 -EntryType Information -Message "Skipping Pull server config as it was not modified"
        }
    }
    if ($UseLog)
    {
        Write-Eventlog -LogName $LogName -Source $LogSourceName -EventID 2005 -EntryType Information -Message "Configuration synchronisation is complete"
    }
}

<#
.Synopsis
   Compare file hash to one stored in a file 
.DESCRIPTION
   Function that compares a file hash to one that was created previously - returns a bool value. Used for detecting changes to DSC configuration files.
   Generating has files: Set-Content -Path <hashfilepath> -Value (Get-FileHash -Path <sourcefile>).hash
.EXAMPLE
   Test-ConfigFileHash -file <targetfile> -hash <hashfile>
#>
Function Test-ConfigFileHash
{
    param (
        # Full path to the target file
        [String]
        $file,
        
        # Full path to the file that contains the checksum for comparison
        [String]
        $hash
    )
        
    if ( !(Test-Path $hash) -or !(Test-Path $file))
    {
        return $false
    }        
    if( (Get-FileHash $file).hash -eq (Get-Content $hash))
    {
        return $true
    }
    else
    {
        return $false
    }
}

<#
.Synopsis
   Short description
.DESCRIPTION
   Long description
.EXAMPLE
   Example of how to use this cmdlet
.EXAMPLE
   Another example of how to use this cmdlet
#>
function Submit-DSCClientRegistration
{
    [CmdletBinding()]
    Param
    (
        # ConfigID help description
        [Parameter(Mandatory=$false)]
        $ConfigID = (Get-DSCSettingValue -Key "ConfigID").ConfigID,

        # ClientConfig help description
        [Parameter(Mandatory=$false)]
        $ClientConfig = (Get-DSCSettingValue -Key "ClientConfig").ClientConfig,

        # ClientRegCertName help description
        [Parameter(Mandatory=$false)]
        $ClientRegCertName = (Get-DSCSettingValue -Key "ClientRegCertName").ClientRegCertName,

        # ClientDSCCertName help description
        [Parameter(Mandatory=$false)]
        $ClientDSCCertName = (Get-DSCSettingValue -Key "ClientDSCCertName").ClientDSCCertName,

        # PullServerName help description
        [Parameter(Mandatory=$false)]
        $PullServerName = (Get-DSCSettingValue -Key "PullServerName").PullServerName,

        # PullServerPort help description
        [Parameter(Mandatory=$false)]
        $Port = 443,

        # Default timeout value to use when sending requests (default: 
        [Parameter(Mandatory=$false)]
        $TimeoutSec = 10
    )

    # Client Regitration code
    $Settings = Get-DSCSettingValue -Key "ConfigID","ClientConfig","ClientRegCertName","ClientDSCCertName","PullServerName","PullServerPort"
    $ClientDSCCert = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$ClientDSCCertName" }).RawData
    $Property = @{
                "ConfigID" = $ConfigID
                "ClientName" = $env:COMPUTERNAME
                "ClientDSCCert" = ([System.Convert]::ToBase64String($ClientDSCCert))
                "ClientConfig" = $ClientConfig
                }
    $AuthCert = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$ClientRegCertName" })
    $RegistrationUri = "https://$($PullServerName):$($Port)/Arnie.svc/secure/ItsShowtime"
    $Body = New-Object -TypeName psobject -Property $Property | ConvertTo-Json
    try 
    {
        Write-Verbose "Trying to send client registration data to Pull server..."
        $ClientRegResult = Invoke-RestMethod -Method Post -Uri $RegistrationUri -TimeoutSec $TimeoutSec -Certificate $AuthCert -Body $Body -ContentType "application/json"  | ConvertFrom-Json
        if ($ClientRegResult.ConfigID -eq $ConfigID)
        {
            Write-Verbose "Client registration data submitted to Pull server successfully"
            return "Success"
        }
        else
        {
            Throw "Failed to submit client registration data - ensure that Pull server is configured correctly."
        }
    }
    catch [System.Management.Automation.RuntimeException]
    {
        Write-Verbose "Error submitting client registration: $($_.Exception.message)"
        Write-Verbose "Target pull server URI: $RegistrationUri"
    }
    catch 
    {
        Write-Verbose "Client registration request failed with: $($_.Exception.message)"
        Write-Verbose "Please verify connectivity to and check functionality of the pull server"
        Write-Verbose "Target pull server URI: $RegistrationUri"
    }
}