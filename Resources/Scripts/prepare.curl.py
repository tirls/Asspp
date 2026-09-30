#!/usr/bin/env python3
"""Build pinned libcurl/Mbed TLS for the Xcode SDK; bundle verified CA roots."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

INPUTS = {
    'curl.tar.xz': ('https://curl.se/download/curl-8.22.0.tar.xz', 'f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7'),
    'mbedtls.tar.bz2': ('https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.6/mbedtls-3.6.6.tar.bz2', '8fb65fae8dcae5840f793c0a334860a411f884cc537ea290ce1c52bb64ca007a'),
    'cacert.pem': ('https://curl.se/ca/cacert-2026-09-25.pem', 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505'),
}


def fetch(root, name):
    url, expected = INPUTS[name]
    path = root / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f'Invalid authentication build input: {name}')
        temporary = path.with_suffix('.pending')
        temporary.write_bytes(data)
        temporary.replace(path)
    return path


def extract(archive, destination):
    if destination.is_dir():
        return
    destination.mkdir()
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            parts = Path(member.name).parts[1:]
            if not parts:
                continue
            target = destination.joinpath(*parts).resolve()
            if not target.is_relative_to(destination.resolve()) or not (member.isdir() or member.isfile()):
                raise RuntimeError('Invalid archive member')
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.extractfile(member).read())


def run(*command):
    subprocess.run(command, check=True)


def main():
    root = Path(os.environ['DERIVED_FILE_DIR']) / 'AuthenticationCurl'
    root.mkdir(parents=True, exist_ok=True)
    curl_archive = fetch(root, 'curl.tar.xz')
    mbed_archive = fetch(root, 'mbedtls.tar.bz2')
    ca = fetch(root, 'cacert.pem')
    curl_source, mbed_source = root / 'curl-source', root / 'mbedtls-source'
    extract(curl_archive, curl_source)
    extract(mbed_archive, mbed_source)
    platform = os.environ['PLATFORM_NAME']
    target_key = 'MACOSX_DEPLOYMENT_TARGET' if platform == 'macosx' else 'IPHONEOS_DEPLOYMENT_TARGET'
    libraries = {name: [] for name in ['curl', 'mbedtls', 'mbedx509', 'mbedcrypto']}
    for arch in os.environ['ARCHS'].split():
        common = ['-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
                  f'-DCMAKE_OSX_SYSROOT={os.environ["SDKROOT"]}', f'-DCMAKE_OSX_ARCHITECTURES={arch}',
                  f'-DCMAKE_OSX_DEPLOYMENT_TARGET={os.environ[target_key]}']
        if platform != 'macosx':
            common.append('-DCMAKE_SYSTEM_NAME=iOS')
        build = root / f'{platform}-{arch}'
        prefix = build / 'install'
        run('cmake', '-S', str(mbed_source), '-B', str(build / 'mbedtls'), *common,
            '-DENABLE_TESTING=OFF', '-DENABLE_PROGRAMS=OFF', f'-DCMAKE_INSTALL_PREFIX={prefix}')
        run('cmake', '--build', str(build / 'mbedtls'), '-j', '8')
        run('cmake', '--install', str(build / 'mbedtls'))
        run('cmake', '-S', str(curl_source), '-B', str(build / 'curl'), *common,
            '-DBUILD_CURL_EXE=OFF', '-DBUILD_TESTING=OFF', '-DBUILD_STATIC_LIBS=ON', '-DHTTP_ONLY=ON',
            '-DCURL_USE_MBEDTLS=ON', '-DCURL_USE_OPENSSL=OFF', '-DCURL_USE_LIBPSL=OFF',
            '-DCURL_USE_LIBSSH2=OFF', '-DCURL_USE_GSSAPI=OFF', '-DUSE_LIBIDN2=OFF',
            '-DCURL_USE_PKGCONFIG=OFF', '-DCURL_ZLIB=OFF', '-DCURL_BROTLI=OFF', '-DCURL_ZSTD=OFF',
            '-DUSE_NGHTTP2=OFF', '-DUSE_NGTCP2=OFF', '-DUSE_QUICHE=OFF',
            '-DCURL_CA_BUNDLE=none', '-DCURL_CA_PATH=none',
            f'-DMBEDTLS_INCLUDE_DIR={prefix}/include', f'-DMBEDTLS_LIBRARY={prefix}/lib/libmbedtls.a',
            f'-DMBEDX509_LIBRARY={prefix}/lib/libmbedx509.a', f'-DMBEDCRYPTO_LIBRARY={prefix}/lib/libmbedcrypto.a',
            f'-DCMAKE_INSTALL_PREFIX={prefix}')
        run('cmake', '--build', str(build / 'curl'), '-j', '8')
        run('cmake', '--install', str(build / 'curl'))
        for name in libraries:
            libraries[name].append(str(prefix / f'lib/lib{name}.a'))
    (root / 'lib').mkdir(exist_ok=True)
    for name, paths in libraries.items():
        run('xcrun', 'lipo', '-create', *paths, '-output', str(root / f'lib/lib{name}.a'))
    shutil.copytree(prefix / 'include/curl', root / 'include/curl', dirs_exist_ok=True)
    resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'AuthenticationTLS'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ca, resources / 'cacert.pem')
    shutil.copy2(curl_source / 'COPYING', resources / 'curl-LICENSE.txt')
    shutil.copy2(mbed_source / 'LICENSE', resources / 'MbedTLS-LICENSE.txt')
    (resources / 'CA-source.txt').write_text('Mozilla CA roots, MPL-2.0\n' + INPUTS['cacert.pem'][0] + '\n')
    print('Prepared libcurl 8.22.0 / Mbed TLS 3.6.6 with verified CA roots.')


if __name__ == '__main__':
    main()
