# Tests/PSLaTeXML.Tests.ps1
# Pester 5.x tests for the PSLaTeXML module.

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$ModuleRoot/PSLaTeXML.psd1" -Force
}

# ── Tokenizer tests ───────────────────────────────────────────────────────────
Describe 'Invoke-LaTeXTokenize' {

    It 'tokenises plain text' {
        $t = Invoke-LaTeXTokenize -Source 'Hello World'
        $types = $t.Type
        $types | Should -Contain 'Char'
        $types | Should -Contain 'Space'
    }

    It 'tokenises a control sequence' {
        $t = Invoke-LaTeXTokenize -Source '\textbf'
        $t.Count | Should -Be 1
        $t[0].Type  | Should -Be 'CtrlSeq'
        $t[0].Value | Should -Be 'textbf'
    }

    It 'tokenises a control symbol' {
        $t = Invoke-LaTeXTokenize -Source '\$'
        $t.Count | Should -Be 1
        $t[0].Type  | Should -Be 'CtrlSym'
        $t[0].Value | Should -Be '$'
    }

    It 'tokenises braces' {
        $t = Invoke-LaTeXTokenize -Source '{}'
        $t[0].Type | Should -Be 'BeginGroup'
        $t[1].Type | Should -Be 'EndGroup'
    }

    It 'tokenises inline math' {
        $t = Invoke-LaTeXTokenize -Source '$x$'
        $t[0].Type | Should -Be 'InlineMath'
        $t[1].Type | Should -Be 'Char'
        $t[2].Type | Should -Be 'InlineMath'
    }

    It 'tokenises display math' {
        $t = Invoke-LaTeXTokenize -Source '$$y$$'
        $t[0].Type  | Should -Be 'DispMath'
        $t[0].Value | Should -Be '$$'
    }

    It 'strips comments' {
        $t = Invoke-LaTeXTokenize -Source "Hello % comment`nWorld"
        $text = $t | Where-Object { $_.Type -eq 'Char' } | ForEach-Object { $_.Value }
        $text -join '' | Should -Not -Match 'comment'
    }

    It 'produces a paragraph break from a blank line' {
        $t = Invoke-LaTeXTokenize -Source "Line1`n`nLine2"
        $t.Type | Should -Contain 'ParBreak'
    }

    It 'converts -- to en-dash' {
        $t = Invoke-LaTeXTokenize -Source '--'
        $t.Count | Should -Be 1
        $t[0].Value | Should -Be ([string][char]0x2013)
    }

    It 'converts --- to em-dash' {
        $t = Invoke-LaTeXTokenize -Source '---'
        $t.Count | Should -Be 1
        $t[0].Value | Should -Be ([string][char]0x2014)
    }

    It 'converts `` to opening double-quote' {
        $t = Invoke-LaTeXTokenize -Source '``'
        $t[0].Value | Should -Be ([string][char]0x201C)
    }

    It "converts '' to closing double-quote" {
        $t = Invoke-LaTeXTokenize -Source "''"
        $t[0].Value | Should -Be ([string][char]0x201D)
    }
}

