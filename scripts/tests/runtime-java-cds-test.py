#!/usr/bin/env python3
"""Adversarial Java CDS packaging tests; no Java or virtual machine is run."""
import copy
import hashlib
import io
from pathlib import Path
import stat
import struct
import sys
import tarfile
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/runtime-environments'))
import java_cds


JDK = 'usr/lib/jvm/java-21-openjdk/'
DESTINATION = JDK + 'lib/server/rish-compiler-http.jsa'
FLAGS = 'tmp/rish-cds-build/flags.txt'
DUMP = 'tmp/rish-cds-build/dump.log'
INVENTORY = 'tmp/rish-cds-build/archive-inventory.txt'
REGULAR = stat.S_IFREG | 0o644
REQUIRED_CLASSES = (
    'com.sun.tools.javac.util.JavacMessages',
    'com.sun.tools.javac.file.JavacFileManager',
    'com.sun.tools.javac.api.JavacTool',
    'com.sun.tools.javac.launcher.Main',
    'com.sun.net.httpserver.HttpServer',
    'sun.net.httpserver.ServerImpl',
)
BINDINGS = tuple(JDK + name for name in (
    'release', 'bin/java', 'lib/server/libjvm.so', 'lib/modules', 'lib/classlist',
    'lib/server/classes.jsa', 'lib/server/classes_nocoops.jsa',
    'jmods/java.compiler.jmod', 'jmods/jdk.compiler.jmod', 'jmods/jdk.httpserver.jmod',
))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def archive_bytes():
    # GenericCDSFileMapHeader from this JDK's include/cds.h is 24 bytes.
    # Payload is deliberately opaque test data, never deserialized or executed.
    header_size = 32
    data = bytearray(struct.pack('<IIiIII', 0xf00baba2, 0, 18, header_size, 0, 0))
    data.extend(b'\0' * (header_size - len(data)))
    struct.pack_into('<I', data, 4, zlib.crc32(data[16:header_size]))
    return bytes(data) + b'opaque static archive payload'


def inventory_bytes(classes=REQUIRED_CLASSES, loader='app_loader'):
    lines = [
        'Static archive name: /' + DESTINATION,
        'Static archive version 18',
        'Shared Dictionary',
        'Shared Builtin Dictionary',
    ]
    lines.extend(f'{index:4d}: {name} {loader}' for index, name in enumerate(classes))
    lines.extend([
        'Shared Unregistered Dictionary',
        'Number of shared symbols: 32',
        'Number of shared strings: 16',
        'VM version: OpenJDK 64-Bit Server VM (21.0.12+8-alpine-r0)',
        'archive is valid',
    ])
    return ('\n'.join(lines) + '\n').encode('utf-8')


def export_files():
    return {
        DESTINATION: archive_bytes(),
        FLAGS: b'     bool UseCompressedOops = true {product} {ergonomic}\n',
        DUMP: b'[info][cds] Loading classes to share ...\n',
        INVENTORY: inventory_bytes(),
    }


def install_fixture():
    entries = {name: (REGULAR, ('signed package fixture: ' + name).encode()) for name in BINDINGS}
    entries['etc/unchanged'] = (REGULAR, b'unrelated signed content')
    archive, inventory = archive_bytes(), inventory_bytes()
    descriptor = {
        'kind': 'java-static-cds',
        'filename': 'java-static-cds-test.jsa',
        'bytes': len(archive),
        'sha256': digest(archive),
        'inventory_sha256': digest(inventory),
        'source_bindings': {
            name: {'bytes': len(entries[name][1]), 'sha256': digest(entries[name][1])}
            for name in BINDINGS
        },
    }
    return entries, descriptor, archive, inventory


class JavaCDSExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / 'export.tar'

    def tearDown(self):
        self.temporary.cleanup()

    def write_members(self, members):
        with tarfile.open(self.path, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for name, data, kind in members:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.mode = 0o644
                member.size = len(data) if kind == tarfile.REGTYPE else 0
                if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                    member.linkname = DESTINATION
                archive.addfile(member, io.BytesIO(data) if kind == tarfile.REGTYPE else None)

    def write_files(self, files):
        self.write_members([(name, data, tarfile.REGTYPE) for name, data in files.items()])

    def test_reads_only_the_four_expected_files_without_extracting_them(self):
        files = export_files()
        self.write_files(files)
        self.assertEqual(java_cds.read_export(self.path), files)
        self.assertEqual(list(Path(self.temporary.name).iterdir()), [self.path])

    def test_rejects_each_missing_evidence_or_archive_file(self):
        for missing in export_files():
            with self.subTest(missing=missing):
                files = export_files()
                del files[missing]
                self.write_files(files)
                with self.assertRaises(ValueError):
                    java_cds.read_export(self.path)

    def test_rejects_extra_paths_including_existing_jdk_and_workspace_files(self):
        for extra in ('tmp/extra', JDK + 'lib/server/classes.jsa', 'workspace/Main.class'):
            with self.subTest(extra=extra):
                files = export_files()
                files[extra] = b'foreign payload'
                self.write_files(files)
                with self.assertRaises(ValueError):
                    java_cds.read_export(self.path)

    def test_rejects_duplicate_files_including_same_content(self):
        for duplicate in (DESTINATION, FLAGS, DUMP, INVENTORY):
            with self.subTest(duplicate=duplicate):
                files = export_files()
                members = [(name, data, tarfile.REGTYPE) for name, data in files.items()]
                members.append((duplicate, files[duplicate], tarfile.REGTYPE))
                self.write_members(members)
                with self.assertRaises(ValueError):
                    java_cds.read_export(self.path)

    def test_rejects_absolute_parent_and_backslash_paths(self):
        for name in ('/' + DESTINATION, '../' + DESTINATION, 'tmp/../' + DESTINATION,
                     DESTINATION.replace('/', '\\')):
            with self.subTest(name=name):
                files = export_files()
                files[name] = files.pop(DESTINATION)
                self.write_files(files)
                with self.assertRaises(ValueError):
                    java_cds.read_export(self.path)

    def test_rejects_links_devices_fifos_and_directory_impostors(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE,
                     tarfile.BLKTYPE, tarfile.FIFOTYPE, tarfile.DIRTYPE):
            for replaced in (DESTINATION, INVENTORY):
                with self.subTest(kind=kind, replaced=replaced):
                    members = [(name, data, kind if name == replaced else tarfile.REGTYPE)
                               for name, data in export_files().items()]
                    self.write_members(members)
                    with self.assertRaises(ValueError):
                        java_cds.read_export(self.path)

    def test_rejects_declared_oversized_members_before_reading_their_payloads(self):
        for name, limit in ((DESTINATION, 128 << 20), (FLAGS, 8 << 20),
                            (DUMP, 8 << 20), (INVENTORY, 8 << 20)):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.size = limit + 1
                self.path.write_bytes(member.tobuf(format=tarfile.USTAR_FORMAT) + b'\0' * 1024)
                with self.assertRaises(ValueError):
                    java_cds.read_export(self.path)

    def test_rejects_truncated_payload(self):
        member = tarfile.TarInfo(DESTINATION)
        member.size = 4096
        self.path.write_bytes(member.tobuf(format=tarfile.USTAR_FORMAT) + b'partial')
        with self.assertRaises((ValueError, tarfile.TarError)):
            java_cds.read_export(self.path)


class JavaCDSArchiveTests(unittest.TestCase):
    def test_accepts_static_jdk_classes_even_when_they_use_app_loader(self):
        result = java_cds.validate_archive(archive_bytes(), inventory_bytes())
        self.assertEqual(result['archive_version'], 18)
        self.assertEqual(set(result['required_classes']), set(REQUIRED_CLASSES))
        self.assertEqual(len(result['required_classes']), 6)
        self.assertEqual(result['archived_classes'], 6)

    def test_rejects_dynamic_wrong_magic_wrong_version_and_byte_order(self):
        for offset, value in ((0, 0xf00baba8), (0, 0), (0, 0xa2ba0bf0),
                              (8, 17), (8, 19), (8, 0xffffffff)):
            with self.subTest(offset=offset, value=value):
                data = bytearray(archive_bytes())
                struct.pack_into('<I', data, offset, value)
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(bytes(data), inventory_bytes())

    def test_rejects_truncated_archive_header(self):
        for length in (0, 4, 12, 23, 24, 31, 32):
            with self.subTest(length=length):
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(archive_bytes()[:length], inventory_bytes())

    def test_rejects_header_size_outside_the_archive(self):
        for size in (0, 16, 23, len(archive_bytes()), len(archive_bytes()) + 1, 0xffffffff):
            with self.subTest(size=size):
                data = bytearray(archive_bytes())
                struct.pack_into('<I', data, 12, size)
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(bytes(data), inventory_bytes())

    def test_static_archive_cannot_reference_a_base_archive(self):
        for offset in (16, 20):
            with self.subTest(offset=offset):
                data = bytearray(archive_bytes())
                struct.pack_into('<I', data, offset, 1)
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(bytes(data), inventory_bytes())

    def test_rejects_missing_target_even_if_a_log_mentions_its_name(self):
        for missing in REQUIRED_CLASSES:
            with self.subTest(missing=missing):
                inventory = inventory_bytes(tuple(name for name in REQUIRED_CLASSES if name != missing))
                inventory += ('Diagnostic note: ' + missing + '\n').encode()
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(archive_bytes(), inventory)

    def test_class_name_prefix_is_not_a_match_for_a_required_target(self):
        classes = tuple(name + 'Fake' if name == REQUIRED_CLASSES[0] else name
                        for name in REQUIRED_CLASSES)
        with self.assertRaises(ValueError):
            java_cds.validate_archive(archive_bytes(), inventory_bytes(classes))

    def test_rejects_user_workspace_and_unregistered_classes(self):
        for classname in ('Main', 'workspace.Main', 'fixture.Main', 'org.example.Main'):
            with self.subTest(classname=classname):
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(archive_bytes(), inventory_bytes(REQUIRED_CLASSES + (classname,)))
        with self.assertRaises(ValueError):
            java_cds.validate_archive(archive_bytes(), inventory_bytes(loader='unregistered_loader'))

    def test_rejects_invalid_or_missing_success_inventory(self):
        for inventory in (b'', inventory_bytes().replace(b'archive is valid\n', b''),
                          inventory_bytes().replace(b'archive is valid', b'archive is invalid'),
                          inventory_bytes() + b'archive is invalid\n'):
            with self.subTest(inventory=inventory[-80:]):
                with self.assertRaises(ValueError):
                    java_cds.validate_archive(archive_bytes(), inventory)


class JavaCDSInstallTests(unittest.TestCase):
    def assert_rejected_without_mutation(self, entries, descriptor, archive, inventory):
        before = copy.deepcopy(entries)
        with self.assertRaises(ValueError):
            java_cds.install(entries, descriptor, archive, inventory)
        self.assertEqual(entries, before)

    def test_installs_only_new_archive_and_preserves_all_signed_files(self):
        entries, descriptor, archive, inventory = install_fixture()
        before = copy.deepcopy(entries)
        java_cds.install(entries, descriptor, archive, inventory)
        self.assertEqual(set(entries) - set(before), {DESTINATION})
        self.assertEqual(entries[DESTINATION], (REGULAR, archive))
        self.assertEqual({name: entries[name] for name in before}, before)

    def test_rejects_existing_destination_even_when_bytes_are_identical(self):
        entries, descriptor, archive, inventory = install_fixture()
        entries[DESTINATION] = (REGULAR, archive)
        self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)

    def test_rejects_changed_archive_and_inventory(self):
        entries, descriptor, archive, inventory = install_fixture()
        self.assert_rejected_without_mutation(entries, descriptor, archive + b'changed', inventory)
        self.assert_rejected_without_mutation(entries, descriptor, archive, inventory + b'changed')

    def test_rejects_bad_descriptor_kind_hash_size_and_filename(self):
        for key, value in (('kind', 'go-stdlib-cache'), ('sha256', '0' * 64),
                           ('inventory_sha256', '0' * 64), ('bytes', 0), ('bytes', True),
                           ('filename', '../cache.jsa'), ('filename', '/cache.jsa')):
            with self.subTest(key=key, value=value):
                entries, descriptor, archive, inventory = install_fixture()
                descriptor[key] = value
                self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)

    def test_requires_every_exact_source_binding_and_rejects_extra_bindings(self):
        for missing in BINDINGS:
            with self.subTest(missing=missing):
                entries, descriptor, archive, inventory = install_fixture()
                del descriptor['source_bindings'][missing]
                self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)
        entries, descriptor, archive, inventory = install_fixture()
        descriptor['source_bindings']['etc/unchanged'] = {'bytes': 24, 'sha256': '0' * 64}
        self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)

    def test_each_jdk_input_is_bound_to_its_exact_content_and_size(self):
        for changed in BINDINGS:
            for field in ('bytes', 'sha256'):
                with self.subTest(changed=changed, field=field):
                    entries, descriptor, archive, inventory = install_fixture()
                    binding = descriptor['source_bindings'][changed]
                    binding[field] = binding[field] + 1 if field == 'bytes' else '0' * 64
                    self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)

    def test_rejects_missing_or_nonregular_bound_jdk_files(self):
        for changed in BINDINGS:
            for kind in (None, stat.S_IFLNK, stat.S_IFDIR):
                with self.subTest(changed=changed, kind=kind):
                    entries, descriptor, archive, inventory = install_fixture()
                    if kind is None:
                        del entries[changed]
                    else:
                        entries[changed] = (kind | 0o644, entries[changed][1])
                    self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)

    def test_invalid_inventory_cannot_mutate_signed_entries_even_with_matching_hash(self):
        entries, descriptor, archive, _ = install_fixture()
        inventory = inventory_bytes(REQUIRED_CLASSES + ('workspace.Main',))
        descriptor['inventory_sha256'] = digest(inventory)
        self.assert_rejected_without_mutation(entries, descriptor, archive, inventory)


if __name__ == '__main__':
    unittest.main(verbosity=2)
