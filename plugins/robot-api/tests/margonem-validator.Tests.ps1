BeforeAll {
    Import-Module "$PSScriptRoot/../../../Robot.PowerShell.psm1" -Force -WarningAction SilentlyContinue
}

Describe 'Robot.MargonemValidator' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.MargonemValidator').Type) {
            Set-ItResult -Skipped -Because 'Robot.MargonemValidator not compiled'
        }

        # Generate a test RSA keypair, write the public half as PEM,
        # load it into the cache. The private half stays in-test for signing.
        $script:TestRsa = [System.Security.Cryptography.RSA]::Create(2048)
        $script:PemPath = [System.IO.Path]::GetTempFileName()
        $PublicPem = $script:TestRsa.ExportSubjectPublicKeyInfoPem()
        [System.IO.File]::WriteAllText($script:PemPath, $PublicPem)
        [Robot.MargonemPublicKeyCache]::Load($script:PemPath)
    }

    AfterAll {
        if ($script:TestRsa) { $script:TestRsa.Dispose() }
        if ($script:PemPath -and (Test-Path $script:PemPath)) {
            Remove-Item -LiteralPath $script:PemPath -Force -ErrorAction SilentlyContinue
        }
        if (([System.Management.Automation.PSTypeName]'Robot.MargonemPublicKeyCache').Type) {
            [Robot.MargonemPublicKeyCache]::Reset()
        }
    }

    # Helper: sign components with the test private key, return a Margonem-shaped JSON
    function script:New-SignedPayload {
        param(
            [long]$UserId,
            [string]$Token,
            [long]$Ts
        )
        $ValidatedString = "$UserId+$Token+$Ts"
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($ValidatedString)
        $Sig = $script:TestRsa.SignData(
            $Bytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $SigB64 = [Convert]::ToBase64String($Sig)
        $Obj = @{
            user_id         = $UserId
            token           = $Token
            ts              = $Ts
            validatedString = $ValidatedString
            signatureBase64 = $SigB64
        }
        return ($Obj | ConvertTo-Json -Compress)
    }

    Context 'Happy path' {
        It 'verifies a properly-signed payload and round-trips fields' {
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token '123xyz' -Ts $Now
            $Result = [Robot.MargonemValidator]::Validate($Json, 300)
            $Result.IsValid       | Should -BeTrue
            $Result.UserId        | Should -Be 78198
            $Result.Token         | Should -Be '123xyz'
            $Result.Timestamp     | Should -Be $Now
            $Result.FailureReason | Should -BeNullOrEmpty
        }
    }

    Context 'Tampered payloads fail closed' {
        It 'rejects a payload with a swapped user_id' {
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token '123xyz' -Ts $Now
            # Surgically swap the user_id while keeping the signature
            $Tampered = $Json -replace '"user_id":78198', '"user_id":99999'
            $Result = [Robot.MargonemValidator]::Validate($Tampered, 300)
            $Result.IsValid       | Should -BeFalse
            $Result.FailureReason | Should -Match 'signature does not verify'
        }

        It 'rejects a payload with a swapped token' {
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token '123xyz' -Ts $Now
            $Tampered = $Json -replace '"token":"123xyz"', '"token":"hijack"'
            $Result = [Robot.MargonemValidator]::Validate($Tampered, 300)
            $Result.IsValid | Should -BeFalse
        }
    }

    Context 'Freshness window' {
        It 'rejects a payload older than the freshness window' {
            $Old = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token 'abc' -Ts $Old
            $Result = [Robot.MargonemValidator]::Validate($Json, 300)
            $Result.IsValid       | Should -BeFalse
            $Result.FailureReason | Should -Match 'timestamp skew'
        }

        It 'rejects a payload too far in the future (symmetric window)' {
            $Future = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token 'abc' -Ts $Future
            $Result = [Robot.MargonemValidator]::Validate($Json, 300)
            $Result.IsValid       | Should -BeFalse
            $Result.FailureReason | Should -Match 'timestamp skew'
        }

        It 'accepts a payload within the freshness window' {
            $Just = [DateTimeOffset]::UtcNow.AddSeconds(-60).ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 78198 -Token 'abc' -Ts $Just
            $Result = [Robot.MargonemValidator]::Validate($Json, 300)
            $Result.IsValid | Should -BeTrue
        }
    }

    Context 'Malformed input' {
        It 'rejects empty payload' {
            $Result = [Robot.MargonemValidator]::Validate('', 300)
            $Result.IsValid | Should -BeFalse
            $Result.FailureReason | Should -Match 'empty'
        }

        It 'rejects non-JSON payload' {
            $Result = [Robot.MargonemValidator]::Validate('not json', 300)
            $Result.IsValid | Should -BeFalse
            $Result.FailureReason | Should -Match 'not valid JSON'
        }

        It 'rejects JSON missing required fields' {
            $Result = [Robot.MargonemValidator]::Validate('{"user_id":1}', 300)
            $Result.IsValid | Should -BeFalse
            $Result.FailureReason | Should -Match 'missing required fields'
        }

        It 'rejects base64 garbage in signatureBase64' {
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $Bad = (@{
                user_id         = 1
                token           = 'x'
                ts              = $Now
                validatedString = "1+x+$Now"
                signatureBase64 = '!!! not base64 !!!'
            } | ConvertTo-Json -Compress)
            $Result = [Robot.MargonemValidator]::Validate($Bad, 300)
            $Result.IsValid | Should -BeFalse
            $Result.FailureReason | Should -Match 'not valid base64'
        }
    }

    Context 'Key unavailable' {
        It 'returns "public key not loaded" when cache is reset' {
            [Robot.MargonemPublicKeyCache]::Reset()
            $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $Json = New-SignedPayload -UserId 1 -Token 'x' -Ts $Now
            # First, re-load the key for the signing helper. We need to reload
            # after Reset to verify the "not loaded" branch.
            $Result = [Robot.MargonemValidator]::Validate($Json, 300)
            $Result.IsValid | Should -BeFalse
            $Result.FailureReason | Should -Match 'public key is not loaded'
            # Reload for any subsequent tests
            [Robot.MargonemPublicKeyCache]::Load($script:PemPath)
        }
    }
}

