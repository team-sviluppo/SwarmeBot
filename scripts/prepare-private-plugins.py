#!/usr/bin/env python3
"""Stage optional private plugins inside the Swift package, without tracking them."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def identifier(value):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ValueError(f"invalid Swift identifier: {value!r}")
    return value


def source_directory(base, relative):
    path = (base / relative).resolve()
    if not path.is_relative_to(base.resolve()) or not path.is_dir():
        raise ValueError(f"plugin source must be a directory inside {base}: {relative}")
    return path


def prepare(root, private, disabled=False):
    staging = root / '.build/private-plugins'
    # Remove the previous selection even when validation fails: a public build
    # must never silently reuse private code from an earlier build.
    if staging.exists():
        shutil.rmtree(staging)
    if disabled:
        print('Private plugins disabled')
        return
    if not private.is_dir():
        print(f'No private plugins at {private}; building public plugins only')
        return
    manifests = sorted((private / 'Plugins').glob('*/plugin.json'))
    if not manifests:
        raise ValueError(f'no Plugins/*/plugin.json found in {private}')
    staging.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='private-plugins-', dir=staging.parent) as temp:
        work = Path(temp)
        targets, registrations, tables, ids, names = [], {'app': [], 'engine': []}, [], set(), set()

        def add_target(name, path, dependencies, test=False):
            identifier(name)
            if name in names:
                raise ValueError(f'duplicate private target: {name}')
            names.add(name)
            targets.append({'name': name, 'path': path, 'dependencies': [identifier(d) for d in dependencies], 'test': test})

        for manifest in manifests:
            plugin = json.loads(manifest.read_text(encoding='utf-8'))
            plugin_id = identifier(plugin['id'])
            if plugin_id in ids:
                raise ValueError(f'duplicate private plugin: {plugin_id}')
            ids.add(plugin_id)
            base = manifest.parent
            for side in ('app', 'engine'):
                if side not in plugin:
                    continue
                spec = plugin[side]
                module, entry = identifier(spec['module']), identifier(spec['type'])
                relative = f'{plugin_id}/{side}'
                shutil.copytree(source_directory(base, spec['path']), work / relative)
                add_target(module, relative, spec['dependencies'])
                registrations[side].append((module, entry))
            for test in plugin.get('tests', []):
                name = identifier(test['name'])
                relative = f'{plugin_id}/Tests/{name}'
                shutil.copytree(source_directory(base, test['path']), work / relative)
                add_target(name, relative, test['dependencies'], test=True)
            if 'translations' in plugin:
                spec = plugin['translations']
                table = identifier(spec['table'])
                if table in tables:
                    raise ValueError(f'duplicate translation table: {table}')
                tables.append(table)
                shutil.copytree(source_directory(base, spec['path']), work / f'SwarmeL10n/Private/{plugin_id}')

        # Keep translations in the existing module: all tr() calls, including
        # private plugin tests, use the same language and placeholder lookup.
        shutil.copytree(root / 'Sources/SwarmeL10n', work / 'SwarmeL10n', dirs_exist_ok=True)
        (work / 'SwarmeL10n/PrivateTranslations.swift').write_text(
            'extension Translations {\n    static let privatePlugins: [[String: String]] = [' + ', '.join(tables) + ']\n}\n')
        for side, host, protocol in (('app', 'SwarmeBotUI', 'AppPlugin'), ('engine', 'HarnessCore', 'EnginePlugin')):
            registry = 'PrivatePlugins' + side.title()
            folder = work / registry
            folder.mkdir()
            entries = registrations[side]
            imports = '\n'.join('import ' + module for module, _ in entries)
            instances = ', '.join(entry + '()' for _, entry in entries)
            (folder / 'Plugins.swift').write_text(
                f'import {host}\n{imports}\n\n' + ('@MainActor\n' if side == 'app' else '') + f'public enum {registry} {{\n'
                f'    public static func make() -> [any {protocol}] {{ [{instances}] }}\n}}\n')
            add_target(registry, registry, [host] + [module for module, _ in entries])
        (work / 'targets.json').write_text(json.dumps(targets, indent=2) + '\n')
        work.rename(staging)
    print('Private plugins prepared: ' + ', '.join(sorted(ids)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-private-plugins', action='store_true', help='remove staged private sources and build public plugins only')
    parser.add_argument('--private-plugins-dir', type=Path, default=Path(os.environ.get('SWARMEBOT_PRIVATE_PLUGINS_DIR', ROOT.parent / 'SwarmeBotPlugins')))
    args = parser.parse_args()
    try:
        prepare(ROOT, args.private_plugins_dir.expanduser().resolve(), args.no_private_plugins)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f'error preparing private plugins: {error}\n')


if __name__ == '__main__':
    main()
