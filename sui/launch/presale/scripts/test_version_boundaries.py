#!/usr/bin/env python3
"""Prove the surface gate detects removal of every public mutation guard."""
import ast
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VersionBoundaryTests(unittest.TestCase):
    def test_nested_module_cannot_define_package_administration(self):
        package = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(package / 'sources', root / 'sources')
            (root / 'scripts').mkdir()
            check = root / 'scripts/check_version_boundaries.py'
            shutil.copyfile(package / 'scripts' / check.name, check)
            rogue = root / 'sources/config/rogue.move'
            rogue.write_text('module blast_presale::rogue;\npublic struct PackageAdmin() has drop;\n')
            result = subprocess.run([sys.executable, str(check)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('public struct PackageAdmin', result.stderr)

    def test_each_guard_is_required(self):
        package = Path(__file__).resolve().parent.parent
        script = package / 'scripts/check_version_boundaries.py'
        tree = ast.parse(script.read_text())
        guarded = next(ast.literal_eval(node.value) for node in tree.body
                       if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == 'GUARDED'
                               for target in node.targets))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(package / 'sources', root / 'sources')
            (root / 'scripts').mkdir()
            check = root / 'scripts' / script.name
            shutil.copyfile(script, check)
            baseline = subprocess.run([sys.executable, str(check)], capture_output=True)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            for module, functions in guarded.items():
                paths = list((root / 'sources').rglob(module + '.move'))
                self.assertEqual(len(paths), 1, module)
                path = paths[0]
                original = path.read_text()
                for name in functions:
                    with self.subTest(module=module, function=name):
                        start = original.index('public fun ' + name + '<') if ('public fun ' + name + '<') in original else original.index('public fun ' + name + '(')
                        statement = 'package_version.assert_current(constants::version!());'
                        offset = original.index(statement, start)
                        path.write_text(original[:offset] + original[offset + len(statement):])
                        result = subprocess.run([sys.executable, str(check)], capture_output=True)
                        self.assertNotEqual(result.returncode, 0, f'{module}::{name}')
                        path.write_text(original)


if __name__ == '__main__':
    unittest.main()
