#!/usr/bin/env python3
"""Validate the narrow source-only CI and feedback contract, not legal clearance."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CHECKOUT = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
DIGEST = '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'


def load_yaml(path):
    # macOS provides Ruby/Psych. Safe loading rejects tags and aliases.
    code = "require 'yaml'; require 'json'; puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))"
    result = subprocess.run(['ruby', '-e', code, str(path)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def validate_workflow(document):
    if set(document.get('on', {})) != {'push', 'pull_request', 'workflow_dispatch'}:
        raise ValueError('Unexpected workflow trigger')
    if document.get('permissions') != {'contents': 'read'}:
        raise ValueError('Workflow must be read-only')
    jobs = document.get('jobs', {})
    if set(jobs) != {'source', 'secrets'}:
        raise ValueError('Unexpected job')
    for name, job in jobs.items():
        if set(job) != {'runs-on', 'timeout-minutes', 'steps'}:
            raise ValueError('Unexpected job capabilities')
        expected = 'macos-15' if name == 'source' else 'ubuntu-24.04'
        if job['runs-on'] != expected or not 1 <= job['timeout-minutes'] <= 20:
            raise ValueError('Unexpected runner or unbounded job')
        checkouts = 0
        for step in job['steps']:
            if set(step) - {'name', 'uses', 'with', 'run', 'shell', 'env'}:
                raise ValueError('Unexpected step capability')
            if 'uses' in step:
                if step['uses'] != CHECKOUT or step.get('with') != {'persist-credentials': False, 'fetch-depth': 0}:
                    raise ValueError('Unreviewed action or credentials persisted')
                checkouts += 1
            run = step.get('run', '')
            if re.search(r'gh\s+|git\s+push|upload|osascript|\bopen\s|\bsudo\s', run):
                raise ValueError('Source checks cannot publish, upload or launch')
            if '${{' in run:
                raise ValueError('Do not interpolate event data into scripts')
            env = step.get('env', {})
            if env and env != {'GITLEAKS_BIN': '${{ runner.temp }}/gitleaks'}:
                raise ValueError('Unexpected workflow environment')
        if checkouts != 1:
            raise ValueError('Each job needs one complete credential-free checkout')
    runs = '\n'.join(step.get('run', '') for job in jobs.values() for step in job['steps'])
    for required in ['swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors',
                     'scripts/check-localization.py', 'scripts/test-public-source.py',
                     'scripts/test-release-safety.py', 'scripts/check-release-safety.py',
                     'scripts/public-source.py check', 'scripts/build-lyric-preview.sh',
                     'scripts/build-source-alpha-acceptance.sh',
                     'scripts/build-source-alpha-acceptance.sh --permission-denied',
                     'scripts/build-source-alpha-acceptance.sh --permission-allowed',
                     'scripts/scan-secrets.sh', DIGEST, 'sha256sum --check']:
        if required not in runs:
            raise ValueError('Required check or scanner checksum missing')


def validate_dependabot(document):
    expected = {'version': 2, 'updates': [{'package-ecosystem': 'github-actions', 'directory': '/',
        'schedule': {'interval': 'monthly'}, 'open-pull-requests-limit': 3,
        'commit-message': {'prefix': 'chore'}}]}
    if document != expected:
        raise ValueError('Dependency updates must be bounded, Actions-only review proposals')


def check(root):
    validate_workflow(load_yaml(root / '.github/workflows/source-checks.yml'))
    validate_dependabot(load_yaml(root / '.github/dependabot.yml'))
    bug = load_yaml(root / '.github/ISSUE_TEMPLATE/bug_report.yml')
    if {item.get('id') for item in bug['body'] if 'id' in item} != {'version', 'system', 'reproduction', 'privacy'}:
        raise ValueError('Missing minimal feedback fields')
    for item in bug['body']:
        if item.get('type') in {'input', 'textarea'} and item.get('validations') != {'required': True}:
            raise ValueError('Missing required redacted reproduction')
        if item.get('id') == 'privacy' and not all(option.get('required') for option in item['attributes']['options']):
            raise ValueError('Privacy review must be required')
    config = load_yaml(root / '.github/ISSUE_TEMPLATE/config.yml')
    if config.get('blank_issues_enabled') is not False:
        raise ValueError('Blank issues must not bypass feedback guidance')
    security = (root / 'SECURITY.md').read_text()
    if 'security/advisories/new' not in security or 'does not claim the channel' not in security:
        raise ValueError('Security channel availability must be explicit')
    print('Source-only CI, pinned tools and minimal feedback checks passed. Hosted execution is separate.')


if __name__ == '__main__':
    check(ROOT)
