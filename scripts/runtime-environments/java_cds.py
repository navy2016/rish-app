"""Validate a separately generated static CDS archive; never execute guest code."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import tarfile
import zlib

JDK = 'usr/lib/jvm/java-21-openjdk/'
DESTINATION = JDK + 'lib/server/rish-compiler-http.jsa'
EVIDENCE = 'tmp/rish-cds-build/'
EXPORT_PATHS = {DESTINATION, EVIDENCE + 'flags.txt', EVIDENCE + 'dump.log', EVIDENCE + 'archive-inventory.txt'}
MAX_ARCHIVE = 128 << 20
MAX_LOG = 8 << 20
REQUIRED_BINDINGS = tuple(JDK + name for name in (
    'release', 'bin/java', 'lib/server/libjvm.so', 'lib/modules', 'lib/classlist',
    'lib/server/classes.jsa', 'lib/server/classes_nocoops.jsa',
    'jmods/java.compiler.jmod', 'jmods/jdk.compiler.jmod', 'jmods/jdk.httpserver.jmod'))
REQUIRED_CLASSES = (
    'com.sun.tools.javac.util.JavacMessages', 'com.sun.tools.javac.file.JavacFileManager',
    'com.sun.tools.javac.api.JavacTool', 'com.sun.tools.javac.launcher.Main',
    'com.sun.net.httpserver.HttpServer', 'sun.net.httpserver.ServerImpl')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def basename(value):
    return isinstance(value, str) and bool(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,159}', value))


def read_regular(path: Path, limit: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= limit:
            raise ValueError('invalid local CDS input')
        data = file.read(limit + 1)
        if len(data) != info.st_size:
            raise ValueError('CDS input changed while reading')
        return data


def load_candidate(path: Path) -> tuple:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate CDS receipt key')
            result[key] = value
        return result
    descriptor = json.loads(read_regular(path, 1 << 20), object_pairs_hook=unique)
    if (not isinstance(descriptor, dict) or descriptor.get('kind') != 'java-static-cds'
            or not basename(descriptor.get('filename')) or not basename(descriptor.get('inventory_filename'))
            or descriptor.get('build_only') is not True or descriptor.get('runtime_verified') is not False):
        raise ValueError('expected an explicit build-only CDS receipt')
    return (descriptor, read_regular(path.parent / descriptor['filename'], MAX_ARCHIVE),
            read_regular(path.parent / descriptor['inventory_filename'], MAX_LOG))


def read_export(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size > 256 << 20:
        raise ValueError('invalid CDS export size')
    found = {}
    end = 0
    try:
        with tarfile.open(path, 'r:') as archive:
            for member in archive:
                if (member.name not in EXPORT_PATHS or member.name in found
                        or not member.isfile() or member.pax_headers):
                    raise ValueError('unexpected or duplicate CDS export entry')
                limit = MAX_ARCHIVE if member.name == DESTINATION else MAX_LOG
                if not 1 <= member.size <= limit:
                    raise ValueError('CDS export member exceeds its bound')
                data = archive.extractfile(member).read(limit + 1)
                if len(data) != member.size:
                    raise ValueError('truncated CDS export member')
                found[member.name] = data
                end = max(end, member.offset_data + (member.size + 511) // 512 * 512)
    except tarfile.TarError as error:
        raise ValueError('invalid CDS export tar') from error
    if set(found) != EXPORT_PATHS:
        raise ValueError('missing CDS export member')
    with path.open('rb') as file:
        if path.stat().st_size < end + 1024:
            raise ValueError('missing CDS tar terminator')
        file.seek(end)
        while block := file.read(1 << 20):
            if any(block):
                raise ValueError('unexpected data after CDS export')
    return found


def validate_archive(archive: bytes, inventory: bytes) -> dict:
    if not isinstance(archive, bytes) or not 25 <= len(archive) <= MAX_ARCHIVE:
        raise ValueError('invalid CDS archive size')
    magic, crc, version, header_size, base_offset, base_size = struct.unpack_from('<IIiIII', archive)
    if (magic != 0xf00baba2 or version != 18 or not 24 <= header_size < len(archive)
            or base_offset != 0 or base_size != 0):
        raise ValueError('expected exact JDK 21 static archive header')
    if zlib.crc32(archive[16:header_size]) != crc:
        raise ValueError('CDS archive header CRC mismatch')
    if not isinstance(inventory, bytes) or not 1 <= len(inventory) <= MAX_LOG:
        raise ValueError('invalid CDS inventory size')
    try:
        lines = inventory.decode('utf-8').splitlines()
    except UnicodeError as error:
        raise ValueError('invalid CDS inventory encoding') from error
    if (not lines or lines[-1].strip() != 'archive is valid'
            or any('archive is invalid' in line.lower() for line in lines)
            or 'Static archive version 18' not in lines
            or 'Static archive name: /' + DESTINATION not in lines
            or not any(line.startswith('VM version: ') and '21.0.12+8-alpine-r0' in line for line in lines)):
        raise ValueError('CDS inventory does not verify the expected archive')
    section = None
    classes = set()
    loaders = {}
    for line in lines:
        if line == 'Shared Builtin Dictionary': section = 'builtin'
        elif line == 'Shared Unregistered Dictionary': section = 'unregistered'
        elif line == 'Shared Lambda Dictionary': section = 'lambda'
        if not re.match(r'^\s*\d+:', line):
            continue
        match = re.fullmatch(r'\s*\d+: (\S+) (boot_loader|platform_loader|app_loader)', line)
        if not match or section not in ('builtin', 'lambda'):
            raise ValueError('unsupported or unregistered CDS class inventory entry')
        name, loader = match.groups()
        if not name.startswith(('java.', 'javax.', 'jdk.', 'sun.', 'com.sun.', 'org.w3c.', 'org.xml.', 'org.ietf.')):
            raise ValueError('CDS inventory contains a non-JDK class')
        classes.add(name)
        loaders[loader] = loaders.get(loader, 0) + 1
    if not set(REQUIRED_CLASSES) <= classes:
        raise ValueError('CDS archive is missing a required compiler or HTTP class')
    return {'archive_version': version, 'required_classes': list(REQUIRED_CLASSES),
            'archived_classes': len(classes), 'classes_by_loader': loaders,
            'header_bytes': header_size, 'header_crc32': crc, 'static_archive': True}


def install(entries: dict, descriptor: dict, archive: bytes, inventory: bytes) -> dict:
    if (not isinstance(descriptor, dict) or descriptor.get('kind') != 'java-static-cds' or not basename(descriptor.get('filename'))
            or type(descriptor.get('bytes')) is not int or descriptor['bytes'] != len(archive)
            or descriptor.get('sha256') != digest(archive)
            or descriptor.get('inventory_sha256') != digest(inventory)):
        raise ValueError('CDS derived-file identity mismatch')
    bindings = descriptor.get('source_bindings')
    if not isinstance(bindings, dict) or set(bindings) != set(REQUIRED_BINDINGS):
        raise ValueError('CDS requires all exact signed JDK source bindings')
    for name, binding in bindings.items():
        value = entries.get(name)
        if (not isinstance(binding, dict) or set(binding) != {'bytes', 'sha256'}
                or type(binding['bytes']) is not int or not value or not stat.S_ISREG(value[0])
                or binding['bytes'] != len(value[1]) or binding['sha256'] != digest(value[1])):
            raise ValueError('CDS source binding differs from signed JDK content: ' + name)
    if DESTINATION in entries:
        raise ValueError('refusing to replace an existing CDS archive')
    result = validate_archive(archive, inventory)
    # Validate everything before mutating the caller's signed package entries.
    entries[DESTINATION] = stat.S_IFREG | 0o644, archive
    return result
