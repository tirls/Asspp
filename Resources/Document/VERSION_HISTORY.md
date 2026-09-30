# Native version history

Build 4.2.0(4) retains the ipatool-native-v1 authentication implementation from
4.2.0(3). Version listing and historical metadata now use StoreVersionService,
adapted from Asspp PR #63 (65be5b04daea30daf62d7f6dcccfefdfa8891e9a)
and the working AssppWeb downloadProduct flow.

The version metadata request first uses volumeStoreDownloadProduct. Empty or
missing songList, failure 5002, and the observed no-longer-available response can
recover once through redownload. For an unpinned query, Apple's public catalog
resolves an external version for the selected iOS platform and account storefront.
A historical query preserves its requested ID. If redownload is still empty or
returns an empty HTTP 500, the bag's updateProduct endpoint can be tried once.
Explicit license, account and token errors are not treated as empty responses.

Search results retain their platform; legacy packages default to iPhone. History
cache keys include the platform. List and metadata requests validate the returned
bundle and explicit version, merge cookies, and follow validated Apple redirects.
Settings > Logs shows Store versions entries containing app/platform, endpoint,
HTTP status, item count, numeric error codes and fallback reason. Credentials,
response bodies and download URLs are not logged.

Sources:
- https://github.com/Lakr233/Asspp/pull/63
- frontend/src/apple/downloadProduct.ts and versionFinder.ts in the personal
  AssppWeb deployment.
