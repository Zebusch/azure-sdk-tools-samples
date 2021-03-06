<#
.SYNOPSIS
    Deploy VM's on the same availablility set and load balanced on a single endpoint. 
    Subsequent calls targeting the same service name adds new instances.
.DESCRIPTION
    The VMs are deployed on the same availability set, and load balanced on the provided endpoint. 
    If there is an existing service with the given name with VMs deployed having the same base 
    host name, it simply adds new VMs load balanced on the same endpoint.
.EXAMPLE
    .\New-AzureRedundantVm.ps1 -NewService -ServiceName "myservicename" -ComputerNameBase "myhost" `
        -InstanceSize Small -Location "West US" -AffinityGroupName "myag" -EndpointName "http" `
        -EndpointProtocol tcp -EndpointPublicPort 80 -EndpointLocalPort 80 -InstanceCount 3
#>
param
( 
    # Switch to indicate adding VMs to an existing service, already load balanced.
    [Parameter(ParameterSetName = "Existing deployment")]
    [Switch]
    $ExistingService,
    
    # Switch to indicate to create a new deployment from scratch
    [Parameter(ParameterSetName = "New deployment")]
    [Switch]
    $NewService,
    
    # Cloud service name to deploy the VMs to
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # Base of the computer name the VMs are going to assume. 
    # For example, myhost, where the result will be myhost1, myhost2
    [Parameter(Mandatory = $true)]
    [String]
    $ComputerNameBase,
    
    # Size of the VMs that will be deployed
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $InstanceSize,
    
    # Location where the VMs will be deployed to
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $Location,
    
    # Affinity group the VMs will be placed in
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $AffinityGroupName,
    
    # Name of the load balanced endpoint on the VMs
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $EndpointName,
    
    # The protocol for the endpoint
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [ValidateSet("tcp", "udp")]
    [String]
    $EndpointProtocol,
    
    # Endpoint's public port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointPublicPort,
    
    # Endpoint's private port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointLocalPort,
    
    # Number of VM instances
    [Parameter(Mandatory = $false)]
    [Int]
    $InstanceCount = 6)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please install from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
    Adds a new affinity group if it does not exist.
.DESCRIPTION
   Looks up the current subscription's (as set by Set-AzureSubscription cmdlet) affinity groups and creates a new
   affinity group if it does not exist.
.EXAMPLE
   New-AzureAffinityGroupIfNotExists -AffinityGroupNme newAffinityGroup -Locstion "West US"
.INPUTS
   None
.OUTPUTS
   None
#>
function New-AzureAffinityGroupIfNotExists
{
    param
    (
        # Name of the affinity group
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Location where the affinity group will be pointing to
        [Parameter(Mandatory = $true)]
        [String]
        $Location)
    
    $affinityGroup = Get-AzureAffinityGroup -Name $AffinityGroupName -ErrorAction SilentlyContinue
    if ($affinityGroup -eq $null)
    {
        New-AzureAffinityGroup -Name $AffinityGroupName -Location $Location -Label $AffinityGroupName `
        -ErrorVariable lastError -ErrorAction SilentlyContinue | Out-Null
        if (!($?))
        {
            throw "Cannot create the affinity group $AffinityGroupName on $Location"
        }
        Write-Verbose "Created affinity group $AffinityGroupName"
    }
    else
    {
        if ($affinityGroup.Location -ne $Location)
        {
            Write-Warning "Affinity group with name $AffinityGroupName already exists but in location `
            $affinityGroup.Location, not in $Location"
        }
    }
}

<#
.SYNOPSIS
  Returns the latest image for a given image family name filter.
.DESCRIPTION
  Will return the latest image based on a filter match on the ImageFamilyName and
  PublisedDate of the image.  The more specific the filter, the more control you have
  over the object returned.
.EXAMPLE
  The following example will return the latest SQL Server image.  It could be SQL Server
  2014, 2012 or 2008
    
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server*"

  The following example will return the latest SQL Server 2014 image. This function will
  also only select the image from images published by Microsoft.  
   
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server 2014*" -OnlyMicrosoftImages

  The following example will return $null because Microsoft doesn't publish Ubuntu images.
   
    Get-LatestImage -ImageFamilyNameFilter "*Ubuntu*" -OnlyMicrosoftImages
#>

