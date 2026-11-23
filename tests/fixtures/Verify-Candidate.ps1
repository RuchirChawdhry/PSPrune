param([Parameter(Mandatory)][string]$CandidatePath)

$ErrorActionPreference = 'Stop'
. $CandidatePath

$cases = @(
    @{ Input = -99; Expected = 'negative' }
    @{ Input = -1; Expected = 'negative' }
    @{ Input = 0; Expected = 'zero' }
    @{ Input = 1; Expected = 'positive' }
    @{ Input = 99; Expected = 'positive' }
    @{ Input = 100; Expected = 'large' }
    @{ Input = 999; Expected = 'large' }
)

foreach ($case in $cases) {
    $actual = Get-Label -Number $case.Input
    if ($actual -cne $case.Expected) {
        throw "Get-Label($($case.Input)): expected '$($case.Expected)', got '$actual'."
    }
}

if ((Get-Other) -cne 'unchanged') {
    throw 'Get-Other was modified.'
}
