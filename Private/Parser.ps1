# Private/Parser.ps1
# Recursive-descent LaTeX parser.
# Consumes the token stream produced by Tokenizer.ps1 and builds an AST
# represented as PSCustomObject trees.
#
# AST node shapes (Type field distinguishes them):
#   Document   – { Type Class Title Author Date Packages Children }
#   Section    – { Type Level Starred Title Id Children }
#   Paragraph  – { Type Id Children }
#   Text       – { Type Content }
#   Format     – { Type Style Children }   Style: bold|italic|monospace|smallcaps|underline|roman|sans
#   Math       – { Type Display Content }  Display: $false=inline, $true=display
#   Equation   – { Type Starred Content }
#   Align      – { Type Starred Content }
#   Gather     – { Type Starred Content }
#   List       – { Type Style Children }   Style: bullet|ordered|description
#   Item       – { Type Label Children }
#   Tabular    – { Type Spec Rows }        Rows: PSCustomObject[][] of Cell nodes
#   Cell       – { Type Span Children }
#   Figure     – { Type Children }
#   Table      – { Type Float Children }
#   Caption    – { Type Children }
#   Image      – { Type File Options }
#   Verbatim   – { Type Content }
#   CodeBlock  – { Type Content Language }
#   Quote      – { Type Children }
#   Center     – { Type Children }
#   Abstract   – { Type Children }
#   Theorem    – { Type EnvName Children }
#   Label      – { Type Id }
#   Ref        – { Type Id Eq }
#   Cite       – { Type Keys }
#   Footnote   – { Type Children }
#   URL        – { Type Href Children }
#   LineBreak  – { Type }
#   ParBreak   – { Type }
#   Maketitle  – { Type }
#   TableOfContents – { Type }
#   Environment – { Type Name Children }

class LaTeXParser {
    [System.Collections.Generic.List[PSCustomObject]] $Tokens
    [int]    $Pos
    [string] $DocClass
    [System.Collections.Generic.List[string]] $Packages
    [hashtable] $UserCmds   # \newcommand definitions
    [hashtable] $UserEnvs   # \newenvironment definitions
    [int] $SectionCounter
    [int] $ParaCounter

    LaTeXParser([System.Collections.Generic.List[PSCustomObject]]$tokens) {
        $this.Tokens         = $tokens
        $this.Pos            = 0
        $this.DocClass       = 'article'
        $this.Packages       = [System.Collections.Generic.List[string]]::new()
        $this.UserCmds       = @{}
        $this.UserEnvs       = @{}
        $this.SectionCounter = 0
        $this.ParaCounter    = 0
    }

    # ── Token access ──────────────────────────────────────────────────────────

    [bool] HasMore() { return $this.Pos -lt $this.Tokens.Count }

    [PSCustomObject] Peek() {
        if ($this.HasMore()) { return $this.Tokens[$this.Pos] }
        return [PSCustomObject]@{ Type = 'EOF'; Value = '' }
    }

    [PSCustomObject] Consume() {
        $t = $this.Tokens[$this.Pos]
        $this.Pos++
        return $t
    }

    [void] SkipSpaces() {
        while ($this.HasMore() -and $this.Peek().Type -in @('Space', 'ParBreak')) {
            $null = $this.Consume()
        }
    }

    [void] SkipHSpace() {
        while ($this.HasMore() -and $this.Peek().Type -eq 'Space') {
            $null = $this.Consume()
        }
    }

    # ── Argument readers ──────────────────────────────────────────────────────

