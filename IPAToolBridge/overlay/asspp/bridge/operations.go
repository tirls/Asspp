package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/majd/ipatool/v2/pkg/appstore"
	"howett.net/plist"
)

type appReference struct {
	ID       int64  `json:"id"`
	BundleID string `json:"bundleId"`
}

func (a appReference) app() (appstore.App, error) {
	if a.ID <= 0 {
		return appstore.App{}, errors.New("app ID is required")
	}

	return appstore.App{ID: a.ID, BundleID: a.BundleID}, nil
}

// productRequest is shared by operations that act on one app for one account.
type productRequest struct {
	Account   appstore.Account `json:"account"`
	App       appReference     `json:"app"`
	Platform  string           `json:"platform"`
	VersionID string           `json:"versionId"`
}

func decodeProduct(data []byte) (productRequest, *session, appstore.App, error) {
	var request productRequest
	if err := json.Unmarshal(data, &request); err != nil {
		return request, nil, appstore.App{}, invalid(err)
	}

	app, err := request.App.app()
	if err != nil {
		return request, nil, app, invalid(err)
	}

	current, err := sessionFor(request.Account.Email)
	if err != nil {
		return request, nil, app, err
	}

	return request, current, app, nil
}

func platform(value string) appstore.Platform {
	if value == "" {
		return appstore.PlatformIPhone
	}

	return appstore.Platform(strings.ToLower(value))
}

func handleConfigure(_ context.Context, data []byte) (interface{}, error) {
	var request configuration
	if err := json.Unmarshal(data, &request); err != nil {
		return nil, invalid(err)
	}

	return struct{}{}, configure(request)
}

func handleLogin(_ context.Context, data []byte) (interface{}, error) {
	var request struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		AuthCode string `json:"authCode"`
	}
	if err := json.Unmarshal(data, &request); err != nil {
		return nil, invalid(err)
	}

	current, err := sessionFor(request.Email)
	if err != nil {
		return nil, err
	}
	defer current.save()

	output, err := current.store.Login(appstore.LoginInput{
		Email:    request.Email,
		Password: request.Password,
		AuthCode: request.AuthCode,
	})
	if err != nil {
		return nil, err
	}

	return output.Account, nil
}

type sinfOutput struct {
	ID     int64  `json:"id"`
	Data   []byte `json:"data"`
	DPInfo []byte `json:"dpInfo,omitempty"`
}

func handleResolveDownload(ctx context.Context, data []byte) (interface{}, error) {
	request, current, app, err := decodeProduct(data)
	if err != nil {
		return nil, err
	}
	defer current.save()

	resolved, err := appstore.ResolveDownload(current.store, appstore.DownloadInput{
		Context:           ctx,
		Account:           request.Account,
		App:               app,
		ExternalVersionID: request.VersionID,
		Platform:          platform(request.Platform),
	})
	if err != nil {
		return nil, err
	}

	// Metadata values include dates and data; a binary plist keeps their types
	// intact for the iTunesMetadata.plist that Asspp writes into the package.
	metadata, err := plist.Marshal(resolved.Metadata, plist.BinaryFormat)
	if err != nil {
		return nil, fmt.Errorf("encode package metadata: %w", err)
	}

	sinfs := make([]sinfOutput, 0, len(resolved.Sinfs))
	for _, sinf := range resolved.Sinfs {
		sinfs = append(sinfs, sinfOutput{ID: sinf.ID, Data: sinf.Data, DPInfo: sinf.DPInfo})
	}

	return struct {
		URL      string       `json:"url"`
		MD5      string       `json:"md5,omitempty"`
		Sinfs    []sinfOutput `json:"sinfs"`
		Metadata []byte       `json:"metadata"`
		Platform string       `json:"platform"`
	}{resolved.URL, resolved.MD5, sinfs, metadata, string(resolved.Platform)}, nil
}

func handleListVersions(ctx context.Context, data []byte) (interface{}, error) {
	request, current, app, err := decodeProduct(data)
	if err != nil {
		return nil, err
	}
	defer current.save()

	output, err := current.store.ListVersions(appstore.ListVersionsInput{
		Context:  ctx,
		Account:  request.Account,
		App:      app,
		Platform: platform(request.Platform),
	})
	if err != nil {
		return nil, err
	}

	return struct {
		Versions []string `json:"versions"`
		Latest   string   `json:"latest"`
	}{output.ExternalVersionIdentifiers, output.LatestExternalVersionID}, nil
}

func handleVersionMetadata(ctx context.Context, data []byte) (interface{}, error) {
	request, current, app, err := decodeProduct(data)
	if err != nil {
		return nil, err
	}
	defer current.save()

	if request.VersionID == "" {
		return nil, invalid(errors.New("version ID is required"))
	}

	output, err := current.store.GetVersionMetadata(appstore.GetVersionMetadataInput{
		Context:   ctx,
		Account:   request.Account,
		App:       app,
		VersionID: request.VersionID,
		Platform:  platform(request.Platform),
	})
	if err != nil {
		return nil, err
	}

	return struct {
		DisplayVersion string `json:"displayVersion"`
		ReleaseDate    string `json:"releaseDate"`
	}{output.DisplayVersion, output.ReleaseDate.UTC().Format(time.RFC3339)}, nil
}

func handlePurchase(_ context.Context, data []byte) (interface{}, error) {
	request, current, app, err := decodeProduct(data)
	if err != nil {
		return nil, err
	}
	defer current.save()

	err = current.store.Purchase(appstore.PurchaseInput{
		Account:  request.Account,
		App:      app,
		Platform: platform(request.Platform),
	})
	if err != nil {
		return nil, err
	}

	return struct{}{}, nil
}

func handleForget(_ context.Context, data []byte) (interface{}, error) {
	var request struct {
		Email string `json:"email"`
	}
	if err := json.Unmarshal(data, &request); err != nil {
		return nil, invalid(err)
	}

	return struct{}{}, forget(request.Email)
}

type invalidRequestError struct{ err error }

func (e invalidRequestError) Error() string { return e.err.Error() }
func (e invalidRequestError) Unwrap() error { return e.err }

func invalid(err error) error { return invalidRequestError{err} }

func classify(err error) *failure {
	code := "failed"

	var invalidRequest invalidRequestError

	switch {
	case errors.As(err, &invalidRequest):
		code = "invalidRequest"
	case errors.Is(err, context.Canceled):
		code = "canceled"
	case errors.Is(err, appstore.ErrAuthCodeRequired):
		code = "authCodeRequired"
	case errors.Is(err, appstore.ErrPasswordTokenExpired):
		code = "passwordTokenExpired"
	case errors.Is(err, appstore.ErrLicenseRequired):
		code = "licenseRequired"
	case errors.Is(err, appstore.ErrLicenseAlreadyExists):
		code = "licenseAlreadyExists"
	case errors.Is(err, appstore.ErrSubscriptionRequired):
		code = "subscriptionRequired"
	case errors.Is(err, appstore.ErrTemporarilyUnavailable):
		code = "temporarilyUnavailable"
	case errors.Is(err, appstore.ErrAppNotFound):
		code = "appNotFound"
	}

	return &failure{Code: code, Message: err.Error()}
}
