# Private/Serializer.ps1
# Serializes an AST (produced by Parser.ps1) to either:
#   • LaTeXML-flavoured XML (namespace http://dlmf.nist.gov/LaTeXML)
#   • XHTML / HTML5

# ── XML serializer ────────────────────────────────────────────────────────────

function ConvertTo-LaTeXMLXml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Ast,
        [switch] $Indent
    )

    $xdoc = [System.Xml.XmlDocument]::new()
    $null  = $xdoc.AppendChild($xdoc.CreateXmlDeclaration('1.0', 'UTF-8', $null))
    $ns    = 'http://dlmf.nist.gov/LaTeXML'

    $root = $xdoc.CreateElement('document', $ns)
    $root.SetAttribute('class',   'ltx_document')
    $root.SetAttribute('version', '0.8.8')
    $null = $xdoc.AppendChild($root)

    # Metadata
    if ($Ast.Title) {
        $titleEl = $xdoc.CreateElement('title', $ns)
        $null = $titleEl.AppendChild($xdoc.CreateTextNode($Ast.Title))
        $null = $root.PrependChild($titleEl)
    }
    if ($Ast.Author) {
        $authEl = $xdoc.CreateElement('creator', $ns)
        $authEl.SetAttribute('role', 'author')
        $pEl    = $xdoc.CreateElement('personname', $ns)
        $null = $pEl.AppendChild($xdoc.CreateTextNode($Ast.Author))
        $null = $authEl.AppendChild($pEl)
        $null = $root.AppendChild($authEl)
    }
    if ($Ast.Date) {
        $dateEl = $xdoc.CreateElement('date', $ns)
        $null = $dateEl.AppendChild($xdoc.CreateTextNode($Ast.Date))
        $null = $root.AppendChild($dateEl)
    }

    # Body
    foreach ($child in $Ast.Children) {
        $el = ConvertNode-ToXml -Xdoc $xdoc -Ns $ns -Node $child
        if ($el) { $null = $root.AppendChild($el) }
    }

    if ($Indent) {
        $sw  = [System.IO.StringWriter]::new()
        $xtw = [System.Xml.XmlTextWriter]::new($sw)
        $xtw.Formatting  = [System.Xml.Formatting]::Indented
        $xtw.Indentation = 2
        $xdoc.WriteTo($xtw)
        $xtw.Flush()
        return $sw.ToString()
    }

    return $xdoc.OuterXml
}

