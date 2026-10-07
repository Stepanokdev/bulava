package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

type config struct {
	listen      string
	keyPEM      []byte
	keyID       string
	teamID      string
	topic       string
	production  string
	development string
}

// configFromEnv reads the APNs credentials. All four are required: without them there is nothing
// this service could send.
func configFromEnv(get func(string) string) (config, error) {
	cfg := config{
		listen:      orDefault(get("LISTEN"), ":8080"),
		keyID:       get("APNS_KEY_ID"),
		teamID:      get("APNS_TEAM_ID"),
		topic:       orDefault(get("APNS_TOPIC"), "com.stepanok.bulava"),
		production:  orDefault(get("APNS_PRODUCTION_URL"), "https://api.push.apple.com"),
		development: orDefault(get("APNS_DEVELOPMENT_URL"), "https://api.sandbox.push.apple.com"),
	}
	path := get("APNS_KEY_FILE")
	if path == "" || cfg.keyID == "" || cfg.teamID == "" {
		return cfg, errors.New("APNS_KEY_FILE, APNS_KEY_ID and APNS_TEAM_ID are required")
	}
	key, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("reading the APNs key: %w", err)
	}
	cfg.keyPEM = key
	return cfg, nil
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

// MARK: - The provider token

// signer makes the ES256 provider token APNs wants, and reuses it for 50 minutes: Apple refuses
// tokens older than an hour and throttles senders that mint a new one per request.
type signer struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	now    func() time.Time

	mu       sync.Mutex
	token    string
	mintedAt time.Time
}

func newSigner(keyPEM []byte, keyID, teamID string) (*signer, error) {
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, errors.New("the APNs key is not a PEM file")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("the APNs key does not parse: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("the APNs key is not an EC key")
	}
	return &signer{key: key, keyID: keyID, teamID: teamID, now: time.Now}, nil
}

func (s *signer) current() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != "" && s.now().Sub(s.mintedAt) < 50*time.Minute {
		return s.token, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": s.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": s.teamID, "iat": s.now().Unix()})
	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, sig, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	raw := append(pad32(r), pad32(sig)...)
	s.token = unsigned + "." + enc.EncodeToString(raw)
	s.mintedAt = s.now()
	return s.token, nil
}

func pad32(n *big.Int) []byte {
	b := n.Bytes()
	out := make([]byte, 32)
	copy(out[32-len(b):], b)
	return out
}

// MARK: - The relay

type relay struct {
	cfg    config
	signer *signer
	client *http.Client
	now    func() time.Time

	mu       sync.Mutex
	lastSent map[string]time.Time
}

func newRelay(cfg config, s *signer, client *http.Client) *relay {
	return &relay{cfg: cfg, signer: s, client: client, now: time.Now, lastSent: map[string]time.Time{}}
}

// The shortest gap between two pushes of one kind to one device. More than one "Bulava needs you"
// a minute is noise, and a limit per token is what stops this endpoint from being used to pester a
// phone.
const perDeviceGap = 30 * time.Second

// Live Activity pushes are silent and budgeted by Apple, so they may come closer together; a start
// is an alert, and is held to one a minute.
var activityGaps = map[string]time.Duration{"start": time.Minute, "update": 5 * time.Second, "end": 0}

var tokenPattern = regexp.MustCompile(`^[0-9a-fA-F]{64,200}$`)

// Live Activity tokens are longer than device tokens.
var activityTokenPattern = regexp.MustCompile(`^[0-9a-fA-F]{64,400}$`)

type notifyRequest struct {
	Token       string `json:"token"`
	Environment string `json:"environment"`
	// "attention" (the default), "finished" or "done".
	Kind string `json:"kind"`
	// Where a tap should lead, sealed by the Mac with a key only the phone holds. Passed on as it
	// came; this service cannot read it.
	Sealed string `json:"sealed"`
}

// The sentence each kind shows, from the app's own strings, and the thread it groups under.
var notifyKinds = map[string]struct{ body, thread, collapse string }{
	// The Mac is waiting for the director's answer.
	"attention": {"PUSH_BODY", "bulava", "bulava-needs-you"},
	// A task is done and its report is ready to read.
	"finished": {"PUSH_BODY_DONE", "bulava-done", "bulava-done"},
	// A chat's answer is in: the work the director asked for from the phone has finished.
	"done": {"PUSH_BODY_REPLIED", "bulava-done", "bulava-replied"},
}

// sealedPattern is base64 of a small AES-GCM box: nonce, ciphertext, tag.
var sealedPattern = regexp.MustCompile(`^[A-Za-z0-9+/]+={0,2}$`)

const (
	maxSealedRoute    = 512
	maxSealedActivity = 3000
	// Apple's limit for a Live Activity push, all of it.
	maxActivityPayload = 4096
)

