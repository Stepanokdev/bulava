package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const adminToken = "0123456789abcdef0123456789abcdef"

func goodReport() map[string]any {
	return map[string]any{
		"v": 1, "id": "70245184-c57f-488f-8b7a-44a155c0b45b", "code": "chat.start_failed",
		"fingerprint": "6e4c198cc48c6598", "message": "Night Shift did not start in <path>",
		"outcome": "not_fixed", "cause": "unknown", "product_bug": "", "agent": "codex",
		"duration_s": 42, "app": "1.12 (202610061450)", "engine": "202610061450", "os": "26.0.1",
		"channel": "production", "language": "uk", "arch": "arm64",
	}
}

func post(t *testing.T, h http.Handler, body map[string]any, ip string) int {
	t.Helper()
	data, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/v1/reports", strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", ip)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

func newTestInbox(t *testing.T) (*inbox, string) {
	dir := t.TempDir()
	fixed := time.Date(2026, 10, 6, 12, 34, 56, 0, time.UTC)
	return newInbox(dir, adminToken, 90, func() time.Time { return fixed }), dir
}

func TestAReportIsKeptWithoutItsAddress(t *testing.T) {
	in, dir := newTestInbox(t)
	if code := post(t, in.routes(), goodReport(), "203.0.113.7"); code != http.StatusAccepted {
		t.Fatalf("status %d", code)
	}
	data, err := os.ReadFile(filepath.Join(dir, "2026-10-06.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "203.0.113") {
		t.Fatalf("the client's address was written down: %s", data)
	}
	if !strings.Contains(string(data), `"received_at":"2026-10-06T12:34:00Z"`) {
		t.Fatalf("arrival time is kept to the minute: %s", data)
	}
}

func TestAnUnknownFieldIsRefused(t *testing.T) {
	in, _ := newTestInbox(t)
	r := goodReport()
	r["project"] = "Acme Rocket"
	if code := post(t, in.routes(), r, "1.1.1.1"); code != http.StatusBadRequest {
		t.Fatalf("a field outside the list must be refused, got %d", code)
	}
}

func TestShapesAreChecked(t *testing.T) {
	in, _ := newTestInbox(t)
	for field, value := range map[string]any{
		"v": 2, "id": "not-a-uuid", "code": "Chat Failed!", "fingerprint": "xyz",
		"outcome": "maybe", "cause": "aliens", "agent": "gpt", "channel": "beta",
		"language": "ukr", "arch": "ppc", "duration_s": -1,
		"message": strings.Repeat("x", 601), "app": "1.0; rm -rf /",
	} {
		r := goodReport()
		r[field] = value
		if code := post(t, in.routes(), r, "1.1.1.1"); code != http.StatusUnprocessableEntity {
			t.Errorf("%s=%v: got %d", field, value, code)
		}
		in.buckets = map[string]*bucket{}
	}
}

func TestARetriedUploadIsKeptOnce(t *testing.T) {
	in, dir := newTestInbox(t)
	post(t, in.routes(), goodReport(), "1.1.1.1")
	post(t, in.routes(), goodReport(), "1.1.1.1")
	data, _ := os.ReadFile(filepath.Join(dir, "2026-10-06.jsonl"))
	if n := strings.Count(string(data), "\n"); n != 1 {
		t.Fatalf("kept %d times", n)
	}
	r := goodReport()
	r["outcome"] = "fixed"
	post(t, in.routes(), r, "1.1.1.1")
	data, _ = os.ReadFile(filepath.Join(dir, "2026-10-06.jsonl"))
	if n := strings.Count(string(data), "\n"); n != 2 {
		t.Fatalf("the same incident's later outcome is a second line, got %d", n)
	}
}

func TestOneClientCannotFloodIt(t *testing.T) {
	in, _ := newTestInbox(t)
	accepted := 0
	for i := 0; i < 40; i++ {
		r := goodReport()
		r["id"] = strings.Replace(r["id"].(string), "70245184", strings.Repeat("0", 6)+string(rune('a'+i%6))+string(rune('a'+i/6)), 1)
		if post(t, in.routes(), r, "9.9.9.9") == http.StatusAccepted {
			accepted++
		}
	}
	if accepted != 20 {
		t.Fatalf("accepted %d of 40 at once", accepted)
	}
	if post(t, in.routes(), goodReport(), "8.8.8.8") != http.StatusAccepted {
		t.Fatal("another client is not held back by the first")
	}
}

func TestReadingNeedsTheToken(t *testing.T) {
	in, _ := newTestInbox(t)
	post(t, in.routes(), goodReport(), "1.1.1.1")
	for _, auth := range []string{"", "Bearer wrong", "Bearer " + adminToken[:31]} {
		req := httptest.NewRequest("GET", "/v1/reports?since=2026-10-01", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		rec := httptest.NewRecorder()
		in.routes().ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%q read the reports: %d", auth, rec.Code)
		}
	}
	req := httptest.NewRequest("GET", "/v1/reports?since=2026-10-01", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rec := httptest.NewRecorder()
	in.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "chat.start_failed") {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
}

func TestOldDaysAreDeleted(t *testing.T) {
	in, dir := newTestInbox(t)
	for _, day := range []string{"2026-06-01", "2026-07-08", "2026-10-05"} {
		os.WriteFile(filepath.Join(dir, day+".jsonl"), []byte("{}\n"), 0o640)
	}
	in.sweep()
	left, _ := in.days()
	if strings.Join(left, ",") != "2026-07-08,2026-10-05" {
		t.Fatalf("left %v", left)
	}
}
