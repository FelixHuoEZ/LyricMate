import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release_safety', Path(__file__).with_name('check-release-safety.py'))
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class ReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.workflow = safety.load_yaml(safety.ROOT / '.github/workflows/source-checks.yml')

    def test_reviewed_workflow_passes(self):
        safety.validate_workflow(self.workflow)

    def test_privileged_triggers_and_permissions_fail(self):
        for key, value in [('on', {'pull_request_target': None}),
                           ('permissions', {'contents': 'write'})]:
            document = copy.deepcopy(self.workflow)
            document[key] = value
            with self.assertRaises(ValueError):
                safety.validate_workflow(document)

    def test_unpinned_actions_and_persisted_credentials_fail(self):
        for key, value in [('uses', 'actions/checkout@v4'),
                           ('with', {'persist-credentials': True, 'fetch-depth': 0})]:
            document = copy.deepcopy(self.workflow)
            document['jobs']['source']['steps'][0][key] = value
            with self.assertRaises(ValueError):
                safety.validate_workflow(document)

    def test_publication_launch_and_expression_injection_fail(self):
        for run in ['gh release create v1', 'git push origin main', 'open app',
                    'echo ${{ github.event.issue.title }}']:
            document = copy.deepcopy(self.workflow)
            document['jobs']['source']['steps'].append({'run': run})
            with self.assertRaises(ValueError):
                safety.validate_workflow(document)

    def test_scanner_checksum_and_required_tests_cannot_disappear(self):
        for missing in [safety.DIGEST, 'scripts/scan-secrets.sh', 'scripts/build-lyric-preview.sh',
                        'scripts/build-source-alpha-acceptance.sh --permission-denied',
                        'scripts/build-source-alpha-acceptance.sh --permission-allowed']:
            document = copy.deepcopy(self.workflow)
            for job in document['jobs'].values():
                for step in job['steps']:
                    if 'run' in step:
                        step['run'] = step['run'].replace(missing, '')
            with self.assertRaises(ValueError):
                safety.validate_workflow(document)


    def test_bounded_actions_update_configuration_passes(self):
        safety.validate_dependabot(safety.load_yaml(safety.ROOT / '.github/dependabot.yml'))

    def test_extra_ecosystems_and_expanded_dependency_updates_fail(self):
        baseline = safety.load_yaml(safety.ROOT / '.github/dependabot.yml')
        for key, value in [('directory', '/private'), ('open-pull-requests-limit', 100),
                           ('schedule', {'interval': 'daily'}), ('registries', ['private-registry'])]:
            document = copy.deepcopy(baseline)
            document['updates'][0][key] = value
            with self.assertRaises(ValueError):
                safety.validate_dependabot(document)
        document = copy.deepcopy(baseline)
        document['updates'].append({'package-ecosystem': 'pip', 'directory': '/'})
        with self.assertRaises(ValueError):
            safety.validate_dependabot(document)


if __name__ == '__main__':
    unittest.main()
