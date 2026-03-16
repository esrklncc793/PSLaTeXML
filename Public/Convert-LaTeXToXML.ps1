# Public/Convert-LaTeXToXML.ps1
# Converts a LaTeX document to LaTeXML-flavoured XML.

function Convert-LaTeXToXML {
    <#
    .SYNOPSIS
        Converts a LaTeX document to LaTeXML-flavoured XML.

    .DESCRIPTION
        Parses a LaTeX source file (or inline string) and produces an XML
        representation that follows the LaTeXML namespace
        (http://dlmf.nist.gov/LaTeXML).  The pipeline mirrors the three-stage
        approach used by the original Perl LaTeXML project:
          1. Tokenise  – raw source  → token stream
          2. Parse     – token stream → abstract syntax tree (AST)
          3. Serialise – AST          → XML string

    .PARAMETER Path
        Path to a .tex source file to convert.

    .PARAMETER Source
        LaTeX source supplied directly as a string (mutually exclusive with
        -Path).

    .PARAMETER OutputPath
        Optional path to write the XML output.  If omitted the XML string is
        returned to the pipeline.

    .PARAMETER Indent
        When specified, the output XML is pretty-printed with 2-space
        indentation.

    .EXAMPLE
        Convert-LaTeXToXML -Path paper.tex -OutputPath paper.xml -Indent

    .EXAMPLE
        $xml = '\documentclass{article}\begin{document}Hello\end{document}' |
               Convert-LaTeXToXML

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
        [switch] $Indent
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            $Source = Get-Content -Path $Path -Raw -Encoding UTF8
        }

        Write-Verbose "PSLaTeXML: Tokenising source ($($Source.Length) chars) …"
        $ast = Invoke-LaTeXParse -Source $Source

        Write-Verbose "PSLaTeXML: Serialising AST to XML …"
        $xml = ConvertTo-LaTeXMLXml -Ast $ast -Indent:$Indent

        if ($OutputPath) {
            $xml | Set-Content -Path $OutputPath -Encoding UTF8
            Write-Verbose "PSLaTeXML: Written to $OutputPath"
        } else {
            return $xml
        }
    }
}