function ConvertNode-ToXml {
    param(
        [System.Xml.XmlDocument] $Xdoc,
        [string]                 $Ns,
        [PSCustomObject]         $Node
    )

    if (-not $Node) { return $null }

    switch ($Node.Type) {

        'Section' {
            $el = $Xdoc.CreateElement('section', $Ns)
            $el.SetAttribute('xml:id', $Node.Id)
            $el.SetAttribute('class', "ltx_section")
            # Title
            $titleEl = $Xdoc.CreateElement('title', $Ns)
            foreach ($tc in $Node.Title) {
                $tn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $tc
                if ($tn) { $null = $titleEl.AppendChild($tn) }
                elseif ($tc.Type -eq 'Text') { $null = $titleEl.AppendChild($Xdoc.CreateTextNode($tc.Content)) }
            }
            $null = $el.AppendChild($titleEl)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Paragraph' {
            $el = $Xdoc.CreateElement('para', $Ns)
            $el.SetAttribute('xml:id', $Node.Id)
            $p = $Xdoc.CreateElement('p', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $p.AppendChild($cn) }
            }
            $null = $el.AppendChild($p)
            return $el
        }

        'Text' {
            return $Xdoc.CreateTextNode($Node.Content)
        }

        'Format' {
            $tag   = switch ($Node.Style) {
                'bold'       { 'text' }; 'italic'    { 'text' }; 'monospace'  { 'text' }
                'smallcaps'  { 'text' }; 'underline' { 'text' }; 'roman'      { 'text' }
                'sans'       { 'text' }; default      { 'text' }
            }
            $el = $Xdoc.CreateElement($tag, $Ns)
            $el.SetAttribute('font', $Node.Style)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Math' {
            $el = $Xdoc.CreateElement('Math', $Ns)
            $el.SetAttribute('mode', $(if ($Node.Display) { 'display' } else { 'inline' }))
            $el.SetAttribute('tex',  $Node.Content)
            $null = $el.AppendChild($Xdoc.CreateTextNode($Node.Content))
            return $el
        }

        'Equation' {
            $el = $Xdoc.CreateElement('equation', $Ns)
            if ($Node.Starred) { $el.SetAttribute('class', 'ltx_eqn_unnumbered') }
            $math = $Xdoc.CreateElement('Math', $Ns)
            $math.SetAttribute('mode', 'display')
            $math.SetAttribute('tex',  $Node.Content)
            $null = $math.AppendChild($Xdoc.CreateTextNode($Node.Content))
            $null = $el.AppendChild($math)
            return $el
        }

        'Align' {
            $el = $Xdoc.CreateElement('equationgroup', $Ns)
            if ($Node.Starred) { $el.SetAttribute('class', 'ltx_eqn_unnumbered') }
            $math = $Xdoc.CreateElement('Math', $Ns)
            $math.SetAttribute('mode', 'display')
            $math.SetAttribute('tex',  $Node.Content)
            $null = $math.AppendChild($Xdoc.CreateTextNode($Node.Content))
            $null = $el.AppendChild($math)
            return $el
        }

        'Gather' {
            $el = $Xdoc.CreateElement('equationgroup', $Ns)
            $math = $Xdoc.CreateElement('Math', $Ns)
            $math.SetAttribute('mode', 'display')
            $math.SetAttribute('tex',  $Node.Content)
            $null = $math.AppendChild($Xdoc.CreateTextNode($Node.Content))
            $null = $el.AppendChild($math)
            return $el
        }

        'List' {
            $tag = switch ($Node.Style) { 'bullet' { 'itemize' }; 'ordered' { 'enumerate' }; default { 'description' } }
            $el  = $Xdoc.CreateElement($tag, $Ns)
            foreach ($item in $Node.Children) {
                $ie = $Xdoc.CreateElement('item', $Ns)
                if ($item.Label) {
                    $tagEl = $Xdoc.CreateElement('tag', $Ns)
                    $null = $tagEl.AppendChild($Xdoc.CreateTextNode($item.Label))
                    $null = $ie.AppendChild($tagEl)
                }
                foreach ($c in $item.Children) {
                    $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                    if ($cn) { $null = $ie.AppendChild($cn) }
                }
                $null = $el.AppendChild($ie)
            }
            return $el
        }

        'Tabular' {
            $el = $Xdoc.CreateElement('tabular', $Ns)
            $el.SetAttribute('columnspec', $Node.Spec)
            foreach ($row in $Node.Rows) {
                $re = $Xdoc.CreateElement('tr', $Ns)
                foreach ($cell in $row) {
                    $ce = $Xdoc.CreateElement('td', $Ns)
                    if ($cell.Span -gt 1) { $ce.SetAttribute('colspan', [string]$cell.Span) }
                    foreach ($c in $cell.Children) {
                        $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                        if ($cn) { $null = $ce.AppendChild($cn) }
                    }
                    $null = $re.AppendChild($ce)
                }
                $null = $el.AppendChild($re)
            }
            return $el
        }

        'Figure' {
            $el = $Xdoc.CreateElement('figure', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Table' {
            $el = $Xdoc.CreateElement('table', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Caption' {
            $el = $Xdoc.CreateElement('caption', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Image' {
            $el = $Xdoc.CreateElement('graphics', $Ns)
            $el.SetAttribute('graphic', $Node.File)
            return $el
        }

        'Verbatim' {
            $el = $Xdoc.CreateElement('verbatim', $Ns)
            $null = $el.AppendChild($Xdoc.CreateTextNode($Node.Content))
            return $el
        }

        'CodeBlock' {
            $el = $Xdoc.CreateElement('listing', $Ns)
            if ($Node.Language) { $el.SetAttribute('language', $Node.Language) }
            $null = $el.AppendChild($Xdoc.CreateTextNode($Node.Content))
            return $el
        }

        'Quote' {
            $el = $Xdoc.CreateElement('quote', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Center' {
            $el = $Xdoc.CreateElement('block', $Ns)
            $el.SetAttribute('class', 'ltx_centering')
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Abstract' {
            $el = $Xdoc.CreateElement('abstract', $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Theorem' {
            $el = $Xdoc.CreateElement('theorem', $Ns)
            $el.SetAttribute('class', "ltx_$($Node.EnvName)")
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'Label' {
            $el = $Xdoc.CreateElement('label', $Ns)
            $el.SetAttribute('xml:id', $Node.Id)
            return $el
        }

        'Ref' {
            $el = $Xdoc.CreateElement('ref', $Ns)
            $el.SetAttribute('labelref', $Node.Id)
            return $el
        }

        'Cite' {
            $el = $Xdoc.CreateElement('cite', $Ns)
            $el.SetAttribute('key', ($Node.Keys -join ','))
            return $el
        }

        'Footnote' {
            $el = $Xdoc.CreateElement('note', $Ns)
            $el.SetAttribute('role', 'footnote')
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'URL' {
            $el = $Xdoc.CreateElement('ref', $Ns)
            $el.SetAttribute('href', $Node.Href)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        'LineBreak' {
            return $Xdoc.CreateElement('break', $Ns)
        }

        'ParBreak' {
            return $null
        }

        'Maketitle' {
            $el = $Xdoc.CreateElement('maketitle', $Ns)
            return $el
        }

        'TableOfContents' {
            $el = $Xdoc.CreateElement('tableofcontents', $Ns)
            return $el
        }

        'Environment' {
            $el = $Xdoc.CreateElement($Node.Name, $Ns)
            foreach ($c in $Node.Children) {
                $cn = ConvertNode-ToXml -Xdoc $Xdoc -Ns $Ns -Node $c
                if ($cn) { $null = $el.AppendChild($cn) }
            }
            return $el
        }

        default { return $null }
    }
}

# ── HTML serializer ───────────────────────────────────────────────────────────

function ConvertTo-LaTeXMLHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Ast,
        [string] $CssClass = 'latexml'
    )

    $sb = [System.Text.StringBuilder]::new()

    $null = $sb.Append('<!DOCTYPE html>')
    $null = $sb.Append("`n<html lang=`"en`">")
    $null = $sb.Append("`n<head>")
    $null = $sb.Append("`n  <meta charset=`"UTF-8`">")
    $null = $sb.Append("`n  <meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">")

    $titleText = if ($Ast.Title) { [System.Web.HttpUtility]::HtmlEncode($Ast.Title) } else { 'Document' }
    $null = $sb.Append("`n  <title>$titleText</title>")
    $null = $sb.Append("`n  <style>")
    $null = $sb.Append("`n    body { font-family: serif; max-width: 860px; margin: 2em auto; padding: 0 1em; line-height: 1.6; }")
    $null = $sb.Append("`n    h1,h2,h3,h4,h5,h6 { font-family: sans-serif; }")
    $null = $sb.Append("`n    pre, code { background: #f4f4f4; padding: 0.2em 0.4em; border-radius: 3px; }")
    $null = $sb.Append("`n    pre { padding: 1em; overflow-x: auto; }")
    $null = $sb.Append("`n    table { border-collapse: collapse; } td,th { border: 1px solid #ccc; padding: 0.3em 0.6em; }")
    $null = $sb.Append("`n    blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 1em; color: #555; }")
    $null = $sb.Append("`n    .math-display { display: block; text-align: center; margin: 1em 0; font-style: italic; }")
    $null = $sb.Append("`n    .math-inline { font-style: italic; }")
    $null = $sb.Append("`n    .abstract { border: 1px solid #ccc; padding: 1em; margin: 1em 0; background: #fafafa; }")
    $null = $sb.Append("`n    .theorem, .lemma, .definition, .proof { border-left: 3px solid #aaa; padding-left: 1em; margin: 1em 0; }")
    $null = $sb.Append("`n  </style>")
    $null = $sb.Append("`n</head>")
    $null = $sb.Append("`n<body class=`"$CssClass`">")

    # Title block
    if ($Ast.Title) {
        $null = $sb.Append("`n<h1 class=`"ltx_title`">$titleText</h1>")
    }
    if ($Ast.Author) {
        $null = $sb.Append("`n<div class=`"ltx_authors`"><span class=`"ltx_author`">$([System.Web.HttpUtility]::HtmlEncode($Ast.Author))</span></div>")
    }
    if ($Ast.Date) {
        $null = $sb.Append("`n<div class=`"ltx_date`">$([System.Web.HttpUtility]::HtmlEncode($Ast.Date))</div>")
    }

    foreach ($child in $Ast.Children) {
        RenderHtml-Node -Sb $sb -Node $child
    }

    $null = $sb.Append("`n</body>")
    $null = $sb.Append("`n</html>")
    return $sb.ToString()
}

function RenderHtml-Node {
    param(
        [System.Text.StringBuilder] $Sb,
        [PSCustomObject]            $Node
    )
    if (-not $Node) { return }

    switch ($Node.Type) {

        'Section' {
            $htag = switch ($Node.Level) {
                -1 { 'h1' }; 0 { 'h1' }; 1 { 'h2' }; 2 { 'h3' }; 3 { 'h4' }; 4 { 'h5' }; 5 { 'h6' }; default { 'h2' }
            }
            $id = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.Id)
            $null = $Sb.Append("`n<$htag id=`"$id`">")
            foreach ($tc in $Node.Title) { RenderHtml-Inline -Sb $Sb -Node $tc }
            $null = $Sb.Append("</$htag>")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
        }

        'Paragraph' {
            $null = $Sb.Append("`n<p>")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("</p>")
        }

        'Abstract' {
            $null = $Sb.Append("`n<div class=`"abstract`"><strong>Abstract</strong>")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("</div>")
        }

        'Maketitle' { }   # title already rendered above

        'TableOfContents' {
            $null = $Sb.Append("`n<nav class=`"toc`"><p><strong>Contents</strong></p></nav>")
        }

        'Equation' {
            $null = $Sb.Append("`n<div class=`"math-display`">")
            $null = $Sb.Append([System.Web.HttpUtility]::HtmlEncode($Node.Content))
            $null = $Sb.Append("</div>")
        }

        'Align' {
            $null = $Sb.Append("`n<div class=`"math-display`">")
            $null = $Sb.Append([System.Web.HttpUtility]::HtmlEncode($Node.Content))
            $null = $Sb.Append("</div>")
        }

        'Gather' {
            $null = $Sb.Append("`n<div class=`"math-display`">")
            $null = $Sb.Append([System.Web.HttpUtility]::HtmlEncode($Node.Content))
            $null = $Sb.Append("</div>")
        }

        'List' {
            $tag = switch ($Node.Style) { 'bullet' { 'ul' }; 'ordered' { 'ol' }; default { 'dl' } }
            $null = $Sb.Append("`n<$tag>")
            foreach ($item in $Node.Children) {
                if ($Node.Style -eq 'description' -and $item.Label) {
                    $null = $Sb.Append("`n<dt>$([System.Web.HttpUtility]::HtmlEncode($item.Label))</dt>")
                    $null = $Sb.Append("`n<dd>")
                    foreach ($c in $item.Children) { RenderHtml-Node -Sb $Sb -Node $c }
                    $null = $Sb.Append("</dd>")
                } else {
                    $null = $Sb.Append("`n<li>")
                    foreach ($c in $item.Children) {
                        if ($c.Type -eq 'Paragraph') {
                            foreach ($ic in $c.Children) { RenderHtml-Inline -Sb $Sb -Node $ic }
                        } else {
                            RenderHtml-Node -Sb $Sb -Node $c
                        }
                    }
                    $null = $Sb.Append("</li>")
                }
            }
            $null = $Sb.Append("`n</$tag>")
        }

        'Tabular' {
            $null = $Sb.Append("`n<table>")
            foreach ($row in $Node.Rows) {
                $null = $Sb.Append("`n<tr>")
                foreach ($cell in $row) {
                    $span = if ($cell.Span -gt 1) { " colspan=`"$($cell.Span)`"" } else { '' }
                    $null = $Sb.Append("<td$span>")
                    foreach ($c in $cell.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
                    $null = $Sb.Append("</td>")
                }
                $null = $Sb.Append("</tr>")
            }
            $null = $Sb.Append("`n</table>")
        }

        'Figure' {
            $null = $Sb.Append("`n<figure>")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</figure>")
        }

        'Table' {
            $null = $Sb.Append("`n<div class=`"ltx_table`">")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</div>")
        }

        'Caption' {
            $null = $Sb.Append("`n<figcaption>")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("</figcaption>")
        }

        'Image' {
            $src = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.File)
            $null = $Sb.Append("`n<img src=`"$src`" alt=`"`">")
        }

        'Verbatim' {
            $null = $Sb.Append("`n<pre><code>$([System.Web.HttpUtility]::HtmlEncode($Node.Content))</code></pre>")
        }

        'CodeBlock' {
            $langAttr = if ($Node.Language) { " class=`"language-$([System.Web.HttpUtility]::HtmlAttributeEncode($Node.Language))`"" } else { '' }
            $null = $Sb.Append("`n<pre><code$langAttr>$([System.Web.HttpUtility]::HtmlEncode($Node.Content))</code></pre>")
        }

        'Quote' {
            $null = $Sb.Append("`n<blockquote>")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</blockquote>")
        }

        'Center' {
            $null = $Sb.Append("`n<div style=`"text-align:center`">")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</div>")
        }

        'Theorem' {
            $cls = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.EnvName)
            $null = $Sb.Append("`n<div class=`"$cls`"><strong>$([System.Web.HttpUtility]::HtmlEncode($Node.EnvName))</strong> ")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</div>")
        }

        'Environment' {
            $cls = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.Name)
            $null = $Sb.Append("`n<div class=`"env-$cls`">")
            foreach ($c in $Node.Children) { RenderHtml-Node -Sb $Sb -Node $c }
            $null = $Sb.Append("`n</div>")
        }

        # Inline nodes that fall through to body level
        default { RenderHtml-Inline -Sb $Sb -Node $Node }
    }
}

function RenderHtml-Inline {
    param(
        [System.Text.StringBuilder] $Sb,
        [PSCustomObject]            $Node
    )
    if (-not $Node) { return }

    switch ($Node.Type) {
        'Text'  { $null = $Sb.Append([System.Web.HttpUtility]::HtmlEncode($Node.Content)) }

        'Format' {
            $tag = switch ($Node.Style) {
                'bold'       { 'strong' }; 'italic'    { 'em'   }; 'monospace'  { 'code'  }
                'smallcaps'  { 'span'   }; 'underline' { 'u'    }; 'roman'      { 'span'  }
                'sans'       { 'span'   }; default      { 'span' }
            }
            $style = switch ($Node.Style) {
                'smallcaps' { ' style="font-variant:small-caps"' }
                'roman'     { ' style="font-family:serif"' }
                'sans'      { ' style="font-family:sans-serif"' }
                default     { '' }
            }
            $null = $Sb.Append("<$tag$style>")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("</$tag>")
        }

        'Math' {
            $enc = [System.Web.HttpUtility]::HtmlEncode($Node.Content)
            if ($Node.Display) {
                $null = $Sb.Append("<span class=`"math-display`">$enc</span>")
            } else {
                $null = $Sb.Append("<span class=`"math-inline`">$enc</span>")
            }
        }

        'Label'    { $null = $Sb.Append("<span id=`"$([System.Web.HttpUtility]::HtmlAttributeEncode($Node.Id))`"></span>") }
        'Ref'      { $null = $Sb.Append("<a href=`"#$([System.Web.HttpUtility]::HtmlAttributeEncode($Node.Id))`">[$([System.Web.HttpUtility]::HtmlEncode($Node.Id))]</a>") }
        'Cite'     { $null = $Sb.Append("<cite>[$([System.Web.HttpUtility]::HtmlEncode($Node.Keys -join ', '))]</cite>") }
        'Footnote' {
            $null = $Sb.Append("<sup class=`"footnote`">[")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("]</sup>")
        }
        'URL' {
            $href = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.Href)
            $null = $Sb.Append("<a href=`"$href`">")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("</a>")
        }
        'LineBreak' { $null = $Sb.Append("<br>") }
        'ParBreak'  { $null = $Sb.Append("</p>`n<p>") }
        'Image'     {
            $src = [System.Web.HttpUtility]::HtmlAttributeEncode($Node.File)
            $null = $Sb.Append("<img src=`"$src`" alt=`"`">")
        }

        # Block nodes appearing inside inline context – render as block anyway
        'Paragraph' {
            $null = $Sb.Append("<p>")
            foreach ($c in $Node.Children) { RenderHtml-Inline -Sb $Sb -Node $c }
            $null = $Sb.Append("</p>")
        }
        default { }
    }
}
