param (
        [Parameter(Mandatory)]
        [ValidateScript({ $_ -ge 1 -and $_ -le 10 }, ErrorMessage = "The value must be between 1 and 10.")]
        [ValidateScript({ $_ % 2 -eq 0 }, ErrorMessage = "The value must be an even number.")]
        [int] $Value
    )

    Write-Host $Value