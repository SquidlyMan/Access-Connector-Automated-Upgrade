#!/usr/bin/env python3
"""Build the fleet spreadsheet templates from one definition of the example rows.

Usage:  python3 tools/build_fleet_template.py [--outdir DIR]
Needs:  Python 3, standard library only (zipfile and hand-written XML).
Writes: FleetDeploy/fleet.example.csv   UTF-8 with BOM, comma, CRLF
        FleetDeploy/fleet.example.xlsx  sheets Fleet (first), Columns, Read me

The rows mean the same as the two groups in FleetDeploy/fleet.example.psd1.
The columns are the ones -ImportFleet reads and -Mode Discover writes, in the
same order. Every cell of the Fleet sheet is formatted as Text and every value
is stored as a string, so Excel never turns 26.10 into 26.1.

The output is deterministic: rebuilding without changes gives the same bytes.
"""
import argparse
import csv
import io
import os
import sys
import zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_OUTDIR = os.path.join(ROOT, 'FleetDeploy')
CSV_NAME = 'fleet.example.csv'
XLSX_NAME = 'fleet.example.xlsx'

# Fixed time for the zip entries and docProps/core.xml (deterministic output).
FIXED_ZIP_TIME = (2026, 11, 22, 0, 0, 0)
FIXED_W3C_TIME = '2026-11-22T00:00:00Z'

NAVY = 'FF0B3D66'
WHITE = 'FFFFFFFF'
TEXT_ROWS = 500          # Fleet rows 2..TEXT_ROWS are written as Text cells

