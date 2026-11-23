# untouched-before
function Get-Category {
    param([int]$Number)

    if ($Number -lt 0) {
        if ($Number -le -100) { return 'very-negative' }
        return 'negative'
    }
    if ($Number -eq 0) { return 'zero' }
    if ($Number -ge 100) { return 'large' }
    return 'positive'
}

# untouched-after
function Get-Unchanged {
    'unchanged'
}
