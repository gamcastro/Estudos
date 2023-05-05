function Get-FileContents{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatary=$True,
        ValueFromPipeline=$True)]
        [string[]]$Path
    )
    PROCESS{
        foreach ($folder in $path) {
            Write-Verbose "Path is $folder"
            $segments = $folder -split "\\"
            $last = $segments[-1]
            Write-Verbose "Last path is $last"
            $filename = Join-Path $folder $last
            $filename += ".txt"
            Get-Content $filename
        }
    }
}