# ------------------------------------------------------------------ columns
# (Column, Applies to, Required, Example, Meaning). The order is the canonical
# column order of -ImportFleet and -Mode Discover.
COLUMN_INFO = [
    ('Group', 'group', 'Yes', 'TENANT1',
     'Name of the connector group: the fleet entry Name that -Tenant selects. '
     'Rows with the same Group form one group; groups are written in the order '
     'they first appear. Letters, digits, dot, underscore and hyphen, starting '
     'with a letter or digit; case does not matter (tenant1 joins TENANT1). '
     'The header Name or Tenant is also accepted.'),
    ('Host', 'connector', 'Yes', 'connector1.example.local',
     "The server's DNS name, as you would type it for SSH or remoting. One row "
     'per connector, each host once in the sheet. Connectors of a group run one '
     'at a time, in row order. The header Connector or Server is also accepted.'),
    ('SshUser', 'connector', 'No', 'administrator',
     'SSH account for this server. Blank = administrator. -SshUser on the '
     'command line overrides it for the whole run.'),
    ('Installer', 'group', 'Yes', 'Installers\\Access-Connector-Installer.exe',
     'The connector installer to run, relative to the staging folder. It sets '
     'the version that is installed.'),
    ('InstallerVersion', 'group', 'No', '26.10.0.0',
     'The version of that installer: two to four numbers separated by dots. '
     "Passed to the wrapper's version gate. Blank = read from the installer's "
     'file name or file properties.'),
    ('ExpectVersionPrefix', 'group', 'No', '26.10',
     'Health check: the run is Unhealthy unless the installed version starts '
     'with this. When InstallerVersion is set, it must start with this too. '
     'Keep the cells formatted as Text: Excel turns 26.10 into 26.1. '
     '-Mode Discover always leaves it blank for that reason.'),
    ('ConfigFile', 'group', 'Yes', 'Configs\\tenant1-es-config.json',
     "The tenant's es-config.json, relative to the staging folder. Groups of "
     'the same Access tenant use the same file.'),
    ('Services', 'group', 'Yes',
     'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService',
     'The services to install: DirectorySyncService, UserAuthService, '
     'KerberosAuthService, VirtualAppService. Separate them with commas '
     '(semicolons, | or spaces also work), or put one per line in the cell '
     '(Alt+Enter); the word Service may be left off and case does not matter. '
     'This is the only column that may hold a line break.'),
    ('ServiceAccount', 'group', 'With Kerberos Auth or Virtual App',
     'EXAMPLE\\svc-access',
     'The domain account Kerberos Auth and Virtual App run as, DOMAIN\\name. '
     'Its password is asked at run time.'),
    ('Pfx', 'group', 'Recommended with Kerberos Auth',
     'ChildCerts\\connector.example.local.pfx',
     'The PFX the Kerberos Auth service presents, relative to the staging '
     'folder. One file for all connectors in the group, so its certificate '
     'must name each of them. Without it the installer makes a self-signed '
     'certificate. Leave it blank for a group without Kerberos Auth.'),
    ('TrustStore', 'group', 'No', 'TrustedCerts',
     'Folder of CA certificates, relative to the staging folder. Only .pem, '
     '.cer and .crt files are copied.'),
    ('Syslog', 'group', 'No', 'syslog.example.local:514',
     'Syslog target as host:port.'),
    ('ForceReinstall', 'group', 'No', 'FALSE',
     'TRUE makes every run of this group uninstall and reinstall a connector '
     "already on the installer's version. Usually FALSE or blank; give "
     '-ForceReinstall on the command line when wanted.'),
    ('InstallDir', 'group', 'No', 'D:\\Program Files',
     'Folder the connector is installed under, a full Windows path; the '
     'connector goes in <InstallDir>\\Access Connector. Blank = C:\\Program '
     'Files. An upgrade does not move an installed connector; the run warns '
     'when this names a different folder.'),
    ('EnableFips', 'group', 'No', 'FALSE',
     'TRUE installs in FIPS mode (Omnissa Access FedRAMP tenants only). FIPS '
     'mode cannot be changed after install: a run whose setting differs from '
     "the installed connector's is refused."),
    ('DirectorySyncPort', 'group', 'No', '8080',
     'Directory Sync port. Blank = 8080. A whole number from 1 to 65535; no '
     'two services may share a port.'),
    ('UserAuthPort', 'group', 'No', '8090',
     'User Auth port. Blank = 8090. A whole number from 1 to 65535; no two '
     'services may share a port.'),
    ('KerberosAuthPort', 'group', 'No', '443',
     'Kerberos Auth port, the only inbound one. Blank = 443. A whole number '
     'from 1 to 65535; no two services may share a port.'),
    ('VirtualAppPort', 'group', 'No', '8008',
     'Virtual App port. Blank = 8008. A whole number from 1 to 65535; no two '
     'services may share a port.'),
    ('ProxyHost', 'group', 'No', 'proxy.example.local',
     'Outbound proxy name or address. Setting it turns the proxy on.'),
    ('ProxyPort', 'group', 'No', '3128',
     'Proxy port. Needs ProxyHost.'),
    ('ProxyUser', 'group', 'No', 'EXAMPLE\\svc-proxy',
     'Proxy account; makes the proxy authenticated. Needs ProxyHost. Its '
     'password is asked at run time and must not contain a double quote.'),
    ('NonProxyHosts', 'group', 'No', 'host1.example.local|host2.example.local',
     'Hosts reached directly, separated by |. Needs ProxyHost.'),
    ('Notes', 'connector', 'No', 'first row of the group',
     'Free text for you. Ignored by the import, as is any column whose header '
     'starts with #. -Mode Discover fills it with what it found and what is '
     'left to fill in.'),
]
COLUMNS = [c[0] for c in COLUMN_INFO]
CANONICAL = ('Group, Host, SshUser, Installer, InstallerVersion, ExpectVersionPrefix, '
             'ConfigFile, Services, ServiceAccount, Pfx, TrustStore, Syslog, '
             'ForceReinstall, InstallDir, EnableFips, DirectorySyncPort, UserAuthPort, '
             'KerberosAuthPort, VirtualAppPort, ProxyHost, ProxyPort, ProxyUser, '
             'NonProxyHosts, Notes').split(', ')
CONNECTOR_COLUMNS = ('Host', 'SshUser', 'Notes')
BOOLEAN_COLUMNS = ('ForceReinstall', 'EnableFips')

