function Get-DiskCheck {
    [CmdletBinding(DefaultParameterSetName = "name" )]
    Param(
        [Parameter(Position = 0, Mandatory,
            HelpMessage = "Enter a computername to check",
            ParameterSetName = "name",
            ValueFromPipeline
        )]
        [Alias("cn")]
        [ValidateNotNullOrEmpty()]
        [string[]]$Computername,

        [Parameter(Mandatory,
            HelpMessage = "Enter the path to a text file of computer names",
            ParameterSetName = "file")]
        [ValidateScript({
                if (Test-Path $_) {
                    $True
                }
                else {
                    Throw "Cannot validate path $_"
                }
            })]
        [ValidatePattern("\.txt$")]
        [string]$Path,

        [ValidateRange(10, 50)]
        [int]$Threshhold = 25,

        [ValidateSet("C:", "D:", "E:", "F:")]
        [string]$Drive = "C:",

        [switch]$Test
    )
    BEGIN {
        Write-Verbose "[BEGIN ] Starting $($MyInvocation.MyCommand)"

        $cimParam = @{ClassName = 'Win32_LogicalDisk'
            Filter              = "DeviceID='$Drive'"
            ComputerName        = $Null
            ErrorAction         = "Stop"
        }
    }
    PROCESS {
        if ($PSCmdlet.ParameterSetName = 'name') {
            $names = $Computername
        }
        else {
            #get list of names and trim off any extra spaces
            Write-Verbose "[PROCESS] Importing names from $path"
            $names = Get-Content -Path $path | Where { $_ -match "\w+" } |
            foreach { $_.Trim() }
        }

        if ($test) {
            Write-Verbose "[PROCESS ] Testing connectivity"
            #ignore errors for offline computers
            $names = $names | Where { Test-WSman $_ -ErrorAction SilentlyContinue }
        }

        foreach ($computer in $names) {
            $cimParam.ComputerName = $computer
            Write-Verbose "[PROCESS] Querying $($computer.ToUpper())"
            Try {
                $data = Get-CimInstance @cimParam

                #write custom result to the pipeline
                $data | Select ComputerName,
                DeviceID, Size, FreeSpace,
                @{Name = 'PctFree'; Expression = { [math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } },
                @{Name = "OK"; Expression = {
                        [int]$p = ($_.FreeSpace / $_.Size) * 100
                        if ($p -ge $Threshhold) {
                            $True
                        }
                        else {
                            $false
                        }
                    }, @{Name = "Date"; Expression = { (Get-Date) } }
                }
            }
            Catch {
                Write-Warning "[$($computer.ToUpper())] Failed. $($_.Exception.message)"
            }
            
            
        }
        END {
            Write-Verbose "[END ] Ending: $($MyInvocation.MyCommand)"
        }
    }
}