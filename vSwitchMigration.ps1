####################
## 1 Inventory
####################

$isLBFOTeam = Get-NetLbfoTeam | Out-GridView -PassThru
$isvSwitch = Get-VMSwitch | Out-GridView -PassThru
$SETTeam = $isvSwitch.Name.Replace("LS","LSW")   ## New vSwitch name will change from LS01 to LSW01
Write-host "New vSwitch name: $SETTEAM"
Start-Sleep -Seconds 15

$tmpAdapter = Get-NetAdapter | Where-Object InterfaceDescription -in $isvSwitch.NetAdapterInterfaceDescriptions
$tmpTeam = Get-NetLbfoTeam | Where-Object { $_.Name -in $tmpAdapter.Name -or $_.Name -eq $tmpAdapter.Name }
$LBFOTeam = $tmpTeam.Name

## Data collection
$configData = @{ NetLBFOTeam = Get-NetLbfoTeam -Name $LBFOTeam }
$configData += @{
	NetAdapter = Get-NetAdapter -Name $configData.NetLBFOTeam.TeamNics -ErrorAction SilentlyContinue
	NetAdapterBinding = Get-NetAdapterBinding -Name $configData.NetLBFOTeam.TeamNics -ErrorAction SilentlyContinue
}

$configData += @{
	LBFOVMSwitch = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object name -eq $configData.NetAdapter.name
}

$configData += @{
			VMNetworkAdapter = Get-VMNetworkAdapter -All | Where-Object SwitchName -EQ $configData.LBFOVMSwitch.Name -ErrorAction SilentlyContinue
		}


# Grabbing host vNICs (ManagementOS) attached to the LBFO vSwitch
$configData += @{ HostvNICs = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $configData.LBFOVMSwitch.Name) }

# EnableIOV should be $true as a best practice unless Hyper-V QoS is in use. Enabling IOV turns the vSwitch Bandwidth mode to 'None' so no legacy QoS
Write-host "Bandwidth Reservation Mode: $($ConfigData.LBFOVMSwitch.BandwidthReservationMode)"
Switch ($ConfigData.LBFOVMSwitch.BandwidthReservationMode)
{
	{ 'Absolute' -or 'Weight' } {
		If ($configData.LBFOVMSwitch.IovEnabled)
		{
			$IovEnabled = $true
		}
		Else
		{
			$IovEnabled = $false
		}
	}
	'None' { $IovEnabled = $true }
	default { $IovEnabled = $false }
}

Write-host "End of inventory" -ForegroundColor Green
Write-host "Next step makes changes" -ForegroundColor Green

Read-Host "Continue? "

####################
## 2 Create switch, remove first NIC from team, and connect VMs to new switch
####################

## Remove first NIC from the team
$NetAdapterNames = $configData.NetLBFOTeam.Members[0]
Remove-NetLbfoTeamMember -Name $configData.NetLBFOTeam.Members[0] -Team $configData.NetLBFOTeam.Name

Write-Verbose "IOV Enabled: $IovEnabled"
$SETTeamParams = @{
	Name				  = $SETTeam
	NetAdapterName	      = $NetAdapterNames
	EnablePacketDirect    = $false
	EnableEmbeddedTeaming = $true
	AllowManagementOS	  = $false
	MinimumBandwidthMode  = $($ConfigData.LBFOVMSwitch.BandwidthReservationMode)
	EnableIov			  = $IovEnabled
}

## Create new vSwitch
$newVMSwitch = New-VMSwitch @SETTeamParams -verbose:$False
if( !$newVMSwitch)
{
	Write-host "Failed to create new vSwitch" -ForegroundColor Red
	Exit
}else{
	Write-host "vSwitch created" -ForegroundColor Green
}

## Check for VMs attached to the switch
$vmNICs = ($configData.VMNetworkAdapter | Where-Object VMName -ne $Null)
If( $vmNics -eq $null)
{	
	Write-host "No connected VMs, end of script" -ForegroundColor Green
}
else{
	## Move VMs to the new switch
	Connect-VMNetworkAdapter -VMNetworkAdapter $vmNICs -SwitchName $SETTeam
	## Check for VMs that are still connected to the old switch
	$CheckVMs = Get-VMNetworkAdapter -All | Where-Object SwitchName -EQ $configData.LBFOVMSwitch.Name -ErrorAction SilentlyContinue
	if( $CheckVMs)
	{
		write-host "Still VMs connect, script will stop" -ForegroundColor Red
		exit
	}else{ write-host "VM Networkadapter is empty, OK" -ForegroundColor Green}

}