# ------------------------------------------------------------- example rows
# The two groups of FleetDeploy/fleet.example.psd1. Group settings are repeated
# on every row of the group so a reader sees them; the import also accepts them
# blank after the first row of a group.
GROUPS = [
    {
        'Group': 'TENANT1',
        'settings': {
            'Installer': 'Installers\\Access-Connector-Installer.exe',
            'InstallerVersion': '26.10.0.0',
            'ExpectVersionPrefix': '26.10',
            'ConfigFile': 'Configs\\tenant1-es-config.json',
            'TrustStore': 'TrustedCerts',
            'Pfx': 'ChildCerts\\connector.example.local.pfx',
            'Services': 'DirectorySyncService,UserAuthService,KerberosAuthService,VirtualAppService',
            'ServiceAccount': 'EXAMPLE\\svc-access',
            'Syslog': 'syslog.example.local:514',
            'ForceReinstall': 'FALSE',
        },
        'note': ('All four services, with Kerberos Auth: needs Pfx and '
                 'ServiceAccount. Group settings may be left blank after '
                 "a group's first row."),
        'connectors': [
            {'Host': 'connector1.example.local', 'SshUser': 'administrator'},
            {'Host': 'connector2.example.local', 'SshUser': 'administrator'},
        ],
    },
    {
        'Group': 'TENANT2',
        'settings': {
            'Installer': 'Installers\\Access-Connector-Installer.exe',
            'InstallerVersion': '26.10.0.0',
            'ExpectVersionPrefix': '26.10',
            'ConfigFile': 'Configs\\tenant2-es-config.json',
            'TrustStore': 'TrustedCerts',
            'Services': 'DirectorySyncService,UserAuthService,VirtualAppService',
            'ServiceAccount': 'EXAMPLE\\svc-access',
            'ForceReinstall': 'FALSE',
        },
        'note': ('Three services, no Kerberos Auth: no Pfx. SshUser blank = '
                 'administrator.'),
        'connectors': [
            {'Host': 'connector3.example.local'},
            {'Host': 'connector4.example.local'},
        ],
    },
]

# ------------------------------------------------------------------ read me
# One row per line. ('title', text), ('text', text) or ('cmd', text).
README = [
    ('title', 'Access Connector fleet spreadsheet'),
    ('text', 'Fill this workbook in, then import it to write the fleet file '
             '(fleet.psd1) that Invoke-AccessConnectorUpgrade.ps1 runs from.'),
    ('text', ''),
    ('text', '1. On the Fleet sheet, fill in one row per connector. Replace or '
             'delete the four example rows.'),
    ('text', '2. Rows with the same Group make one connector group (one fleet '
             'entry). Group settings (every column except Host, SshUser and '
             'Notes) may be repeated on every row of the group, or left blank '
             "after the group's first row. A different value on a later row of "
             'the same group is an error.'),
    ('text', '3. Never put a password in this workbook. Passwords are asked at '
             'run time, and a column whose header looks like a password is '
             'refused.'),
    ('text', '4. Keep the Fleet sheet first: the import reads the first sheet '
             'that is not hidden, and says which sheet it read. Keep its header '
             'row. Column order does not matter, but every header must be a '
             'known column (see the Columns sheet).'),
    ('text', '5. The Fleet cells are formatted as Text, so 26.10 stays 26.10. '
             'When you paste into them, paste values only. A cell showing an '
             'Excel error such as #N/A or #REF! is refused: type the value in. '
             'Only Services may hold a line break (one service per line).'),
    ('text', '6. Save the workbook under a name of your own in the FleetDeploy '
             'folder, for example fleet.xlsx (not over fleet.example.xlsx, which '
             'is the template and is tracked by version control). As .xlsx, or as '
             'CSV UTF-8; a .csv opened again in Excel loses the Text format, so '
             'keep working in the .xlsx.'),
    ('text', '7. Check it. Nothing is written:'),
    ('cmd', 'pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx -DryRun'),
    ('text', '8. Write the fleet file: fleet.psd1 beside the script, '
             'fleet.<name>.psd1 with -Fleet <name>, or the file -FleetConfig '
             '<path> names. An existing fleet file keeps its top-level settings '
             'and is first copied to <file>.bak-<date>_<time> (a copy is never '
             'overwritten); one that holds groups is replaced only after you '
             'type YES (or with -Yes). A note names every group, connector and '
             'setting of it that the sheet would drop:'),
    ('cmd', 'pwsh ./Invoke-AccessConnectorUpgrade.ps1 -ImportFleet ./fleet.xlsx'),
    ('text', '9. Then run -Mode Verify, and a -DryRun, before any real run. The '
             'import ends by showing both commands, naming the fleet file when '
             'a run would not pick it by itself.'),
    ('text', ''),
    ('text', 'Connectors already installed? -Mode Discover reads their current '
             'settings over SSH (read-only: nothing is changed on them) and '
             'writes a draft CSV in these columns for you to complete:'),
    ('cmd', 'pwsh ./Invoke-AccessConnectorUpgrade.ps1 -Mode Discover -Connector connector1.example.local'),
    ('text', '-Connector takes a comma-separated list of hosts (with it, '
             '-Tenant has no effect). Without it, every connector in the fleet '
             'file in use is read, or those of the groups -Tenant names. The '
             'draft is FleetDeploy/fleet.discovered_<date>_<time>.csv, or the '
             'file -ExportCsv names; an existing file is never overwritten. '
             'Fill the blank cells the Notes column names, then run -ImportFleet '
             'with that file, as the commands at the end of the run show.'),
    ('text', ''),
    ('text', 'The Columns sheet explains every column.'),
]


