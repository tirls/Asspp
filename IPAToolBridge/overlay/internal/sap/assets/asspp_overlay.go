// Asspp overlay: copied into ipatool's internal/sap/assets by
// Resources/Scripts/build.ipatool.sh, which renames the original Load to
// loadUncached and remoteFile.ReadAt to readAtDirect.
//
// On a phone, ipatool's restore-image reader is dominated by round trips:
// every ReadAt is one HTTP range request, and the 33 MB deflated kernel
// collection is read through a 4 KB bufio buffer (about 8,000 requests).
// Aligned 1 MB chunks turn those into a few dozen requests. Load is also
// memoized, because every Store request otherwise re-reads and re-hashes
// about 175 MB from the cache directory.

package assets

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

const (
	remoteChunkSize   = 1 << 20
	remoteChunkLimit  = 24
	progressReportRaw = 16 << 20
)

var (
	progressMu      sync.RWMutex
	progressHandler func(string)

	loadMu sync.Mutex
	loaded *Bundle

	remoteCaches sync.Map // *remoteFile -> *remoteChunks
)

// SetProgressHandler receives human-readable progress for the first-time
// download of Apple components. Messages never contain account data.
func SetProgressHandler(handler func(string)) {
	progressMu.Lock()
	progressHandler = handler
	progressMu.Unlock()
}

func report(format string, arguments ...interface{}) {
	progressMu.RLock()
	handler := progressHandler
	progressMu.RUnlock()

	if handler != nil {
		handler(fmt.Sprintf(format, arguments...))
	}
}

// Load returns the verified Apple components, downloading them on first use.
func Load(ctx context.Context) (Bundle, error) {
	loadMu.Lock()
	defer loadMu.Unlock()

	if loaded != nil {
		return *loaded, nil
	}

	started := time.Now()
	report("Preparing Apple components (first use downloads about 175 MB)")

	bundle, err := loadUncached(ctx)

	remoteCaches.Range(func(key, _ interface{}) bool {
		remoteCaches.Delete(key)

		return true
	})

	if err != nil {
		report("Apple components failed after %s: %v", time.Since(started).Round(time.Second), err)

		return Bundle{}, err
	}

	report("Apple components ready in %s", time.Since(started).Round(time.Second))

	loaded = &bundle

	return bundle, nil
}

type remoteChunks struct {
	mu       sync.Mutex
	chunks   map[int64][]byte
	order    []int64
	fetched  int64
	requests int64
	reported int64
	started  time.Time
}

func chunksFor(file *remoteFile) *remoteChunks {
	created := &remoteChunks{chunks: map[int64][]byte{}, started: time.Now()}
	actual, _ := remoteCaches.LoadOrStore(file, created)

	return actual.(*remoteChunks)
}

func (c *remoteChunks) account(count int) {
	c.fetched += int64(count)
	c.requests++

	if c.fetched-c.reported >= progressReportRaw {
		c.reported = c.fetched
		report("Downloading Apple components: %d MB in %d requests (%s)",
			c.fetched>>20, c.requests, time.Since(c.started).Round(time.Second))
	}
}

func (c *remoteChunks) chunk(file *remoteFile, index int64) ([]byte, error) {
	if data, ok := c.chunks[index]; ok {
		return data, nil
	}

	start := index * remoteChunkSize
	size := min(int64(remoteChunkSize), file.size-start)
	data := make([]byte, size)

	count, err := file.readAtDirect(data, start)
	c.account(count)

	if err != nil && !(errors.Is(err, io.EOF) && int64(count) == size) {
		return nil, err
	}

	if len(c.order) == remoteChunkLimit {
		delete(c.chunks, c.order[0])
		c.order = c.order[1:]
	}

	c.chunks[index] = data
	c.order = append(c.order, index)

	return data, nil
}

// ReadAt serves small reads from aligned chunks and passes large reads through.
func (r *remoteFile) ReadAt(data []byte, offset int64) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}

	if offset < 0 {
		return 0, errors.New("negative remote image offset")
	}

	if offset >= r.size {
		return 0, io.EOF
	}

	cache := chunksFor(r)

	cache.mu.Lock()
	defer cache.mu.Unlock()

	if len(data) >= remoteChunkSize {
		count, err := r.readAtDirect(data, offset)
		cache.account(count)

		return count, err
	}

	wanted := int64(len(data))
	if remaining := r.size - offset; wanted > remaining {
		wanted = remaining
	}

	written := int64(0)
	for written < wanted {
		position := offset + written
		index := position / remoteChunkSize

		chunk, err := cache.chunk(r, index)
		if err != nil {
			return int(written), err
		}

		inside := position - index*remoteChunkSize
		if inside >= int64(len(chunk)) {
			return int(written), io.ErrUnexpectedEOF
		}

		written += int64(copy(data[written:wanted], chunk[inside:]))
	}

	if wanted != int64(len(data)) {
		return int(written), io.EOF
	}

	return int(written), nil
}
