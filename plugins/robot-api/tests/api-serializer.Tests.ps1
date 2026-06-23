<#
    .SYNOPSIS
    Pester tests for Robot.ApiSerializer field-reflection behavior.

    .DESCRIPTION
    Exercises ApiSerializer.SerializeToBytes against:
    - Robot.LogParser.LogLine (struct with public fields)
    - Robot.LogParser.LocationSegment (class with public fields)
    - Robot.SessionPU (class with public properties — no-regression coverage)
    - A synthetic Add-Type class declaring BOTH a property and a field with the
      same name (property-precedence on name collision)

    The reflection fallback in ApiSerializer.WriteValue was previously
    properties-only — field-backed C# types fell through to ToString(), causing
    POST /logs/parse to emit "Robot.LogParser+LogLine" strings instead of
    structured objects. After WP-1 the fallback inspects both kinds of public
    member.
#>

BeforeAll {
    . "$PSScriptRoot/PluginTestHelpers.ps1"
    Import-RobotModuleForPlugin

    function script:Get-SerializedJson {
        param($Value)
        $Bytes = [Robot.ApiSerializer]::SerializeToBytes($Value)
        return [System.Text.Encoding]::UTF8.GetString($Bytes)
    }
}

Describe 'ApiSerializer field reflection' {
    Context 'Robot.LogParser.LogLine (struct with public fields)' {
        BeforeAll {
            $Content = @(
                '[13:00] [Lokalny] Solmyr: Cześć.'
                '[13:01] [Lokalny] Ivor: Witam.'
            ) -join "`n"
            $script:ParseResult = [Robot.LogParser]::Parse($Content)
            $script:LineJson    = Get-SerializedJson -Value $script:ParseResult.Lines[0]
            $script:LineObject  = $script:LineJson | ConvertFrom-Json
        }

        It 'does not stringify the struct as a type name' {
            $script:LineJson | Should -Not -BeLike '*Robot.LogParser*LogLine*'
        }

        It 'emits all six public fields as JSON properties' {
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Index'
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Time'
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Channel'
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Speaker'
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Text'
            $script:LineObject.PSObject.Properties.Name | Should -Contain 'Segment'
        }

        It 'preserves field values through the round-trip' {
            $script:LineObject.Index   | Should -Be 0
            $script:LineObject.Time    | Should -Be '13:00'
            $script:LineObject.Channel | Should -Be 'Lokalny'
            $script:LineObject.Speaker | Should -Be 'Solmyr'
            $script:LineObject.Text    | Should -Be 'Cześć.'
        }
    }

    Context 'Robot.LogParser.LocationSegment (class with public fields)' {
        BeforeAll {
            # Prose layout puts the header line in LocationSegments
            $Content = @('Domostwo', '', 'Narrator: Tekst.') -join "`n"
            $script:ProseResult  = [Robot.LogParser]::Parse($Content)
            $script:SegmentJson  = Get-SerializedJson -Value $script:ProseResult.LocationSegments[0]
            $script:SegmentObject = $script:SegmentJson | ConvertFrom-Json
        }

        It 'does not stringify the class as a type name' {
            $script:SegmentJson | Should -Not -BeLike '*Robot.LogParser*LocationSegment*'
        }

        It 'emits all six public fields as JSON properties' {
            foreach ($Name in @('Index', 'Raw', 'StartLine', 'EndLine', 'Resolved', 'Stage')) {
                $script:SegmentObject.PSObject.Properties.Name | Should -Contain $Name
            }
        }

        It 'preserves Raw and structural fields' {
            $script:SegmentObject.Raw       | Should -Be 'Domostwo'
            $script:SegmentObject.StartLine | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Property-backed type (Robot.SessionPU) — no regression' {
        BeforeAll {
            $Pu = [Robot.SessionPU]::new()
            $Pu.Character = 'Anward'
            $Pu.Value     = 2
            $script:PuJson    = Get-SerializedJson -Value $Pu
            $script:PuObject  = $script:PuJson | ConvertFrom-Json
        }

        It 'serializes property-backed types as JSON objects' {
            $script:PuJson | Should -Not -BeLike '*Robot.SessionPU*'
        }

        It 'emits the Character property' {
            $script:PuObject.Character | Should -Be 'Anward'
        }

        It 'emits the Value property' {
            $script:PuObject.Value | Should -Be 2
        }
    }

    Context 'Property-and-field name collision (property precedence)' {
        BeforeAll {
            # Compile a tiny C# type with a property "Marker" returning "FROM_PROPERTY"
            # and a public field "Marker" set to "FROM_FIELD". Property MUST win.
            if (-not ([System.Management.Automation.PSTypeName]'Robot.PropertyFieldCollisionType').Type) {
                Add-Type -TypeDefinition @'
namespace Robot {
    public class PropertyFieldCollisionType {
        public string Marker { get { return "FROM_PROPERTY"; } }
    }
}
'@ -Language CSharp
            }
            $script:Sample = [Robot.PropertyFieldCollisionType]::new()
            $script:CollisionJson   = Get-SerializedJson -Value $script:Sample
            $script:CollisionObject = $script:CollisionJson | ConvertFrom-Json
        }

        It 'emits the property value, not the field value' {
            $script:CollisionObject.Marker | Should -Be 'FROM_PROPERTY'
        }

        It 'does not emit the key twice' {
            ($script:CollisionJson | Select-String -Pattern '"Marker"' -AllMatches).Matches.Count | Should -Be 1
        }
    }
}