def example_rows():
    """The example rows as lists of strings in column order."""
    rows = []
    for g in GROUPS:
        for i, conn in enumerate(g['connectors']):
            values = {'Group': g['Group']}
            values.update(g['settings'])
            values.update(conn)
            if i == 0:
                values['Notes'] = g['note']
            unknown = set(values) - set(COLUMNS)
            if unknown:
                raise SystemExit('unknown column in example rows: %s' % sorted(unknown))
            rows.append([values.get(c, '') for c in COLUMNS])
    return rows


# ---------------------------------------------------------------------- csv
def build_csv(rows):
    buf = io.StringIO(newline='')
    w = csv.writer(buf, delimiter=',', quotechar='"', quoting=csv.QUOTE_MINIMAL,
                   lineterminator='\r\n')
    w.writerow(COLUMNS)
    for r in rows:
        w.writerow(r)
    return buf.getvalue().encode('utf-8-sig')


# --------------------------------------------------------------------- xlsx
def col_letter(index):
    """0-based column index to its letters (0 -> A, 23 -> X)."""
    s = ''
    n = index + 1
    while n:
        n, rem = divmod(n - 1, 26)
        s = chr(65 + rem) + s
    return s


def attr(value):
    return escape(str(value), {'"': '&quot;'})


class SharedStrings:
    def __init__(self):
        self.index = {}
        self.items = []
        self.refs = 0

    def add(self, text):
        self.refs += 1
        if text not in self.index:
            self.index[text] = len(self.items)
            self.items.append(text)
        return self.index[text]

    def xml(self):
        out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
               '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
               ' count="%d" uniqueCount="%d">' % (self.refs, len(self.items))]
        for t in self.items:
            space = ' xml:space="preserve"' if t != t.strip() else ''
            out.append('<si><t%s>%s</t></si>' % (space, escape(t)))
        out.append('</sst>')
        return ''.join(out)


# Style indexes in cellXfs (see styles_xml).
S_DEFAULT, S_TEXT, S_HEADER, S_WRAP, S_TITLE, S_CMD = range(6)


def styles_xml():
    return ''.join([
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
        '<fonts count="4">',
        '<font><sz val="11"/><color rgb="FF000000"/><name val="Calibri"/><family val="2"/></font>',
        '<font><b/><sz val="11"/><color rgb="%s"/><name val="Calibri"/><family val="2"/></font>' % WHITE,
        '<font><b/><sz val="14"/><color rgb="%s"/><name val="Calibri"/><family val="2"/></font>' % NAVY,
        '<font><sz val="10"/><color rgb="FF000000"/><name val="Courier New"/><family val="3"/></font>',
        '</fonts>',
        '<fills count="3">',
        '<fill><patternFill patternType="none"/></fill>',
        '<fill><patternFill patternType="gray125"/></fill>',
        '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/>'
        '</patternFill></fill>' % NAVY,
        '</fills>',
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>',
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>',
        '<cellXfs count="6">',
        # 0 default
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>',
        # 1 Text (number format 49 = @)
        '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>',
        # 2 header: bold white on navy, Text
        '<xf numFmtId="49" fontId="1" fillId="2" borderId="0" xfId="0" applyNumberFormat="1"'
        ' applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>',
        # 3 wrapped Text, top aligned
        '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"'
        ' applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>',
        # 4 title
        '<xf numFmtId="49" fontId="2" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"'
        ' applyFont="1"/>',
        # 5 command line: monospace, indented
        '<xf numFmtId="49" fontId="3" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"'
        ' applyFont="1" applyAlignment="1"><alignment vertical="top" indent="2"/></xf>',
        '</cellXfs>',
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>',
        '<dxfs count="0"/>',
        '<tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>',
        '</styleSheet>',
    ])