# ── Parser tests ──────────────────────────────────────────────────────────────
Describe 'Invoke-LaTeXParse' {

    Context 'Document structure' {
        It 'returns a Document node' {
            $ast = Invoke-LaTeXParse -Source '\documentclass{article}\begin{document}\end{document}'
            $ast.Type  | Should -Be 'Document'
            $ast.Class | Should -Be 'article'
        }

        It 'captures title, author, date from preamble' {
            $src = @'
\documentclass{article}
\title{My Title}
\author{Jane Doe}
\date{2024-01-01}
\begin{document}
\end{document}
'@
            $ast = Invoke-LaTeXParse -Source $src
            $ast.Title  | Should -Be 'My Title'
            $ast.Author | Should -Be 'Jane Doe'
            $ast.Date   | Should -Be '2024-01-01'
        }

        It 'captures usepackage declarations' {
            $src = '\documentclass{article}\usepackage{amsmath}\usepackage{graphicx}\begin{document}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $ast.Packages | Should -Contain 'amsmath'
            $ast.Packages | Should -Contain 'graphicx'
        }
    }

    Context 'Paragraphs' {
        It 'parses a simple paragraph' {
            $src = '\documentclass{article}\begin{document}Hello world.\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' }
            $para | Should -Not -BeNullOrEmpty
            $text = $para.Children | Where-Object { $_.Type -eq 'Text' } | ForEach-Object { $_.Content }
            ($text -join '') | Should -Match 'Hello'
        }

        It 'handles multiple paragraphs' {
            $src = '\documentclass{article}\begin{document}First paragraph.' + "`n`n" + 'Second paragraph.\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            ($ast.Children | Where-Object { $_.Type -eq 'Paragraph' }).Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'Sections' {
        It 'parses a \section' {
            $src = '\documentclass{article}\begin{document}\section{Introduction}Hello\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $sec = $ast.Children | Where-Object { $_.Type -eq 'Section' }
            $sec | Should -Not -BeNullOrEmpty
            $sec.Level | Should -Be 1
            $titleText = ($sec.Title | Where-Object { $_.Type -eq 'Text' } | ForEach-Object { $_.Content }) -join ''
            $titleText | Should -Be 'Introduction'
        }

        It 'parses nested section levels' {
            $src = @'
\documentclass{article}
\begin{document}
\section{A}
\subsection{B}
\subsubsection{C}
\end{document}
'@
            $ast = Invoke-LaTeXParse -Source $src
            $secs = $ast.Children | Where-Object { $_.Type -eq 'Section' }
            $secs.Count | Should -BeGreaterOrEqual 3
            ($secs | Where-Object { $_.Level -eq 1 }) | Should -Not -BeNullOrEmpty
            ($secs | Where-Object { $_.Level -eq 2 }) | Should -Not -BeNullOrEmpty
            ($secs | Where-Object { $_.Level -eq 3 }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Formatting' {
        It 'parses \textbf as bold' {
            $src = '\documentclass{article}\begin{document}\textbf{bold text}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $fmt  = $para.Children | Where-Object { $_.Type -eq 'Format' }
            $fmt.Style | Should -Be 'bold'
        }

        It 'parses \textit as italic' {
            $src = '\documentclass{article}\begin{document}\textit{italic}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $fmt  = $para.Children | Where-Object { $_.Type -eq 'Format' }
            $fmt.Style | Should -Be 'italic'
        }

        It 'parses \emph as italic' {
            $src = '\documentclass{article}\begin{document}\emph{em}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $fmt  = $para.Children | Where-Object { $_.Type -eq 'Format' }
            $fmt.Style | Should -Be 'italic'
        }

        It 'parses \texttt as monospace' {
            $src = '\documentclass{article}\begin{document}\texttt{code}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $fmt  = $para.Children | Where-Object { $_.Type -eq 'Format' }
            $fmt.Style | Should -Be 'monospace'
        }
    }

    Context 'Math' {
        It 'parses inline math' {
            $src = '\documentclass{article}\begin{document}$x^2$\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $math = $para.Children | Where-Object { $_.Type -eq 'Math' }
            $math.Display  | Should -Be $false
            $math.Content  | Should -Match 'x'
        }

        It 'parses display math' {
            $src = '\documentclass{article}\begin{document}$$y = mx + b$$\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' } | Select-Object -First 1
            $math = $para.Children | Where-Object { $_.Type -eq 'Math' }
            $math.Display | Should -Be $true
        }

        It 'parses equation environment' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{equation}
E = mc^2
\end{equation}
\end{document}
'@
            $ast = Invoke-LaTeXParse -Source $src
            $eq = $ast.Children | Where-Object { $_.Type -eq 'Equation' }
            $eq | Should -Not -BeNullOrEmpty
            $eq.Content | Should -Match 'E'
        }
    }

    Context 'Lists' {
        It 'parses an itemize list' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{itemize}
  \item First
  \item Second
\end{itemize}
\end{document}
'@
            $ast  = Invoke-LaTeXParse -Source $src
            $list = $ast.Children | Where-Object { $_.Type -eq 'List' }
            $list.Style        | Should -Be 'bullet'
            $list.Children.Count | Should -Be 2
        }

        It 'parses an enumerate list' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{enumerate}
  \item One
  \item Two
  \item Three
\end{enumerate}
\end{document}
'@
            $ast  = Invoke-LaTeXParse -Source $src
            $list = $ast.Children | Where-Object { $_.Type -eq 'List' }
            $list.Style          | Should -Be 'ordered'
            $list.Children.Count | Should -Be 3
        }

        It 'parses a description list' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{description}
  \item[term] definition
