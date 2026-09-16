#!/usr/bin/env python3
"""Adversarial archive/package tests for the language environment build tools."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import stat
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/runtime-environments'))
import apk
import ext4
import package
import sources


def archive_file(name='usr/bin/python3', content=b'payload', kind=None, target=None):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        member = tarfile.TarInfo(name)
        member.mode = 0o755
        if kind:
            member.type = kind; member.linkname = target or ''
        else:
            member.size = len(content)
        archive.addfile(member, None if kind else io.BytesIO(content))
    return data.getvalue()


def disk_bytes():
    disk = bytearray(1024 * 1024)
    struct.pack_into('<I', disk, 1024, 2)
    struct.pack_into('<I', disk, 1028, 256)
    struct.pack_into('<I', disk, 1048, 2)
    struct.pack_into('<I', disk, 1056, 256)
    struct.pack_into('<I', disk, 1064, 2)
    struct.pack_into('<H', disk, 1080, 0xEF53)
    struct.pack_into('<H', disk, 1112, 256)
    struct.pack_into('<II', disk, 4100, 2, 3)
    disk[8192] = 3
    struct.pack_into('<H', disk, 12288 + 256, stat.S_IFREG | 0o755)
    disk[100 * 4096:100 * 4096 + 7] = b'CONTENT'
    return disk


def manifest(disk):
    return {'schema_version': 1, 'environment_id': 'python-test-amd64', 'family': 'python',
            'display_name': 'Python', 'version': '3.12.14', 'architecture': 'x86_64',
            'kernel_sha256': 'a' * 64, 'disk_sha256': hashlib.sha256(disk).hexdigest(),
            'disk_bytes': len(disk), 'minimum_memory_mib': 512}


def write_package(path, disk, header=None, suffix=b'', encoded_header=None):
    header = encoded_header or json.dumps(header or manifest(disk)).encode()
    path.write_bytes(b'RISHENV1' + struct.pack('>I', len(header)) + header + gzip.compress(disk, mtime=0) + suffix)


class ArchiveTests(unittest.TestCase):
    def test_rejects_parent_and_absolute_archive_paths(self):
        for name in ['../outside', '/outside', 'usr/../../outside', 'usr\\outside']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                apk.add_tar({}, archive_file(name))

    def test_rejects_symlink_escape(self):
        with self.assertRaises(ValueError):
            apk.add_tar({}, archive_file('usr/bin/link', kind=tarfile.SYMTYPE, target='../../../outside'))

    def test_absolute_guest_link_is_confined_and_equivalent(self):
        entries = {}
        apk.add_tar(entries, archive_file('usr/bin/python3', kind=tarfile.SYMTYPE, target='/usr/bin/python3.12'))
        self.assertEqual(entries['usr/bin/python3'][1], b'python3.12')

    def test_staging_rejects_symlink_ancestors_before_any_external_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            entries = {'usr': (stat.S_IFLNK | 0o777, b'elsewhere'), 'usr/file': (stat.S_IFREG | 0o644, b'data')}
            with self.assertRaises(ValueError): apk.stage_entries(entries, root, 100)
            self.assertFalse((Path(temporary) / 'elsewhere').exists())

    def test_rejects_special_device_entries(self):
        with self.assertRaises(ValueError): apk.add_tar({}, archive_file('dev/hack', kind=tarfile.CHRTYPE))

    def test_rejects_conflicting_signed_package_files(self):
        entries = {}
        apk.add_tar(entries, archive_file(content=b'one'))
        with self.assertRaises(ValueError): apk.add_tar(entries, archive_file(content=b'two'))

    def test_rejects_truncated_gzip(self):
        with self.assertRaises(ValueError): apk.gzip_members(gzip.compress(b'abc')[:-3])

    def test_rejects_excess_gzip_members(self):
        with self.assertRaises(ValueError): apk.gzip_members(gzip.compress(b'abc') * 4)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / 'test.rishenv'
        self.disk = disk_bytes()

    def tearDown(self): self.temporary.cleanup()

    def test_accepts_exact_valid_package_and_kernel(self):
        write_package(self.path, self.disk)
        result = package.verify(self.path, 'a' * 64)
        self.assertEqual(result['package_bytes'], self.path.stat().st_size)
        self.assertEqual(result['manifest']['disk_bytes'], len(self.disk))

    def test_rejects_concatenated_gzip_and_trailing_bytes(self):
        for suffix in [b'X', gzip.compress(b'x')]:
            write_package(self.path, self.disk, suffix=suffix)
            with self.assertRaises(ValueError): package.verify(self.path)

    def test_rejects_wrong_disk_size_hash_geometry_and_kernel(self):
        for field, value in [('disk_bytes', len(self.disk) + 512), ('disk_sha256', 'b' * 64)]:
            header = manifest(self.disk); header[field] = value
            write_package(self.path, self.disk, header)
            with self.assertRaises(ValueError): package.verify(self.path)
        bad = bytearray(self.disk); struct.pack_into('<I', bad, 1028, 1)
        write_package(self.path, bad)
        with self.assertRaises(ValueError): package.verify(self.path)
        write_package(self.path, self.disk)
        with self.assertRaises(ValueError): package.verify(self.path, 'b' * 64)

    def test_rejects_bool_in_integer_field_duplicate_key_and_unknown_key(self):
        header = manifest(self.disk); header['schema_version'] = True
        write_package(self.path, self.disk, header)
        with self.assertRaises(ValueError): package.verify(self.path)
        duplicate = json.dumps(manifest(self.disk))[:-1] + ', "family": "java"}'
        write_package(self.path, self.disk, encoded_header=duplicate.encode())
        with self.assertRaises(ValueError): package.verify(self.path)
        header = manifest(self.disk); header['path'] = '/host'
        write_package(self.path, self.disk, header)
        with self.assertRaises(ValueError): package.verify(self.path)

    def test_rejects_truncated_gzip(self):
        write_package(self.path, self.disk); self.path.write_bytes(self.path.read_bytes()[:-3])
        with self.assertRaises(ValueError): package.verify(self.path)

    def test_ext4_normalization_preserves_content_and_sets_stable_ownership_time(self):
        offset = 12288 + 256
        struct.pack_into('<H', self.disk, offset + 2, 501)
        struct.pack_into('<H', self.disk, offset + 24, 20)
        struct.pack_into('<I', self.disk, offset + 12, 999)
        self.path.write_bytes(self.disk); ext4.normalize_metadata(self.path, 123)
        normalized = self.path.read_bytes()
        self.assertEqual(normalized[100 * 4096:100 * 4096 + 7], b'CONTENT')
        self.assertEqual(struct.unpack_from('<H', normalized, offset + 2)[0], 0)
        self.assertEqual(struct.unpack_from('<H', normalized, offset + 24)[0], 0)
        self.assertEqual(struct.unpack_from('<I', normalized, offset + 12)[0], 123)
        ext4.normalize_metadata(self.path, 123)
        self.assertEqual(self.path.read_bytes(), normalized)

    def test_ext4_normalization_rejects_checksummed_foreign_metadata(self):
        struct.pack_into('<I', self.disk, 1124, 0x400)
        self.path.write_bytes(self.disk)
        with self.assertRaises(ValueError): ext4.normalize_metadata(self.path, 123)
        self.assertEqual(self.path.read_bytes(), self.disk)


class SourceTests(unittest.TestCase):
    def test_literal_source_plan_never_evaluates_recipe_shell(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'runtime-environments').mkdir()
            marker = root / 'must-not-exist'
            recipe = root / 'APKBUILD'
            recipe.write_text('pkgname=$(touch ' + str(marker) + ')\nsha512sums="\n' + 'a' * 128 + '  __source.patch\n"\n')
            manifest = root / 'recipes.json'
            manifest.write_text(json.dumps({'recipes': [{'origin': 'test', 'commit': 'b' * 40, 'retained': True,
                'path': str(recipe), 'sha256': hashlib.sha256(recipe.read_bytes()).hexdigest()}]}))
            (root / 'runtime-environments/test.lock.json').write_text(json.dumps({'alpine_version': '3.23', 'packages': [{
                'source_origin': 'test', 'source_commit': 'b' * 40,
                'source_recipe_url': 'https://raw.githubusercontent.com/alpinelinux/aports/' + 'b' * 40 + '/main/test/APKBUILD'}]}))
            with mock.patch.object(sources, 'ROOT', root): plan = sources.source_plan(manifest)
            self.assertFalse(marker.exists())
            self.assertEqual(len(plan['items']), 1)
            self.assertEqual(plan['items'][0]['filename'], '__source.patch')
            self.assertFalse(plan['unresolved_recipe_items'])

    def test_source_budget_counts_failed_transfer_bytes(self):
        budget = sources.DownloadBudget(10, 6)
        first = budget.reserve(); second = budget.reserve()
        self.assertEqual((first, second), (6, 4))
        budget.release(first, 6); budget.release(second, 4)
        self.assertEqual(budget.reserve(), 0)


class GoCacheTests(unittest.TestCase):
    def test_corrupt_compiled_cache_output_is_rejected(self):
        spec = importlib.util.spec_from_file_location('cache_go_test', ROOT / 'scripts/runtime-environments/cache-go.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'cache.tar'
            identity = hashlib.sha256(b'expected').hexdigest()
            path.write_bytes(archive_file('tmp/go-build/' + identity[:2] + '/' + identity + '-d', b'tampered'))
            with self.assertRaisesRegex(ValueError, 'digest mismatch'): module.normalize(path)

    def test_cache_export_cannot_add_files_outside_cache_prefix(self):
        spec = importlib.util.spec_from_file_location('cache_go_test', ROOT / 'scripts/runtime-environments/cache-go.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'cache.tar'
            path.write_bytes(archive_file('usr/bin/replacement', b'bad'))
            with self.assertRaisesRegex(ValueError, 'escaped'): module.normalize(path)


def load_tests(loader, tests, pattern):
    for name in ['runtime-python-cache-test', 'runtime-java-cds-test']:
        spec = importlib.util.spec_from_file_location(name.replace('-', '_'),
            ROOT / ('scripts/tests/' + name + '.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        tests.addTests(loader.loadTestsFromModule(module))
    return tests


if __name__ == '__main__': unittest.main(verbosity=2)
