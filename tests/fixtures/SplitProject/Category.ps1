# untouched-before
function Get-Category {
    param([int]$Number)

    if ($Number -lt 0) {
        if ($Number -le -500) { return 'extreme-negative' }
        if ($Number -le -400) { return 'severe-negative' }
        if ($Number -le -300) { return 'moderately-negative' }
        if ($Number -le -200) { return 'strong-negative' }
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