    # Read a mandatory braced argument { ... } and return its parsed children.
    [PSCustomObject[]] ReadArg() {
        $this.SkipHSpace()
        if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
            $null = $this.Consume()   # {
            $kids = $this.ParseContent('EndGroup')
            if ($this.HasMore() -and $this.Peek().Type -eq 'EndGroup') { $null = $this.Consume() }
            return $kids
        }
        # single-token arg
        if ($this.HasMore()) {
            $t = $this.Consume()
            return @([PSCustomObject]@{ Type = 'Text'; Content = $t.Value })
        }
        return @()
    }

    # Read a mandatory braced argument and return it as plain text.
    [string] ReadArgText() {
        $this.SkipHSpace()
        if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
            $null = $this.Consume()
            $sb = [System.Text.StringBuilder]::new()
            $depth = 1
            while ($this.HasMore()) {
                $t = $this.Peek()
                if ($t.Type -eq 'BeginGroup') { $depth++; $null = $this.Consume(); $null = $sb.Append('{') }
                elseif ($t.Type -eq 'EndGroup') {
                    $depth--
                    if ($depth -eq 0) { $null = $this.Consume(); break }
                    $null = $this.Consume(); $null = $sb.Append('}')
                }
                elseif ($t.Type -eq 'Char')    { $null = $this.Consume(); $null = $sb.Append($t.Value) }
                elseif ($t.Type -eq 'Space')   { $null = $this.Consume(); $null = $sb.Append(' ') }
                elseif ($t.Type -eq 'CtrlSeq') { $null = $this.Consume(); $null = $sb.Append($t.Value) }
                elseif ($t.Type -eq 'CtrlSym') {
                    $null = $this.Consume()
                    $map = @{ '$'='$';'%'='%';'&'='&';'#'='#';'_'='_';'{'='{';'}'='}';' '=' ';'\'='\';'*'='*' }
                    if ($map.ContainsKey($t.Value)) { $null = $sb.Append($map[$t.Value]) }
                    else { $null = $sb.Append($t.Value) }
                }
                else { $null = $this.Consume() }
            }
            return $sb.ToString()
        }
        elseif ($this.HasMore() -and $this.Peek().Type -eq 'Char') {
            return [string]$this.Consume().Value
        }
        return ''
    }

    # Read an optional argument [ ... ] and return its parsed children, or $null.
    [PSCustomObject[]] ReadOptArg() {
        $this.SkipHSpace()
        if ($this.HasMore() -and $this.Peek().Type -eq 'Char' -and $this.Peek().Value -eq '[') {
            $null = $this.Consume()   # [
            $raw = [System.Collections.Generic.List[PSCustomObject]]::new()
            $depth = 0
            while ($this.HasMore()) {
                $t = $this.Peek()
                if ($t.Type -eq 'Char' -and $t.Value -eq ']' -and $depth -eq 0) { $null = $this.Consume(); break }
                if ($t.Type -eq 'BeginGroup') { $depth++ }
                if ($t.Type -eq 'EndGroup')   { $depth-- }
                $raw.Add($this.Consume())
            }
            # re-parse the collected tokens as inline content
            $saved = $this.Tokens; $savedPos = $this.Pos
            $this.Tokens = $raw; $this.Pos = 0
            $kids = $this.ParseContent('EOF')
            $this.Tokens = $saved; $this.Pos = $savedPos
            return $kids
        }
        return $null
    }

    # Read an optional argument and return as plain text, or ''.
    [string] ReadOptArgText() {
        $kids = $this.ReadOptArg()
        if ($null -eq $kids) { return '' }
        return ($kids | Where-Object { $_.Type -eq 'Text' } | ForEach-Object { $_.Content }) -join ''
    }

    # ── Math content reader ───────────────────────────────────────────────────

    # Collect tokens as raw LaTeX text until endType/endValue is hit.
    [string] ReadMathUntil([string]$endType, [string]$endValue) {
        $sb    = [System.Text.StringBuilder]::new()
        $depth = 0
        while ($this.HasMore()) {
            $t = $this.Peek()
            if ($t.Type -eq $endType -and ($endValue -eq '' -or $t.Value -eq $endValue) -and $depth -eq 0) {
                $null = $this.Consume(); break
            }
            switch ($t.Type) {
                'BeginGroup' { $depth++; $null = $this.Consume(); $null = $sb.Append('{') }
                'EndGroup'   {
                    $depth--
                    if ($depth -lt 0) { break }
                    $null = $this.Consume(); $null = $sb.Append('}')
                }
                'CtrlSeq'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value + ' ') }
                'CtrlSym'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value) }
                'Char'       { $null = $this.Consume(); $null = $sb.Append($t.Value) }
                'Space'      { $null = $this.Consume(); $null = $sb.Append(' ') }
                'Super'      { $null = $this.Consume(); $null = $sb.Append('^') }
                'Sub'        { $null = $this.Consume(); $null = $sb.Append('_') }
                'Align'      { $null = $this.Consume(); $null = $sb.Append('&') }
                'Tilde'      { $null = $this.Consume(); $null = $sb.Append('~') }
                'InlineMath' { $null = $this.Consume(); $null = $sb.Append('$') }
                'ParBreak'   { $null = $this.Consume(); $null = $sb.Append(' ') }
                default      { $null = $this.Consume() }
            }
        }
        return $sb.ToString().Trim()
    }

    # Read math environment body until \end{envName}.
    [string] ReadMathEnvBody([string]$envName) {
        $sb = [System.Text.StringBuilder]::new()
        while ($this.HasMore()) {
            $t = $this.Peek()
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { break }
                    $sb.Append('\end{' + $name + '}') | Out-Null
                    continue
                }
                $this.Pos = $savedPos
            }
            switch ($t.Type) {
                'CtrlSeq'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value + ' ') }
                'CtrlSym'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value) }
                'BeginGroup' { $null = $this.Consume(); $null = $sb.Append('{') }
                'EndGroup'   { $null = $this.Consume(); $null = $sb.Append('}') }
                'Align'      { $null = $this.Consume(); $null = $sb.Append('&') }
                'Super'      { $null = $this.Consume(); $null = $sb.Append('^') }
                'Sub'        { $null = $this.Consume(); $null = $sb.Append('_') }
                'Space'      { $null = $this.Consume(); $null = $sb.Append(' ') }
                'ParBreak'   { $null = $this.Consume(); $null = $sb.Append("`n") }
                'Char'       { $null = $this.Consume(); $null = $sb.Append($t.Value) }
                default      { $null = $this.Consume() }
            }
        }
        return $sb.ToString().Trim()
    }

    # ── Helper: collect text tokens until EndGroup ────────────────────────────
    [string] CollectToEndGroup() {
        $sb = [System.Text.StringBuilder]::new()
        while ($this.HasMore() -and $this.Peek().Type -ne 'EndGroup') {
            $t = $this.Consume()
            if ($t.Type -eq 'Char')    { $null = $sb.Append($t.Value) }
            elseif ($t.Type -eq 'CtrlSeq') { $null = $sb.Append($t.Value) }
            elseif ($t.Type -eq 'CtrlSym' -and $t.Value -eq '*') { $null = $sb.Append('*') }
        }
        if ($this.HasMore()) { $null = $this.Consume() }   # consume }
        return $sb.ToString()
    }

    # ── Main entry point ──────────────────────────────────────────────────────

    [PSCustomObject] Parse() {
        $doc = [PSCustomObject]@{
            Type     = 'Document'
            Class    = 'article'
            Title    = ''
            Author   = ''
            Date     = ''
            Packages = [System.Collections.Generic.List[string]]::new()
            Children = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        $this.ParsePreamble($doc)

        # Advance past \begin{document}
        while ($this.HasMore()) {
            if ($this.Peek().Type -eq 'CtrlSeq' -and $this.Peek().Value -eq 'begin') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq 'document') { break }
                }
                $this.Pos = $savedPos
            }
            $null = $this.Consume()
        }

        $body = $this.ParseEnvBody('document')
        foreach ($n in $body) { if ($n) { $doc.Children.Add($n) } }

        return $doc
    }

    # ── Preamble ──────────────────────────────────────────────────────────────

    [void] ParsePreamble([PSCustomObject]$doc) {
        while ($this.HasMore()) {
            $t = $this.Peek()

            # Stop when we reach \begin{document}
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'begin') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq 'document') { $this.Pos = $savedPos; return }
                }
                $this.Pos = $savedPos
            }

            if ($t.Type -ne 'CtrlSeq') { $null = $this.Consume(); continue }

            switch ($t.Value) {
                'documentclass' {
                    $null = $this.Consume()
                    $null = $this.ReadOptArg()
                    $doc.Class = $this.ReadArgText()
                }
                'usepackage' {
                    $null = $this.Consume()
                    $null = $this.ReadOptArg()
                    $pkgs = $this.ReadArgText()
                    foreach ($p in ($pkgs -split ',')) {
                        $p = $p.Trim()
                        if ($p) { $doc.Packages.Add($p) }
                    }
                }
                'title'  { $null = $this.Consume(); $doc.Title  = $this.ReadArgText() }
                'author' { $null = $this.Consume(); $doc.Author = $this.ReadArgText() }
                'date'   { $null = $this.Consume(); $doc.Date   = $this.ReadArgText() }
                'newcommand'  { $null = $this.Consume(); $this.ParseNewCommand() }
                'renewcommand'{ $null = $this.Consume(); $this.ParseNewCommand() }
                'providecommand'{ $null = $this.Consume(); $this.ParseNewCommand() }
                'newenvironment'  { $null = $this.Consume(); $this.ParseNewEnvironment() }
                'renewenvironment'{ $null = $this.Consume(); $this.ParseNewEnvironment() }
                default        { $null = $this.Consume() }
            }
        }
    }

    # ── User-defined command/environment registration ─────────────────────────

    [void] ParseNewCommand() {
        $this.SkipHSpace()
        $name = ''
        if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
            $null = $this.Consume()
            if ($this.HasMore() -and $this.Peek().Type -eq 'CtrlSeq') { $name = $this.Consume().Value }
            if ($this.HasMore() -and $this.Peek().Type -eq 'EndGroup') { $null = $this.Consume() }
        } elseif ($this.HasMore() -and $this.Peek().Type -eq 'CtrlSeq') {
            $name = $this.Consume().Value
        }

        $nArgs  = 0
        $optTxt = $this.ReadOptArgText()
        if ($optTxt -match '^\d+$') { $nArgs = [int]$optTxt }
        $null = $this.ReadOptArg()   # optional default for #1

        # Collect definition body
        $body = [System.Collections.Generic.List[PSCustomObject]]::new()
        if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
            $null = $this.Consume()
            $depth = 1
            while ($this.HasMore()) {
                $t = $this.Peek()
                if ($t.Type -eq 'BeginGroup') { $depth++; $body.Add($this.Consume()) }
                elseif ($t.Type -eq 'EndGroup') {
                    $depth--
                    if ($depth -eq 0) { $null = $this.Consume(); break }
                    $body.Add($this.Consume())
                } else { $body.Add($this.Consume()) }
            }
        }
        if ($name) {
            $this.UserCmds[$name] = @{ ArgCount = $nArgs; Body = $body }
        }
    }

    [void] ParseNewEnvironment() {
        $name  = $this.ReadArgText()
        $nArgs = 0
        $optTxt = $this.ReadOptArgText()
        if ($optTxt -match '^\d+$') { $nArgs = [int]$optTxt }
        $null  = $this.ReadOptArg()   # optional default

        [System.Collections.Generic.List[PSCustomObject]] $beginBody = $this.CollectRawGroup()
        [System.Collections.Generic.List[PSCustomObject]] $endBody   = $this.CollectRawGroup()

        if ($name) {
            $this.UserEnvs[$name] = @{ ArgCount = $nArgs; Begin = $beginBody; End = $endBody }
        }
    }

    [System.Collections.Generic.List[PSCustomObject]] CollectRawGroup() {
        $result = [System.Collections.Generic.List[PSCustomObject]]::new()
        $this.SkipHSpace()
        if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
            $null = $this.Consume()
            $depth = 1
            while ($this.HasMore()) {
                $t = $this.Peek()
                if ($t.Type -eq 'BeginGroup') { $depth++; $result.Add($this.Consume()) }
                elseif ($t.Type -eq 'EndGroup') {
                    $depth--
                    if ($depth -eq 0) { $null = $this.Consume(); break }
                    $result.Add($this.Consume())
                } else { $result.Add($this.Consume()) }
            }
        }
        return $result
    }

    # ── Environment body ──────────────────────────────────────────────────────

    # Parse the body of an environment until \end{envName}.
    [PSCustomObject[]] ParseEnvBody([string]$envName) {
        $nodes = [System.Collections.Generic.List[PSCustomObject]]::new()

        while ($this.HasMore()) {
            # Check for \end{envName}
            if ($this.Peek().Type -eq 'CtrlSeq' -and $this.Peek().Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { break }
                    $this.Pos = $savedPos
                } else { $this.Pos = $savedPos }
            }

            $n = $this.ParseBodyElement()
            if ($n) { $nodes.Add($n) }
        }

        return $nodes.ToArray()
    }

    # Parse a single body-level element.
    [PSCustomObject] ParseBodyElement() {
        $t = $this.Peek()

        if ($t.Type -in @('Space', 'ParBreak')) { $null = $this.Consume(); return $null }

        if ($t.Type -eq 'CtrlSeq') {
            if ($t.Value -in @('part','chapter','section','subsection','subsubsection','paragraph','subparagraph')) {
                return $this.ParseSection()
            }
            if ($t.Value -eq 'maketitle') {
                $null = $this.Consume()
                return [PSCustomObject]@{ Type = 'Maketitle' }
            }
            if ($t.Value -eq 'tableofcontents') {
                $null = $this.Consume()
                return [PSCustomObject]@{ Type = 'TableOfContents' }
            }
            if ($t.Value -eq 'begin') {
                $null = $this.Consume()
                $this.SkipHSpace()
                $null = $this.Consume()   # consume {
                $envName = $this.CollectToEndGroup()
                return $this.ParseEnvironment($envName)
            }
        }

        return $this.ParseParagraph()
    }

    # ── Section ───────────────────────────────────────────────────────────────

    [PSCustomObject] ParseSection() {
        $name = $this.Consume().Value
        $starred = $false
        if ($this.HasMore() -and $this.Peek().Type -eq 'CtrlSym' -and $this.Peek().Value -eq '*') {
            $null = $this.Consume(); $starred = $true
        }
        $level = switch ($name) {
            'part'          { -1 }; 'chapter'       { 0 }; 'section'       { 1 }
            'subsection'    { 2  }; 'subsubsection' { 3 }; 'paragraph'     { 4 }
            'subparagraph'  { 5  }; default          { 1 }
        }
        $null  = $this.ReadOptArg()
        $title = $this.ReadArg()
        $this.SectionCounter++

        return [PSCustomObject]@{
            Type    = 'Section'
            Level   = $level
            Starred = $starred
            Title   = $title
            Id      = "S$($this.SectionCounter)"
            Children = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
    }

    # ── Paragraph ─────────────────────────────────────────────────────────────

    [PSCustomObject] ParseParagraph() {
        $nodes   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $textBuf = [System.Text.StringBuilder]::new()

        [scriptblock]$flush = {
            $txt = $textBuf.ToString()
            if ($txt.Length -gt 0) {
                $nodes.Add([PSCustomObject]@{ Type = 'Text'; Content = $txt })
                $null = $textBuf.Clear()
            }
        }

        while ($this.HasMore()) {
            $t = $this.Peek()

            # Stop conditions
            if ($t.Type -eq 'ParBreak')                                                   { $null = $this.Consume(); break }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -in @('part','chapter','section','subsection','subsubsection','paragraph','subparagraph')) { break }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'end')                            { break }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'begin')                          { break }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'item')                           { break }
            if ($t.Type -eq 'EOF')                                                         { break }

            switch ($t.Type) {
                'Char'  { $null = $this.Consume(); $null = $textBuf.Append($t.Value) }
                'Space' {
                    $null = $this.Consume()
                    if ($textBuf.Length -gt 0 -or $nodes.Count -gt 0) { $null = $textBuf.Append(' ') }
                }
                'Tilde' { $null = $this.Consume(); $null = $textBuf.Append([string][char]0xA0) }
                'CtrlSym' {
                    $sym = $t.Value; $null = $this.Consume()
                    if ($sym -eq '\') {
                        & $flush
                        $null = $this.ReadOptArg()   # optional spacing arg
                        $nodes.Add([PSCustomObject]@{ Type = 'LineBreak' })
                    } else {
                        $map = @{ '$'='$';'%'='%';'&'='&';'#'='#';'_'='_';'{'='{';'}'='}';' '=[string][char]0xA0 }
                        if ($map.ContainsKey($sym)) { $null = $textBuf.Append($map[$sym]) }
                    }
                }
                'InlineMath' {
                    & $flush
                    $null = $this.Consume()
                    $content = $this.ReadMathUntil('InlineMath', '$')
                    $nodes.Add([PSCustomObject]@{ Type = 'Math'; Display = $false; Content = $content })
                }
                'DispMath' {
                    & $flush
                    $null = $this.Consume()
                    $content = $this.ReadMathUntil('DispMath', '$$')
                    $nodes.Add([PSCustomObject]@{ Type = 'Math'; Display = $true; Content = $content })
                }
                'BeginGroup' {
                    & $flush
                    $null = $this.Consume()
                    $kids = $this.ParseContent('EndGroup')
                    if ($this.HasMore() -and $this.Peek().Type -eq 'EndGroup') { $null = $this.Consume() }
                    foreach ($k in $kids) { $nodes.Add($k) }
                }
                'EndGroup' { & $flush; break }
                'CtrlSeq' {
                    & $flush
                    $node = $this.ParseCommand($t.Value)
                    if ($node) {
                        $nodes.Add($node)
                        # If this produced a block element end the paragraph
                        if ($node.Type -in @('Section','List','Equation','Align','Gather',
                                              'Figure','Table','Tabular','Abstract',
                                              'Verbatim','CodeBlock','Maketitle',
                                              'TableOfContents','Theorem','Quote',
                                              'Center','Environment')) {
                            break
                        }
                    }
                }
                default { $null = $this.Consume() }
            }
        }

        & $flush

        if ($nodes.Count -eq 0) { return $null }

        # Unwrap single block-level nodes
        if ($nodes.Count -eq 1 -and $nodes[0].Type -in @('Section','List','Equation','Align','Gather',
                'Figure','Table','Tabular','Abstract','Verbatim','CodeBlock',
                'Maketitle','TableOfContents','Theorem','Quote','Center','Environment','Label')) {
            return $nodes[0]
        }

        $this.ParaCounter++
        return [PSCustomObject]@{
            Type     = 'Paragraph'
            Id       = "p$($this.ParaCounter)"
            Children = $nodes.ToArray()
        }
    }

    # Parse inline content until the $until token type is reached.
    [PSCustomObject[]] ParseContent([string]$until) {
        $nodes   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $textBuf = [System.Text.StringBuilder]::new()

        [scriptblock]$flush = {
            $txt = $textBuf.ToString()
            if ($txt.Length -gt 0) {
                $nodes.Add([PSCustomObject]@{ Type = 'Text'; Content = $txt })
                $null = $textBuf.Clear()
            }
        }

        while ($this.HasMore()) {
            $t = $this.Peek()
            if ($t.Type -eq $until -or $t.Type -eq 'EOF') { break }

            switch ($t.Type) {
                'Char'  { $null = $this.Consume(); $null = $textBuf.Append($t.Value) }
                'Space' {
                    $null = $this.Consume()
                    if ($textBuf.Length -gt 0 -or $nodes.Count -gt 0) { $null = $textBuf.Append(' ') }
                }
                'Tilde' { $null = $this.Consume(); $null = $textBuf.Append([string][char]0xA0) }
                'ParBreak' {
                    & $flush
                    $null = $this.Consume()
                    $nodes.Add([PSCustomObject]@{ Type = 'ParBreak' })
                }
                'CtrlSym' {
                    $sym = $t.Value; $null = $this.Consume()
                    $map = @{ '$'='$';'%'='%';'&'='&';'#'='#';'_'='_';'{'='{';'}'='}';' '=[string][char]0xA0 }
                    if ($map.ContainsKey($sym)) { $null = $textBuf.Append($map[$sym]) }
                }
                'InlineMath' {
                    & $flush
                    $null = $this.Consume()
                    $content = $this.ReadMathUntil('InlineMath', '$')
                    $nodes.Add([PSCustomObject]@{ Type = 'Math'; Display = $false; Content = $content })
                }
                'DispMath' {
                    & $flush
                    $null = $this.Consume()
                    $content = $this.ReadMathUntil('DispMath', '$$')
                    $nodes.Add([PSCustomObject]@{ Type = 'Math'; Display = $true; Content = $content })
                }
                'BeginGroup' {
                    & $flush
                    $null = $this.Consume()
                    $kids = $this.ParseContent('EndGroup')
                    if ($this.HasMore() -and $this.Peek().Type -eq 'EndGroup') { $null = $this.Consume() }
                    foreach ($k in $kids) { $nodes.Add($k) }
                }
                'EndGroup' { & $flush; break }
                'CtrlSeq' {
                    & $flush
                    $node = $this.ParseCommand($t.Value)
                    if ($node) { $nodes.Add($node) }
                }
                default { $null = $this.Consume() }
            }
        }

        & $flush
        return $nodes.ToArray()
    }

    # ── Command dispatcher ────────────────────────────────────────────────────

    [PSCustomObject] ParseCommand([string]$name) {
        $null = $this.Consume()   # consume the CtrlSeq token

        # User-defined commands
        if ($this.UserCmds.ContainsKey($name)) {
            return $this.ExpandUserCmd($name)
        }

        # ── Accent commands (handled before the switch to avoid regex quoting issues) ─
        $accentNames = @("'", '`', 'v', 'u', 'H', 'c', 'k', 'r', 'b', 'd', '=', '.')
        $accentNamesWithSpecial = $accentNames + @('^', '~')
        if ($name -in $accentNamesWithSpecial) {
            $base     = $this.ReadArgText()
            $accented = ConvertTo-AccentedChar -Accent $name -Base $base
            return [PSCustomObject]@{ Type = 'Text'; Content = $accented }
        }
        # Handle diaeresis accent (double-quote ctrl sym)
        if ($name -eq '"') {
            $base     = $this.ReadArgText()
            $accented = ConvertTo-AccentedChar -Accent '"' -Base $base
            return [PSCustomObject]@{ Type = 'Text'; Content = $accented }
        }

        # Starred variant handled inline
        $starred = $false
        if ($this.HasMore() -and $this.Peek().Type -eq 'CtrlSym' -and $this.Peek().Value -eq '*') {
            $null = $this.Consume(); $starred = $true
        }

        switch -Regex ($name) {

            # ── Environments via \begin ────────────────────────────────────────
            '^begin$' {
                $envName = $this.ReadArgText()
                return $this.ParseEnvironment($envName)
            }
            '^end$' { $this.ReadArgText() | Out-Null; return $null }

            # ── Sectioning ────────────────────────────────────────────────────
            '^(part|chapter|section|subsection|subsubsection|paragraph|subparagraph)$' {
                $level = switch ($name) {
                    'part' {-1}; 'chapter' {0}; 'section' {1}; 'subsection' {2}
                    'subsubsection' {3}; 'paragraph' {4}; 'subparagraph' {5}; default {1}
                }
                $null = $this.ReadOptArg()
                $title = $this.ReadArg()
                $this.SectionCounter++
                return [PSCustomObject]@{
                    Type = 'Section'; Level = $level; Starred = $starred
                    Title = $title; Id = "S$($this.SectionCounter)"
                    Children = [System.Collections.Generic.List[PSCustomObject]]::new()
                }
            }

            '^maketitle$'       { return [PSCustomObject]@{ Type = 'Maketitle' } }
            '^tableofcontents$' { return [PSCustomObject]@{ Type = 'TableOfContents' } }

            # ── Text formatting ───────────────────────────────────────────────
            '^textbf$'    { return [PSCustomObject]@{ Type='Format'; Style='bold';       Children=$this.ReadArg() } }
            '^(textit|emph)$' { return [PSCustomObject]@{ Type='Format'; Style='italic';     Children=$this.ReadArg() } }
            '^texttt$'    { return [PSCustomObject]@{ Type='Format'; Style='monospace';  Children=$this.ReadArg() } }
            '^textsc$'    { return [PSCustomObject]@{ Type='Format'; Style='smallcaps';  Children=$this.ReadArg() } }
            '^textrm$'    { return [PSCustomObject]@{ Type='Format'; Style='roman';      Children=$this.ReadArg() } }
            '^textsf$'    { return [PSCustomObject]@{ Type='Format'; Style='sans';       Children=$this.ReadArg() } }
            '^underline$' { return [PSCustomObject]@{ Type='Format'; Style='underline';  Children=$this.ReadArg() } }
            '^mbox$'      { return [PSCustomObject]@{ Type='Format'; Style='normal';     Children=$this.ReadArg() } }
            '^text$'      { return [PSCustomObject]@{ Type='Format'; Style='normal';     Children=$this.ReadArg() } }

            # Font size declarations – consume nothing, emit nothing
            '^(tiny|scriptsize|footnotesize|small|normalsize|large|Large|LARGE|huge|Huge)$' { return $null }

            # ── References and citations ──────────────────────────────────────
            '^label$'  { return [PSCustomObject]@{ Type='Label'; Id=$this.ReadArgText() } }
            '^ref$'    { return [PSCustomObject]@{ Type='Ref';   Id=$this.ReadArgText(); Eq=$false } }
            '^eqref$'  { return [PSCustomObject]@{ Type='Ref';   Id=$this.ReadArgText(); Eq=$true  } }
            '^cite$'   {
                $null = $this.ReadOptArg()
                $keys = ($this.ReadArgText() -split ',') | ForEach-Object { $_.Trim() }
                return [PSCustomObject]@{ Type='Cite'; Keys=$keys }
            }
            '^nocite$' { $this.ReadArgText() | Out-Null; return $null }

            # ── Footnotes ─────────────────────────────────────────────────────
            '^footnote$' { return [PSCustomObject]@{ Type='Footnote'; Children=$this.ReadArg() } }

            # ── Hyperlinks ────────────────────────────────────────────────────
            '^url$'  {
                $href = $this.ReadArgText()
                return [PSCustomObject]@{ Type='URL'; Href=$href; Children=@([PSCustomObject]@{Type='Text';Content=$href}) }
            }
            '^href$' {
                $href = $this.ReadArgText()
                return [PSCustomObject]@{ Type='URL'; Href=$href; Children=$this.ReadArg() }
            }

            # ── Special text symbols ──────────────────────────────────────────
            '^(ldots|dots)$'  { return [PSCustomObject]@{ Type='Text'; Content=[string][char]0x2026 } }
            '^cdots$'         { return [PSCustomObject]@{ Type='Text'; Content=[string][char]0x22EF } }
            '^vdots$'         { return [PSCustomObject]@{ Type='Text'; Content=[string][char]0x22EE } }
            '^ddots$'         { return [PSCustomObject]@{ Type='Text'; Content=[string][char]0x22F1 } }
            '^LaTeX$'         { return [PSCustomObject]@{ Type='Text'; Content='LaTeX' } }
            '^TeX$'           { return [PSCustomObject]@{ Type='Text'; Content='TeX' } }
            '^LaTeXML$'       { return [PSCustomObject]@{ Type='Text'; Content='LaTeXML' } }
            '^today$'         { return [PSCustomObject]@{ Type='Text'; Content=(Get-Date -Format 'MMMM d, yyyy') } }

            # ── Lists ─────────────────────────────────────────────────────────
            '^item$' {
                $opt   = $this.ReadOptArg()
                $label = if ($opt) { ($opt | Where-Object{$_.Type -eq 'Text'} | ForEach-Object{$_.Content}) -join '' } else { '' }
                return [PSCustomObject]@{ Type='Item'; Label=$label; Children=[System.Collections.Generic.List[PSCustomObject]]::new() }
            }

            # ── Graphics ──────────────────────────────────────────────────────
            '^includegraphics$' {
                $null = $this.ReadOptArg()
                $file = $this.ReadArgText()
                return [PSCustomObject]@{ Type='Image'; File=$file }
            }
            '^caption$' {
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Caption'; Children=$this.ReadArg() }
            }

            # ── Spacing (consume args, emit nothing) ──────────────────────────
            '^(vspace|hspace|vspace\*|hspace\*)$' { $this.ReadArgText() | Out-Null; return $null }
            '^(newline|linebreak)$'               { return [PSCustomObject]@{ Type='LineBreak' } }
            '^par$'                               { return [PSCustomObject]@{ Type='ParBreak'  } }

            # ── Ignored structural commands ───────────────────────────────────
            '^(noindent|indent|centering|raggedright|raggedleft|sloppy|relax|protect|long|global|outer)$' { return $null }
            '^(clearpage|cleardoublepage|newpage|pagebreak)$'                                               { return $null }
            '^(bibliographystyle|bibliography|printbibliography)$' { $this.ReadArgText() | Out-Null; return $null }
            '^(pagestyle|pagenumbering)$'       { $this.ReadArgText() | Out-Null; return $null }
            '^(setcounter|addtocounter|stepcounter)$' {
                $this.ReadArgText() | Out-Null
                if ($name -ne 'stepcounter') { $this.ReadArgText() | Out-Null }
                return $null
            }
            '^(setlength|addtolength)$' { $this.ReadArgText() | Out-Null; $this.ReadArgText() | Out-Null; return $null }
            '^(markboth|markright)$'    { $this.ReadArgText() | Out-Null; return $null }
            '^index$'                   { $this.ReadArgText() | Out-Null; return $null }
            '^(newcommand|renewcommand|providecommand)$' { $this.ParseNewCommand(); return $null }
            '^(newenvironment|renewenvironment)$'        { $this.ParseNewEnvironment(); return $null }
            '^(newtheorem|newcounter)$'  { $this.ReadArgText() | Out-Null; $this.ReadOptArg() | Out-Null; return $null }

            # ── Catch-all ─────────────────────────────────────────────────────
            default { return $null }
        }
        return $null
    }

    # ── Environment dispatcher ────────────────────────────────────────────────

    [PSCustomObject] ParseEnvironment([string]$envName) {
        switch -Regex ($envName) {
            '^document$'  { return $null }
            '^abstract$'  { return [PSCustomObject]@{ Type='Abstract'; Children=$this.ParseEnvBody('abstract') } }

            # Lists
            '^itemize$'     { return [PSCustomObject]@{ Type='List'; Style='bullet';      Children=$this.ParseListBody('itemize')     } }
            '^enumerate$'   { return [PSCustomObject]@{ Type='List'; Style='ordered';     Children=$this.ParseListBody('enumerate')   } }
            '^description$' { return [PSCustomObject]@{ Type='List'; Style='description'; Children=$this.ParseListBody('description') } }

            # Verbatim-ish
            '^(verbatim|Verbatim)$' {
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Verbatim'; Content=$this.ReadVerbatimBody($envName) }
            }
            '^lstlisting$' {
                $opt  = $this.ReadOptArgText()
                $lang = if ($opt -match 'language\s*=\s*(\w+)') { $Matches[1] } else { '' }
                return [PSCustomObject]@{ Type='CodeBlock'; Content=$this.ReadVerbatimBody('lstlisting'); Language=$lang }
            }
            '^minted$' {
                $lang = $this.ReadArgText()
                return [PSCustomObject]@{ Type='CodeBlock'; Content=$this.ReadVerbatimBody('minted'); Language=$lang }
            }

            # Alignment environments
            '^(center|flushleft|flushright)$' {
                $kids = $this.ParseEnvBody($envName)
                return [PSCustomObject]@{ Type='Center'; Children=$kids }
            }
            '^(quote|quotation|verse)$' { return [PSCustomObject]@{ Type='Quote'; Children=$this.ParseEnvBody($envName) } }

            # Math environments
            '^equation\*?$' {
                $s = $envName -match '\*$'
                return [PSCustomObject]@{ Type='Equation'; Starred=$s; Content=$this.ReadMathEnvBody($envName) }
            }
            '^(align|flalign|alignat)\*?$' {
                $s = $envName -match '\*$'
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Align'; Starred=$s; Content=$this.ReadMathEnvBody($envName) }
            }
            '^gather\*?$' {
                $s = $envName -match '\*$'
                return [PSCustomObject]@{ Type='Gather'; Starred=$s; Content=$this.ReadMathEnvBody($envName) }
            }
            '^(multline|split)\*?$' {
                $s = $envName -match '\*$'
                return [PSCustomObject]@{ Type='Equation'; Starred=$s; Content=$this.ReadMathEnvBody($envName) }
            }
            '^eqnarray\*?$' {
                $s = $envName -match '\*$'
                return [PSCustomObject]@{ Type='Align'; Starred=$s; Content=$this.ReadMathEnvBody($envName) }
            }
            '^(math|displaymath)$' {
                $disp = $envName -eq 'displaymath'
                return [PSCustomObject]@{ Type='Math'; Display=$disp; Content=$this.ReadMathEnvBody($envName) }
            }

            # Floats
            '^figure\*?$' {
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Figure'; Children=$this.ParseEnvBody($envName) }
            }
            '^table\*?$' {
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Table'; Float=$true; Children=$this.ParseEnvBody($envName) }
            }

            # Tabular
            '^tabular\*?$' {
                if ($envName -eq 'tabular*') { $this.ReadArgText() | Out-Null }
                $null = $this.ReadOptArg()
                $spec = $this.ReadArgText()
                $rows = $this.ParseTabularBody($envName)
                return [PSCustomObject]@{ Type='Tabular'; Spec=$spec; Rows=$rows }
            }
            '^array$' {
                $null = $this.ReadOptArg()
                $spec = $this.ReadArgText()
                $rows = $this.ParseTabularBody('array')
                return [PSCustomObject]@{ Type='Tabular'; Spec=$spec; Rows=$rows }
            }

            # Theorem-like
            '^(theorem|lemma|corollary|proposition|definition|proof|remark|example|exercise|solution|conjecture|claim|notation)$' {
                $null = $this.ReadOptArg()
                return [PSCustomObject]@{ Type='Theorem'; EnvName=$envName; Children=$this.ParseEnvBody($envName) }
            }

            # User-defined
            default {
                if ($this.UserEnvs.ContainsKey($envName)) {
                    $kids = $this.ParseEnvBody($envName)
                    return [PSCustomObject]@{ Type='Environment'; Name=$envName; Children=$kids }
                }
                $kids = $this.ParseEnvBody($envName)
                return [PSCustomObject]@{ Type='Environment'; Name=$envName; Children=$kids }
            }
        }
        return $null
    }

    # ── List body ─────────────────────────────────────────────────────────────

    [PSCustomObject[]] ParseListBody([string]$envName) {
        $items = [System.Collections.Generic.List[PSCustomObject]]::new()
        [PSCustomObject]$current = $null

        while ($this.HasMore()) {
            # Check for \end{envName}
            if ($this.Peek().Type -eq 'CtrlSeq' -and $this.Peek().Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { break }
                    $this.Pos = $savedPos
                } else { $this.Pos = $savedPos }
            }

            $t = $this.Peek()

            if ($t.Type -in @('Space', 'ParBreak')) { $null = $this.Consume(); continue }

            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'item') {
                if ($current) { $items.Add($current) }
                $null = $this.Consume()
                $opt   = $this.ReadOptArg()
                $label = if ($opt) { ($opt | Where-Object{$_.Type -eq 'Text'} | ForEach-Object{$_.Content}) -join '' } else { '' }
                $current = [PSCustomObject]@{ Type='Item'; Label=$label; Children=[System.Collections.Generic.List[PSCustomObject]]::new() }
                continue
            }

            # Anything else belongs to the current item
            if ($current) {
                $n = $this.ParseBodyElement()
                if ($n) { $current.Children.Add($n) }
            } else {
                $null = $this.Consume()
            }
        }

        if ($current) { $items.Add($current) }
        return $items.ToArray()
    }

    # ── Tabular body ──────────────────────────────────────────────────────────

    [PSCustomObject[][]] ParseTabularBody([string]$envName) {
        $rows = [System.Collections.Generic.List[object]]::new()
        $cells = [System.Collections.Generic.List[PSCustomObject]]::new()

        [scriptblock]$addRow = {
            if ($cells.Count -gt 0) {
                $rows.Add($cells.ToArray())
                $cells.Clear()
            }
        }

        while ($this.HasMore()) {
            if ($this.Peek().Type -eq 'CtrlSeq' -and $this.Peek().Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { & $addRow; break }
                    $this.Pos = $savedPos
                } else { $this.Pos = $savedPos }
            }

            $t = $this.Peek()

            # Row separator \\
            if ($t.Type -eq 'CtrlSym' -and $t.Value -eq '\') {
                $null = $this.Consume()
                $null = $this.ReadOptArg()
                & $addRow
                continue
            }

            # \hline – skip
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'hline') { $null = $this.Consume(); continue }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'cline') { $null = $this.Consume(); $this.ReadArgText() | Out-Null; continue }

            # Column separator &
            if ($t.Type -eq 'Align') {
                $null = $this.Consume()
                & $addRow   # flush current cell, treat & as row separator signal below
                # Actually & separates cells, not rows – redo logic:
                # We'll collect cell content differently below
                continue
            }

            # Spaces/parbreaks inside tabular
            if ($t.Type -in @('Space','ParBreak')) { $null = $this.Consume(); continue }

            # Multicolumn
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'multicolumn') {
                $null = $this.Consume()
                $span    = [int]($this.ReadArgText())
                $null    = $this.ReadArgText()   # alignment spec
                $content = $this.ReadArg()
                $cells.Add([PSCustomObject]@{ Type='Cell'; Span=$span; Children=$content })
                continue
            }

            # Ordinary cell content – collect until & or \\
            $cellNodes = $this.ParseTabularCell($envName)
            $cells.Add([PSCustomObject]@{ Type='Cell'; Span=1; Children=$cellNodes })
        }

        return $rows.ToArray()
    }

    # Collect one tabular cell's content.
    [PSCustomObject[]] ParseTabularCell([string]$envName) {
        $nodes   = [System.Collections.Generic.List[PSCustomObject]]::new()
        $textBuf = [System.Text.StringBuilder]::new()

        [scriptblock]$flush = {
            $txt = $textBuf.ToString().Trim()
            if ($txt) { $nodes.Add([PSCustomObject]@{ Type='Text'; Content=$txt }); $null = $textBuf.Clear() }
        }

        while ($this.HasMore()) {
            $t = $this.Peek()
            # Stop at cell or row boundary
            if ($t.Type -eq 'Align') { break }
            if ($t.Type -eq 'CtrlSym' -and $t.Value -eq '\') { break }
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { $this.Pos = $savedPos; break }
                    $this.Pos = $savedPos
                } else { $this.Pos = $savedPos }
                break
            }

            switch ($t.Type) {
                'Char'       { $null = $this.Consume(); $null = $textBuf.Append($t.Value) }
                'Space'      { $null = $this.Consume(); if ($textBuf.Length -gt 0) { $null = $textBuf.Append(' ') } }
                'CtrlSym'    {
                    $sym = $t.Value; $null = $this.Consume()
                    $map = @{ '$'='$';'%'='%';'_'='_';'{'='{';'}'='}' }
                    if ($map.ContainsKey($sym)) { $null = $textBuf.Append($map[$sym]) }
                }
                'InlineMath' {
                    & $flush; $null = $this.Consume()
                    $nodes.Add([PSCustomObject]@{ Type='Math'; Display=$false; Content=$this.ReadMathUntil('InlineMath','$') })
                }
                'BeginGroup' {
                    & $flush; $null = $this.Consume()
                    $kids = $this.ParseContent('EndGroup')
                    if ($this.HasMore() -and $this.Peek().Type -eq 'EndGroup') { $null = $this.Consume() }
                    foreach ($k in $kids) { $nodes.Add($k) }
                }
                'CtrlSeq' {
                    & $flush
                    $node = $this.ParseCommand($t.Value)
                    if ($node) { $nodes.Add($node) }
                }
                default { $null = $this.Consume() }
            }
        }

        & $flush
        return $nodes.ToArray()
    }

    # ── Verbatim body ─────────────────────────────────────────────────────────

    [string] ReadVerbatimBody([string]$envName) {
        $sb = [System.Text.StringBuilder]::new()
        while ($this.HasMore()) {
            $t = $this.Peek()
            if ($t.Type -eq 'CtrlSeq' -and $t.Value -eq 'end') {
                $savedPos = $this.Pos
                $null = $this.Consume()
                $this.SkipHSpace()
                if ($this.HasMore() -and $this.Peek().Type -eq 'BeginGroup') {
                    $null = $this.Consume()
                    $name = $this.CollectToEndGroup()
                    if ($name -eq $envName) { break }
                    $sb.Append('\end{' + $name + '}') | Out-Null
                    continue
                }
                $this.Pos = $savedPos
            }
            switch ($t.Type) {
                'CtrlSeq'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value + ' ') }
                'CtrlSym'    { $null = $this.Consume(); $null = $sb.Append('\' + $t.Value) }
                'BeginGroup' { $null = $this.Consume(); $null = $sb.Append('{') }
                'EndGroup'   { $null = $this.Consume(); $null = $sb.Append('}') }
                'InlineMath' { $null = $this.Consume(); $null = $sb.Append('$') }
                'DispMath'   { $null = $this.Consume(); $null = $sb.Append('$$') }
                'Align'      { $null = $this.Consume(); $null = $sb.Append('&') }
                'Super'      { $null = $this.Consume(); $null = $sb.Append('^') }
                'Sub'        { $null = $this.Consume(); $null = $sb.Append('_') }
                'Tilde'      { $null = $this.Consume(); $null = $sb.Append('~') }
                'Space'      { $null = $this.Consume(); $null = $sb.Append(' ') }
                'ParBreak'   { $null = $this.Consume(); $null = $sb.Append("`n") }
                'Char'       { $null = $this.Consume(); $null = $sb.Append($t.Value) }
                default      { $null = $this.Consume() }
            }
        }
        return $sb.ToString()
    }

    # ── User-command expansion ────────────────────────────────────────────────

    [PSCustomObject] ExpandUserCmd([string]$name) {
        $def   = $this.UserCmds[$name]
        $nArgs = $def.ArgCount
        $args  = @()
        for ($i = 0; $i -lt $nArgs; $i++) { $args += ,$this.ReadArgText() }

        # Substitute #1 … #9 in the body token stream and re-parse
        $expanded = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($bt in $def.Body) {
            if ($bt.Type -eq 'Param' -and $bt.Value -match '^\d$') {
                $idx = [int]$bt.Value - 1
                if ($idx -ge 0 -and $idx -lt $args.Count) {
                    $expanded.Add([PSCustomObject]@{ Type='Char'; Value=$args[$idx] })
                }
            } else {
                $expanded.Add($bt)
            }
        }

        $saved = $this.Tokens; $savedPos = $this.Pos
        $this.Tokens = $expanded; $this.Pos = 0
        $result = $this.ParseContent('EOF')
        $this.Tokens = $saved; $this.Pos = $savedPos

        if ($result.Count -eq 0) { return $null }
        if ($result.Count -eq 1) { return $result[0] }
        return [PSCustomObject]@{ Type='Format'; Style='normal'; Children=$result }
    }
}

