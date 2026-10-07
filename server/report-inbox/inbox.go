package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Report is everything a report may carry. Bulava's IncidentReport.swift writes exactly these
// keys; a request with any other key is refused, so a field cannot start arriving by accident.
type Report struct {
	V           int    `json:"v"`
	ID          string `json:"id"`
	Code        string `json:"code"`
	Fingerprint string `json:"fingerprint"`
	Message     string `json:"message"`
	Outcome     string `json:"outcome"`
	Cause       string `json:"cause"`
	ProductBug  string `json:"product_bug"`
	Agent       string `json:"agent"`
	DurationS   int    `json:"duration_s"`
	App         string `json:"app"`
	Engine      string `json:"engine"`
	OS          string `json:"os"`
	Channel     string `json:"channel"`
	Language    string `json:"language"`
	Arch        string `json:"arch"`
}

// stored is a report as it is written down: the report plus when it arrived — the day, to the
// minute, and nothing about where from.
type stored struct {
	Report
	ReceivedAt string `json:"received_at"`
}

const maxBody = 8 << 10

var (
	reID          = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	reCode        = regexp.MustCompile(`^[a-z0-9_.]{1,64}$`)
	reFingerprint = regexp.MustCompile(`^[0-9a-f]{16}$`)
	reShort       = regexp.MustCompile(`^[A-Za-z0-9 ._()+-]{0,40}$`)
	reLanguage    = regexp.MustCompile(`^[a-z]{2}$`)
	outcomes      = set("fixed", "unverified", "not_fixed", "needs_user", "not_attempted", "repair_unavailable")
	causes        = set("project", "environment", "bulava_state", "bulava_bug", "engine_bug", "needs_user", "unknown")
	agents        = set("codex", "claude", "none")
	channels      = set("production", "dev")
	arches        = set("arm64", "x86_64")
)

func set(values ...string) map[string]bool {
	m := make(map[string]bool, len(values))
	for _, v := range values {
		m[v] = true
	}
	return m
}

func (r Report) validate() error {
	switch {
	case r.V != 1:
		return errors.New("v")
	case !reID.MatchString(r.ID):
		return errors.New("id")
	case !reCode.MatchString(r.Code):
		return errors.New("code")
	case !reFingerprint.MatchString(r.Fingerprint):
		return errors.New("fingerprint")
	case len([]rune(r.Message)) > 600 || strings.TrimSpace(r.Message) == "":
		return errors.New("message")
	case !outcomes[r.Outcome]:
		return errors.New("outcome")
	case !causes[r.Cause]:
		return errors.New("cause")
	case len([]rune(r.ProductBug)) > 800:
		return errors.New("product_bug")
	case !agents[r.Agent]:
		return errors.New("agent")
	case r.DurationS < 0 || r.DurationS > 86400:
		return errors.New("duration_s")
	case !reShort.MatchString(r.App) || !reShort.MatchString(r.Engine) || !reShort.MatchString(r.OS):
		return errors.New("versions")
	case !channels[r.Channel]:
		return errors.New("channel")
	case !reLanguage.MatchString(r.Language):
		return errors.New("language")
	case !arches[r.Arch]:
		return errors.New("arch")
	}
	return nil
}

type inbox struct {
	dir       string
	token     string
	retention int
	// How long the weekly usage summaries are kept, in days.
	usageRetention int
	now            func() time.Time

	mu      sync.Mutex
	seen    map[string]time.Time // id|outcome → when, for dropping a retried upload
	buckets map[string]*bucket   // client → its allowance; in memory only, never written
}

type bucket struct {
	tokens float64
	at     time.Time
}

func newInbox(dir, token string, retention int, now func() time.Time) *inbox {
	return &inbox{dir: dir, token: token, retention: retention, usageRetention: 730, now: now,
		seen: map[string]time.Time{}, buckets: map[string]*bucket{}}
}

