#!/usr/bin/env python3
"""Build docs/Getting-Started.docx from docs/Getting-Started.md.

Usage:  python3 tools/build_getting_started.py
Needs:  python-docx  (pip install python-docx)
Then:   soffice --headless --convert-to pdf --outdir docs docs/Getting-Started.docx

The Markdown file is the source. It may use: # ## ### headings, paragraphs,
- bullets, 1. numbered steps, ``` code blocks, | tables |, > call-outs, and
`code` / **bold** inside text. Nothing else is understood.
"""
import os
import re
import sys

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'docs', 'Getting-Started.md')
OUT = os.path.join(ROOT, 'docs', 'Getting-Started.docx')

BODY_FONT = 'Arial'
CODE_FONT = 'Courier New'
NAVY = RGBColor(0x0B, 0x3D, 0x66)
GREY = RGBColor(0x55, 0x55, 0x55)
PAGE_WIDTH_IN = 6.5          # Letter, 1 inch margins


def read_version():
    path = os.path.join(ROOT, 'FleetDeploy', 'Invoke-AccessConnectorUpgrade.ps1')
    m = re.search(r"\$script:Version\s*=\s*'([^']+)'", open(path, encoding='ascii').read())
    return m.group(1) if m else '?'


# ------------------------------------------------------------ low-level XML
def shade(paragraph, fill):
    ppr = paragraph._p.get_or_add_pPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    ppr.append(shd)


def border(paragraph, side, color, size=18, space=6):
    ppr = paragraph._p.get_or_add_pPr()
    pbdr = ppr.find(qn('w:pBdr'))
    if pbdr is None:
        pbdr = OxmlElement('w:pBdr')
        ppr.append(pbdr)
    el = OxmlElement('w:' + side)
    el.set(qn('w:val'), 'single')
    el.set(qn('w:sz'), str(size))
    el.set(qn('w:space'), str(space))
    el.set(qn('w:color'), color)
    pbdr.append(el)


def shade_cell(cell, fill):
    tcpr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    tcpr.append(shd)


def cell_margins(table, top=60, bottom=60, left=100, right=100):
    tblpr = table._tbl.tblPr
    mar = OxmlElement('w:tblCellMar')
    for side, val in (('top', top), ('left', left), ('bottom', bottom), ('right', right)):
        el = OxmlElement('w:' + side)
        el.set(qn('w:w'), str(val))
        el.set(qn('w:type'), 'dxa')
        mar.append(el)
    tblpr.append(mar)


def repeat_header(row):
    trpr = row._tr.get_or_add_trPr()
    el = OxmlElement('w:tblHeader')
    el.set(qn('w:val'), 'true')
    trpr.append(el)


def no_split(row):
    trpr = row._tr.get_or_add_trPr()
    trpr.append(OxmlElement('w:cantSplit'))


def add_field(paragraph, instr, style=None):
    # A complete field (begin, instruction, separate, result, end), each part in its own run and
    # each formatted by style(run), so every viewer shows the result in the same colour and font.
    runs = []
    for kind, text in (('begin', None), ('instr', instr), ('separate', None), ('result', '1'), ('end', None)):
        run = paragraph.add_run()
        if kind == 'result':
            run.text = text
        elif kind == 'instr':
            el = OxmlElement('w:instrText')
            el.set(qn('xml:space'), 'preserve')
            el.text = text
            run._r.append(el)
        else:
            el = OxmlElement('w:fldChar')
            el.set(qn('w:fldCharType'), kind)
            run._r.append(el)
        if style:
            style(run)
        runs.append(run)
    return runs[-1]


