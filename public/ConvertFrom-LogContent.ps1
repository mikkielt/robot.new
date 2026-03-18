# Thin public wrapper — exposes ConvertFrom-LogContent (defined in private/parse-logcontent.ps1)
# for the API worker runspace which can only call exported Verb-Noun functions.
# The private file is already dot-sourced at module scope by get-sessionlog.ps1,
# so the function body is available; this file just ensures the name appears in
# $ExportedFunctions via the module's Phase 1 Verb-Noun auto-discovery.

if (-not (Get-Command -Name 'ConvertFrom-LogContent' -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot/../private/parse-logcontent.ps1"
}