// Payload is the whole push, always: a title and a sentence the app localises itself, grouped so
// several arrive as one. No project, no chat, no text from the work is ever in it in the clear —
// only, when the Mac sends one, a sealed box the app opens to know which chat a tap should open.
//
// Every kind is an ordinary alert with a sound: a finished piece of work is what the director is
// waiting to hear about.
func payload(kind, sealed string) []byte {
	k := notifyKinds[kind]
	aps := map[string]any{
		"alert":     map[string]string{"title-loc-key": "PUSH_TITLE", "loc-key": k.body},
		"sound":     "default",
		"thread-id": k.thread,
	}
	body := map[string]any{"aps": aps}
	if sealed != "" {
		body["sealed"] = sealed
	}
	b, _ := json.Marshal(body)
	return b
}

// features says what this relay takes beyond the first version: which kinds of push, and whether a
// sealed box may ride along. A Mac asks before it sends either, so an older relay — which answers
// this with 404 — is sent only what it knows, and a newer Mac never has a push refused for it.
func (r *relay) features(w http.ResponseWriter, _ *http.Request) {
	kinds := make([]string, 0, len(notifyKinds))
	for _, k := range []string{"attention", "finished", "done"} {
		if _, ok := notifyKinds[k]; ok {
			kinds = append(kinds, k)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"kinds": kinds, "sealed": true})
}

func validSealed(s string, limit int) bool {
	return s == "" || (len(s) <= limit && sealedPattern.MatchString(s))
}

func (r *relay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	mux.HandleFunc("GET /v1/features", r.features)
	mux.HandleFunc("POST /v1/notify", r.notify)
	mux.HandleFunc("POST /v1/activity", r.activity)
	return mux
}

// environmentBase is the APNs host for an environment name, or "" for one that does not exist.
func (r *relay) environmentBase(environment string) string {
	switch environment {
	case "", "production":
		return r.cfg.production
	case "development":
		return r.cfg.development
	}
	return ""
}

// answer turns what APNs said into what the Mac acts on: 202 sent, 410 forget this token.
func answer(w http.ResponseWriter, status int, reason string) {
	switch {
	case status == http.StatusOK:
		w.WriteHeader(http.StatusAccepted)
	case status == http.StatusGone || reason == "BadDeviceToken" || reason == "Unregistered" || reason == "ExpiredToken":
		// The phone no longer has the app, the activity is over, or the token belongs to the
		// other environment. The Mac forgets the token on this answer.
		http.Error(w, reason, http.StatusGone)
	default:
		http.Error(w, "apns: "+reason, http.StatusBadGateway)
	}
}

func (r *relay) notify(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(io.LimitReader(req.Body, 1024))
	if err != nil {
		http.Error(w, "unreadable", http.StatusBadRequest)
		return
	}
	var in notifyRequest
	if json.Unmarshal(body, &in) != nil || !tokenPattern.MatchString(in.Token) {
		http.Error(w, "a device token is required", http.StatusBadRequest)
		return
	}
	token := strings.ToLower(in.Token)
	base := r.environmentBase(in.Environment)
	if base == "" {
		http.Error(w, "environment is production or development", http.StatusBadRequest)
		return
	}
	kind := in.Kind
	if kind == "" {
		kind = "attention"
	}
	if _, known := notifyKinds[kind]; !known {
		http.Error(w, "kind is attention, finished or done", http.StatusBadRequest)
		return
	}
	if !validSealed(in.Sealed, maxSealedRoute) {
		http.Error(w, "sealed is a short base64 string", http.StatusBadRequest)
		return
	}
	if !r.admit(kind+"|"+token, perDeviceGap) {
		http.Error(w, "too soon", http.StatusTooManyRequests)
		return
	}
	status, reason := r.send(base, token, payload(kind, in.Sealed), map[string]string{
		"apns-topic":       r.cfg.topic,
		"apns-push-type":   "alert",
		"apns-priority":    "10",
		"apns-collapse-id": notifyKinds[kind].collapse,
		"apns-expiration":  fmt.Sprint(r.now().Add(time.Hour).Unix()),
	})
	log.Printf("push %s %s → %d %s", kind, tokenFingerprint(token), status, reason)
	answer(w, status, reason)
}

// MARK: - Live Activity

// What a Live Activity shows: runs working, things waiting for the director, reports ready — and,
// for a phone that gave its Mac a key, what is running by name, sealed with that key. The counts
// and an opaque string are the whole of what this service ever learns about the work.
type shiftState struct {
	Working int    `json:"working"`
	Waiting int    `json:"waiting"`
	Ready   int    `json:"ready"`
	Sealed  string `json:"sealed,omitempty"`
}

