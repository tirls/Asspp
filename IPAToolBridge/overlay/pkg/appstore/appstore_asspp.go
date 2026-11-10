// Asspp overlay: copied into ipatool's pkg/appstore by
// Resources/Scripts/build.ipatool.sh. It exposes the Store commerce step of
// Download without transferring the package, so Asspp keeps its own resumable
// downloader, progress UI and signature injection.

package appstore

import (
	"errors"
	"fmt"
	"strings"
)

// ResolvedDownload is the package location and licensing data for one app version.
type ResolvedDownload struct {
	URL      string
	MD5      string
	Sinfs    []Sinf
	Metadata map[string]interface{}
	Platform Platform
}

// ResolveDownload performs the same Store requests as Download (ent/download
// with kbsync, then volumeStore, redownload and updateProduct, each carrying a
// Store AMD proof) and returns the selected package item.
func ResolveDownload(store AppStore, input DownloadInput) (ResolvedDownload, error) {
	t, ok := store.(*appstore)
	if !ok {
		return ResolvedDownload{}, errors.New("unsupported App Store implementation")
	}

	macAddr, err := t.machine.MacAddress()
	if err != nil {
		return ResolvedDownload{}, fmt.Errorf("failed to get mac address: %w", err)
	}

	guid := strings.ReplaceAll(strings.ToUpper(macAddr), ":", "")

	externalVersionID := input.ExternalVersionID
	if externalVersionID == "" && (input.Platform == PlatformAppleTV || input.Platform == PlatformWatchOS || input.Platform == PlatformVisionOS) {
		externalVersionID, err = t.lookupLatestExternalVersionID(input.Account, input.App, input.Platform)
		missingTVOffer := input.Platform == PlatformAppleTV &&
			(errors.Is(err, errPlatformAppNotFound) || errors.Is(err, errPlatformOffersNotFound))
		if err != nil && !missingTVOffer {
			return ResolvedDownload{}, fmt.Errorf("failed to resolve platform version: %w", err)
		}
	}

	res, resolvedPlatform, err := t.sendDownloadProduct(input.Context, input.Account, input.App, guid, externalVersionID, input.Platform)
	if err != nil {
		return ResolvedDownload{}, err
	}

	switch res.Data.FailureType {
	case FailureTypePasswordTokenExpired, FailureTypeSignInRequired,
		FailureTypeDeviceVerificationFailed, FailureTypeLicenseAlreadyExists:
		return ResolvedDownload{}, ErrPasswordTokenExpired
	case FailureTypeLicenseNotFound:
		return ResolvedDownload{}, ErrLicenseRequired
	}

	if res.Data.CustomerMessage != "" && (res.Data.FailureType != "" || len(res.Data.Items) == 0) {
		return ResolvedDownload{}, NewErrorWithMetadata(fmt.Errorf("received error: %s", res.Data.CustomerMessage), res)
	}

	if res.Data.FailureType != "" {
		return ResolvedDownload{}, NewErrorWithMetadata(fmt.Errorf("received error: %s", res.Data.FailureType), res)
	}

	if len(res.Data.Items) == 0 {
		return ResolvedDownload{}, NewErrorWithMetadata(errors.New("invalid response"), res)
	}

	item := res.Data.Items[0]
	if item.URL == "" {
		return ResolvedDownload{}, errors.New("download response has no package URL")
	}

	packagePlatform, err := downloadPackagePlatform(input.Platform, item)
	if err != nil {
		return ResolvedDownload{}, err
	}

	if packagePlatform == PlatformMacOS {
		return ResolvedDownload{}, errors.New("macOS installer packages are not supported by Asspp")
	}

	if resolvedPlatform == "" {
		resolvedPlatform = packagePlatform
	}

	return ResolvedDownload{
		URL:      item.URL,
		MD5:      item.HashMD5,
		Sinfs:    item.Sinfs,
		Metadata: item.Metadata,
		Platform: resolvedPlatform,
	}, nil
}