\end{description}
\end{document}
'@
            $ast  = Invoke-LaTeXParse -Source $src
            $list = $ast.Children | Where-Object { $_.Type -eq 'List' }
            $list.Style | Should -Be 'description'
            $list.Children[0].Label | Should -Be 'term'
        }
    }

    Context 'References and citations' {
        It 'parses \label' {
            $src = '\documentclass{article}\begin{document}\label{sec:intro}\end{document}'
            $ast = Invoke-LaTeXParse -Source $src
            $lbl = $ast.Children | Where-Object { $_.Type -eq 'Label' }
            $lbl.Id | Should -Be 'sec:intro'
        }

        It 'parses \ref' {
            $src = '\documentclass{article}\begin{document}See \ref{sec:intro}\end{document}'
            $ast  = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' }
            $ref  = $para.Children | Where-Object { $_.Type -eq 'Ref' }
            $ref.Id | Should -Be 'sec:intro'
        }

        It 'parses \cite' {
            $src = '\documentclass{article}\begin{document}\cite{smith2020}\end{document}'
            $ast  = Invoke-LaTeXParse -Source $src
            $para = $ast.Children | Where-Object { $_.Type -eq 'Paragraph' }
            $cite = $para.Children | Where-Object { $_.Type -eq 'Cite' }
            $cite.Keys | Should -Contain 'smith2020'
        }
    }

    Context 'Environments' {
        It 'parses abstract environment' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{abstract}
This is an abstract.
\end{abstract}
\end{document}
'@
            $ast  = Invoke-LaTeXParse -Source $src
            $abs  = $ast.Children | Where-Object { $_.Type -eq 'Abstract' }
            $abs | Should -Not -BeNullOrEmpty
        }

        It 'parses verbatim environment' {
            $src = @'
\documentclass{article}
\begin{document}
\begin{verbatim}
some code here
\end{verbatim}
\end{document}
'@
            $ast  = Invoke-LaTeXParse -Source $src
            $verb = $ast.Children | Where-Object { $_.Type -eq 'Verbatim' }
            $verb | Should -Not -BeNullOrEmpty
            $verb.Content | Should -Match 'some code here'
        }
    }
}

# ── Convert-LaTeXToXML tests ──────────────────────────────────────────────────
Describe 'Convert-LaTeXToXML' {

    It 'returns a string' {
        $src = '\documentclass{article}\begin{document}Hello\end{document}'
        $result = Convert-LaTeXToXML -Source $src
        $result | Should -BeOfType [string]
    }

    It 'produces valid XML' {
        $src = '\documentclass{article}\begin{document}Hello\end{document}'
        $xml = Convert-LaTeXToXML -Source $src
        { [xml]$xml } | Should -Not -Throw
    }

    It 'contains the LaTeXML namespace' {
        $src = '\documentclass{article}\begin{document}Hello\end{document}'
        $xml = Convert-LaTeXToXML -Source $src
        $xml | Should -Match 'dlmf.nist.gov/LaTeXML'
    }

    It 'indents output when -Indent is given' {
        $src = '\documentclass{article}\begin{document}Hello\end{document}'
        $xml = Convert-LaTeXToXML -Source $src -Indent
        $xml | Should -Match "`n"
    }

    It 'includes the document title in XML' {
        $src = @'
\documentclass{article}
\title{Test Title}
\begin{document}
\maketitle
\end{document}
'@
        $xml = Convert-LaTeXToXML -Source $src
        $xml | Should -Match 'Test Title'
    }

    It 'writes to a file when -OutputPath is specified' {
        $src  = '\documentclass{article}\begin{document}Hello\end{document}'
        $tmp  = [System.IO.Path]::GetTempFileName() + '.xml'
        Convert-LaTeXToXML -Source $src -OutputPath $tmp
        Test-Path $tmp | Should -Be $true
        $content = Get-Content $tmp -Raw
        $content | Should -Match 'dlmf.nist.gov/LaTeXML'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }

    It 'accepts pipeline input' {
        $xml = '\documentclass{article}\begin{document}Pipeline\end{document}' | Convert-LaTeXToXML
        $xml | Should -Match 'Pipeline'
    }
}