func (in *inbox) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/reports", in.accept)
	mux.HandleFunc("GET /v1/reports", in.list)
	mux.HandleFunc("GET /v1/reports/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /v1/usage", in.acceptUsage)
	mux.HandleFunc("GET /v1/usage", in.listUsage)
	mux.HandleFunc("GET /v1/usage/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

// accept takes one report. 202 when kept (or already kept), 4xx when its shape is wrong — Bulava
// drops those rather than sending them again — and 429 when one client sends too many.
func (in *inbox) accept(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		http.Error(w, "json only", http.StatusUnsupportedMediaType)
		return
	}
	if !in.allow(clientKey(r)) {
		http.Error(w, "slow down", http.StatusTooManyRequests)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		http.Error(w, "unreadable", http.StatusBadRequest)
		return
	}
	if len(body) > maxBody {
		http.Error(w, "too large", http.StatusRequestEntityTooLarge)
		return
	}
	var rep Report
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&rep); err != nil {
		http.Error(w, "not a report", http.StatusBadRequest)
		return
	}
	if err := rep.validate(); err != nil {
		http.Error(w, "invalid "+err.Error(), http.StatusUnprocessableEntity)
		return
	}
	if err := in.store(rep); err != nil {
		log.Printf("report-inbox: could not store a report: %v", err)
		http.Error(w, "not stored", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

func (in *inbox) store(rep Report) error {
	now := in.now().UTC()
	key := rep.ID + "|" + rep.Outcome
	in.mu.Lock()
	defer in.mu.Unlock()
	if _, dup := in.seen[key]; dup {
		return nil
	}
	line, err := json.Marshal(stored{Report: rep, ReceivedAt: now.Truncate(time.Minute).Format(time.RFC3339)})
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(in.dir, now.Format("2006-01-02")+".jsonl"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	in.seen[key] = now
	if len(in.seen) > 50_000 {
		for k, t := range in.seen {
			if now.Sub(t) > 48*time.Hour {
				delete(in.seen, k)
			}
		}
	}
	return nil
}

// list returns the reports received on or after ?since=YYYY-MM-DD (default: yesterday), one JSON
// line each, to whoever holds the admin token — and to nobody else.
func (in *inbox) list(w http.ResponseWriter, r *http.Request) {
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(auth), []byte(in.token)) != 1 {
		http.Error(w, "no", http.StatusUnauthorized)
		return
	}
	today := in.now().UTC()
	since := today.AddDate(0, 0, -1).Format("2006-01-02")
	if v := r.URL.Query().Get("since"); v != "" {
		if _, err := time.Parse("2006-01-02", v); err != nil {
			http.Error(w, "since=YYYY-MM-DD", http.StatusBadRequest)
			return
		}
		since = v
	}
	days, err := in.days()
	if err != nil {
		http.Error(w, "unreadable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	out := bufio.NewWriter(w)
	defer out.Flush()
	for _, day := range days {
		if day < since {
			continue
		}
		data, err := os.ReadFile(filepath.Join(in.dir, day+".jsonl"))
		if err != nil {
			continue
		}
		out.Write(data)
	}
}

func (in *inbox) days() ([]string, error) {
	entries, err := os.ReadDir(in.dir)
	if err != nil {
		return nil, err
	}
	var days []string
	for _, e := range entries {
		name := e.Name()
		if day, ok := strings.CutSuffix(name, ".jsonl"); ok {
			if _, err := time.Parse("2006-01-02", day); err == nil {
				days = append(days, day)
			}
		}
	}
	sort.Strings(days)
	return days, nil
}

// sweep deletes the days older than the retention.
func (in *inbox) sweep() {
	cutoff := in.now().UTC().AddDate(0, 0, -in.retention).Format("2006-01-02")
	days, err := in.days()
	if err != nil {
		return
	}
	for _, day := range days {
		if day < cutoff {
			os.Remove(filepath.Join(in.dir, day+".jsonl"))
		}
	}
}

func (in *inbox) sweepForever() {
	for {
		in.sweep()
		in.sweepUsage(in.usageRetention)
		time.Sleep(6 * time.Hour)
	}
}

// allow is a small token bucket per client: 20 reports at once, then one a minute. A Mac that
// hits a loop cannot fill the disk. The key is held in memory for the hour it matters, never
// written anywhere.
func (in *inbox) allow(client string) bool {
	now := in.now()
	in.mu.Lock()
	defer in.mu.Unlock()
	b, ok := in.buckets[client]
	if !ok {
		b = &bucket{tokens: 20, at: now}
		in.buckets[client] = b
	}
	b.tokens = min(20, b.tokens+now.Sub(b.at).Minutes())
	b.at = now
	if len(in.buckets) > 10_000 {
		for k, v := range in.buckets {
			if now.Sub(v.at) > time.Hour {
				delete(in.buckets, k)
			}
		}
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// clientKey is the address Traefik saw, or the connection's own when there is no proxy in front.
func clientKey(r *http.Request) string {
	// The last address is the one Traefik added; anything before it the client could have
	// written itself.
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		parts := strings.Split(fwd, ",")
		return strings.TrimSpace(parts[len(parts)-1])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
