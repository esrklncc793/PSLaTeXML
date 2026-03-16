# PSLaTeXML.psm1
# Main module file – dot-sources all Private and Public scripts.

# ── Load private helpers first ────────────────────────────────────────────────
$privateFiles = Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue
foreach ($f in $privateFiles) {
    . $f.FullName
}

# ── Load public cmdlets ────────────────────────────────────────────────────────
$publicFiles = Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1" -ErrorAction SilentlyContinue
foreach ($f in $publicFiles) {
    . $f.FullName
}

# ── Load System.Web for HtmlEncode ───────────────────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'System.Web.HttpUtility').Type) {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function @(
    'Convert-LaTeXToXML',
    'Convert-LaTeXToHTML',
    'Convert-LaTeXMath',
    'Invoke-LaTeXTokenize',
    'Invoke-LaTeXParse'
)
