# Pure bounded observation seam. Never launches, kills, retries or cleans up.
function Wait-Batch3Process {
    param([Parameter(Mandatory)][scriptblock]$WaitForExit,
          [Parameter(Mandatory)][scriptblock]$GetExitCode,
          [Parameter(Mandatory)][scriptblock]$Clock,
          [ValidateRange(1, 30000)][int]$DeadlineMilliseconds = 15000)
    $reason = 'observation_exception'; $polls = 0; $previous = -1L
    try {
        $start = & $Clock
        if ($start -isnot [long] -or $start -lt 0) { throw 'clock' }
        $previous = $start
        # Finite even for a broken/frozen injected clock or a nonblocking waiter.
        while ($polls -lt 301) {
            $now = & $Clock
            if ($now -isnot [long] -or $now -lt $previous) { throw 'clock' }
            $previous = $now
            $remaining = $DeadlineMilliseconds - ($now - $start)
            if ($remaining -le 0) { $reason = 'deadline'; break }
            ++$polls
            $exited = & $WaitForExit ([int][Math]::Min(100, $remaining))
            if ($exited -isnot [bool]) { throw 'wait_shape' }
            $after = & $Clock
            if ($after -isnot [long] -or $after -lt $previous) { throw 'clock' }
            $previous = $after
            if ($after - $start -ge $DeadlineMilliseconds) { $reason = 'deadline'; break }
            if ($exited) {
                $code = & $GetExitCode
                if ($code -isnot [int]) { throw 'exit_shape' }
                $finished = & $Clock
                if ($finished -isnot [long] -or $finished -lt $previous) { throw 'clock' }
                $previous = $finished
                if ($finished - $start -ge $DeadlineMilliseconds) { $reason = 'deadline'; break }
                return [pscustomobject]@{ Code = $code; Reason = 'exited'; SettlementUnknown = $false; Polls = $polls }
            }
        }
        if ($polls -eq 301) { $reason = 'poll_budget' }
    } catch { } # Fixed categories only; never a raw exception or path.
    return [pscustomobject]@{ Code = 10; Reason = $reason; SettlementUnknown = $true; Polls = $polls }
}