def fmt_width(w):
    return ('%.2f' % w).rstrip('0').rstrip('.')


def sheet_xml(sst, rows, widths, col_styles=None, header_rows=1, pad_to=0,
              pad_cols=0, pad_style=S_TEXT, autofilter=None, validations=(),
              selected=False, landscape=False, fit_width=False, text_numbers=None):
    """One worksheet. rows: list of rows; each row is a list of (text, style).

    An empty text writes a styled cell without a value. pad_to/pad_cols add
    empty styled cells up to that row and column count. text_numbers: a range
    where Excel should not flag numbers stored as text.
    """
    ncols = max([len(r) for r in rows] + [pad_cols])
    nrows = max(len(rows), pad_to)
    last = '%s%d' % (col_letter(ncols - 1), nrows)
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
           '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
           ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">']
    if fit_width:
        out.append('<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>')
    out.append('<dimension ref="A1:%s"/>' % last)
    out.append('<sheetViews><sheetView%s workbookViewId="0">' % (' tabSelected="1"' if selected else ''))
    if header_rows:
        top = 'A%d' % (header_rows + 1)
        out.append('<pane ySplit="%d" topLeftCell="%s" activePane="bottomLeft" state="frozen"/>'
                   '<selection pane="bottomLeft" activeCell="%s" sqref="%s"/>' % (header_rows, top, top, top))
    out.append('</sheetView></sheetViews>')
    out.append('<sheetFormatPr defaultRowHeight="15"/>')
    out.append('<cols>')
    for i, w in enumerate(widths):
        style = ''
        if col_styles is not None:
            style = ' style="%d"' % col_styles[i]
        out.append('<col min="%d" max="%d" width="%s"%s customWidth="1"/>' % (i + 1, i + 1, fmt_width(w), style))
    out.append('</cols>')
    out.append('<sheetData>')
    for ri in range(nrows):
        rnum = ri + 1
        if ri < len(rows):
            cells = list(rows[ri])
        else:
            cells = []
        if len(cells) < pad_cols and ri >= header_rows:
            cells += [('', pad_style)] * (pad_cols - len(cells))
        height = ' ht="20" customHeight="1"' if ri < header_rows else ''
        out.append('<row r="%d" spans="1:%d"%s>' % (rnum, ncols, height))
        for ci, (text, style) in enumerate(cells):
            ref = '%s%d' % (col_letter(ci), rnum)
            if text == '':
                out.append('<c r="%s" s="%d"/>' % (ref, style))
            else:
                out.append('<c r="%s" s="%d" t="s"><v>%d</v></c>' % (ref, style, sst.add(text)))
        out.append('</row>')
    out.append('</sheetData>')
    if autofilter:
        out.append('<autoFilter ref="%s"/>' % autofilter)
    if validations:
        out.append('<dataValidations count="%d">' % len(validations))
        for sqref, values, title, message in validations:
            out.append('<dataValidation type="list" allowBlank="1" showErrorMessage="1"'
                       ' errorTitle="%s" error="%s" sqref="%s"><formula1>%s</formula1>'
                       '</dataValidation>' % (attr(title), attr(message), sqref,
                                              escape('"' + ','.join(values) + '"')))
        out.append('</dataValidations>')
    out.append('<pageMargins left="0.5" right="0.5" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>')
    if landscape or fit_width:
        out.append('<pageSetup%s%s/>' % (' orientation="landscape"' if landscape else '',
                                         ' fitToWidth="1" fitToHeight="0"' if fit_width else ''))
    if text_numbers:
        out.append('<ignoredErrors><ignoredError sqref="%s" numberStoredAsText="1"/>'
                   '</ignoredErrors>' % text_numbers)
    out.append('</worksheet>')
    return ''.join(out)


