// Command report-inbox keeps the anonymous error reports Bulava sends when something stopped
// somebody's work, so that the people who make it can see every failure users meet and fix it
// once, for everyone, in a release.
//
// What it accepts is a closed list of fields (see Report), each checked for shape and size; a
// request carrying anything else is refused. It keeps no address: the client's IP is used for
// nothing but a short-lived rate limit held in memory, and nothing here logs requests. Reports are
// written one JSON line per report into a file per day and deleted after RETENTION_DAYS.
//
// Reading them back is for the makers only: GET /v1/reports with the admin token.
package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	token := os.Getenv("REPORTS_ADMIN_TOKEN")
	if len(token) < 32 {
		log.Fatal("report-inbox: REPORTS_ADMIN_TOKEN must be set (32+ characters)")
	}
	retention := 90
	if v, err := strconv.Atoi(os.Getenv("RETENTION_DAYS")); err == nil && v > 0 {
		retention = v
	}
	dir := orDefault(os.Getenv("DATA_DIR"), "/data")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		log.Fatalf("report-inbox: %v", err)
	}
	inbox := newInbox(dir, token, retention, time.Now)
	if v, err := strconv.Atoi(os.Getenv("USAGE_RETENTION_DAYS")); err == nil && v > 0 {
		inbox.usageRetention = v
	}
	go inbox.sweepForever()
	server := &http.Server{
		Addr:              orDefault(os.Getenv("LISTEN"), ":8080"),
		Handler:           inbox.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second,
	}
	log.Printf("report-inbox listening on %s, keeping %d days in %s", server.Addr, retention, dir)
	log.Fatal(server.ListenAndServe())
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
