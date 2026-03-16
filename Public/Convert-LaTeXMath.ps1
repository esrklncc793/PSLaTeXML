# Public/Convert-LaTeXMath.ps1
# Converts a standalone LaTeX math expression to various output formats.

function Convert-LaTeXMath {
    <#
    .SYNOPSIS
        Converts a LaTeX math expression to a structured representation.

    .DESCRIPTION
        Wraps the math expression in a minimal LaTeX document, parses it, and
        returns the math content as one of several output formats:

          Text   – the original LaTeX string (default)
          XML    – LaTeXML XML fragment
          HTML   – HTML <span> element
          MathML – a basic Presentation MathML fragment

    .PARAMETER Expression
        The LaTeX math expression, e.g.  '\frac{1}{2}'  or  'E = mc^2'.
        Display-math delimiters (\[…\] or $$…$$) are optional; if absent the
        expression is treated as display math.

    .PARAMETER DisplayMode
        When set, the expression is rendered in display mode (centred block).
        Default is display mode; use -DisplayMode:$false for inline.

    .PARAMETER Format
        Output format: Text | XML | HTML | MathML.  Default: Text.

    .EXAMPLE
        Convert-LaTeXMath -Expression '\frac{\pi}{2}'

    .EXAMPLE
        Convert-LaTeXMath '\sum_{n=1}^{\infty} \frac{1}{n^2}' -Format HTML

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string] $Expression,

        [Parameter()]
        [bool] $DisplayMode = $true,

        [Parameter()]
        [ValidateSet('Text', 'XML', 'HTML', 'MathML')]
        [string] $Format = 'Text'
    )

    process {
        # Strip surrounding $…$ or \[…\] if present
        $inner = $Expression.Trim()
        $inner = $inner -replace '^\$\$(.*)\$\$$', '$1'
        $inner = $inner -replace '^\$(.*)\$$',   '$1'
        $inner = $inner -replace '^\\\[(.*)\\\]$', '$1'
        $inner = $inner -replace '^\\\((.*)\\\)$', '$1'
        $inner = $inner.Trim()

        switch ($Format) {
            'Text' {
                return $inner
            }

            'XML' {
                $mode = if ($DisplayMode) { 'display' } else { 'inline' }
                $enc  = [System.Web.HttpUtility]::HtmlEncode($inner)
                return @"
<Math xmlns="http://dlmf.nist.gov/LaTeXML" mode="$mode" tex="$enc">$enc</Math>
"@
            }

            'HTML' {
                $cls = if ($DisplayMode) { 'math-display' } else { 'math-inline' }
                $enc = [System.Web.HttpUtility]::HtmlEncode($inner)
                return "<span class=`"$cls`">$enc</span>"
            }

            'MathML' {
                return ConvertTo-PresentationMathML -Expression $inner -Display:$DisplayMode
            }
        }
    }
}

# ── Basic Presentation MathML generator ──────────────────────────────────────
# Produces a minimal <math> element for simple expressions.
# Full MathML generation would require a complete math parser; this covers
# the most common patterns.

function ConvertTo-PresentationMathML {
    [CmdletBinding()]
    param(
        [string] $Expression,
        [switch] $Display
    )

    $displayAttr = if ($Display) { 'block' } else { 'inline' }
    $enc = [System.Web.HttpUtility]::HtmlEncode($Expression)

    # Convert common LaTeX math constructs to MathML tokens
    $mml = Convert-MathToMML $Expression

    return "<math xmlns=`"http://www.w3.org/1998/Math/MathML`" display=`"$displayAttr`">`n  $mml`n</math>"
}

function Convert-MathToMML {
    param([string]$Expr)

    # Greek letters
    $greek = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    # Lowercase Greek
    $null = $greek.Add('\alpha', '&#x03B1;');   $null = $greek.Add('\beta',     '&#x03B2;')
    $null = $greek.Add('\gamma', '&#x03B3;');   $null = $greek.Add('\delta',    '&#x03B4;')
    $null = $greek.Add('\epsilon', '&#x03F5;'); $null = $greek.Add('\varepsilon','&#x03B5;')
    $null = $greek.Add('\zeta',  '&#x03B6;');   $null = $greek.Add('\eta',      '&#x03B7;')
    $null = $greek.Add('\theta', '&#x03B8;');   $null = $greek.Add('\vartheta', '&#x03D1;')
    $null = $greek.Add('\iota',  '&#x03B9;');   $null = $greek.Add('\kappa',    '&#x03BA;')
    $null = $greek.Add('\lambda','&#x03BB;');   $null = $greek.Add('\mu',       '&#x03BC;')
    $null = $greek.Add('\nu',    '&#x03BD;');   $null = $greek.Add('\xi',       '&#x03BE;')
    $null = $greek.Add('\pi',    '&#x03C0;');   $null = $greek.Add('\varpi',    '&#x03D6;')
    $null = $greek.Add('\rho',   '&#x03C1;');   $null = $greek.Add('\varrho',   '&#x03F1;')
    $null = $greek.Add('\sigma', '&#x03C3;');   $null = $greek.Add('\varsigma', '&#x03C2;')
    $null = $greek.Add('\tau',   '&#x03C4;');   $null = $greek.Add('\upsilon',  '&#x03C5;')
    $null = $greek.Add('\phi',   '&#x03D5;');   $null = $greek.Add('\varphi',   '&#x03C6;')
    $null = $greek.Add('\chi',   '&#x03C7;');   $null = $greek.Add('\psi',      '&#x03C8;')
    $null = $greek.Add('\omega', '&#x03C9;')
    # Uppercase Greek (commands that exist in LaTeX)
    $null = $greek.Add('\Gamma',   '&#x0393;'); $null = $greek.Add('\Delta',   '&#x0394;')
    $null = $greek.Add('\Theta',   '&#x0398;'); $null = $greek.Add('\Lambda',  '&#x039B;')
    $null = $greek.Add('\Xi',      '&#x039E;'); $null = $greek.Add('\Pi',      '&#x03A0;')
    $null = $greek.Add('\Sigma',   '&#x03A3;'); $null = $greek.Add('\Upsilon', '&#x03A5;')
    $null = $greek.Add('\Phi',     '&#x03A6;'); $null = $greek.Add('\Psi',     '&#x03A8;')
    $null = $greek.Add('\Omega',   '&#x03A9;')

    # Operators / relations
    $ops = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $null = $ops.Add('\cdot',        '&#x22C5;'); $null = $ops.Add('\times',       '&#x00D7;')
    $null = $ops.Add('\div',         '&#x00F7;'); $null = $ops.Add('\pm',          '&#x00B1;')
    $null = $ops.Add('\mp',          '&#x2213;'); $null = $ops.Add('\leq',         '&#x2264;')
    $null = $ops.Add('\geq',         '&#x2265;'); $null = $ops.Add('\neq',         '&#x2260;')
    $null = $ops.Add('\approx',      '&#x2248;'); $null = $ops.Add('\equiv',       '&#x2261;')
    $null = $ops.Add('\sim',         '&#x223C;'); $null = $ops.Add('\simeq',       '&#x2243;')
    $null = $ops.Add('\subset',      '&#x2282;'); $null = $ops.Add('\supset',      '&#x2283;')
    $null = $ops.Add('\subseteq',    '&#x2286;'); $null = $ops.Add('\supseteq',    '&#x2287;')
    $null = $ops.Add('\in',          '&#x2208;'); $null = $ops.Add('\notin',       '&#x2209;')
    $null = $ops.Add('\cup',         '&#x222A;'); $null = $ops.Add('\cap',         '&#x2229;')
    $null = $ops.Add('\forall',      '&#x2200;'); $null = $ops.Add('\exists',      '&#x2203;')
    $null = $ops.Add('\nabla',       '&#x2207;'); $null = $ops.Add('\partial',     '&#x2202;')
    $null = $ops.Add('\infty',       '&#x221E;'); $null = $ops.Add('\emptyset',    '&#x2205;')
    $null = $ops.Add('\ldots',       '&#x2026;'); $null = $ops.Add('\cdots',       '&#x22EF;')
    $null = $ops.Add('\vdots',       '&#x22EE;'); $null = $ops.Add('\ddots',       '&#x22F1;')
    $null = $ops.Add('\to',          '&#x2192;'); $null = $ops.Add('\leftarrow',   '&#x2190;')
    $null = $ops.Add('\rightarrow',  '&#x2192;'); $null = $ops.Add('\leftrightarrow','&#x2194;')
    $null = $ops.Add('\Rightarrow',  '&#x21D2;'); $null = $ops.Add('\Leftarrow',   '&#x21D0;')
    $null = $ops.Add('\Leftrightarrow','&#x21D4;')
    $null = $ops.Add('\sum',         '&#x2211;'); $null = $ops.Add('\prod',        '&#x220F;')
    $null = $ops.Add('\int',         '&#x222B;'); $null = $ops.Add('\oint',        '&#x222E;')
    $null = $ops.Add('\sqrt',        '&#x221A;')

    $result = $Expr

    # Replace \frac{a}{b} → <mfrac><mrow>a</mrow><mrow>b</mrow></mfrac>
    $fracPattern = [regex]'\\frac\{([^{}]*)\}\{([^{}]*)\}'
    while ($result -match '\\frac\{') {
        $result = $fracPattern.Replace($result, {
            param($m)
            $num = Convert-MathToMML $m.Groups[1].Value
            $den = Convert-MathToMML $m.Groups[2].Value
            "<mfrac><mrow>$num</mrow><mrow>$den</mrow></mfrac>"
        }, 1)
    }

    # Replace \sqrt{a} → <msqrt><mrow>a</mrow></msqrt>
    $sqrtPat = [regex]'\\sqrt\{([^{}]*)\}'
    while ($result -match '\\sqrt\{') {
        $result = $sqrtPat.Replace($result, {
            param($m)
            $inner = Convert-MathToMML $m.Groups[1].Value
            "<msqrt><mrow>$inner</mrow></msqrt>"
        }, 1)
    }

    # Replace \sqrt[n]{a} → <mroot><mrow>a</mrow><mn>n</mn></mroot>
    $sqrtNPat = [regex]'\\sqrt\[([^\]]*)\]\{([^{}]*)\}'
    while ($result -match '\\sqrt\[') {
        $result = $sqrtNPat.Replace($result, {
            param($m)
            $idx   = Convert-MathToMML $m.Groups[1].Value
            $inner = Convert-MathToMML $m.Groups[2].Value
            "<mroot><mrow>$inner</mrow><mrow>$idx</mrow></mroot>"
        }, 1)
    }

    # Replace ^{exp} → <msup><mi/><mrow>exp</mrow></msup>  (simple cases)
    # Replace _{sub} similarly
    # These are hard to do perfectly without a full parser; use simple regex for common patterns
    $result = [regex]::Replace($result, '\^{([^{}]*)}', { param($m) "<msup><mrow></mrow><mrow>$(Convert-MathToMML $m.Groups[1].Value)</mrow></msup>" })
    $result = [regex]::Replace($result, '_{([^{}]*)}',  { param($m) "<msub><mrow></mrow><mrow>$(Convert-MathToMML $m.Groups[1].Value)</mrow></msub>" })
    $result = [regex]::Replace($result, '\^([^{])',      { param($m) "<msup><mrow></mrow><mi>$($m.Groups[1].Value)</mi></msup>" })
    $result = [regex]::Replace($result, '_([^{])',       { param($m) "<msub><mrow></mrow><mi>$($m.Groups[1].Value)</mi></msub>" })

    # Greek letters and operators
    foreach ($k in $greek.Keys) {
        $escaped = [regex]::Escape($k)
        $result  = [regex]::Replace($result, "$escaped(?![a-zA-Z])", "<mi>$($greek[$k])</mi>")
    }
    foreach ($k in $ops.Keys) {
        $escaped = [regex]::Escape($k)
        $result  = [regex]::Replace($result, "$escaped(?![a-zA-Z])", "<mo>$($ops[$k])</mo>")
    }

    # Remaining letters → <mi>, digits → <mn>, operators → <mo>
    $result = [regex]::Replace($result, '([a-zA-Z]+)',  { param($m) "<mi>$($m.Value)</mi>" })
    $result = [regex]::Replace($result, '(\d+\.?\d*)', { param($m) "<mn>$($m.Value)</mn>" })
    $result = [regex]::Replace($result, '([+\-=<>])',   { param($m) "<mo>$([System.Web.HttpUtility]::HtmlEncode($m.Value))</mo>" })

    return $result
}