def fleet_widths(rows):
    widths = []
    for ci, name in enumerate(COLUMNS):
        longest = max([len(name)] + [len(r[ci]) for r in rows])
        if name == 'Notes':
            longest = max(len(name), 40)
        widths.append(min(max(longest, 8) + 3, 80))
    return widths


def build_xlsx(rows):
    sst = SharedStrings()
    ncols = len(COLUMNS)

    # Sheet 1: Fleet
    fleet_rows = [[(c, S_HEADER) for c in COLUMNS]]
    for r in rows:
        fleet_rows.append([(v, S_TEXT) for v in r])
    validations = []
    for name in BOOLEAN_COLUMNS:
        letter = col_letter(COLUMNS.index(name))
        validations.append(('%s2:%s%d' % (letter, letter, TEXT_ROWS), ('TRUE', 'FALSE'), name,
                            'Choose TRUE or FALSE, or leave the cell blank.'))
    last_data = '%s%d' % (col_letter(ncols - 1), len(rows) + 1)
    sheet1 = sheet_xml(sst, fleet_rows, fleet_widths(rows), col_styles=[S_TEXT] * ncols,
                       pad_to=TEXT_ROWS, pad_cols=ncols, autofilter='A1:%s' % last_data,
                       validations=validations, selected=True, landscape=True,
                       text_numbers='A2:%s%d' % (col_letter(ncols - 1), TEXT_ROWS))

    # Sheet 2: Columns
    head = ['Column', 'Applies to', 'Required', 'Example', 'Meaning']
    col_rows = [[(h, S_HEADER) for h in head]]
    for info in COLUMN_INFO:
        col_rows.append([(v, S_WRAP) for v in info])
    sheet2 = sheet_xml(sst, col_rows, [20, 11, 20, 76, 80], landscape=True, fit_width=True,
                       text_numbers='D2:D%d' % len(col_rows))

    # Sheet 3: Read me
    style_of = {'title': S_TITLE, 'text': S_WRAP, 'cmd': S_CMD}
    rm_rows = [[(text, style_of[kind])] for kind, text in README]
    sheet3 = sheet_xml(sst, rm_rows, [105], header_rows=0, landscape=True, fit_width=True)

    sheets = [('Fleet', sheet1), ('Columns', sheet2), ('Read me', sheet3)]

    ns_main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    ns_r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    ns_pkg = 'http://schemas.openxmlformats.org/package/2006/relationships'
    head_xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'

    content_types = ''.join(
        [head_xml,
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
         '<Default Extension="xml" ContentType="application/xml"/>',
         '<Override PartName="/xl/workbook.xml" ContentType="application/'
         'vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>']
        + ['<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/'
           'vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % (i + 1)
           for i in range(len(sheets))]
        + ['<Override PartName="/xl/styles.xml" ContentType="application/'
           'vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
           '<Override PartName="/xl/sharedStrings.xml" ContentType="application/'
           'vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>',
           '<Override PartName="/docProps/core.xml" ContentType="application/'
           'vnd.openxmlformats-package.core-properties+xml"/>',
           '<Override PartName="/docProps/app.xml" ContentType="application/'
           'vnd.openxmlformats-officedocument.extended-properties+xml"/>',
           '</Types>'])

    root_rels = ''.join([
        head_xml, '<Relationships xmlns="%s">' % ns_pkg,
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>' % ns_r,
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/'
        'relationships/metadata/core-properties" Target="docProps/core.xml"/>',
        '<Relationship Id="rId3" Type="%s/extended-properties" Target="docProps/app.xml"/>' % ns_r,
        '</Relationships>'])

    workbook = ''.join(
        [head_xml, '<workbook xmlns="%s" xmlns:r="%s">' % (ns_main, ns_r),
         '<workbookPr/>',
         '<bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800"'
         ' windowHeight="16000" activeTab="0"/></bookViews>',
         '<sheets>']
        + ['<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (attr(name), i + 1, i + 1)
           for i, (name, _) in enumerate(sheets)]
        + ['</sheets>',
           '<definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0"'
           ' hidden="1">Fleet!$A$1:$%s$%d</definedName></definedNames>'
           % (col_letter(ncols - 1), len(rows) + 1),
           '<calcPr calcId="191029"/>',
           '</workbook>'])

    n = len(sheets)
    workbook_rels = ''.join(
        [head_xml, '<Relationships xmlns="%s">' % ns_pkg]
        + ['<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>'
           % (i + 1, ns_r, i + 1) for i in range(n)]
        + ['<Relationship Id="rId%d" Type="%s/styles" Target="styles.xml"/>' % (n + 1, ns_r),
           '<Relationship Id="rId%d" Type="%s/sharedStrings" Target="sharedStrings.xml"/>' % (n + 2, ns_r),
           '</Relationships>'])

    core = ''.join([
        head_xml,
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"'
        ' xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"'
        ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
        '<dc:title>Access Connector fleet spreadsheet</dc:title>',
        '<dc:subject>Fleet file source for Invoke-AccessConnectorUpgrade.ps1 -ImportFleet</dc:subject>',
        '<dc:creator>Access Connector Automated Upgrade</dc:creator>',
        '<cp:lastModifiedBy>tools/build_fleet_template.py</cp:lastModifiedBy>',
        '<dcterms:created xsi:type="dcterms:W3CDTF">%s</dcterms:created>' % FIXED_W3C_TIME,
        '<dcterms:modified xsi:type="dcterms:W3CDTF">%s</dcterms:modified>' % FIXED_W3C_TIME,
        '</cp:coreProperties>'])

    app = ''.join(
        [head_xml,
         '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"'
         ' xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">',
         '<Application>tools/build_fleet_template.py</Application>',
         '<DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>',
         '<HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr>'
         '</vt:variant><vt:variant><vt:i4>%d</vt:i4></vt:variant></vt:vector></HeadingPairs>' % n,
         '<TitlesOfParts><vt:vector size="%d" baseType="lpstr">' % n]
        + ['<vt:lpstr>%s</vt:lpstr>' % escape(name) for name, _ in sheets]
        + ['</vt:vector></TitlesOfParts>',
           '<LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc>'
           '<HyperlinksChanged>false</HyperlinksChanged>',
           '</Properties>'])

    # The shared strings are complete only after every sheet is built.
    parts = [('[Content_Types].xml', content_types),
             ('_rels/.rels', root_rels),
             ('docProps/core.xml', core),
             ('docProps/app.xml', app),
             ('xl/workbook.xml', workbook),
             ('xl/_rels/workbook.xml.rels', workbook_rels),
             ('xl/styles.xml', styles_xml())]
    parts += [('xl/worksheets/sheet%d.xml' % (i + 1), xml) for i, (_, xml) in enumerate(sheets)]
    parts.append(('xl/sharedStrings.xml', sst.xml()))

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for name, text in parts:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0
            z.writestr(info, text.encode('utf-8'), compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    return buf.getvalue()


def check_ascii(label, data):
    bad = [b for b in data if b > 127]
    if bad:
        raise SystemExit('%s: %d non-ASCII characters in the example text' % (label, len(bad)))


def main():
    ap = argparse.ArgumentParser(description='Build the fleet spreadsheet templates.')
    ap.add_argument('--outdir', default=DEFAULT_OUTDIR,
                    help='folder to write into (default: the FleetDeploy folder)')
    opts = ap.parse_args()

    if COLUMNS != CANONICAL:
        raise SystemExit('column list differs from the canonical order')
    rows = example_rows()
    for r in rows:
        check_ascii('rows', '\x00'.join(r).encode('utf-8'))
    for info in COLUMN_INFO:
        check_ascii('columns', '\x00'.join(info).encode('utf-8'))
    for _, text in README:
        check_ascii('read me', text.encode('utf-8'))

    os.makedirs(opts.outdir, exist_ok=True)
    out = [(os.path.join(opts.outdir, CSV_NAME), build_csv(rows)),
           (os.path.join(opts.outdir, XLSX_NAME), build_xlsx(rows))]
    for path, data in out:
        with open(path, 'wb') as f:
            f.write(data)
        print('wrote %s (%d bytes)' % (path, len(data)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
