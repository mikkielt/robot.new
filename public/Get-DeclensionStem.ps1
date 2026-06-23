# Thin public wrapper — exposes Get-DeclensionStem (defined in
# public/resolve/resolve-name.ps1) for the API worker runspace which can only
# call exported Verb-Noun functions. The private definition is already loaded
# at module scope by resolve-name.ps1; this file just ensures the name appears
# in $ExportedFunctions via the module's Phase 1 Verb-Noun auto-discovery.

if (-not (Get-Command -Name 'Get-DeclensionStem' -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot/resolve/resolve-name.ps1"
}
