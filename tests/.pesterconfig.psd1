@{
    Run = @{
        Path = './tests'
        Exit = $true
    }
    Output = @{
        Verbosity = 'Detailed'
    }
    TestResult = @{
        Enabled    = $true
        OutputPath = './tests/test-results.xml'
        OutputFormat = 'NUnitXml'
    }
    CodeCoverage = @{
        Enabled    = $false
        Path       = @('./*.ps1')
        OutputPath = './tests/coverage.xml'
    }
}