Describe 'Robot.MargonemPublicKeyCache' {
    BeforeAll {
        if (-not ([System.Management.Automation.PSTypeName]'Robot.MargonemPublicKeyCache').Type) {
            Set-ItResult -Skipped -Because 'Robot.MargonemPublicKeyCache not compiled'
        }
    }

    It 'throws FileNotFoundException for a non-existent path' {
        # PowerShell wraps static-method exceptions in MethodInvocationException;
        # walk the InnerException chain to assert the underlying type.
        try {
            [Robot.MargonemPublicKeyCache]::Load('/no/such/path.pem')
            $false | Should -BeTrue -Because 'Load should have thrown'
        } catch {
            $Inner = $_.Exception
            while ($Inner.InnerException) { $Inner = $Inner.InnerException }
            $Inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }
    }

    It 'throws on garbage content' {
        $Tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($Tmp, 'not a pem')
            { [Robot.MargonemPublicKeyCache]::Load($Tmp) } | Should -Throw
        } finally {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips IsLoaded and LoadedFromPath after Load' {
        $Tmp = [System.IO.Path]::GetTempFileName()
        $Rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            [System.IO.File]::WriteAllText($Tmp, $Rsa.ExportSubjectPublicKeyInfoPem())
            [Robot.MargonemPublicKeyCache]::Load($Tmp)
            [Robot.MargonemPublicKeyCache]::IsLoaded | Should -BeTrue
            [Robot.MargonemPublicKeyCache]::LoadedFromPath | Should -Be $Tmp
        } finally {
            [Robot.MargonemPublicKeyCache]::Reset()
            $Rsa.Dispose()
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