function Get-LatestImage
{
    param
    (
        # A filter for selecting the image family.
        # For example, "Windows Server 2012*", "*2012 Datacenter*", "*SQL*, "Sharepoint*"
        [Parameter(Mandatory = $true)]
        [String]
        $ImageFamilyNameFilter,

        # A switch to indicate whether or not to select the latest image where the publisher is Microsoft.
        # If this switch is not specified, then images from all possible publishers are considered.
        [Parameter(Mandatory = $false)]
        [switch]
        $OnlyMicrosoftImages
    )

    # Get a list of all available images.
    $imageList = Get-AzureVMImage

    if ($OnlyMicrosoftImages.IsPresent)
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.PublisherName -ilike "Microsoft*" -and `
                              $_.ImageFamily -ilike $ImageFamilyNameFilter ) }
    }
    else
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.ImageFamily -ilike $ImageFamilyNameFilter ) } 
    }

    $imageList = $imageList | 
                     Sort-Object -Unique -Descending -Property ImageFamily |
                     Sort-Object -Descending -Property PublishedDate

    $imageList | Select-Object -First(1)
}

# Check if the current subscription's storage account's location is the same as the Location parameter
$subscription = Get-AzureSubscription -Current
$currentStorageAccountLocation = (Get-AzureStorageAccount -StorageAccountName $subscription.CurrentStorageAccount).GeoPrimaryLocation

if ($Location -ne $currentStorageAccountLocation)
{
    throw "Selected location parameter value, ""$Location"" is not the same as the active (current) subscription's current storage account location `
        ($currentStorageAccountLocation). Either change the location parameter value, or select a different storage account for the `
        subscription."
}

# Get an image to provision virtual machines from.
$imageFamilyNameFilter = "Windows Server 2012 Datacenter"
$image = Get-LatestImage -ImageFamilyNameFilter $imageFamilyNameFilter -OnlyMicrosoftImages
if ($image -eq $null)
{
    throw "Unable to find an image for $imageFamilyNameFilter to provision Virtual Machine."
}
$imageName = $image.ImageName


if ($NewService.IsPresent)
{
    # Check the related affinity group
    New-AzureAffinityGroupIfNotExists -AffinityGroupName $AffinityGroupName -Location $Location
}

$existingVMs = Get-AzureVM -ServiceName $ServiceName | Where-Object {$_.Name -Like "$ComputerNameBase*"} 
$vmNumberStart = 1
if ($existingVMs -ne $null)
{
    if (!($ExistingService.IsPresent) -and $NewService.IsPresent)
    {
        throw "Cannot add new instances to an existing set of instances when the ""new deployment"" parameter set `
        is active"
    }
    
    # Find the largest instance number   
    $highestInstanceNumber = ($existingVMs | 
        ForEach-Object {$_.Name.Substring($ComputerNameBase.Length, ($_.Name.Length - $ComputerNameBase.Length))} | 
            Measure-Object -Maximum).Maximum

    $vmNumberStart = $highestInstanceNumber + 1
    $firstVm = $existingVMs[0]
    
    $loadBalancedEndpoint = Get-AzureEndpoint -VM $firstVm | Where-Object {$_.LBSetName -ne $null}
    if ($loadBalancedEndpoint -eq $null)
    {
        throw "No load balanced endpoints on the VMs"
    }
    
    $availabilitySetName = $firstVm.AvailabilitySetName
    $imageName = (Get-AzureOSDisk -VM $firstVm).SourceImageName
    $InstanceSize = $firstVm.InstanceSize
    $EndpointName = $loadBalancedEndpoint.Name
    $EndpointProtocol = $loadBalancedEndpoint.Protocol
    $EndpointLocalPort = $loadBalancedEndpoint.LocalPort
    $EndpointPublicPort = $loadBalancedEndpoint.Port
    $lbSetName = $loadBalancedEndpoint.LBSetName
    $DirectServerReturn = $loadBalancedEndpoint.EnableDirectServerReturn
} 

$vms = @()

$lbSetName = "LB" + $EndpointName
$availabilitySetName = $EndpointName + "availability"

Write-Verbose "Prompt user for administrator credentials to use when provisioning the virtual machine(s)."
$credential = Get-Credential
Write-Verbose "Administrator credentials captured.  Use these credentials to login to the virtual machine(s) when the script is complete."

$service = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue

if ($service -eq $null)
{
    New-AzureService -ServiceName $ServiceName -AffinityGroup $AffinityGroupName
}

for ($index = $vmNumberStart; $index -lt $InstanceCount + $vmNumberStart; $index++)
{
    $ComputerName = $ComputerNameBase + $index
    $directLocalPort = 30000 + $index
    $directInstanceEndpointName = "directInstance" + $index
    $vm = New-AzureVMConfig -Name $ComputerName -InstanceSize $InstanceSize -ImageName $imageName `
            -AvailabilitySetName $availabilitySetName | 
            Add-AzureEndpoint -Name $EndpointName -Protocol $EndpointProtocol -LocalPort $EndpointLocalPort `
            -PublicPort $EndpointPublicPort -LBSetName $lbSetName -ProbeProtocol $EndpointProtocol `
            -ProbePort $EndpointPublicPort | 
            Add-AzureEndpoint -Name "directInstancePort" -Protocol $EndpointProtocol -LocalPort $EndpointLocalPort `
            -PublicPort $directLocalPort | 
            Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().UserName `
            -Password $credential.GetNetworkCredential().Password 
    
    New-AzureVM -ServiceName $ServiceName -VMs $vm -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VM."
    } 
}
