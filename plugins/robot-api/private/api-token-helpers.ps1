<#
    .SYNOPSIS
    Token store file I/O helpers for the robot-api plugin.

    .DESCRIPTION
    This file contains helpers for reading, writing, and generating API
    tokens persisted in a PowerShell data file (.psd1). The token store
    lives at the path specified by the data manifest's ApiTokensFile key,
    falling back to {RepoRoot}/.robot/res/api-tokens.psd1.

    Token format: each entry is a hashtable with Name, Token (plaintext
    bearer string), Scopes (string array), and CreatedAt (ISO timestamp).
    The .psd1 format is used so Import-PowerShellDataFile can read it
    without deserialization dependencies; Export-ApiTokenStore manually
    serializes via StringBuilder to control whitespace and quoting.

    The rbt_ prefix on generated tokens provides a scannable marker for
    secret detection tools and log scrubbing.

    Helpers:
    - Resolve-TokenFilePath: resolves token file path from data manifest,
      falls back to .robot/res/api-tokens.psd1
    - Import-ApiTokenStore: reads .psd1 via Import-PowerShellDataFile,
      handles single-element array unwrapping (PS gotcha), returns @()
      on missing file or parse failure
    - Export-ApiTokenStore: serializes token array to .psd1 with
      UTF-8 no-BOM encoding; creates parent directory if needed
    - New-CryptoToken: generates a 44-char base62 random string with
      rbt_ prefix (~260 bits entropy from two RNG passes)
    - Sync-ApiTokenStore: loads .psd1 entries into a [Robot.ApiTokenStore]
      C# instance for in-memory bearer-token lookups by the middleware
    - Test-TokenFileGitignored: spawns `git check-ignore -q` to verify
      the token file will not be committed (fail-safe: returns $false
      if git is unavailable)
#>

function Resolve-TokenFilePath {
    <#
        .SYNOPSIS
        Resolves the absolute path to the api-tokens.psd1 store file.
    #>

    [CmdletBinding()] param()

    # Prefer explicit path from data manifest over conventional default
    $ManifestResult = Find-DataManifest
    if ($ManifestResult -and $ManifestResult.Manifest.ApiTokensFile) {
        $RelPath = $ManifestResult.Manifest.ApiTokensFile
        return [System.IO.Path]::Combine($ManifestResult.ManifestDir, $RelPath)
    }

    # Fallback: conventional location when manifest has no ApiTokensFile
    $RepoRoot = Get-RepoRoot
    $Config = Get-AdminConfig
    return [System.IO.Path]::Combine($Config.ResDir, 'api-tokens.psd1')
}

function Import-ApiTokenStore {
    [CmdletBinding()] param(
        [Parameter(HelpMessage = "Path to api-tokens.psd1")]
        [string]$Path
    )

    if (-not $Path) { $Path = Resolve-TokenFilePath }

    if (-not [System.IO.File]::Exists($Path)) {
        return , @()  # comma operator preserves empty array through pipeline
    }

    try {
        $Data = Import-PowerShellDataFile -Path $Path
        if ($Data.Tokens) {
            $Raw = $Data.Tokens
            # PS single-element array unwrapping gotcha: @(hashtable) in .psd1
            # becomes a bare hashtable when Tokens has exactly one entry
            if ($Raw -is [hashtable]) {
                $Raw = @($Raw)
            }
            return , @($Raw)  # comma operator prevents pipeline unwrapping
        }
        return , @()
    } catch {
        Write-RobotWarning "[Import-ApiTokenStore] Failed to parse '$Path': $_"
        return , @()
    }
}

function Export-ApiTokenStore {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Tokens,

        [Parameter(HelpMessage = "Path to api-tokens.psd1")]
        [string]$Path
    )

    if (-not $Path) { $Path = Resolve-TokenFilePath }

    # Ensure parent directory exists
    $Dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($Dir)) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
    }

    # Manual .psd1 serialization — Import-PowerShellDataFile requires exact syntax
    $SB = [System.Text.StringBuilder]::new()
    [void]$SB.AppendLine('@{')
    [void]$SB.AppendLine('    Tokens = @(')

    foreach ($T in $Tokens) {
        [void]$SB.AppendLine('        @{')
        [void]$SB.AppendLine("            Name      = '$($T.Name)'")
        [void]$SB.AppendLine("            Token     = '$($T.Token)'")

        # Inline scopes array on a single line for readability
        $ScopeItems = ($T.Scopes.ForEach({ "'$_'" })) -join ', '
        [void]$SB.AppendLine("            Scopes    = @($ScopeItems)")
        [void]$SB.AppendLine("            CreatedAt = '$($T.CreatedAt)'")
        [void]$SB.AppendLine('        }')
    }

    [void]$SB.AppendLine('    )')
    [void]$SB.AppendLine('}')

    $Encoding = [System.Text.UTF8Encoding]::new($false)  # UTF-8 no BOM
    [System.IO.File]::WriteAllText($Path, $SB.ToString(), $Encoding)
}

function New-CryptoToken {
    <#
        .SYNOPSIS
        Generates a cryptographically random rbt_-prefixed bearer token string.
    #>

    [CmdletBinding()] param()

    # Two-pass RNG: 32 bytes primary + 12 bytes supplemental = 44 base62 chars
    $RNG = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Bytes = [byte[]]::new(32)
    $RNG.GetBytes($Bytes)
    $RNG.Dispose()

    # Base62 alphabet avoids URL-unsafe characters (no +, /, =)
    $Chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $SB = [System.Text.StringBuilder]::new(48)
    foreach ($B in $Bytes) {
        [void]$SB.Append($Chars[[int]$B % 62])
    }

    # Second RNG pass for remaining 12 chars (~260 bits total entropy)
    $Extra = [byte[]]::new(12)
    $RNG2 = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $RNG2.GetBytes($Extra)
    $RNG2.Dispose()
    foreach ($B in $Extra) {
        [void]$SB.Append($Chars[[int]$B % 62])
    }

    return "rbt_$($SB.ToString())"  # rbt_ prefix for secret scanning tools
}

function Sync-ApiTokenStore {
    [CmdletBinding()] param(
        [Parameter(Mandatory)]
        [Robot.ApiTokenStore]$TokenStore,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $Tokens = Import-ApiTokenStore -Path $FilePath

    foreach ($T in $Tokens) {
        $Info = [Robot.ApiTokenInfo]::new()
        $Info.Name = $T.Name
        $Info.Scopes = @($T.Scopes)
        $Info.CreatedAt = $T.CreatedAt
        [void]$TokenStore.Add($T.Token, $Info)
    }
}

function Test-TokenFileGitignored {
    <#
        .SYNOPSIS
        Checks whether the token store file is covered by .gitignore rules.
    #>

    [CmdletBinding()] param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        # Use git check-ignore -q: exit 0 = ignored, exit 1 = not ignored
        $PSI = [System.Diagnostics.ProcessStartInfo]::new()
        $PSI.FileName = 'git'
        $PSI.Arguments = "check-ignore -q `"$Path`""
        $PSI.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Path)
        $PSI.RedirectStandardOutput = $true
        $PSI.RedirectStandardError  = $true
        $PSI.UseShellExecute = $false
        $PSI.CreateNoWindow = $true

        $Proc = [System.Diagnostics.Process]::Start($PSI)
        $Proc.WaitForExit(5000)  # 5s timeout guards against hung git processes

        return ($Proc.ExitCode -eq 0)
    } catch {
        # Fail-safe: if git is unavailable, report not-ignored so callers can warn
        return $false
    }
}
