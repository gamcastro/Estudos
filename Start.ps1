function Get-MachineInfo {
    [CmdletBinding()]
    Param(
        [Parameter(ValueFromPipeline = $True,
            Mandatary = $True)]
        [Alias('CN', 'MachineName', 'Name')]
        [string[]]$ComputerName,

        [string]$LogFailuresToPath,

        [switch]$ProtocolFallback
    )
    BEGIN {}
    PROCESS {
        foreach ($computer in $computerName) {
            if ($protocol -eq 'Dcom') {
                $option = New-CimSessionOption -Protocol Dcom
            }
            else {
                $option = New-CimSessionOption -Protocol Wsman
            }

            Try {
                Write-Verbose "Connecting to $computer over $protocol "
                $params = @{'ComputerName' = $ComputerName
                    'SessionOption'        = $option
                    'ErrorAction'          = 'Stop'
                }
                $session = New-CimSession @params

                Write-Verose 'Querying from $computer'
                $os_params = @{'ClassName' = 'Win32_OperatingSystem'
                    'CimSession'           = $session
                }
                $os = Get-CimInstante @os_params

                $cs_params = @{'ClassName' = 'Win32_ComputerSystem'
                    'CimSession'           = $session
                }
                
                $cs = Get-CimInstance @cs_params

                $sysdrive = $os.SystemDrive
                $drive_params = @{'ClassName' = 'Win32_LogicalDrive'
                    'Filter'                  = "DeviceID='$sysdrive'"
                    'CimSession'              = $session
                }
                $drive = Get-CimInstance @drive_params

                $proc_params = @{'ClassName' = 'Win32_Processor'
                    'CimSession'             = $session
                }
                $proc = Get-CimInstance @proc_params | Select-Object -first 1

                Write-Verbose "Closing session to $computer"
                $session | Remove-CimSession

                Write-Verbose "Outputting for $computer"
                $obj = [pscustomobject]@{'ComputerName' = $computer
                    'OSVersion'                         = $os.version
                    'SPVersion'                         = $os.servicepachmajorversion
                    'OSBuild'                           = $os.buildnumber
                    'Manufacturer'                      = $cs.Manufacturer
                    'Model'                             = $cs.Model
                    'Procs'                             = $cs.numberofprocessors
                    'Cores'                             = $cs.numberoflogicalprocessors
                    'RAM'                               = ($cs.totalphysicalmemory / 1GB)
                    'Arch'                              = $proc.addresswidth
                    'SysDriveFreeSpace'                 = $drive.freespace
                }
                [string[]]$props = 'ComputerName', 'OSVersion', 'Cores', 'RAM'
                $ddps = New-Object -TypeName System.Management.Automation.PSPropertySet DefaultDisplayPropertySet, $props
                $pssm = [System.Management.Automation.PSMemberInfo[]]$ddps
                $obj | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value $pssm
                Write-Output $obj
            }
            Catch {
                Write-Warning "FAILED $computer on $protocol"

                if ($ProtocolFallback) {
                    if ($protocol -eq 'Dcom') {
                        $newprotocol = 'Wsman'
                    }
                    else {
                        $newprotocol = 'Dcom'
                    }

                    Write-Verbose "Trying again with $newprotocol"
                    $params = @{'ComputerName' = $ComputerName
                        'Protocol'             = $newprotocol
                        'ProtocolFallback'     = $False
                    }

                    if ($PSBoundParameters.ContainsKey('LoginFailureToPath') {
                            $params += @{'LogFailuresToPath' = $LogFailuresToPath }
                        }

                        Get-MachinfeInfo @params
                    }

                    If (-not $ProtocolFallback -and $PSBoundParameters.ContainsKey('LogFailuresToPath')) {
                        Write-Verbose "Logging to $LogFailureToPath"
                        $computer | Out-File $LogFailuresToPath -Append
                    }
                }
            }
        }
    }