<#
    .SYNOPSIS
    Pester tests for session-parsehelpers.ps1 (local log path support).

    .DESCRIPTION
    Tests for Get-SessionListMetadata covering .Logs extraction with:
    - Local file paths (res/logs/filename) accepted in @Logi: blocks
    - HTTPS URLs still extracted normally
    - Mixed entries (URLs and local paths) all extracted
    Uses loading pattern B (internal + dot-source).
#>

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    Import-RobotModule

    # Dot-source session-parsehelpers to expose internal functions
    . (Join-Path $script:ModuleRoot 'private' 'session-parsehelpers.ps1')

    # Precompile the regexes used by Get-SessionListMetadata (same as get-session.ps1)
    $script:PURegex  = [regex]::new('^(.+?):\s*([\d,\.]+)')
    $script:UrlRegex = [regex]::new('(https?://\S+)')

    # Helper: Build parent→children index from list items (same structure as get-session.ps1)
    function Build-ChildrenOf {
        param([object[]]$Items)
        $Result = @{}
        foreach ($LI in $Items) {
            if ($null -ne $LI.ParentListItem) {
                $ParentId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($LI.ParentListItem)
                if (-not $Result.ContainsKey($ParentId)) {
                    $Result[$ParentId] = [System.Collections.Generic.List[object]]::new()
                }
                $Result[$ParentId].Add($LI)
            }
        }
        return $Result
    }

    # Helper: Build list items matching the structure from Get-Markdown section parser
    function New-MockListItem {
        param(
            [string]$Text,
            [int]$Indent = 0,
            [object]$Parent = $null
        )
        return [PSCustomObject]@{
            Text           = $Text
            Indent         = $Indent
            ParentListItem = $Parent
        }
    }
}

# ── Get-SessionListMetadata — Logs extraction ────────────────────────────────

Describe 'Get-SessionListMetadata' {
    Context 'local file paths in Logi block' {
        BeforeAll {
            # Simulate: "- Logi:\n    - res/logs/pastebincomrawABC123"
            $LogiParent = New-MockListItem -Text 'Logi:' -Indent 0
            $LogChild   = New-MockListItem -Text 'res/logs/pastebincomrawABC123' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogChild)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts local path as a log entry' {
            $script:Result.Logs.Count | Should -Be 1
            $script:Result.Logs[0] | Should -Be 'res/logs/pastebincomrawABC123'
        }
    }

    Context 'HTTPS URLs in Logi block' {
        BeforeAll {
            $LogiParent = New-MockListItem -Text 'Logi:' -Indent 0
            $LogChild   = New-MockListItem -Text 'https://pastebin.com/raw/XYZ789' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogChild)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts URL as a log entry' {
            $script:Result.Logs.Count | Should -Be 1
            $script:Result.Logs[0] | Should -Be 'https://pastebin.com/raw/XYZ789'
        }
    }

    Context 'mixed entries (URLs and local paths)' {
        BeforeAll {
            $LogiParent = New-MockListItem -Text 'Logi:' -Indent 0
            $LogUrl     = New-MockListItem -Text 'https://pastebin.com/raw/AAA111' -Indent 1 -Parent $LogiParent
            $LogLocal   = New-MockListItem -Text 'res/logs/pastebincomrawBBB222' -Indent 1 -Parent $LogiParent
            $LogUrl2    = New-MockListItem -Text 'https://example.com/log-xyz' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogUrl, $LogLocal, $LogUrl2)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts all three entries' {
            $script:Result.Logs.Count | Should -Be 3
        }

        It 'includes the URL entries' {
            $script:Result.Logs | Should -Contain 'https://pastebin.com/raw/AAA111'
            $script:Result.Logs | Should -Contain 'https://example.com/log-xyz'
        }

        It 'includes the local path entry' {
            $script:Result.Logs | Should -Contain 'res/logs/pastebincomrawBBB222'
        }
    }

    Context 'Gen4 @Logi tag prefix' {
        BeforeAll {
            # Gen4 uses "@Logi:" prefix which is stripped via $MatchText
            $LogiParent = New-MockListItem -Text '@Logi:' -Indent 0
            $LogLocal   = New-MockListItem -Text 'res/logs/pastebincomrawGEN4' -Indent 1 -Parent $LogiParent
            $LogUrl     = New-MockListItem -Text 'https://pastebin.com/raw/GEN4URL' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogLocal, $LogUrl)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts local path from @Logi block' {
            $script:Result.Logs | Should -Contain 'res/logs/pastebincomrawGEN4'
        }

        It 'extracts URL from @Logi block' {
            $script:Result.Logs | Should -Contain 'https://pastebin.com/raw/GEN4URL'
        }
    }

    Context 'no log entries' {
        BeforeAll {
            # Session with PU only, no Logi block
            $PUParent = New-MockListItem -Text 'PU:' -Indent 0
            $PUChild  = New-MockListItem -Text 'Xeron: 0,3' -Indent 1 -Parent $PUParent

            $Items = @($PUParent, $PUChild)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'returns empty Logs collection' {
            $script:Result.Logs.Count | Should -Be 0
        }
    }

    Context 'non-matching child items are ignored' {
        BeforeAll {
            # Text that does not match URL regex and does not start with res/logs/
            $LogiParent = New-MockListItem -Text 'Logi:' -Indent 0
            $LogJunk    = New-MockListItem -Text 'brak logów z tej sesji' -Indent 1 -Parent $LogiParent
            $LogUrl     = New-MockListItem -Text 'https://pastebin.com/raw/VALID01' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogJunk, $LogUrl)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'ignores non-URL non-path entries' {
            $script:Result.Logs.Count | Should -Be 1
            $script:Result.Logs[0] | Should -Be 'https://pastebin.com/raw/VALID01'
        }
    }

    Context 'inline URL in Logi header' {
        BeforeAll {
            # "- Logi: https://example.com/inline-log" (Gen2/Gen3 inline pattern)
            $LogiInline = New-MockListItem -Text 'Logi: https://example.com/inline-log' -Indent 0

            $Items = @($LogiInline)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts inline URL from Logi header' {
            $script:Result.Logs.Count | Should -Be 1
            $script:Result.Logs[0] | Should -Be 'https://example.com/inline-log'
        }
    }

    Context 'multiple local paths only' {
        BeforeAll {
            $LogiParent = New-MockListItem -Text 'Logi:' -Indent 0
            $LogLocal1  = New-MockListItem -Text 'res/logs/pastebincomrawFILE1' -Indent 1 -Parent $LogiParent
            $LogLocal2  = New-MockListItem -Text 'res/logs/pastebincomrawFILE2' -Indent 1 -Parent $LogiParent
            $LogLocal3  = New-MockListItem -Text 'res/logs/examplecomlogABC' -Indent 1 -Parent $LogiParent

            $Items = @($LogiParent, $LogLocal1, $LogLocal2, $LogLocal3)
            $script:Result = Get-SessionListMetadata `
                -SectionLists $Items `
                -PURegex $script:PURegex `
                -UrlRegex $script:UrlRegex `
                -ChildrenOf (Build-ChildrenOf -Items $Items)
        }

        It 'extracts all local paths' {
            $script:Result.Logs.Count | Should -Be 3
        }

        It 'preserves exact path values' {
            $script:Result.Logs[0] | Should -Be 'res/logs/pastebincomrawFILE1'
            $script:Result.Logs[1] | Should -Be 'res/logs/pastebincomrawFILE2'
            $script:Result.Logs[2] | Should -Be 'res/logs/examplecomlogABC'
        }
    }
}