type activityRequest struct {
	Token       string      `json:"token"`
	Environment string      `json:"environment"`
	Event       string      `json:"event"`
	State       *shiftState `json:"state"`
}

// How long an activity's counts are trusted without a fresh push. The Mac re-sends them every ten
// minutes while it runs, so an activity that goes stale is one whose Mac went to sleep or offline,
// and the phone shows it as such.
const activityStaleAfter = 25 * time.Minute

// How long a finished activity stays on the Lock Screen, showing how many reports are ready.
const activityLingers = time.Hour

// activityPayload is an ActivityKit push: the counts, the time they were read, and for a start,
// the attributes type the app declares and a fixed alert the app localises.
func activityPayload(event string, state shiftState, now time.Time) []byte {
	aps := map[string]any{
		"timestamp":     now.Unix(),
		"event":         event,
		"content-state": state,
	}
	switch event {
	case "start":
		aps["attributes-type"] = "ShiftAttributes"
		aps["attributes"] = map[string]any{}
		aps["alert"] = map[string]any{
			"title": map[string]string{"loc-key": "LIVE_START_TITLE"},
			"body":  map[string]string{"loc-key": "LIVE_START_BODY"},
		}
		// Asks the system for the new activity's own update token, which the app hands the Mac.
		aps["input-push-token"] = 1
		aps["stale-date"] = now.Add(activityStaleAfter).Unix()
	case "update":
		aps["stale-date"] = now.Add(activityStaleAfter).Unix()
	case "end":
		aps["dismissal-date"] = now.Add(activityLingers).Unix()
	}
	b, _ := json.Marshal(map[string]any{"aps": aps})
	return b
}

func (r *relay) activity(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(io.LimitReader(req.Body, 8192))
	if err != nil {
		http.Error(w, "unreadable", http.StatusBadRequest)
		return
	}
	var in activityRequest
	if json.Unmarshal(body, &in) != nil || !activityTokenPattern.MatchString(in.Token) {
		http.Error(w, "an activity token is required", http.StatusBadRequest)
		return
	}
	gap, known := activityGaps[in.Event]
	if !known {
		http.Error(w, "event is start, update or end", http.StatusBadRequest)
		return
	}
	if in.State == nil || !inRange(in.State.Working) || !inRange(in.State.Waiting) || !inRange(in.State.Ready) {
		http.Error(w, "state is three counts", http.StatusBadRequest)
		return
	}
	if !validSealed(in.State.Sealed, maxSealedActivity) {
		http.Error(w, "sealed is a base64 string", http.StatusBadRequest)
		return
	}
	base := r.environmentBase(in.Environment)
	if base == "" {
		http.Error(w, "environment is production or development", http.StatusBadRequest)
		return
	}
	token := strings.ToLower(in.Token)
	if !r.admit("activity."+in.Event+"|"+token, gap) {
		http.Error(w, "too soon", http.StatusTooManyRequests)
		return
	}
	priority := "5"
	if in.Event != "update" {
		priority = "10"
	}
	now := r.now()
	push := activityPayload(in.Event, *in.State, now)
	if len(push) > maxActivityPayload {
		http.Error(w, "too large for a Live Activity", http.StatusRequestEntityTooLarge)
		return
	}
	status, reason := r.send(base, token, push, map[string]string{
		"apns-topic":      r.cfg.topic + ".push-type.liveactivity",
		"apns-push-type":  "liveactivity",
		"apns-priority":   priority,
		"apns-expiration": fmt.Sprint(now.Add(activityStaleAfter).Unix()),
	})
	log.Printf("activity %s %s → %d %s", in.Event, tokenFingerprint(token), status, reason)
	answer(w, status, reason)
}

func inRange(n int) bool { return n >= 0 && n <= 9999 }

// MARK: - Sending

func (r *relay) admit(key string, gap time.Duration) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	if last, ok := r.lastSent[key]; ok && now.Sub(last) < gap {
		return false
	}
	r.lastSent[key] = now
	if len(r.lastSent) > 50_000 {
		for t, at := range r.lastSent {
			if now.Sub(at) > perDeviceGap*2 {
				delete(r.lastSent, t)
			}
		}
	}
	return true
}

func (r *relay) send(base, token string, body []byte, headers map[string]string) (int, string) {
	jwt, err := r.signer.current()
	if err != nil {
		return 0, "signing failed"
	}
	req, err := http.NewRequest(http.MethodPost, base+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return 0, err.Error()
	}
	req.Header.Set("authorization", "bearer "+jwt)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	var answer struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&answer)
	return resp.StatusCode, answer.Reason
}

// tokenFingerprint is how a token appears in logs: never whole.
func tokenFingerprint(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:4])
}
