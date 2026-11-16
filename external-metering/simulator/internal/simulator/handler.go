// Package simulator implements the gateway's OpenMeter-compatible logging API.
package simulator

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const MaxEventBytes = 64 << 10

// Handler serializes writes so concurrent events never interleave on stdout.
type Handler struct {
	events io.Writer
	logger *slog.Logger
	mu     sync.Mutex
}

func New(events io.Writer, logger *slog.Logger) http.Handler {
	h := &Handler{events: events, logger: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthy)
	mux.HandleFunc("GET /readyz", healthy)
	mux.HandleFunc("GET /api/v1/customers/{id}/entitlements/{key}/value", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = io.WriteString(w, "{\"hasAccess\":true,\"balance\":0,\"usage\":0,\"overage\":0}\n")
	})
	mux.HandleFunc("POST /api/v1/events", h.ingest)
	return mux
}

func healthy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, "ok\n")
}

func (h *Handler) ingest(w http.ResponseWriter, r *http.Request) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || (mediaType != "application/json" && mediaType != "application/cloudevents+json") {
		http.Error(w, "expected a structured JSON CloudEvent", http.StatusUnsupportedMediaType)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxEventBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			http.Error(w, "event exceeds 64 KiB", http.StatusRequestEntityTooLarge)
		} else {
			http.Error(w, "cannot read event", http.StatusBadRequest)
		}
		return
	}
	if err := validate(body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// Compact the original bytes instead of decoding/re-encoding data numbers.
	var line bytes.Buffer
	if err := json.Compact(&line, body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	line.WriteByte('\n')
	h.mu.Lock()
	n, err := h.events.Write(line.Bytes())
	h.mu.Unlock()
	if err != nil || n != line.Len() {
		h.logger.Error("event log write failed", "error", err, "bytes_written", n)
		http.Error(w, "cannot log event", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func validate(body []byte) error {
	var event map[string]json.RawMessage
	if err := json.Unmarshal(body, &event); err != nil || event == nil {
		return errors.New("expected a single JSON object")
	}
	for _, key := range []string{"specversion", "id", "source", "type"} {
		var value string
		if err := json.Unmarshal(event[key], &value); err != nil || strings.TrimSpace(value) == "" {
			return errors.New("missing or invalid CloudEvent " + key)
		}
		if key == "specversion" && value != "1.0" {
			return errors.New("specversion must be 1.0")
		}
		if key == "source" {
			if _, err := url.Parse(value); err != nil {
				return errors.New("source must be a URI reference")
			}
		}
	}
	for _, key := range []string{"time", "subject", "datacontenttype", "dataschema"} {
		if raw, ok := event[key]; ok {
			var value string
			if err := json.Unmarshal(raw, &value); err != nil || value == "" {
				return errors.New("invalid CloudEvent " + key)
			}
			if key == "time" {
				if _, err := time.Parse(time.RFC3339Nano, value); err != nil {
					return errors.New("time must be RFC3339")
				}
			}
		}
	}
	if _, ok := event["data"]; !ok {
		return errors.New("a JSON data payload is required")
	}
	if _, ok := event["data_base64"]; ok {
		return errors.New("data_base64 is unsupported; send JSON data")
	}
	return nil
}
