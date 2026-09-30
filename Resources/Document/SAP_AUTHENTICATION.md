# Signed App Store authentication

This branch starts at upstream Asspp `caed708182c61897bd539557a10618f9b0eba066`
(4.2.0), applies the iOS interpreter bridge from Asspp PR #62, then aligns it with
official ipatool 2.5.0 (`d5d0b56faf64e3fdef885d49e7928b390aadb6c7`).
Asspp replaces ApplePackage's unsigned login with this SAP-signed flow.
Authentication and account refresh both use the new implementation.
ApplePackage continues to provide account models, catalog, license and IPA operations.

## Runtime

The app obtains the current authentication endpoint and SAP setup configuration
from Apple's bag, completes the SAP handshake, and signs the exact serialized
login body. Transient retries sign the same serialized body again. The login loop
matches ipatool: an initial `-5000` challenge advances from attempt 1 to 2; a pod
redirect sends attempt 1 to the validated redirected URL, with at most four steps.
Passwords, codes, signatures and cookies are never sent to an auxiliary server.

The device GUID is uppercase hexadecimal decoded into six hardware bytes. Platform
errors retain their native all-ones return value, and `_get_mac_address` executes
CommerceCore's real export rather than PR #62's added MAC shim. SAP setup uses
`application/x-plist`; bag/setup/login use ipatool's Configurator User-Agent.
The app uses URLSession and Apple's bag-selected legacy authentication endpoint.
There is no forced `/native/fast/` URL, browser transport, Worker or container.

The x86 SAP implementation runs locally in Unicorn's TCI interpreter. It does not
allocate executable code buffers, require JIT, private Apple entitlements, or a
Mac helper. Each login has its own short-lived emulator and ephemeral cookie jar.
The app decompresses and verifies all four Apple assets before loading them into
the interpreter. Assets are bundled as `.sapz` data so SideStore does not attempt
to sign the interpreted Mach-O images. Decompressed lengths and SHA-256 hashes
must match the original pinned inputs.

Foundation represents domain cookies with a leading dot; ApplePackage 1.2.7's
request matcher expects the bare domain. Login export normalizes that format,
and every store operation also normalizes previously saved account cookies.
Restoring cookies for SAP reauthentication preserves their subdomain scope.
License acquisition refreshes through the same signed authenticator.

Login requests follow only HTTPS redirects to the documented buy/pN-buy Apple
hosts and authentication path. Certificate validation remains enabled, including
Debug builds. Unstructured HTTP 204, 404 and 5xx responses get at most three
transport attempts. Credential errors, HTTP 403 and 429 do not trigger that retry.
Only Apple's explicit code challenge/rejection reveals the verification-code UI.

## Reproducible builds

Install CMake (`brew install cmake`) alongside Xcode. The existing workspace build
runs `Resources/Scripts/prepare.sap.py` before compiling the app. No Go runtime or
installed ipatool is needed.

The script fetches a pinned, SHA-256-checked Unicorn source archive, builds only the
x86 guest interpreter for the selected Apple platform/architectures, and downloads
the four SAP assets directly from Apple's software-update package. It verifies
the expected lengths and SHA-256 digests used by official ipatool. Inputs and
libraries are cached in Xcode's DerivedSources/SAP directory. The initial build
requires access to GitHub and Apple's download servers. Subsequent builds reuse
verified assets and the pinned source. Apple binaries are not committed here.

The app bundle includes compressed Apple SAP data, plus the interpreter and its pinned source archive.
The data files are interpreted; they are not loaded as native dynamic libraries.

The dedicated `Unsigned iOS IPA` GitHub Actions workflow builds version 4.2.0(3),
checks the packaged asset hashes, and uploads an unsigned IPA plus its SHA-256.

## Regression checks

Run the regression suite on macOS:

```sh
bash Resources/Scripts/check.sap.sh
```

This checks credential redirects, plist decoding, request serialization, cookie
scope, challenges, retry limits, compiled English/Chinese resources and build
cache invalidation. Native allocator and malformed Mach-O checks run under
AddressSanitizer and UndefinedBehaviorSanitizer. An optional argument points to
an existing macOS `DerivedSources/SAP` directory to reuse the interpreter build.
The suite requires no Apple account. It also runs in a dedicated PR workflow.

A successful public SAP handshake proves that the signing engine works. It does
not by itself establish that Apple will accept any particular account or network.
Empty/location-less Apple responses remain distinguishable from password and 2FA
errors; the app does not silently fall back to unsigned authentication.

## Sources and licenses

- Protocol and native platform behavior: [majd/ipatool 2.5.0](https://github.com/majd/ipatool/tree/v2.5.0),
  commit `d5d0b56faf64e3fdef885d49e7928b390aadb6c7`, MIT; see `Resources/Licenses/ipatool.txt`.
- C++ Mach-O loader and SAP host shims adapted from
  [Sorvigolova/ipatool](https://github.com/Sorvigolova/ipatool), commit
  `def04b943b9b7da11571fffcc46de79f07b94c01`, MIT. The bridge comes from
  [Asspp #62](https://github.com/Lakr233/Asspp/pull/62), commit
  `2b46c813a350ef9941cd7f8e1fd1af73de751671`, with the native behavior aligned as above.
- [Naville/unicorn, feature/tci](https://github.com/Naville/unicorn/tree/feature/tci),
  commit `53471ef9cf480fab094bf13db3e5d2f9e2c30dc5`, GPL-2.0; see
  `Resources/Licenses/Unicorn.txt`. Build scripts identify the complete source of
  the linked interpreter. Distribution of the combined binary must comply with
  its GPL terms; Asspp's original source retains its MIT notice.
- Apple framework assets remain Apple's software and are retrieved from Apple.
