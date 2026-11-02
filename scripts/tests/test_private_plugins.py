#!/usr/bin/env python3
"""Offline checks for private source selection and build option propagation."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('private_plugins', ROOT / 'scripts/prepare-private-plugins.py')
plugins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plugins)


class PrivatePluginsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='swarme-private-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'SwarmeBot'
        self.private = self.root.parent / 'SwarmeBotPlugins'
        (self.root / 'Sources/SwarmeL10n').mkdir(parents=True)
        (self.root / 'Sources/SwarmeL10n/Core.swift').write_text('// core translations\n')
        self.plugin = self.private / 'Plugins/Example'
        self.plugin.mkdir(parents=True)
        for folder in ('App', 'Engine', 'Tests', 'Translations'):
            (self.plugin / folder).mkdir()
            (self.plugin / folder / 'Example.swift').write_text('// ' + folder)
        self.manifest = {
            'id': 'example',
            'app': {'module': 'ExampleApp', 'type': 'ExampleAppPlugin', 'path': 'App', 'dependencies': ['SwarmeBotUI']},
            'engine': {'module': 'ExampleEngine', 'type': 'ExampleEnginePlugin', 'path': 'Engine', 'dependencies': ['HarnessCore']},
            'tests': [{'name': 'ExampleTests', 'path': 'Tests', 'dependencies': ['ExampleEngine']}],
            'translations': {'path': 'Translations', 'table': 'example'},
        }
        self.save()
        self.stage = self.root / '.build/private-plugins'

    def save(self):
        (self.plugin / 'plugin.json').write_text(json.dumps(self.manifest))

    def prepare(self, **kwargs):
        plugins.prepare(self.root, self.private, **kwargs)

    def test_sources_tests_translations_and_registration_are_staged(self):
        self.prepare()
        targets = json.loads((self.stage / 'targets.json').read_text())
        self.assertEqual({t['name'] for t in targets}, {'ExampleApp', 'ExampleEngine', 'ExampleTests', 'PrivatePluginsApp', 'PrivatePluginsEngine'})
        self.assertTrue(next(t for t in targets if t['name'] == 'ExampleTests')['test'])
        self.assertIn('ExampleAppPlugin()', (self.stage / 'PrivatePluginsApp/Plugins.swift').read_text())
        self.assertIn('ExampleEnginePlugin()', (self.stage / 'PrivatePluginsEngine/Plugins.swift').read_text())
        self.assertIn('@MainActor', (self.stage / 'PrivatePluginsApp/Plugins.swift').read_text())
        self.assertNotIn('@MainActor', (self.stage / 'PrivatePluginsEngine/Plugins.swift').read_text())
        self.assertTrue((self.stage / 'SwarmeL10n/Core.swift').is_file())
        self.assertTrue((self.stage / 'SwarmeL10n/Private/example/Example.swift').is_file())
        self.assertIn('[example]', (self.stage / 'SwarmeL10n/PrivateTranslations.swift').read_text())

    def test_disable_removes_all_previously_staged_private_sources(self):
        self.prepare()
        self.prepare(disabled=True)
        self.assertFalse(self.stage.exists())

    def test_missing_checkout_clears_old_selection(self):
        self.prepare()
        plugins.prepare(self.root, self.private / 'missing')
        self.assertFalse(self.stage.exists())

    def test_refresh_replaces_stale_sources_and_translations(self):
        self.prepare()
        (self.plugin / 'App/Example.swift').unlink()
        (self.plugin / 'App/New.swift').write_text('// updated')
        (self.root / 'Sources/SwarmeL10n/Core.swift').write_text('// updated core')
        self.prepare()
        self.assertFalse((self.stage / 'example/app/Example.swift').exists())
        self.assertTrue((self.stage / 'example/app/New.swift').exists())
        self.assertEqual((self.stage / 'SwarmeL10n/Core.swift').read_text(), '// updated core')

    def test_malformed_checkout_fails_and_does_not_reuse_old_selection(self):
        self.prepare()
        self.manifest['app']['type'] = 'Bad(); code()'
        self.save()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.stage.exists())

    def test_source_path_cannot_escape_plugin(self):
        self.manifest['app']['path'] = '../..'
        self.save()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_empty_existing_checkout_fails(self):
        (self.plugin / 'plugin.json').unlink()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_engine_only_plugin_needs_no_translations(self):
        del self.manifest['app']
        del self.manifest['translations']
        self.save()
        self.prepare()
        self.assertIn('[]', (self.stage / 'PrivatePluginsApp/Plugins.swift').read_text())
        self.assertIn('[]', (self.stage / 'SwarmeL10n/PrivateTranslations.swift').read_text())

    def test_linux_build_mounts_private_sources_only_when_selected(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('build-linux-engine.sh', 'prepare-private-plugins.py'):
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        commands = self.root / 'commands'
        commands.mkdir()
        log = self.root / 'docker.args'
        docker = commands / 'docker'
        docker.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$QA_DOCKER_LOG"\nexit 42\n')
        docker.chmod(0o755)
        env = {**os.environ, 'PATH': str(commands) + os.pathsep + os.environ['PATH'],
               'SWARMEBOT_PRIVATE_PLUGINS_DIR': str(self.private), 'QA_DOCKER_LOG': str(log)}
        for arguments in ([], ['--no-private-plugins']):
            result = subprocess.run(['bash', str(scripts / 'build-linux-engine.sh'), 'aarch64', *arguments], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertEqual(':/private-plugins:ro' in log.read_text(), not arguments)
            self.assertEqual(self.stage.exists(), not arguments)

    def test_public_manifest_rebuilds_even_when_reuse_was_requested(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        shutil.copy2(ROOT / 'scripts/linux-engines-manifest.sh', scripts)
        builder = scripts / 'build-linux-engine.sh'
        builder.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "' + str(self.root / 'build.args') + '"\nexit 42\n')
        builder.chmod(0o755)
        result = subprocess.run(['bash', str(scripts / 'linux-engines-manifest.sh'), '1.2.3', '--skip-build', '--no-private-plugins'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual((self.root / 'build.args').read_text().splitlines(), ['--no-private-plugins', 'aarch64', 'x86_64'])

    def test_build_wrapper_strips_private_flag_and_forwards_swift_options(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('build.sh', 'prepare-private-plugins.py'):
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        commands = self.root / 'commands'
        commands.mkdir()
        swift = commands / 'swift'
        swift.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        swift.chmod(0o755)
        env = {**os.environ, 'PATH': str(commands) + os.pathsep + os.environ['PATH'], 'SWARMEBOT_PRIVATE_PLUGINS_DIR': str(self.private)}
        for arguments in ([], ['--no-private-plugins']):
            result = subprocess.run(['bash', str(scripts / 'build.sh'), *arguments, '-c', 'release', '--product', 'swarme-harness'], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines()[1:], ['build', '-c', 'release', '--product', 'swarme-harness'])
            self.assertEqual(self.stage.exists(), not arguments)


if __name__ == '__main__':
    unittest.main()
