package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Usage is the weekly summary of how Bulava was used, sent by a Mac whose owner keeps it on
// (Bulava's UsageReport.swift writes exactly these keys). Ranges instead of counts, the ISO week
// instead of dates, yes or no instead of what — and nothing that tells one Mac from another: the
// id is random for each report, only so that a retried upload is kept once.
type Usage struct {
	ID            string   `json:"id"`
	Week          string   `json:"week"`
	App           string   `json:"app"`
	OS            string   `json:"os"`
	Channel       string   `json:"channel"`
	Language      string   `json:"language"`
	Runs          string   `json:"runs"`
	AgentHours    string   `json:"agentHours"`
	AcceptedShare *string  `json:"acceptedShare,omitempty"`
	ActiveDays    int      `json:"activeDays"`
	NightWork     bool     `json:"nightWork"`
	CodexReview   bool     `json:"codexReview"`
	Phone         bool     `json:"phone"`
	Automations   bool     `json:"automations"`
	Widgets       []string `json:"widgets"`
}

type storedUsage struct {
	Usage
	ReceivedDay string `json:"received_day"`
}

var (
	reUUID      = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
	reWeek      = regexp.MustCompile(`^20[0-9]{2}-W(0[1-9]|[1-4][0-9]|5[0-3])$`)
	runRanges   = set("0", "1–5", "6–20", "21–60", "60+")
	hourRanges  = set("0", "<5", "5–20", "20–40", "40–80", "80+")
	shareRanges = set("0–10%", "10–20%", "20–30%", "30–40%", "40–50%", "50–60%", "60–70%", "70–80%", "80–90%", "90–100%")
	widgetKinds = set("autonomy", "outcomes", "receipt", "rhythm", "volume", "limits", "now", "glance")
	usageLangs  = set("en", "uk", "ru")
)

func (u Usage) validate() error {
	switch {
	case !reUUID.MatchString(u.ID):
		return errors.New("id")
	case !reWeek.MatchString(u.Week):
		return errors.New("week")
	case !reShort.MatchString(u.App) || !reShort.MatchString(u.OS):
		return errors.New("versions")
	case !channels[u.Channel]:
		return errors.New("channel")
	case !usageLangs[u.Language]:
		return errors.New("language")
	case !runRanges[u.Runs]:
		return errors.New("runs")
	case !hourRanges[u.AgentHours]:
		return errors.New("agentHours")
	case u.AcceptedShare != nil && !shareRanges[*u.AcceptedShare]:
		return errors.New("acceptedShare")
	case u.ActiveDays < 0 || u.ActiveDays > 7:
		return errors.New("activeDays")
	case len(u.Widgets) > len(widgetKinds):
		return errors.New("widgets")
	}
	seen := map[string]bool{}
	for _, w := range u.Widgets {
		if !widgetKinds[w] || seen[w] {
			return errors.New("widgets")
		}
		seen[w] = true
	}
	return nil
}

func (in *inbox) usageDir() string { return filepath.Join(in.dir, "usage") }

// acceptUsage takes one weekly summary: 202 when kept (or already kept), 4xx for a wrong shape —
// Bulava does not send that week again — and 429 when one client sends too many.
func (in *inbox) acceptUsage(w http.ResponseWriter, r *http.Request) {
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
	var u Usage
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&u); err != nil {
		http.Error(w, "not a summary", http.StatusBadRequest)
		return
	}
	if u.Widgets == nil {
		u.Widgets = []string{}
	}
	if err := u.validate(); err != nil {
		http.Error(w, "invalid "+err.Error(), http.StatusUnprocessableEntity)
		return
	}
	if err := in.storeUsage(u); err != nil {
		log.Printf("report-inbox: could not store a summary: %v", err)
		http.Error(w, "not stored", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// storeUsage appends the summary to the file of the week it describes. The day it arrived is kept,
// not the minute: when a Mac sends says nothing anybody needs.
func (in *inbox) storeUsage(u Usage) error {
	now := in.now().UTC()
	key := "usage|" + u.ID
	in.mu.Lock()
	defer in.mu.Unlock()
	if _, dup := in.seen[key]; dup {
		return nil
	}
	if err := os.MkdirAll(in.usageDir(), 0o750); err != nil {
		return err
	}
	line, err := json.Marshal(storedUsage{Usage: u, ReceivedDay: now.Format("2006-01-02")})
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(in.usageDir(), u.Week+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
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
	return nil
}

// listUsage returns the summaries of ?since=YYYY-Www (default: the last eight weeks), one JSON line
// each, to whoever holds the admin token — and to nobody else.
func (in *inbox) listUsage(w http.ResponseWriter, r *http.Request) {
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(auth), []byte(in.token)) != 1 {
		http.Error(w, "no", http.StatusUnauthorized)
		return
	}
	y, wk := in.now().UTC().AddDate(0, 0, -56).ISOWeek()
	since := isoWeekName(y, wk)
	if v := r.URL.Query().Get("since"); v != "" {
		if !reWeek.MatchString(v) {
			http.Error(w, "since=YYYY-Www", http.StatusBadRequest)
			return
		}
		since = v
	}
	weeks, _ := in.usageWeeks()
	w.Header().Set("Content-Type", "application/x-ndjson")
	out := bufio.NewWriter(w)
	defer out.Flush()
	for _, week := range weeks {
		if week < since {
			continue
		}
		if data, err := os.ReadFile(filepath.Join(in.usageDir(), week+".jsonl")); err == nil {
			out.Write(data)
		}
	}
}

func (in *inbox) usageWeeks() ([]string, error) {
	entries, err := os.ReadDir(in.usageDir())
	if err != nil {
		return nil, err
	}
	var weeks []string
	for _, e := range entries {
		if week, ok := strings.CutSuffix(e.Name(), ".jsonl"); ok && reWeek.MatchString(week) {
			weeks = append(weeks, week)
		}
	}
	sort.Strings(weeks)
	return weeks, nil
}

// sweepUsage deletes the weeks older than the usage retention.
func (in *inbox) sweepUsage(retentionDays int) {
	y, wk := in.now().UTC().AddDate(0, 0, -retentionDays).ISOWeek()
	cutoff := isoWeekName(y, wk)
	weeks, err := in.usageWeeks()
	if err != nil {
		return
	}
	for _, week := range weeks {
		if week < cutoff {
			os.Remove(filepath.Join(in.usageDir(), week+".jsonl"))
		}
	}
}

func isoWeekName(year, week int) string { return fmt.Sprintf("%04d-W%02d", year, week) }
