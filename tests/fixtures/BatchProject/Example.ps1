# before sentinel
function Get-Label {
    param([int]$Number)
    if ($Number -lt 0) { return 'negative' }
    if ($Number -eq 0) { return 'zero' }
    if ($Number -ge 100) { return 'large' }
    return 'positive'
}

# after sentinel
function Get-Other {
    return 'unchanged'
}
