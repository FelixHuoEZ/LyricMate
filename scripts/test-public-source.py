import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('public_source', Path(__file__).with_name('public-source.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)

class SourceExportTests(unittest.TestCase):
    def test_only_reviewed_maintenance_files_are_permitted(self):
        for name in source.GITHUB_FILES | {'CONTRIBUTING.md', 'LICENSES/LyricMate-assets-MIT.txt',
                                          'scripts/scan-secrets.sh', 'scripts/check-release-safety.py',
                                          'scripts/test-release-safety.py'}:
            self.assertTrue(source.permitted(name))
        for name in ['.github/workflows/release.yml', '.github/credentials.json',
                     '.github/ISSUE_TEMPLATE/private.yml', 'LICENSES/private.txt', '.gitleaks.toml']:
            self.assertFalse(source.permitted(name))

    def test_only_named_app_icons_are_permitted(self):
        for name in ['LyricPreview/Resources/LyricMate.icns',
                     'LyricPreview/Resources/LyricMateIcon-1024.png',
                     'docs/app-icon.md', 'scripts/build-lyricmate-icon.sh',
                     'scripts/test-lyricmate-icon.sh']:
            self.assertTrue(source.permitted(name))
        for name in ['LyricPreview/Resources/private.png',
                     'LyricPreview/Resources/Other.icns',
                     'LyricPreview/Resources/settings.plist',
                     'LyricPreview/Resources/backup.json',
                     'LyricPreview/Resources/.DS_Store',
                     'LyricPreview/Resources/subdir/LyricMate.icns',
                     'docs/acceptance/install.json']:
            self.assertFalse(source.permitted(name))

    def fixture(self, root):
        (root / 'README.md').write_text('Synthetic project\n')
        (root / 'release-files.txt').write_text('README.md\nrelease-files.txt\n')

    def test_rejects_escape_metadata_and_unlisted_files(self):
        for name in ['../secret', '/secret', '.git/config', 'docs/../../secret',
                     'docs//privacy.md', 'LyricFever/../secret.swift', '.env', 'docs/playback.json']:
            self.assertFalse(source.permitted(name))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            self.assertEqual(len(source.collect(root)), 2)
            (root / 'private.json').write_text('{}')
            with self.assertRaises(ValueError):
                source.collect(root)

    def test_rejects_symlinks_duplicates_and_missing_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            (root / 'README.md').unlink()
            (root / 'README.md').symlink_to(root / 'release-files.txt')
            with self.assertRaises(ValueError):
                source.collect(root)
            (root / 'release-files.txt').write_text('README.md\nREADME.md\n')
            with self.assertRaises(ValueError):
                source.collect(root)
            (root / 'README.md').unlink()
            (root / 'release-files.txt').write_text('README.md\nrelease-files.txt\n')
            with self.assertRaises(ValueError):
                source.collect(root)

    def test_archive_is_deterministic_and_does_not_export_git_or_builds(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fixture(root)
            for directory in ['.git', '.build', 'dist']:
                (root / directory).mkdir()
                (root / directory / 'private.txt').write_text('Not an input')
            data = source.collect(root)
            first, second = root / 'dist/first.tgz', root / 'dist/second.tgz'
            source.archive(data, first)
            source.archive(data, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with self.assertRaises(FileExistsError):
                source.archive(data, first)
            with tarfile.open(first) as tar:
                self.assertEqual(tar.getnames(), ['LyricMate/README.md', 'LyricMate/release-files.txt'])
                self.assertTrue(all(x.uid == x.gid == x.mtime == 0 and x.uname == x.gname == '' for x in tar))

if __name__ == '__main__':
    unittest.main()
