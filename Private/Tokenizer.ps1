# Private/Tokenizer.ps1
# LaTeX tokenizer – converts raw LaTeX source into a flat token stream.
#
# Token types produced:
#   CtrlSeq    – multi-letter control word, e.g. \textbf  (Value = word, no backslash)
#   CtrlSym    – single-character control symbol, e.g. \$  (Value = the symbol)
#   BeginGroup – {
#   EndGroup   – }
#   InlineMath – $
#   DispMath   – $$
#   Align      – &
#   Super      – ^
#   Sub        – _
#   Tilde      – ~ (non-breaking space)
#   Space      – one or more spaces/tabs collapsed to a single ' '
#   ParBreak   – blank line (paragraph break)
#   Char       – any other character

class LaTeXTokenizer {
    [string] $Source
    [int]    $Pos

    LaTeXTokenizer([string]$source) {
        $this.Source = $source
        $this.Pos    = 0
    }

    [bool] HasMore() { return $this.Pos -lt $this.Source.Length }

    [char] Peek([int]$offset) {
        $p = $this.Pos + $offset
        if ($p -lt $this.Source.Length) { return $this.Source[$p] }
        return [char]0
    }

    [char] Peek() { return $this.Peek(0) }

    [char] Consume() {
        $c = $this.Source[$this.Pos]
        $this.Pos++
        return $c
    }

    [bool] IsLetter([char]$c) { return ([string]$c) -match '^[a-zA-Z@]$' }
    [bool] IsSpace([char]$c)  { return $c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" }

    [PSCustomObject] Tok([string]$type, [string]$value) {
        return [PSCustomObject]@{ Type = $type; Value = $value }
    }

    # Return the full token list for $this.Source
    [System.Collections.Generic.List[PSCustomObject]] Tokenize() {
        $tokens = [System.Collections.Generic.List[PSCustomObject]]::new()

        while ($this.HasMore()) {
            $c  = $this.Peek()
            $cs = [string]$c

            # ── Comment ──────────────────────────────────────────────────────
            if ($cs -eq '%') {
                $null = $this.Consume()
                while ($this.HasMore() -and $this.Peek() -ne [char]10) { $null = $this.Consume() }
                if ($this.HasMore()) { $null = $this.Consume() }   # consume LF
                continue
            }

            # ── Backslash ────────────────────────────────────────────────────
            if ($cs -eq '\') {
                $null = $this.Consume()
                if (-not $this.HasMore()) {
                    $tokens.Add($this.Tok('CtrlSym', '\'))
                    continue
                }
                $nc = $this.Peek()
                if ($this.IsLetter($nc)) {
                    $name = ''
                    while ($this.HasMore() -and $this.IsLetter($this.Peek())) {
                        $name += [string]$this.Consume()
                    }
                    # consume trailing horizontal whitespace after a control word
                    while ($this.HasMore() -and $this.IsSpace($this.Peek())) { $null = $this.Consume() }
                    $tokens.Add($this.Tok('CtrlSeq', $name))
                } else {
                    $tokens.Add($this.Tok('CtrlSym', [string]$this.Consume()))
                }
                continue
            }

            # ── Grouping ─────────────────────────────────────────────────────
            if ($cs -eq '{') { $null = $this.Consume(); $tokens.Add($this.Tok('BeginGroup', '{')); continue }
            if ($cs -eq '}') { $null = $this.Consume(); $tokens.Add($this.Tok('EndGroup', '}'));   continue }

            # ── Special tokens ───────────────────────────────────────────────
            if ($cs -eq '&') { $null = $this.Consume(); $tokens.Add($this.Tok('Align', '&'));  continue }
            if ($cs -eq '^') { $null = $this.Consume(); $tokens.Add($this.Tok('Super', '^'));  continue }
            if ($cs -eq '_') { $null = $this.Consume(); $tokens.Add($this.Tok('Sub',   '_'));  continue }
            if ($cs -eq '~') { $null = $this.Consume(); $tokens.Add($this.Tok('Tilde', '~'));  continue }

            # ── Math shift ───────────────────────────────────────────────────
            if ($cs -eq '$') {
                $null = $this.Consume()
                if ($this.HasMore() -and $this.Peek() -eq [char]'$') {
                    $null = $this.Consume()
                    $tokens.Add($this.Tok('DispMath', '$$'))
                } else {
                    $tokens.Add($this.Tok('InlineMath', '$'))
                }
                continue
            }

            # ── Newline / paragraph break ────────────────────────────────────
            if ($c -eq [char]10) {
                $null = $this.Consume()
                while ($this.HasMore() -and $this.IsSpace($this.Peek())) { $null = $this.Consume() }
                if ($this.HasMore() -and $this.Peek() -eq [char]10) {
                    # two or more consecutive newlines = paragraph break
                    while ($this.HasMore() -and ($this.IsSpace($this.Peek()) -or $this.Peek() -eq [char]10)) {
                        $null = $this.Consume()
                    }
                    $tokens.Add($this.Tok('ParBreak', ''))
                } else {
                    $tokens.Add($this.Tok('Space', ' '))
                }
                continue
            }

            # ── Horizontal whitespace ────────────────────────────────────────
            if ($this.IsSpace($c)) {
                $null = $this.Consume()
                while ($this.HasMore() -and $this.IsSpace($this.Peek())) { $null = $this.Consume() }
                $tokens.Add($this.Tok('Space', ' '))
                continue
            }

            # ── Dashes: -, --, --- ───────────────────────────────────────────
            if ($cs -eq '-') {
                $null = $this.Consume()
                if ($this.HasMore() -and $this.Peek() -eq [char]'-') {
                    $null = $this.Consume()
                    if ($this.HasMore() -and $this.Peek() -eq [char]'-') {
                        $null = $this.Consume()
                        $tokens.Add($this.Tok('Char', [string][char]0x2014))   # em-dash
                    } else {
                        $tokens.Add($this.Tok('Char', [string][char]0x2013))   # en-dash
                    }
                } else {
                    $tokens.Add($this.Tok('Char', '-'))
                }
                continue
            }

            # ── Opening smart quotes: ` and `` ───────────────────────────────
            if ($cs -eq '`') {
                $null = $this.Consume()
                if ($this.HasMore() -and $this.Peek() -eq [char]'`') {
                    $null = $this.Consume()
                    $tokens.Add($this.Tok('Char', [string][char]0x201C))   # "
                } else {
                    $tokens.Add($this.Tok('Char', [string][char]0x2018))   # '
                }
                continue
            }

            # ── Closing smart quotes: ' and '' ───────────────────────────────
            if ($cs -eq "'") {
                $null = $this.Consume()
                if ($this.HasMore() -and $this.Peek() -eq [char]"'") {
                    $null = $this.Consume()
                    $tokens.Add($this.Tok('Char', [string][char]0x201D))   # "
                } else {
                    $tokens.Add($this.Tok('Char', [string][char]0x2019))   # '
                }
                continue
            }

            # ── Everything else ──────────────────────────────────────────────
            $null = $this.Consume()
            $tokens.Add($this.Tok('Char', $cs))
        }

        return $tokens
    }
}

# Public helper used by the parser
function Invoke-LaTeXTokenize {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param(
        [Parameter(Mandatory)][string]$Source
    )
    $tok = [LaTeXTokenizer]::new($Source)
    return $tok.Tokenize()
}
