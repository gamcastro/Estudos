function Get-DiskInfo {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True,
            ValueFromPipeline = $True)]
        [string[]]$ComputerName
    )
    BEGIN {
        Set-StrictMode -Version 2.0
    }
    PROCESS {
        foreach ($comp in $ComputerName) {
            $params = @{'ComputerName' = $comp
                'ClassName'            = 'Win32_LogicalDisk'
            }
            
            $disks = Get-CimInstance @params

            foreach ($disk in $disks) {
                $props = @{'ComputerName' = $comp
                    'Size'                = $disk.Size
                    'DriveType'           = $disk.DriveType
                }

                if ($disk.DriveType -eq 'fixed') {
                    $props.Add('FreeSpace' , $disk.FreeSpace)
                }
                else {
                    $props.Add('FreeSpace', 'N/A')
                }

                New-Object -TypeName PSObject -Property $props

            }

        }
    }
}
Get-DiskInfo -ComputerName localhost