Write-host "vSwitch created and VMs switched" -ForegroundColor Green
Write-host "Next section removes old vSwitch" -ForegroundColor Green
Read-Host "Continue?"

####################
## 3 vSwitch cleanup
####################

$remainingAdapters = $configData.NetLBFOTeam.Members
Remove-VMSwitch -Name $configData.LBFOVMSwitch.Name -Force
Write-host "30sec wait"
Start-Sleep -Seconds 30
Remove-NetLbfoTeam -Name $configData.NetLBFOTeam.Name

## Remaining adapters are added to the new vSwitch
Add-VMSwitchTeamMember -NetAdapterName $remainingAdapters -VMSwitchName $SETTeam

## This part is optional, it will reset the advanced properties of the SET adapters to best practices
## However it was not working for us and we are not sure if it is needed
$EnableBestPractices = $false  ## Voor nu even op false tot fouten eruit zijn
if ($EnableBestPractices)
{
	$SETInterfaces = (Get-VMSwitchTeam -Name $SETTeam).NetAdapterInterfaceDescription
	$SETAdapters = (Get-NetAdapter | Where-Object InterfaceDescription -in $SETInterfaces).Name
	Foreach ($interface in $SETAdapters)
	{
		Reset-NetAdapterAdvancedProperty -Name $interface -ErrorAction SilentlyContinue `
											-DisplayName 'NVGRE Encapsulated Task Offload', 'VXLAN Encapsulated Task Offload', 'IPV4 Checksum Offload',
											'NetworkDirect Technology', 'Recv Segment Coalescing (IPv4)', 'Recv Segment Coalescing (IPv6)',
											'Maximum number of RSS Processors', 'Maximum Number of RSS Queues', 'RSS Base Processor Number',
											'RSS Load Balancing Profile', 'SR-IOV', 'TCP/UDP Checksum Offload (IPv4)', 'TCP/UDP Checksum Offload (IPv6)'
		Set-NetAdapterAdvancedProperty -Name $interface -DisplayName 'Packet Direct' -RegistryValue 0 -ErrorAction SilentlyContinue
		Set-NetAdapterAdvancedProperty -Name $interface -RegistryValue 1 -DisplayName 'Receive Side Scaling', 'Virtual Switch RSS', 'Virtual Machine Queues', 'NetworkDirect Functionality' -ErrorAction SilentlyContinue
	}
	$NodeOSCaption = (Get-CimInstance -ClassName 'Win32_OperatingSystem').Caption
	Switch -Wildcard ($NodeOSCaption)
	{
		'*Windows Server 2016*' {
			Write-Host " 2016 found " 
			$SETSwitchUpdates = @{ DefaultQueueVrssQueueSchedulingMode = 'StaticVRSS' }
			$vmNICUpdates = @{ VrssQueueSchedulingMode = 'StaticVRSS' }
			$HostvNICUpdates = @{ VrssQueueSchedulingMode = 'StaticVRSS' }
		}
		'*Windows Server 2019*' {
			$SETSwitchUpdates = @{
				EnableSoftwareRsc				    = $true
				DefaultQueueVrssQueueSchedulingMode = 'Dynamic'
			}
			$vmNICUpdates = @{ VrssQueueSchedulingMode = 'Dynamic' }
			$HostvNICUpdates = @{ VrssQueueSchedulingMode = 'Dynamic' }
		}
	}
	$SETSwitchUpdates += @{
		Name						  = $SETTeam
		DefaultQueueVrssEnabled	      = $true
		DefaultQueueVmmqEnabled	      = $true
		DefaultQueueVrssMinQueuePairs = 8
		DefaultQueueVrssMaxQueuePairs = 16
	}
	$vmNICUpdates += @{
		VMName		      = '*'
		VrssEnabled	      = $true
		VmmqEnabled	      = $true
		VrssMinQueuePairs = 8
		VrssMaxQueuePairs = 16
	}
	$HostvNICUpdates += @{
		ManagementOS	  = $true
		VrssEnabled	      = $true
		VmmqEnabled	      = $true
		VrssMinQueuePairs = 8
		VrssMaxQueuePairs = 16
	}
	Set-VMSwitch @SETSwitchUpdates
	Set-VMSwitchTeam -Name $SETTeam -LoadBalancingAlgorithm HyperVPort
	Set-VMNetworkAdapter $HostvNICUpdates
	Set-VMNetworkAdapter @vmNICUpdates
	Remove-Variable SETSwitchUpdates, vmNICUpdates, HostvNICUpdates, NodeOSCaption -ErrorAction SilentlyContinue
}

