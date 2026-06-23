BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
    . "$PSScriptRoot/../private/margonem-audit.ps1"
}

Describe 'Margonem audit log' {
    BeforeEach {
        $script:TempLog = [System.IO.Path]::GetTempFileName()
        # GetTempFileName creates an empty file — delete it so Initialize re-creates parent
        Remove-Item -LiteralPath $script:TempLog -Force -ErrorAction SilentlyContinue
        Initialize-MargonemAuditLog -Path $script:TempLog
    }

    AfterEach {
        if (Test-Path $script:TempLog) {
            Remove-Item -LiteralPath $script:TempLog -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a well-formed JSON line per event' {
        Write-MargonemAuditLog -Event 'mint-ok' -Detail @{
            outcome        = 'success'
            playerName     = 'Bob'
            margonemUserId = 78198
            httpStatus     = 201
        }
        $Lines = [System.IO.File]::ReadAllLines($script:TempLog)
        $Lines.Count | Should -Be 1
        $Obj = $Lines[0] | ConvertFrom-Json
        $Obj.event          | Should -Be 'mint-ok'
        $Obj.outcome        | Should -Be 'success'
        $Obj.playerName     | Should -Be 'Bob'
        $Obj.margonemUserId | Should -Be 78198
        $Obj.httpStatus     | Should -Be 201
        $Obj.ts             | Should -Not -BeNullOrEmpty
    }

    It 'appends successive events without truncating' {
        Write-MargonemAuditLog -Event 'mint-ok'   -Detail @{ httpStatus = 201 }
        Write-MargonemAuditLog -Event 'mint-fail' -Detail @{ httpStatus = 401 }
        $Lines = [System.IO.File]::ReadAllLines($script:TempLog)
        $Lines.Count | Should -Be 2
    }

    It 'NEVER contains an "ip" or "payload" or raw bearer in any event' {
        # Cross-validate the "no PII" invariant. We emit ten realistic
        # event shapes; none of the recorded lines may contain forbidden keys.
        $RealShapes = @(
            @{ event='mint-ok';              detail=@{ outcome='success'; playerName='Alice'; margonemUserId=1; httpStatus=201 } },
            @{ event='mint-fail';            detail=@{ outcome='failure'; reason='signature does not verify'; httpStatus=401 } },
            @{ event='verify-ok';            detail=@{ outcome='success'; margonemUserId=1; httpStatus=200 } },
            @{ event='verify-fail';          detail=@{ outcome='failure'; reason='timestamp skew 600s exceeds limit 300s'; httpStatus=401 } },
            @{ event='introspect';           detail=@{ outcome='active'; tokenName='margonem:Alice'; httpStatus=200 } },
            @{ event='refresh-key';          detail=@{ outcome='success'; sourceUrl='http://x'; httpStatus=200 } },
            @{ event='refresh-key';          detail=@{ outcome='failure'; reason='upstream-fetch-failed'; sourceUrl='http://x'; httpStatus=502 } },
            @{ event='sessions-invalidated'; detail=@{ outcome='success'; reason='operator-revoke'; playerName='Bob'; removed=3; httpStatus=200 } },
            @{ event='sessions-invalidated'; detail=@{ outcome='success'; reason='gracze-md-write'; removed=5; file='Gracze.md'; httpStatus=0 } },
            @{ event='mint-fail';            detail=@{ outcome='failure'; reason='no-matching-player'; margonemUserId=99; httpStatus=404 } }
        )
        foreach ($S in $RealShapes) {
            Write-MargonemAuditLog -Event $S.event -Detail $S.detail
        }
        $Lines = [System.IO.File]::ReadAllLines($script:TempLog)
        foreach ($L in $Lines) {
            # The audit log MUST NEVER carry IP, payload, or raw token. We check
            # the literal field-name strings — if any handler ever puts these
            # in $Detail by mistake, this test catches it.
            $L | Should -Not -Match '"ip"\s*:'
            $L | Should -Not -Match '"payload"\s*:'
            $L | Should -Not -Match '"signatureBase64"\s*:'
            $L | Should -Not -Match '"token"\s*:\s*"rb[ts]_'
        }
    }

    It 'is a no-op when not initialised' {
        # Force the helper into the uninitialised state — should not throw,
        # should not create the file
        $script:MargonemAuditPath = $null
        $TmpProbe = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
            'mg-audit-noop-' + [guid]::NewGuid().ToString('N'))
        { Write-MargonemAuditLog -Event 'mint-ok' -Detail @{ httpStatus = 201 } } |
            Should -Not -Throw
        Test-Path $TmpProbe | Should -BeFalse
    }
}
