#Requires -Version 3.0

Param(
  [string] [Parameter(Mandatory=$true)] $ResourceGroupLocation,
  [string] [Parameter(Mandatory=$true)] $ResourceGroupName,
  [string] $AdminPassword,
  [string] $DockerCertsDirectory,
  [string] $TemplateFile = "..\Templates\ASPNET5_DockerDockerVM.json",
  [string] $TemplateParametersFile = "..\Templates\ASPNET5_DockerDockerVM.param.dev.json",
  [string] $OpenSSLExePath = "..\Tools\openssl.exe",
  [string] $OpenSSLConfigPath = "..\Tools\openssl.cnf"
)

Import-Module Azure -ErrorAction SilentlyContinue

if ((Get-Module Azure).Version.Major -lt 1) 
{
    Throw "The version of the Azure PowerShell cmdlets installed on this machine is not compatible with this script.  For help updating this script visit: http://go.microsoft.com/fwlink/?LinkID=623011"
} 

try {
    $host.UI.RawUI.WindowTitle = "Creating Resource Group $ResourceGroupName ..."
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-HostInCloudDocker($host.name)".replace(" ","_"), "2.7.1")
} catch { }

Set-StrictMode -Version 3

function EnsureDockerCertificates($directory, $opensslExePath, $opensslConfigPath)
{
    if (!(Test-Path $directory))
    {
        # Creates the certificate directory
        New-Item $directory -type directory
    }

    $PreviousLocation = Get-Location
    Set-Location $directory

    if ((Test-Path ca.pem) -And (Test-Path server-cert.pem) -And (Test-Path server-key.pem) -And (Test-Path cert.pem) -And (Test-Path key.pem))
    {
        # Certs already there, skip generation
        return;
    }

    Write-Verbose "Generating Docker certificates in $directory ..."

    # Set openssl config file path
    $env:OPENSSL_CONF=$opensslConfigPath

    # Set random seed file to be generated in current folder to avoid permission issue
    $env:RANDFILE=".rnd"

    # Generate certificates
    & $opensslExePath genrsa -aes256 -out ca-key.pem -passout pass:Docker123 2048 2>&1>$null
    & $opensslExePath req -new -x509 -passin pass:Docker123 -subj "/C=US/ST=WA/L=Redmond/O=Microsoft" -days 365 -key ca-key.pem -sha256 -out ca.pem 2>&1>$null
    & $opensslExePath genrsa -out server-key.pem 2048 2>&1>$null
    & $opensslExePath req -subj "/C=US/ST=WA/L=Redmond/O=Microsoft" -new -key server-key.pem -out server.csr 2>&1>$null

    # Generate certificate with multiple domain names
    "subjectAltName = IP:10.10.10.20,IP:127.0.0.1,DNS.1:*.cloudapp.net,DNS.2:*.$ResourceGroupLocation.cloudapp.azure.com" | Out-File extfile.cnf -Encoding ASCII 2>&1>$null
    & $opensslExePath x509 -req -days 365 -in server.csr -passin pass:Docker123 -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -extfile extfile.cnf 2>&1>$null
    & $opensslExePath genrsa -out key.pem 2048 2>&1>$null
    & $opensslExePath req -subj "/CN=client" -new -key key.pem -out client.csr 2>&1>$null
    "extendedKeyUsage = clientAuth" | Out-File extfile.cnf -Encoding ASCII 2>&1>$null
    & $opensslExePath x509 -req -days 365 -in client.csr -passin pass:Docker123 -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out cert.pem -extfile extfile.cnf 2>&1>$null

    # Clean up
    Remove-Item *.csr,.rnd
    Set-Location $PreviousLocation

    Write-Verbose "Generation completed."
}

$TemplateFile = [System.IO.Path]::Combine($PSScriptRoot, $TemplateFile)
$TemplateParametersFile = [System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile)

$OptionalParameters = New-Object -TypeName Hashtable
if ($DockerCertsDirectory) {
    $OpenSSLExePath = [System.IO.Path]::Combine($PSScriptRoot, $OpenSSLExePath)
    $OpenSSLConfigPath = [System.IO.Path]::Combine($PSScriptRoot, $OpenSSLConfigPath)

    # Generate required certificates in the user's Docker directory if necessary
    EnsureDockerCertificates $DockerCertsDirectory $OpenSSLExePath $OpenSSLConfigPath

    $OptionalParameters["base64EncodedDockerCACert"] = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText([System.IO.Path]::Combine($DockerCertsDirectory, "ca.pem"))))
    $OptionalParameters["base64EncodedDockerServerCert"] = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText([System.IO.Path]::Combine($DockerCertsDirectory, "server-cert.pem"))))
    $OptionalParameters["base64EncodedDockerServerKey"] = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText([System.IO.Path]::Combine($DockerCertsDirectory, "server-key.pem"))))
}

if ($AdminPassword) {
    $OptionalParameters["adminPassword"] = (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
}

# Create or update the resource group using the specified template file and template parameters file
New-AzureRmResourceGroup -Name $ResourceGroupName `
                         -Location $ResourceGroupLocation `
                         -Verbose -Force -ErrorAction Stop

New-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                                   -TemplateFile $TemplateFile `
                                   -TemplateParameterFile $TemplateParametersFile `
                                   @OptionalParameters `
                                   -Force -Verbose
