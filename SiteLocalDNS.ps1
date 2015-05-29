$LocalZoneName = "site"
$ControlZoneName = "sitelocal"
$MainZoneName = "jivedev.com"


#Check to make sure that this is a DNS server.
$DNSServerObject = Get-DnsServer -ComputerName $Env:Computername
If (!($DNSServerObject)) {Throw "$Env:Computername is not a DNS Server." }
#Get this server's AD site name
$SiteName = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name.ToLower()

#Check for the existence of the "Magic" zone.  If it's not there, create it.
if ($DNSServerObject.ServerZone.ZoneName -notcontains $LocalZoneName) {
    $ObjWMIClass = [wmiclass]"root\MicrosoftDNS:MicrosoftDNS_Zone"
    $ObjWMIClass.CreateZone($LocalZoneName, 0, $False)
    }

if ((Get-ADDomain).pdcemulator -match $Env:Computername) {
    if ($DNSServerObject.ServerZone.ZoneName -notcontains $ControlZoneName) {
        $ObjWMIClass = [wmiclass]"root\MicrosoftDNS:MicrosoftDNS_Zone"
        $ObjWMIClass.CreateZone($ControlZoneName, 1, $True)
        }
    }
#Gather records from this site's "control" subdomain (e.g. "magic-pdx")
$NonMagicRecords = @()
Foreach ($Record in $(Get-DnsServerResourceRecord -ZoneName $ControlZoneName | ? Hostname -match "\.$sitename")) {
    $NonMagicRecords += $Record | Select-Object *, @{Expression={$MainZoneName}; Label="ZoneName"}, @{Expression={($Record.hostname -split "\.")[0]}; Label="ShortName"}
    } 

#Check the other control subdomains for records that this one doesn't have and then add this to this one, ensuring reliable resolution.
Foreach ($Record in $(Get-DnsServerResourceRecord -ZoneName $MainZoneName | ? Hostname -match "\.$LocalZoneName-" | ? Hostname -notmatch "$sitename" )) {
    if ($NonMagicRecords.ShortName -notcontains ($Record.hostname -split "\.")[0]){
        $NonMagicHostname = "$(($Record.hostname -split "\.")[0]).$LocalZoneName-$sitename"
        Add-DnsServerResourceRecordCName -ZoneName $MainZoneName  -Name $NonMagicHostname -HostNameAlias $Record.RecordData.HostnameAlias
        $Record = Get-DnsServerResourceRecord -ZoneName $MainZoneName | ? Hostname -match $NonMagicHostname
        $NonMagicRecords += $Record | Select-Object *, @{Expression={$MainZoneName}; Label="ZoneName"}, @{Expression={($Record.hostname -split "\.")[0]}; Label="ShortName"}
        }
    }

#Get the current list of records in this server's "Magic" zone.
$MagicRecords = Get-DnsServerZone -zone $LocalZoneName | Get-DnsServerResourceRecord | ? Hostname -NotMatch "@"

#Add new "magic" records, update existing records.
Foreach ($Record in $NonMagicRecords) {
    if ($MagicRecords.hostname -notcontains $Record.ShortName) {
        Add-DnsServerResourceRecordCName -ZoneName $LocalZoneName  -Name $Record.ShortName  -HostNameAlias "$($Record.Hostname).$($Record.ZoneName)"
        } else {
        $ExistingMagicRecord = Get-DNSServerResourceRecord -ZoneName $LocalZoneName -Name $Record.ShortName
        $UpdatedMagicRecord = $ExistingMagicRecord.clone()
        $UpdatedMagicRecord.RecordData.HostNameAlias = "$($Record.Hostname).$($Record.ZoneName)"
        Set-DnsServerResourceRecord -ZoneName $LocalZoneName -NewInputObject $UpdatedMagicRecord -OldInputObject $ExistingMagicRecord
        }
    }

$MagicRecords = Get-DnsServerZone -zone $LocalZoneName | Get-DnsServerResourceRecord | ? Hostname -NotMatch "@"
Foreach ($Record in $MagicRecords) {
    if (!(Get-DnsServerResourceRecord -ZoneName $MainZoneName -Name $Record.Hostname -ErrorAction SilentlyContinue)) {
        Add-DNSServerResourceRecordCName -ZoneName $MainZoneName -Name $Record.Hostname -HostNameAlias "$($Record.Hostname).$LocalZoneName"
    }

    }