# ── Convert-LaTeXToHTML tests ─────────────────────────────────────────────────
Describe 'Convert-LaTeXToHTML' {

    It 'returns a string' {
        $src  = '\documentclass{article}\begin{document}Hello\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -BeOfType [string]
    }

    It 'produces an HTML5 doctype' {
        $src  = '\documentclass{article}\begin{document}Hello\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<!DOCTYPE html>'
    }

    It 'includes a <title> element' {
        $src = @'
\documentclass{article}
\title{My Document}
\begin{document}
\maketitle
\end{document}
'@
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<title>My Document</title>'
    }

    It 'renders \textbf as <strong>' {
        $src  = '\documentclass{article}\begin{document}\textbf{bold}\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<strong>bold</strong>'
    }

    It 'renders \textit as <em>' {
        $src  = '\documentclass{article}\begin{document}\textit{italic}\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<em>italic</em>'
    }

    It 'renders \texttt as <code>' {
        $src  = '\documentclass{article}\begin{document}\texttt{mono}\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<code>mono</code>'
    }

    It 'renders inline math in a span' {
        $src  = '\documentclass{article}\begin{document}$x^2$\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match 'math-inline'
    }

    It 'renders section as h2' {
        $src = @'
\documentclass{article}
\begin{document}
\section{Introduction}
Text.
\end{document}
'@
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<h2'
        $html | Should -Match 'Introduction'
    }

    It 'renders itemize as <ul>' {
        $src = @'
\documentclass{article}
\begin{document}
\begin{itemize}
  \item Alpha
  \item Beta
\end{itemize}
\end{document}
'@
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<ul>'
        $html | Should -Match '<li>'
    }

    It 'renders enumerate as <ol>' {
        $src = @'
\documentclass{article}
\begin{document}
\begin{enumerate}
  \item One
  \item Two
\end{enumerate}
\end{document}
'@
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<ol>'
    }

    It 'renders verbatim as <pre><code>' {
        $src = @'
\documentclass{article}
\begin{document}
\begin{verbatim}
code block
\end{verbatim}
\end{document}
'@
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '<pre>'
        $html | Should -Match '<code>'
    }

    It 'writes to a file when -OutputPath is specified' {
        $src = '\documentclass{article}\begin{document}Hello\end{document}'
        $tmp = [System.IO.Path]::GetTempFileName() + '.html'
        Convert-LaTeXToHTML -Source $src -OutputPath $tmp
        Test-Path $tmp | Should -Be $true
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }

    It 'accepts pipeline input' {
        $html = '\documentclass{article}\begin{document}Pipeline\end{document}' | Convert-LaTeXToHTML
        $html | Should -Match 'Pipeline'
    }

    It 'respects custom -CssClass' {
        $src  = '\documentclass{article}\begin{document}X\end{document}'
        $html = Convert-LaTeXToHTML -Source $src -CssClass 'my-class'
        $html | Should -Match 'class="my-class"'
    }

    It 'HTML-encodes special characters in text content' {
        $src  = '\documentclass{article}\begin{document}a \& b\end{document}'
        $html = Convert-LaTeXToHTML -Source $src
        $html | Should -Match '&amp;'
    }
}

