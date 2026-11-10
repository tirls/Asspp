package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	cookiejar "github.com/juju/persistent-cookiejar"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/keychain"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
)

// configuration is supplied once by the app before any Store operation.
type configuration struct {
	StateDirectory   string `json:"stateDirectory"`
	DeviceIdentifier string `json:"deviceIdentifier"`
}

var (
	configMu sync.RWMutex
	config   configuration

	sessionsMu sync.Mutex
	sessions   = map[string]*session{}
)

// session isolates one Apple Account: its cookies, Store AMD provisioning state
// and kbsync cache never mix with another account's.
type session struct {
	store appstore.AppStore
	jar   *cookiejar.Jar
}

func configure(input configuration) error {
	identifier := normalizeIdentifier(input.DeviceIdentifier)
	if identifier == "" {
		return errors.New("device identifier must be 12 hexadecimal characters")
	}

	if input.StateDirectory == "" || !filepath.IsAbs(input.StateDirectory) {
		return errors.New("state directory must be an absolute path")
	}

	if err := os.MkdirAll(input.StateDirectory, 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}

	configMu.Lock()
	changed := config.DeviceIdentifier != identifier || config.StateDirectory != input.StateDirectory
	config = configuration{StateDirectory: input.StateDirectory, DeviceIdentifier: identifier}
	configMu.Unlock()

	// Store AMD state and kbsync blobs are bound to the device identifier.
	if changed {
		sessionsMu.Lock()
		sessions = map[string]*session{}
		sessionsMu.Unlock()
	}

	return nil
}

func currentConfiguration() (configuration, error) {
	configMu.RLock()
	defer configMu.RUnlock()

	if config.StateDirectory == "" {
		return configuration{}, errors.New("ipatool bridge is not configured")
	}

	return config, nil
}

func normalizeIdentifier(value string) string {
	value = strings.ToUpper(strings.NewReplacer(":", "", "-", "", " ", "").Replace(value))
	if len(value) != 12 {
		return ""
	}

	if _, err := hex.DecodeString(value); err != nil {
		return ""
	}

	return value
}

func accountDirectory(root, identifier, email string) string {
	digest := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(email)) + "\x00" + identifier))

	return filepath.Join(root, "accounts", hex.EncodeToString(digest[:12]))
}

func sessionFor(email string) (*session, error) {
	if strings.TrimSpace(email) == "" {
		return nil, errors.New("account email is required")
	}

	cfg, err := currentConfiguration()
	if err != nil {
		return nil, err
	}

	key := strings.ToLower(strings.TrimSpace(email))

	sessionsMu.Lock()
	defer sessionsMu.Unlock()

	if existing, ok := sessions[key]; ok {
		return existing, nil
	}

	directory := accountDirectory(cfg.StateDirectory, cfg.DeviceIdentifier, email)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, fmt.Errorf("create account state directory: %w", err)
	}

	jar, err := cookiejar.New(&cookiejar.Options{Filename: filepath.Join(directory, "cookies")})
	if err != nil {
		return nil, fmt.Errorf("open cookie jar: %w", err)
	}

	ring, err := newFileKeychain(filepath.Join(directory, "keychain.json"))
	if err != nil {
		return nil, err
	}

	created := &session{
		store: appstore.NewAppStore(appstore.Args{
			Keychain:        ring,
			CookieJar:       jar,
			OperatingSystem: operatingsystem.New(),
			Machine:         fixedMachine{identifier: cfg.DeviceIdentifier, home: cfg.StateDirectory},
		}),
		jar: jar,
	}
	// The dynamic availableStoreFronts request fails on iOS; see the overlay.
	appstore.SeedStorefronts(created.store)
	sessions[key] = created

	return created, nil
}

// forget drops the in-memory session and deletes its persisted state.
func forget(email string) error {
	cfg, err := currentConfiguration()
	if err != nil {
		return err
	}

	key := strings.ToLower(strings.TrimSpace(email))

	sessionsMu.Lock()
	delete(sessions, key)
	sessionsMu.Unlock()

	return os.RemoveAll(accountDirectory(cfg.StateDirectory, cfg.DeviceIdentifier, email))
}

func (s *session) save() {
	// Cookie persistence is best effort; a lost jar only costs a fresh sign-in.
	_ = s.jar.Save()
}

// fixedMachine reports Asspp's configured device identifier as the MAC address.
// iOS hides real interface addresses, and Apple binds sessions to this value.
type fixedMachine struct {
	identifier string
	home       string
}

func (m fixedMachine) MacAddress() (string, error) {
	parts := make([]string, 0, 6)
	for index := 0; index < len(m.identifier); index += 2 {
		parts = append(parts, m.identifier[index:index+2])
	}

	return strings.Join(parts, ":"), nil
}

func (m fixedMachine) HomeDirectory() string { return m.home }

func (fixedMachine) ReadPassword(int) ([]byte, error) {
	return nil, errors.New("interactive input is not available")
}

// fileKeychain stores ipatool's state in the app container. Asspp applies iOS
// data protection to the state directory; the container is private to the app.
type fileKeychain struct {
	mu     sync.Mutex
	path   string
	values map[string][]byte
}

var _ keychain.Keychain = (*fileKeychain)(nil)

func newFileKeychain(path string) (*fileKeychain, error) {
	ring := &fileKeychain{path: path, values: map[string][]byte{}}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ring, nil
	}

	if err != nil {
		return nil, fmt.Errorf("read keychain state: %w", err)
	}

	if err := json.Unmarshal(data, &ring.values); err != nil {
		// A corrupt file only loses provisioning and cached kbsync state.
		ring.values = map[string][]byte{}
	}

	return ring, nil
}

func (k *fileKeychain) Get(key string) ([]byte, error) {
	k.mu.Lock()
	defer k.mu.Unlock()

	value, ok := k.values[key]
	if !ok {
		return nil, fmt.Errorf("keychain item %q not found", key)
	}

	return append([]byte(nil), value...), nil
}

func (k *fileKeychain) Set(key string, data []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()

	k.values[key] = append([]byte(nil), data...)

	return k.persist()
}

func (k *fileKeychain) Remove(key string) error {
	k.mu.Lock()
	defer k.mu.Unlock()

	delete(k.values, key)

	return k.persist()
}

func (k *fileKeychain) persist() error {
	data, err := json.Marshal(k.values)
	if err != nil {
		return fmt.Errorf("encode keychain state: %w", err)
	}

	temporary := k.path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return fmt.Errorf("write keychain state: %w", err)
	}

	if err := os.Rename(temporary, k.path); err != nil {
		return fmt.Errorf("replace keychain state: %w", err)
	}

	return nil
}
