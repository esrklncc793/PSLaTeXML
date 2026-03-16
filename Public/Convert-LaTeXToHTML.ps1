# Public/Convert-LaTeXToHTML.ps1
# Converts a LaTeX document to a self-contained HTML5 page.

function Convert-LaTeXToHTML {
    <#
    .SYNOPSIS
        Converts a LaTeX document to a self-contained HTML5 page.

    .DESCRIPTION
        Parses LaTeX source and generates an HTML5 document with embedded CSS.
        Math content is preserved as LaTeX strings inside <span> elements
        (compatible with MathJax / KaTeX client-side rendering).

    .PARAMETER Path
        Path to a .tex source file to convert.

    .PARAMETER Source
        LaTeX source supplied directly as a string (mutually exclusive with
        -Path).

    .PARAMETER OutputPath
        Optional path to write the HTML output.  If omitted the HTML string is
        returned to the pipeline.

    .PARAMETER CssClass
        CSS class applied to the <body> element (default: latexml).

    .EXAMPLE
        Convert-LaTeXToHTML -Path paper.tex -OutputPath paper.html

    .EXAMPLE
        $html = '\documentclass{article}\begin{document}Hello\end{document}' |
                Convert-LaTeXToHTML

    .OUTPUTS
        System.String  (when -OutputPath is not specified)
    #>
    [CmdletBinding(DefaultParameterSetName = 'File')]
    [OutputType([string])]
    param(
        [Parameter(ParameterSetName = 'File',   Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string] $Path,

        [Parameter(ParameterSetName = 'String', Mandatory, ValueFromPipeline)]
        [string] $Source,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [string] $CssClass = 'latexml'
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            $Source = Get-Content -Path $Path -Raw -Encoding UTF8
        }

        Write-Verbose "PSLaTeXML: Tokenising source ($($Source.Length) chars) …"
        $ast = Invoke-LaTeXParse -Source $Source

        Write-Verbose "PSLaTeXML: Rendering AST to HTML …"
        $html = ConvertTo-LaTeXMLHtml -Ast $ast -CssClass $CssClass

        if ($OutputPath) {
            $html | Set-Content -Path $OutputPath -Encoding UTF8
            Write-Verbose "PSLaTeXML: Written to $OutputPath"
        } else {
            return $html
        }
    }
}