# ── Convert-LaTeXMath tests ───────────────────────────────────────────────────
Describe 'Convert-LaTeXMath' {

    It 'returns the expression as Text by default' {
        $out = Convert-LaTeXMath -Expression '\frac{1}{2}'
        $out | Should -Be '\frac{1}{2}'
    }

    It 'strips surrounding $ delimiters' {
        $out = Convert-LaTeXMath -Expression '$x^2$'
        $out | Should -Be 'x^2'
    }

    It 'strips surrounding $$ delimiters' {
        $out = Convert-LaTeXMath -Expression '$$E=mc^2$$'
        $out | Should -Be 'E=mc^2'
    }

    It 'strips surrounding \[...\] delimiters' {
        $out = Convert-LaTeXMath -Expression '\[E=mc^2\]'
        $out | Should -Be 'E=mc^2'
    }

    It 'returns XML format' {
        $out = Convert-LaTeXMath -Expression 'x+y' -Format XML
        $out | Should -Match 'Math'
        $out | Should -Match 'dlmf.nist.gov/LaTeXML'
    }

    It 'XML output contains mode="display" by default' {
        $out = Convert-LaTeXMath -Expression 'x' -Format XML
        $out | Should -Match 'mode="display"'
    }

    It 'XML output contains mode="inline" when DisplayMode is false' {
        $out = Convert-LaTeXMath -Expression 'x' -Format XML -DisplayMode $false
        $out | Should -Match 'mode="inline"'
    }

    It 'returns HTML format with math-display class' {
        $out = Convert-LaTeXMath -Expression '\pi' -Format HTML
        $out | Should -Match 'math-display'
    }

    It 'returns HTML format with math-inline class when DisplayMode false' {
        $out = Convert-LaTeXMath -Expression '\pi' -Format HTML -DisplayMode $false
        $out | Should -Match 'math-inline'
    }

    It 'returns MathML format' {
        $out = Convert-LaTeXMath -Expression 'x' -Format MathML
        $out | Should -Match '<math'
        $out | Should -Match 'MathML'
    }

    It 'accepts pipeline input' {
        $out = '\alpha' | Convert-LaTeXMath
        $out | Should -Be '\alpha'
    }
}

# ── Integration test ──────────────────────────────────────────────────────────
Describe 'Integration: Full document round-trip' {

    BeforeAll {
        $FullDoc = @'
\documentclass[12pt]{article}
\usepackage{amsmath}
\usepackage{graphicx}
\title{A Sample Paper}
\author{Alice Smith}
\date{March 2024}
\begin{document}
\maketitle
\tableofcontents
\begin{abstract}
This paper demonstrates the PSLaTeXML converter.
\end{abstract}
\section{Introduction}
\label{sec:intro}
LaTeX\footnote{A typesetting system.} is widely used in academia.
Inline math: $E = mc^2$.
Display math:
$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$
\section{Results}
See \ref{sec:intro} and \cite{doe2023}.
\begin{equation}
F = ma
\end{equation}
\begin{itemize}
  \item First result
  \item Second result: $a > b$
\end{itemize}
\begin{tabular}{|l|r|}
\hline
Name & Value \\
\hline
Alpha & 1 \\
Beta & 2 \\
\hline
\end{tabular}
\end{document}
'@
    }

    It 'produces valid XML for a full document' {
        $xml = Convert-LaTeXToXML -Source $FullDoc
        { [xml]$xml } | Should -Not -Throw
    }

    It 'XML contains the title' {
        $xml = Convert-LaTeXToXML -Source $FullDoc
        $xml | Should -Match 'A Sample Paper'
    }

    It 'XML contains the author' {
        $xml = Convert-LaTeXToXML -Source $FullDoc
        $xml | Should -Match 'Alice Smith'
    }

    It 'XML contains Math element' {
        $xml = Convert-LaTeXToXML -Source $FullDoc
        $xml | Should -Match 'Math'
    }

    It 'produces an HTML page for a full document' {
        $html = Convert-LaTeXToHTML -Source $FullDoc
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'A Sample Paper'
        $html | Should -Match 'Introduction'
        $html | Should -Match 'Results'
    }
}
