#!/usr/bin/env python3
"""Check translation coverage, tokens and packaged permission resources offline."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def table(path):
    data = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)])
    return json.loads(data)

tables = {language: table(ROOT / 'Localization/Resources' / (language + '.lproj') / 'Localizable.strings')
          for language in ['en', 'zh-Hans']}
assert tables['en'].keys() == tables['zh-Hans'].keys()
tokens = re.compile(r'%[1-9][0-9]*\$@')
for key, value in tables['en'].items():
    assert value == key and not re.search('[\u4e00-\u9fff]', key)
    assert sorted(tokens.findall(value)) == sorted(tokens.findall(tables['zh-Hans'][key]))
    assert value and tables['zh-Hans'][key]
calls = 0
for folder in ['LyricFever', 'LyricPreview']:
    for path in (ROOT / folder).rglob('*.swift'):
        for value in re.findall(r'L10n\.text\(("(?:[^"\\]|\\.)*")', path.read_text()):
            assert json.loads(value) in tables['en'], path.relative_to(ROOT).as_posix()
            calls += 1
info = table(ROOT / 'LyricPreview/Info.plist')
assert info['CFBundleDevelopmentRegion'] == 'en'
assert info['CFBundleLocalizations'] == ['en', 'zh-Hans']
for language in tables:
    permission = table(ROOT / 'Localization/Resources' / (language + '.lproj') / 'InfoPlist.strings')
    assert permission['NSAppleEventsUsageDescription']
assert table(ROOT / 'Localization/Resources/en.lproj/InfoPlist.strings')['NSAppleEventsUsageDescription'] == info['NSAppleEventsUsageDescription']
assert (ROOT / 'README.zh-CN.md').is_file()
assert '[简体中文](README.zh-CN.md)' in (ROOT / 'README.md').read_text()
assert '[English](README.md)' in (ROOT / 'README.zh-CN.md').read_text()
print(json.dumps({'languages': list(tables), 'catalogEntriesPerLanguage': len(tables['en']),
                  'localizedCalls': calls, 'permissionResources': 'passed', 'readmeLinks': 'passed'}))
