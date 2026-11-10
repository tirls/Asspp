# ipatool Store engine

Since November 2026 Apple rejects App Store commerce requests (`volumeStoreDownloadProduct`,
`redownload`, `updateProduct`, purchase and sign-in) that do not carry a Store AMD device proof,
and the preferred download endpoint `ent/download` needs a `kbsync` blob. Without them the
requests fail with HTTP 403 and an empty body.

ipatool 2.8 produces both locally by running pinned macOS 27 components (AppleMediaServices,
`adid`, `fairplayd`, FairPlayIOKit, CommerceKit) in Unicorn. Asspp links ipatool as a Go
library instead of porting that code.

## Layout

| Path | Purpose |
|---|---|
| `IPAToolBridge/overlay/pkg/appstore/appstore_asspp.go` | Copied into ipatool. `ResolveDownload` runs ipatool's download request chain and returns the package URL, sinfs and metadata without transferring the IPA. |
| `IPAToolBridge/overlay/asspp/bridge/` | Copied into ipatool. cgo exports `AssppIPAToolCall`, `AssppIPAToolCancel`, `AssppIPAToolFree` (JSON in, JSON out). One ipatool session per account, state under Application Support. |
| `Resources/Scripts/build.ipatool.sh` | Fetches the pinned ipatool and Unicorn revisions, builds Unicorn's TCI interpreter (AArch64 guest, no JIT) and the Go c-archive for `iphoneos`, and writes `Configuration/IPATool.generated.xcconfig`. |
| `Asspp/Backend/AppStore/IPATool.swift` | Swift wrapper. Compiled against the bridge only when `ASSPP_IPATOOL` is defined by the generated xcconfig. |

Builds without the bridge (simulator, macOS, or a checkout where the script did not run) keep
the ApplePackage store path, which Apple now rejects for downloads.

## Building

```bash
Resources/Scripts/build.ipatool.sh
```

Requires Xcode, CMake and Go (`GOTOOLCHAIN=auto` downloads the version ipatool's `go.mod`
asks for). `compile.release.mobile.ci.sh` runs it automatically; set `ASSPP_IPATOOL=0` to skip.

## Runtime behaviour

- Sign-in uses ipatool's native flow, including Store device provisioning. Accounts saved by
  older versions have no ipatool session and must sign in again before downloading.
- The first Store operation downloads and verifies about 175 MB of Apple components from
  Apple's CDN (ranges of the macOS 27.0.1 restore image) into `Library/Caches/ipatool`.
  Nothing from Apple is bundled with the app.
- All guest code runs in Unicorn's TCI interpreter because iOS forbids JIT for sideloaded
  apps. Expect operations to be much slower than ipatool on a desktop.

## Updating ipatool

Bump `IPATOOL_REVISION` in `build.ipatool.sh`. `appstore_asspp.go` calls ipatool internals
(`sendDownloadProduct`, `downloadPackagePlatform`, `lookupLatestExternalVersionID`), so check
that they still exist with the same signatures.

## Licences

ipatool is MIT licensed. Unicorn is GPLv2; distributing an app that statically links it must
follow GPLv2, including offering the corresponding source.
