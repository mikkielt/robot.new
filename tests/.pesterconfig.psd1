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
        Path       = @('./public/*.ps1', './public/**/*.ps1', './private/*.ps1')
        OutputPath = './tests/coverage.xml'
    }
}
