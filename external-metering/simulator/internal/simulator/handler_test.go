package simulator

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestSimulator(t *testing.T) {
	var logs bytes.Buffer
	handler := New(&logs, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	request := func(method, path string, body []byte) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}

	t.Run("entitlement and health", func(t *testing.T) {
		w := request(http.MethodGet, "/api/v1/customers/alice/entitlements/inference-tokens/value", nil)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"hasAccess":true`) {
			t.Fatalf("entitlement: %d %s", w.Code, w.Body.String())
		}
		for _, path := range []string{"/healthz", "/readyz"} {
			if w := request(http.MethodGet, path, nil); w.Code != http.StatusOK {
				t.Fatalf("%s: %d", path, w.Code)
			}
		}
	})

	t.Run("event logged intact", func(t *testing.T) {
		body, err := os.ReadFile("../../testdata/usage-event.json")
		if err != nil {
			t.Fatal(err)
		}
		body = bytes.Replace(body, []byte(`"total_tokens": 230`), []byte(`"total_tokens": 9007199254740993`), 1)
		w := request(http.MethodPost, "/api/v1/events", body)
		var compact bytes.Buffer
		if err := json.Compact(&compact, body); err != nil {
			t.Fatal(err)
		}
		if w.Code != http.StatusNoContent || logs.String() != compact.String()+"\n" {
			t.Fatalf("POST status=%d, log=%s", w.Code, logs.String())
		}
	})

	t.Run("invalid event rejected", func(t *testing.T) {
		logs.Reset()
		w := request(http.MethodPost, "/api/v1/events", []byte(`{"data":42}`))
		if w.Code != http.StatusBadRequest || logs.Len() != 0 {
			t.Fatalf("invalid event: status=%d, log=%s", w.Code, logs.String())
		}
	})
}
