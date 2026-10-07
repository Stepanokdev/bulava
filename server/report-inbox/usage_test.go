package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func goodUsage() map[string]any {
	return map[string]any{
		"id": "6C1B6E7A-2B8E-4B4C-9D2E-6A5F3C1D9E01", "week": "2026-W40", "app": "1.12 (412)", "os": "27.0",
		"channel": "production", "language": "uk", "runs": "21–60", "agentHours": "40–80",
		"acceptedShare": "70–80%", "activeDays": 6, "nightWork": true, "codexReview": true,
		"phone": true, "automations": false, "widgets": []string{"autonomy", "limits"},
	}
}

func postUsage(t *testing.T, h http.Handler, body map[string]any, ip string) int {
	t.Helper()
	data, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/v1/usage", strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", ip)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

func TestAWeeklySummaryIsKeptUnderItsWeekWithoutAnAddress(t *testing.T) {
	in, dir := newTestInbox(t)
	if code := postUsage(t, in.routes(), goodUsage(), "203.0.113.7"); code != http.StatusAccepted {
		t.Fatalf("a good summary got %d", code)
	}
	data, err := os.ReadFile(filepath.Join(dir, "usage", "2026-W40.jsonl"))
	if err != nil {
		t.Fatalf("not kept under its week: %v", err)
	}
	line := string(data)
	if strings.Contains(line, "203.0.113.7") {
		t.Fatalf("the address was written down: %s", line)
	}
	if !strings.Contains(line, `"received_day":"2026-10-06"`) || strings.Contains(line, "12:34") {
		t.Fatalf("it keeps the day it arrived, not the time: %s", line)
	}
}

func TestARetriedSummaryIsKeptOnce(t *testing.T) {
	in, dir := newTestInbox(t)
	h := in.routes()
	postUsage(t, h, goodUsage(), "203.0.113.7")
	postUsage(t, h, goodUsage(), "203.0.113.7")
	data, _ := os.ReadFile(filepath.Join(dir, "usage", "2026-W40.jsonl"))
	if n := strings.Count(string(data), "\n"); n != 1 {
		t.Fatalf("kept %d times", n)
	}
}

func TestASummaryWithAnythingExtraOrOutOfRangeIsRefused(t *testing.T) {
	in, _ := newTestInbox(t)
	h := in.routes()
	cases := map[string]func(m map[string]any){
		"an unknown key":          func(m map[string]any) { m["project"] = "Acme" },
		"a count, not a range":    func(m map[string]any) { m["runs"] = "37" },
		"exact hours":             func(m map[string]any) { m["agentHours"] = "63" },
		"a share off the grid":    func(m map[string]any) { m["acceptedShare"] = "74%" },
		"a widget we do not make": func(m map[string]any) { m["widgets"] = []string{"autonomy", "weather"} },
		"a widget twice":          func(m map[string]any) { m["widgets"] = []string{"limits", "limits"} },
		"a date for a week":       func(m map[string]any) { m["week"] = "2026-10-05" },
		"eight active days":       func(m map[string]any) { m["activeDays"] = 8 },
		"an id that is a name":    func(m map[string]any) { m["id"] = "ivan-macbook" },
	}
	for name, change := range cases {
		m := goodUsage()
		change(m)
		if code := postUsage(t, h, m, "198.51.100."+name[:1]); code < 400 || code >= 500 {
			t.Errorf("%s: accepted with %d", name, code)
		}
	}
}

func TestOnlyTheAdminReadsTheSummariesBack(t *testing.T) {
	in, _ := newTestInbox(t)
	h := in.routes()
	postUsage(t, h, goodUsage(), "203.0.113.7")
	req := httptest.NewRequest("GET", "/v1/usage?since=2026-W30", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("read without the token: %d", rec.Code)
	}
	req = httptest.NewRequest("GET", "/v1/usage?since=2026-W30", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"week":"2026-W40"`) {
		t.Fatalf("the admin read %d: %s", rec.Code, rec.Body.String())
	}
}

func TestOldWeeksAreSweptAway(t *testing.T) {
	in, dir := newTestInbox(t)
	os.MkdirAll(filepath.Join(dir, "usage"), 0o750)
	os.WriteFile(filepath.Join(dir, "usage", "2024-W01.jsonl"), []byte("{}\n"), 0o640)
	os.WriteFile(filepath.Join(dir, "usage", "2026-W39.jsonl"), []byte("{}\n"), 0o640)
	in.sweepUsage(730)
	if _, err := os.Stat(filepath.Join(dir, "usage", "2024-W01.jsonl")); err == nil {
		t.Fatal("a week older than the retention is still there")
	}
	if _, err := os.Stat(filepath.Join(dir, "usage", "2026-W39.jsonl")); err != nil {
		t.Fatal("a recent week was swept")
	}
}