# ── Accent helper ─────────────────────────────────────────────────────────────

function ConvertTo-AccentedChar {
    [CmdletBinding()]
    param(
        [string]$Accent,
        [string]$Base
    )
    # Encode the lookup as "accent|base" → unicode codepoint to avoid case-insensitive hashtable issues.
    $backtick = [char]0x60
    $dquote   = [char]0x22
    $caret    = [char]0x5E
    $tilde    = [char]0x7E

    $key = "$Accent|$Base"
    $map = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::Ordinal)

    # Acute accent (')
    $null = $map.Add("'|a", 0xE1); $null = $map.Add("'|e", 0xE9); $null = $map.Add("'|i", 0xED)
    $null = $map.Add("'|o", 0xF3); $null = $map.Add("'|u", 0xFA); $null = $map.Add("'|y", 0xFD)
    $null = $map.Add("'|A", 0xC1); $null = $map.Add("'|E", 0xC9); $null = $map.Add("'|I", 0xCD)
    $null = $map.Add("'|O", 0xD3); $null = $map.Add("'|U", 0xDA); $null = $map.Add("'|Y", 0xDD)
    # Grave accent (`)
    $gk = "$backtick"
    $null = $map.Add("$gk|a", 0xE0); $null = $map.Add("$gk|e", 0xE8); $null = $map.Add("$gk|i", 0xEC)
    $null = $map.Add("$gk|o", 0xF2); $null = $map.Add("$gk|u", 0xF9)
    $null = $map.Add("$gk|A", 0xC0); $null = $map.Add("$gk|E", 0xC8); $null = $map.Add("$gk|I", 0xCC)
    $null = $map.Add("$gk|O", 0xD2); $null = $map.Add("$gk|U", 0xD9)
    # Umlaut/diaeresis (")
    $dk = "$dquote"
    $null = $map.Add("$dk|a", 0xE4); $null = $map.Add("$dk|e", 0xEB); $null = $map.Add("$dk|i", 0xEF)
    $null = $map.Add("$dk|o", 0xF6); $null = $map.Add("$dk|u", 0xFC); $null = $map.Add("$dk|y", 0xFF)
    $null = $map.Add("$dk|A", 0xC4); $null = $map.Add("$dk|E", 0xCB); $null = $map.Add("$dk|I", 0xCF)
    $null = $map.Add("$dk|O", 0xD6); $null = $map.Add("$dk|U", 0xDC)
    # Circumflex (^)
    $ck = "$caret"
    $null = $map.Add("$ck|a", 0xE2); $null = $map.Add("$ck|e", 0xEA); $null = $map.Add("$ck|i", 0xEE)
    $null = $map.Add("$ck|o", 0xF4); $null = $map.Add("$ck|u", 0xFB)
    $null = $map.Add("$ck|A", 0xC2); $null = $map.Add("$ck|E", 0xCA); $null = $map.Add("$ck|I", 0xCE)
    $null = $map.Add("$ck|O", 0xD4); $null = $map.Add("$ck|U", 0xDB)
    # Tilde (~)
    $tk = "$tilde"
    $null = $map.Add("$tk|a", 0xE3); $null = $map.Add("$tk|n", 0xF1); $null = $map.Add("$tk|o", 0xF5)
    $null = $map.Add("$tk|A", 0xC3); $null = $map.Add("$tk|N", 0xD1); $null = $map.Add("$tk|O", 0xD5)
    # Cedilla (c)
    $null = $map.Add('c|c', 0xE7); $null = $map.Add('c|C', 0xC7)
    # Macron (=)
    $null = $map.Add('=|a', 0x101); $null = $map.Add('=|e', 0x113); $null = $map.Add('=|i', 0x12B)
    $null = $map.Add('=|o', 0x14D); $null = $map.Add('=|u', 0x16B)
    # Breve (u)
    $null = $map.Add('u|a', 0x103); $null = $map.Add('u|e', 0x115); $null = $map.Add('u|i', 0x12D)
    $null = $map.Add('u|o', 0x14F); $null = $map.Add('u|u', 0x16D)
    # Caron (v)
    $null = $map.Add('v|c', 0x10D); $null = $map.Add('v|n', 0x148); $null = $map.Add('v|s', 0x161)
    $null = $map.Add('v|z', 0x17E); $null = $map.Add('v|C', 0x10C); $null = $map.Add('v|N', 0x147)
    $null = $map.Add('v|S', 0x160); $null = $map.Add('v|Z', 0x17D)
    # Double acute (H)
    $null = $map.Add('H|o', 0x151); $null = $map.Add('H|u', 0x171)
    $null = $map.Add('H|O', 0x150); $null = $map.Add('H|U', 0x170)
    # Ogonek (k)
    $null = $map.Add('k|a', 0x105); $null = $map.Add('k|e', 0x119)
    $null = $map.Add('k|A', 0x104); $null = $map.Add('k|E', 0x118)
    # Dot above (.)
    $null = $map.Add('.|a', 0x227); $null = $map.Add('.|e', 0x117); $null = $map.Add('.|i', 0x12F)
    $null = $map.Add('.|z', 0x17C); $null = $map.Add('.|A', 0x226); $null = $map.Add('.|Z', 0x17B)
    # Ring above (r)
    $null = $map.Add('r|a', 0xE5); $null = $map.Add('r|A', 0xC5)
    # Bar below (b)
    $null = $map.Add('b|b', 0x1E07); $null = $map.Add('b|d', 0x1E0F)
    $null = $map.Add('b|B', 0x1E06); $null = $map.Add('b|D', 0x1E0E)

    $codepoint = 0
    if ($map.TryGetValue($key, [ref]$codepoint)) {
        return [string][char]$codepoint
    }
    return $Base
}

# ── Public entry point ────────────────────────────────────────────────────────

function Invoke-LaTeXParse {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Source
    )
    $tokens = Invoke-LaTeXTokenize -Source $Source
    $parser = [LaTeXParser]::new($tokens)
    return $parser.Parse()
}
