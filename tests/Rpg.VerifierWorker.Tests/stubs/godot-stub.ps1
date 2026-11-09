# Stands in for godot.exe in the GodotReplayRunner tests (spec battle-verify 6). Behaviour comes from STUB_MODE.
# STUB_LOG: append the command line. STUB_PID: write this process id before hanging.
$all = $args
if ($env:STUB_LOG) { Add-Content -Path $env:STUB_LOG -Value ($all -join ' ') }

function Arg($name) {
    $i = [array]::IndexOf($all, $name)
    if ($i -ge 0 -and $i + 1 -lt $all.Count) { return $all[$i + 1] }
}

$inPath = Arg '--in'
$outPath = Arg '--out'
$mode = $env:STUB_MODE
$battleId = ''
if ($inPath -and (Test-Path $inPath)) { $battleId = (Get-Content $inPath -Raw | ConvertFrom-Json).snapshot.battleId }

function Verified {
    '{"schemaVersion":1,"battleId":"' + $battleId + '","verdict":"Verified","errorCode":null,"error":null,"mismatch":null,"outcome":"Victory","turns":5,"finalStateHash":"abc","engineVersion":"stub"}'
}

function Rejected {
    '{"schemaVersion":1,"battleId":"' + $battleId + '","verdict":"Rejected","errorCode":2002,"error":"ReplayMismatch","mismatch":{"reason":"TurnMismatch","turn":1,"detail":"d"},"outcome":"Ongoing","turns":1,"finalStateHash":"abc","engineVersion":"stub"}'
}

# Spec economy-challenges (e2e): a Verified Victory whose facts come from STUB_FACTS (a BattleFacts JSON), so a scenario can
# report completions that no game content emits yet.
function VerifiedWithFacts {
    $v = Verified
    $v.Substring(0, $v.Length - 1) + ',"facts":' + $env:STUB_FACTS + '}'
}

# Spec run-verify (steps): the step scene reads a StepRequest and writes a StepVerdict.
function StepVerified {
    '{"status":"Verified","errorCode":null,"error":null,"mismatch":null,"startHash":"s","endHash":"e","battles":[],"verifierRulesetVersion":"","engineVersion":"stub","verifiedAt":"2026-11-08T00:00:00Z"}'
}

function StepRejected {
    '{"status":"Rejected","errorCode":2002,"error":"ReplayMismatch","mismatch":{"reason":"StateHashMismatch","seq":3,"detail":"d"},"startHash":"s","endHash":"","battles":[],"verifierRulesetVersion":"","engineVersion":"stub","verifiedAt":"2026-11-08T00:00:00Z"}'
}

# Spec run-verify (e2e): a worker over the stub that reports facts. A step request is answered here, except the genesis
# step, which must produce the real start the client's seq 1 is compared with, so it goes to the real engine (STUB_REAL_GODOT).
if ($mode -eq 'verified-facts' -and $all -contains 'res://game/verify/step_main.tscn') {
    $step = Get-Content $inPath -Raw | ConvertFrom-Json
    if ($step.kind -eq 'Genesis') {
        & $env:STUB_REAL_GODOT @all
        exit $LASTEXITCODE
    }
    $reported = @()
    foreach ($item in $step.actions) {
        if ($item.action.battle) {
            $facts = if ($env:STUB_FACTS) { ',"facts":' + $env:STUB_FACTS } else { '' }
            $reported += ('{"schemaVersion":1,"battleId":"' + $item.action.battle.battleId + '","verdict":"Verified","errorCode":null,"error":null,"mismatch":null,"outcome":"Victory","turns":5,"finalStateHash":"abc","engineVersion":"stub"' + $facts + '}')
        }
    }
    $last = $step.actions[$step.actions.Count - 1]
    $text = '{"status":"Verified","errorCode":null,"error":null,"mismatch":null,"startHash":"' + $step.startStateHash + '","endHash":"' + $last.stateHash + '","battles":[' + ($reported -join ',') + '],"verifierRulesetVersion":"","engineVersion":"stub","verifiedAt":"2026-11-08T00:00:00Z"}'
    [System.IO.File]::WriteAllText($outPath, $text)
    exit 0
}

switch ($mode) {
    'step-verified' { [System.IO.File]::WriteAllText($outPath, (StepVerified)); exit 0 }
    'step-rejected' { [System.IO.File]::WriteAllText($outPath, (StepRejected)); exit 2 }
    'malformed-step-result' { [System.IO.File]::WriteAllText($outPath, ((StepRejected) -replace 'StateHashMismatch', 'MalformedRequest')); exit 3 }
    'malformed-battle-result' { [System.IO.File]::WriteAllText($outPath, ((Rejected) -replace 'TurnMismatch', 'MalformedRequest')); exit 3 }
    'malformed' { exit 3 }
    'malformed-with-result' { [System.IO.File]::WriteAllText($outPath, (StepRejected)); exit 3 }
    'verified-facts' { [System.IO.File]::WriteAllText($outPath, (VerifiedWithFacts)); exit 0 }
    'verified' { [System.IO.File]::WriteAllText($outPath, (Verified)); exit 0 }
    'rejected' { [System.IO.File]::WriteAllText($outPath, (Rejected)); exit 2 }
    'exit-mismatch' { [System.IO.File]::WriteAllText($outPath, (Verified)); exit 2 }
    'crash' { Write-Output 'SCRIPT ERROR: something broke'; exit 1 }
    'noresult' { exit 0 }
    'garbage' { [System.IO.File]::WriteAllText($outPath, 'not json'); exit 0 }
    'hang' {
        if ($env:STUB_PID) { Set-Content -Path $env:STUB_PID -Value $PID }
        Start-Sleep -Seconds 120
        exit 0
    }
    'version-noisy' {
        Write-Output 'C:\a+b\x'
        Write-Output '4.7.2.stable.mono+0123456789abcdef'
        Write-Output 'trailing+warning'
        exit 0
    }
    'version' { Write-Output 'Godot Engine v4.7.2'; Write-Output '4.7.2.stable.mono+0123456789abcdef'; exit 0 }
    default { exit 1 }
}