def set_font(run, name, size=None, bold=None, color=None, italic=None):
    run.font.name = name
    rpr = run._r.get_or_add_rPr()
    rfonts = rpr.find(qn('w:rFonts'))
    if rfonts is None:
        rfonts = OxmlElement('w:rFonts')
        rpr.append(rfonts)
    for attr in ('w:ascii', 'w:hAnsi', 'w:cs', 'w:eastAsia'):
        rfonts.set(qn(attr), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if italic is not None:
        run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color


# --------------------------------------------------------------- inline text
INLINE = re.compile(r'(\*\*.+?\*\*|`[^`]+`)')


def add_inline(paragraph, text, size=11, color=None, bold=False):
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith('**') and part.endswith('**'):
            set_font(paragraph.add_run(part[2:-2]), BODY_FONT, size, True, color)
        elif part.startswith('`') and part.endswith('`'):
            set_font(paragraph.add_run(part[1:-1]), CODE_FONT, size - 1, bold, color or RGBColor(0x1F, 0x2D, 0x3D))
        else:
            set_font(paragraph.add_run(part), BODY_FONT, size, bold, color)


def plain_len(text):
    return len(re.sub(r'[`*]', '', text))


# ------------------------------------------------------------------- blocks
def spacing(paragraph, before=0, after=6, line=1.15, keep_next=False, keep_lines=False):
    pf = paragraph.paragraph_format
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.line_spacing = line
    pf.keep_with_next = keep_next
    pf.keep_together = keep_lines


def add_heading(doc, text, level):
    p = doc.add_heading(level=level)
    size = {1: 16, 2: 12.5}[level]
    set_font(p.add_run(text), BODY_FONT, size, True, NAVY)
    spacing(p, before={1: 18, 2: 12}[level], after={1: 6, 2: 4}[level], line=1.0, keep_next=True)
    if level == 1:
        border(p, 'bottom', 'C9D3DC', size=6, space=3)
    return p


def add_paragraph(doc, text):
    p = doc.add_paragraph()
    add_inline(p, text)
    spacing(p)
    return p


def add_bullet(doc, text):
    p = doc.add_paragraph(style='List Bullet')
    add_inline(p, text)
    spacing(p, after=3)
    return p


def add_step(doc, number, text):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.left_indent = Inches(0.3)
    pf.first_line_indent = Inches(-0.3)
    pf.tab_stops.add_tab_stop(Inches(0.3))
    set_font(p.add_run('%s.\t' % number), BODY_FONT, 11, True, NAVY)
    add_inline(p, text)
    spacing(p, after=3)
    return p


def add_callout(doc, text):
    p = doc.add_paragraph()
    add_inline(p, text, size=10.5)
    shade(p, 'F5F9FD')
    border(p, 'left', '0B3D66', size=24, space=8)
    pf = p.paragraph_format
    pf.left_indent = Inches(0.15)
    pf.right_indent = Inches(0.1)
    spacing(p, before=4, after=8, keep_lines=True)
    return p


RED = RGBColor(0xC0, 0x00, 0x00)


def add_disclaimer(doc, paras):
    # The tool's legal disclaimer: a white-on-red title bar, as in -Help, then the text in red.
    title, body = paras[0], paras[1:]
    p = doc.add_paragraph()
    set_font(p.add_run(' ' + title.strip('*').strip() + ' '), BODY_FONT, 10.5, True, RGBColor(0xFF, 0xFF, 0xFF))
    shade(p, 'C00000')
    spacing(p, before=10, after=4, line=1.0, keep_next=True)
    for i, t in enumerate(body):
        q = doc.add_paragraph()
        add_inline(q, t, size=9.5, color=RED)
        border(q, 'left', 'C00000', size=24, space=8)
        q.paragraph_format.left_indent = Inches(0.15)
        spacing(q, after=4 if i < len(body) - 1 else 12, line=1.1, keep_next=(i < len(body) - 1), keep_lines=True)


def add_code(doc, lines):
    last = len(lines) - 1
    for i, line in enumerate(lines):
        p = doc.add_paragraph()
        set_font(p.add_run(line if line else ' '), CODE_FONT, 9, False, RGBColor(0x1A, 0x1A, 0x1A))
        shade(p, 'F1F3F5')
        pf = p.paragraph_format
        pf.left_indent = Inches(0.15)
        pf.right_indent = Inches(0.1)
        spacing(p, before=4 if i == 0 else 0, after=8 if i == last else 0, line=1.1,
                keep_next=(i != last), keep_lines=True)


def add_table(doc, rows):
    header, body = rows[0], rows[1:]
    ncol = len(header)
    # column widths from content, within limits, scaled to the page width
    weights = []
    for c in range(ncol):
        longest = max(plain_len(r[c]) for r in rows if c < len(r))
        weights.append(min(max(longest, 9), 60))
    total = float(sum(weights))
    widths = [PAGE_WIDTH_IN * w / total for w in weights]
    low = 1.05
    short = [i for i, w in enumerate(widths) if w < low]
    if short and len(short) < ncol:
        need = sum(low - widths[i] for i in short)
        rest = sum(widths[i] for i in range(ncol) if i not in short)
        widths = [low if i in short else widths[i] - need * widths[i] / rest for i in range(ncol)]

    table = doc.add_table(rows=1, cols=ncol)
    table.style = 'Table Grid'
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    cell_margins(table)
    for c, text in enumerate(header):
        cell = table.rows[0].cells[c]
        cell.width = Inches(widths[c])
        shade_cell(cell, '0B3D66')
        p = cell.paragraphs[0]
        add_inline(p, text, size=10, color=RGBColor(0xFF, 0xFF, 0xFF), bold=True)
        spacing(p, after=0, line=1.05)
    repeat_header(table.rows[0])
    for n, r in enumerate(body):
        row = table.add_row()
        no_split(row)
        for c in range(ncol):
            cell = row.cells[c]
            cell.width = Inches(widths[c])
            if n % 2:
                shade_cell(cell, 'F7FAFC')
            p = cell.paragraphs[0]
            add_inline(p, r[c] if c < len(r) else '', size=10)
            spacing(p, after=0, line=1.05)
    gap = doc.add_paragraph()
    spacing(gap, after=4, line=0.6)


# ------------------------------------------------------------------ parsing
def parse(md):
    lines = md.split('\n')
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.strip() == '<!-- disclaimer -->':
            # > [!CAUTION] block between the markers: one paragraph per blank '>' line
            i += 1
            paras, cur = [], []
            while i < n and lines[i].strip() != '<!-- /disclaimer -->':
                t = lines[i].lstrip('>').strip()
                if t == '[!CAUTION]':
                    pass
                elif t:
                    cur.append(t)
                elif cur:
                    paras.append(' '.join(cur)); cur = []
                i += 1
            if cur:
                paras.append(' '.join(cur))
            i += 1
            yield ('disclaimer', paras)
            continue
        if line.startswith('<!--'):
            i += 1
            continue
        if line.startswith('```'):
            i += 1
            code = []
            while i < n and not lines[i].startswith('```'):
                code.append(lines[i])
                i += 1
            i += 1
            yield ('code', code)
            continue
        m = re.match(r'^(#{1,3}) (.*)$', line)
        if m:
            yield ('h%d' % len(m.group(1)), m.group(2).strip())
            i += 1
            continue
        if line.startswith('|'):
            rows = []
            while i < n and lines[i].startswith('|'):
                cells = [c.strip() for c in lines[i].strip().strip('|').split('|')]
                if not all(re.match(r'^:?-+:?$', c) for c in cells):
                    rows.append(cells)
                i += 1
            yield ('table', rows)
            continue
        if line.startswith('> '):
            buf = []
            while i < n and lines[i].startswith('>'):
                buf.append(lines[i][1:].strip())
                i += 1
            yield ('callout', ' '.join(buf))
            continue
        m = re.match(r'^(\d+)\. (.*)$', line)
        if m:
            yield ('step', (m.group(1), m.group(2)))
            i += 1
            continue
        if line.startswith('- '):
            yield ('bullet', line[2:])
            i += 1
            continue
        buf = [line]
        i += 1
        while i < n and lines[i].strip() and not re.match(r'^(#{1,3} |\||> |- |\d+\. |```)', lines[i]):
            buf.append(lines[i])
            i += 1
        yield ('para', ' '.join(buf))


# --------------------------------------------------------------------- main
def build():
    version = read_version()
    doc = Document()

    sec = doc.sections[0]
    sec.page_width, sec.page_height = Inches(8.5), Inches(11)
    for side in ('left_margin', 'right_margin', 'top_margin', 'bottom_margin'):
        setattr(sec, side, Inches(1))

    normal = doc.styles['Normal']
    normal.font.name = BODY_FONT
    normal.font.size = Pt(11)
    normal.element.rPr.rFonts.set(qn('w:eastAsia'), BODY_FONT)

    zoom = doc.settings.element.find(qn('w:zoom'))
    if zoom is not None:
        zoom.set(qn('w:percent'), '100')

    doc.core_properties.title = 'Access Connector Automated Upgrade - Getting Started'
    doc.core_properties.subject = 'Getting started guide'
    doc.core_properties.author = 'Access Connector Automated Upgrade'
    doc.core_properties.keywords = 'Omnissa Access Connector upgrade install SSH WinRM'

    # footer: document name left, page number right
    fp = sec.footer.paragraphs[0]
    fp.paragraph_format.tab_stops.add_tab_stop(Inches(PAGE_WIDTH_IN), WD_ALIGN_PARAGRAPH.RIGHT)
    set_font(fp.add_run('Access Connector Automated Upgrade  |  Getting Started  |  v%s\t' % version), BODY_FONT, 8.5, False, GREY)
    set_font(fp.add_run('Page '), BODY_FONT, 8.5, False, GREY)
    add_field(fp, 'PAGE', lambda r: set_font(r, BODY_FONT, 8.5, False, GREY))

    blocks = list(parse(open(SRC, encoding='utf-8').read()))
    sections = [b[1] for b in blocks if b[0] == 'h2']
    first_h2_seen = False

    for kind, data in blocks:
        if kind == 'h1':
            p = doc.add_paragraph()
            set_font(p.add_run('Access Connector Automated Upgrade'), BODY_FONT, 12, True, GREY)
            spacing(p, after=2, line=1.0)
            p = doc.add_paragraph()
            set_font(p.add_run(data), BODY_FONT, 28, True, NAVY)
            spacing(p, after=4, line=1.0)
            border(p, 'bottom', '0B3D66', size=18, space=6)
            p = doc.add_paragraph()
            set_font(p.add_run('Install, upgrade and repair Omnissa Access Connectors  |  tool version %s' % version), BODY_FONT, 10, False, GREY)
            spacing(p, before=4, after=12, line=1.0)
        elif kind == 'h2':
            if not first_h2_seen:
                first_h2_seen = True
                # contents, placed before the first section
                p = doc.add_paragraph()
                set_font(p.add_run('In this guide'), BODY_FONT, 12.5, True, NAVY)
                spacing(p, before=8, after=4, line=1.0, keep_next=True)
                for s in sections:
                    q = doc.add_paragraph()
                    set_font(q.add_run(s), BODY_FONT, 10.5, False, RGBColor(0x1A, 0x1A, 0x1A))
                    q.paragraph_format.left_indent = Inches(0.2)
                    spacing(q, after=1, line=1.05)
                doc.add_page_break()
            add_heading(doc, data, 1)
        elif kind == 'h3':
            add_heading(doc, data, 2)
        elif kind == 'para':
            add_paragraph(doc, data)
        elif kind == 'bullet':
            add_bullet(doc, data)
        elif kind == 'step':
            add_step(doc, data[0], data[1])
        elif kind == 'callout':
            add_callout(doc, data)
        elif kind == 'disclaimer':
            add_disclaimer(doc, data)
        elif kind == 'code':
            add_code(doc, data)
        elif kind == 'table':
            add_table(doc, data)

    doc.save(OUT)
    print('wrote', OUT)


if __name__ == '__main__':
    sys.exit(build())
