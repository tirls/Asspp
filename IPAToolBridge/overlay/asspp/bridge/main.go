// Package main is Asspp's C bridge to ipatool. It is built with
// -buildmode=c-archive by Resources/Scripts/build.ipatool.sh.
//
// Every call takes and returns UTF-8 JSON. Responses are
// {"ok":true,"result":...} or {"ok":false,"error":{"code":...,"message":...}}.
// Calls block; the app runs them off the main thread.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/pkg/appstore"
)

func main() {}

func init() {
	assets.SetProgressHandler(logf)
	appstore.AssppDiagnostics = func(line string) { logf("%s", redact(line)) }
}

const logLimit = 200

var (
	logMu    sync.Mutex
	logLines []string
)

// logf records diagnostics for the app's log viewer. Callers pass operation
// names, durations and progress only, never account data or Apple replies.
func logf(format string, arguments ...interface{}) {
	logMu.Lock()
	defer logMu.Unlock()

	logLines = append(logLines, fmt.Sprintf(format, arguments...))
	if len(logLines) > logLimit {
		logLines = logLines[len(logLines)-logLimit:]
	}
}

// AssppIPAToolDrainLog returns and clears pending diagnostic lines, one per
// line. The returned string must be released with AssppIPAToolFree.
//
//export AssppIPAToolDrainLog
func AssppIPAToolDrainLog() *C.char {
	logMu.Lock()
	lines := logLines
	logLines = nil
	logMu.Unlock()

	return C.CString(strings.Join(lines, "\n"))
}

type response struct {
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  *failure    `json:"error,omitempty"`
}

type failure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type handler func(ctx context.Context, request []byte) (interface{}, error)

var handlers = map[string]handler{
	"configure":       handleConfigure,
	"login":           handleLogin,
	"resolveDownload": handleResolveDownload,
	"listVersions":    handleListVersions,
	"versionMetadata": handleVersionMetadata,
	"purchase":        handlePurchase,
	"forget":          handleForget,
}

var (
	cancelMu sync.Mutex
	cancels  = map[string]context.CancelFunc{}
)

// AssppIPAToolCall runs one operation. The returned string must be released
// with AssppIPAToolFree.
//
//export AssppIPAToolCall
func AssppIPAToolCall(operation *C.char, request *C.char) *C.char {
	return C.CString(call(C.GoString(operation), []byte(C.GoString(request))))
}

// AssppIPAToolCancel cancels a running operation that was started with the
// same "requestId". Operations without cancellation support finish normally.
//
//export AssppIPAToolCancel
func AssppIPAToolCancel(requestID *C.char) {
	cancelMu.Lock()
	cancel := cancels[C.GoString(requestID)]
	cancelMu.Unlock()

	if cancel != nil {
		cancel()
	}
}

// AssppIPAToolFree releases a string returned by AssppIPAToolCall.
//
//export AssppIPAToolFree
func AssppIPAToolFree(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func call(operation string, request []byte) (output string) {
	defer func() {
		// A guest emulation fault must not terminate the app.
		if recovered := recover(); recovered != nil {
			output = encode(response{Error: &failure{Code: "internal", Message: fmt.Sprint(recovered)}})
		}
	}()

	handle, ok := handlers[operation]
	if !ok {
		return encode(response{Error: &failure{Code: "invalidRequest", Message: "unknown operation " + operation}})
	}

	var envelope struct {
		RequestID string `json:"requestId"`
	}
	_ = json.Unmarshal(request, &envelope)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if envelope.RequestID != "" {
		cancelMu.Lock()
		cancels[envelope.RequestID] = cancel
		cancelMu.Unlock()

		defer func() {
			cancelMu.Lock()
			delete(cancels, envelope.RequestID)
			cancelMu.Unlock()
		}()
	}

	started := time.Now()
	if operation != "configure" {
		logf("%s started", operation)
	}

	result, err := handle(ctx, request)
	if operation != "configure" {
		status := "ok"
		if err != nil {
			status = classify(err).Code + ": " + redact(err.Error())
		}

		logf("%s finished in %s (%s)", operation, time.Since(started).Round(100*time.Millisecond), status)
	}

	if err != nil {
		if ctx.Err() != nil && !errors.Is(err, context.Canceled) {
			err = fmt.Errorf("%w: %w", context.Canceled, err)
		}

		return encode(response{Error: classify(err)})
	}

	return encode(response{OK: true, Result: result})
}

var (
	redactURL    = regexp.MustCompile(`https?://[^\s"']+`)
	redactEmail  = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)
	redactNumber = regexp.MustCompile(`\d{7,}`)
	redactToken  = regexp.MustCompile(`[A-Za-z0-9+/=_-]{32,}`)
)

// redact keeps error chains readable in the log while removing values that
// can identify an account: addresses, URLs (hosts kept), long identifiers.
func redact(message string) string {
	message = redactURL.ReplaceAllStringFunc(message, func(raw string) string {
		if index := strings.IndexAny(raw, "?#"); index >= 0 {
			raw = raw[:index] + "?…"
		}

		return raw
	})
	message = redactEmail.ReplaceAllString(message, "<email>")
	message = redactNumber.ReplaceAllString(message, "<number>")
	message = redactToken.ReplaceAllString(message, "<token>")

	if len(message) > 600 {
		message = message[:600] + "…"
	}

	return message
}

func encode(value response) string {
	data, err := json.Marshal(value)
	if err != nil {
		return `{"ok":false,"error":{"code":"internal","message":"failed to encode response"}}`
	}

	return string(data)
}