# ── Integration: Get-Session with inline test content ─────────────────────────

Describe 'Get-Session .Logs with local paths (integration)' {
    BeforeAll {
        $script:TempDir = New-TestTempDir

        # Mock Get-RepoRoot in both script and module scope so that
        # module-internal calls (Get-Player default -File param) also resolve
        Mock Get-RepoRoot { return $script:TempDir }
        Mock Get-RepoRoot { return $script:TempDir } -ModuleName Robot

        # Write a minimal Gen3 session file with mixed log entries
        $SessionContent = @(
            '# Sesje'
            ''
            '## Historia'
            ''
            '### 2025-01-10, Sesja Lokalna, Narrator'
            ''
            '- Logi:'
            '    - res/logs/pastebincomrawLOCAL01'
            '    - https://pastebin.com/raw/REMOTE01'
            ''
            'Treść sesji testowej.'
        ) -join "`n"

        Write-TestFile -Path ([System.IO.Path]::Combine($script:TempDir, 'sessions-test.md')) -Content $SessionContent

        # Write a minimal Gracze.md so Get-Player does not fail
        $PlayersContent = @(
            '# Gracze'
            ''
            '## Lista'
            ''
            '### Narrator'
            ''
            '- Nick: Narrator'
        ) -join "`n"

        Write-TestFile -Path ([System.IO.Path]::Combine($script:TempDir, 'Gracze.md')) -Content $PlayersContent
    }

    It 'parses .Logs containing both local paths and URLs' {
        $Sessions = @(Get-Session -Quiet)
        $Sessions.Count | Should -Be 1

        $S = $Sessions[0]
        $S.Logs.Count | Should -Be 2
        $S.Logs | Should -Contain 'res/logs/pastebincomrawLOCAL01'
        $S.Logs | Should -Contain 'https://pastebin.com/raw/REMOTE01'
    }

    AfterAll {
        Remove-TestTempDir
    }
}
