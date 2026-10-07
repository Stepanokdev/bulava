package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAPNs is Apple's push service as far as the relay can tell: HTTP/2 over TLS, checking what a
// real one checks, and remembering what it was sent.
type fakeAPNs struct {
	t      *testing.T
	pub    *ecdsa.PublicKey
	mu     sync.Mutex
	got    []http.Header
	bodies [][]byte
	paths  []string
	answer func(token string) (int, string)
}

func (f *fakeAPNs) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.ProtoMajor != 2 {
		f.t.Errorf("APNs speaks HTTP/2 only, got %s", r.Proto)
	}
	body, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	f.got = append(f.got, r.Header.Clone())
	f.bodies = append(f.bodies, body)
	f.paths = append(f.paths, r.URL.Path)
	f.mu.Unlock()
	if !f.validJWT(strings.TrimPrefix(r.Header.Get("authorization"), "bearer ")) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"reason":"InvalidProviderToken"}`))
		return
	}
	token := strings.TrimPrefix(r.URL.Path, "/3/device/")
	status, reason := http.StatusOK, ""
	if f.answer != nil {
		status, reason = f.answer(token)
	}
	w.WriteHeader(status)
	if reason != "" {
		_, _ = w.Write([]byte(`{"reason":"` + reason + `"}`))
	}
}

func (f *fakeAPNs) validJWT(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	var header map[string]string
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	if json.Unmarshal(h, &header) != nil || header["alg"] != "ES256" || header["kid"] != "KEY123" {
		return false
	}
	var claims map[string]any
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if json.Unmarshal(c, &claims) != nil || claims["iss"] != "TEAM123" {
		return false
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return ecdsa.Verify(f.pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

func setup(t *testing.T) (*relay, *fakeAPNs, *httptest.Server) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	apns := &fakeAPNs{t: t, pub: &key.PublicKey}
	server := httptest.NewUnstartedServer(apns)
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	s, err := newSigner(keyPEM, "KEY123", "TEAM123")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config{topic: "com.stepanok.bulava", production: server.URL, development: server.URL + "/sandbox"}
	return newRelay(cfg, s, server.Client()), apns, server
}

const token = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

func post(t *testing.T, r *relay, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	r.routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/v1/notify", strings.NewReader(body)))
	return w
}

func TestAPushCarriesNothingButTheFixedSentence(t *testing.T) {
	r, apns, _ := setup(t)
	w := post(t, r, `{"token":"`+token+`","environment":"production"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d %s", w.Code, w.Body)
	}
	if len(apns.bodies) != 1 {
		t.Fatalf("expected one push, got %d", len(apns.bodies))
	}
	var sent map[string]any
	_ = json.Unmarshal(apns.bodies[0], &sent)
	if len(sent) != 1 {
		t.Fatalf("the push carries only aps, got %v", sent)
	}
	aps := sent["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["loc-key"] != "PUSH_BODY" || alert["title-loc-key"] != "PUSH_TITLE" || len(alert) != 2 {
		t.Fatalf("the alert is the app's own localised sentence and nothing else, got %v", alert)
	}
	h := apns.got[0]
	for k, v := range map[string]string{"apns-topic": "com.stepanok.bulava", "apns-push-type": "alert",
		"apns-priority": "10", "apns-collapse-id": "bulava-needs-you"} {
		if h.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, h.Get(k), v)
		}
	}
	if apns.paths[0] != "/3/device/"+token {
		t.Errorf("sent to %s", apns.paths[0])
	}
}

func TestOnePushPerDeviceEveryThirtySeconds(t *testing.T) {
	r, apns, _ := setup(t)
	clock := time.Unix(1_800_000_000, 0)
	r.now = func() time.Time { return clock }
	if post(t, r, `{"token":"`+token+`"}`).Code != http.StatusAccepted {
		t.Fatal("first push refused")
	}
	if code := post(t, r, `{"token":"`+token+`"}`).Code; code != http.StatusTooManyRequests {
		t.Fatalf("a second push within the gap must be refused, got %d", code)
	}
	clock = clock.Add(31 * time.Second)
	if post(t, r, `{"token":"`+token+`"}`).Code != http.StatusAccepted {
		t.Fatal("a push after the gap must go through")
	}
	if len(apns.bodies) != 2 {
		t.Fatalf("expected two pushes, got %d", len(apns.bodies))
	}
}

func TestAGoneDeviceIsReportedSoTheMacForgetsIt(t *testing.T) {
	r, apns, _ := setup(t)
	apns.answer = func(string) (int, string) { return http.StatusGone, "Unregistered" }
	if code := post(t, r, `{"token":"`+token+`"}`).Code; code != http.StatusGone {
		t.Fatalf("expected 410, got %d", code)
	}
}

func TestNonsenseIsRefusedBeforeAnythingIsSent(t *testing.T) {
	r, apns, _ := setup(t)
	for _, body := range []string{`{}`, `{"token":"xyz"}`, `not json`, `{"token":"` + token + `","environment":"staging"}`} {
		if code := post(t, r, body).Code; code != http.StatusBadRequest {
			t.Errorf("%s: expected 400, got %d", body, code)
		}
	}
	if len(apns.bodies) != 0 {
		t.Fatalf("nothing should have reached APNs, got %d", len(apns.bodies))
	}
}

func TestTheProviderTokenIsReusedForItsLifetime(t *testing.T) {
	r, _, _ := setup(t)
	clock := time.Unix(1_800_000_000, 0)
	r.signer.now = func() time.Time { return clock }
	a, _ := r.signer.current()
	clock = clock.Add(49 * time.Minute)
	b, _ := r.signer.current()
	clock = clock.Add(2 * time.Minute)
	c, _ := r.signer.current()
	if a != b || b == c {
		t.Fatal("the token lives 50 minutes, then a new one is minted")
	}
}

func TestTheDevelopmentEnvironmentGoesToTheSandbox(t *testing.T) {
	r, apns, _ := setup(t)
	post(t, r, `{"token":"`+token+`","environment":"development"}`)
	if len(apns.paths) != 1 || !strings.HasPrefix(apns.paths[0], "/sandbox/3/device/") {
		t.Fatalf("expected the sandbox, got %v", apns.paths)
	}
}

func postTo(t *testing.T, r *relay, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	r.routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
	return w
}

func TestAFinishedReportIsToldAloud(t *testing.T) {
	r, apns, _ := setup(t)
	if w := post(t, r, `{"token":"`+token+`","kind":"finished"}`); w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d %s", w.Code, w.Body)
	}
	var sent map[string]map[string]any
	_ = json.Unmarshal(apns.bodies[0], &sent)
	aps := sent["aps"]
	alert := aps["alert"].(map[string]any)
	if alert["loc-key"] != "PUSH_BODY_DONE" || alert["title-loc-key"] != "PUSH_TITLE" || len(alert) != 2 {
		t.Fatalf("the finished sentence is the app's own and nothing else, got %v", alert)
	}
	if aps["interruption-level"] != nil || aps["sound"] != "default" {
		t.Fatalf("finished work is what the director waits to hear about: a sound and a banner, got %v", aps)
	}
	if h := apns.got[0]; h.Get("apns-collapse-id") != "bulava-done" || h.Get("apns-push-type") != "alert" {
		t.Fatalf("finished reports collapse into one of their own, got %v", h)
	}
	// Its own limit: a report coming in does not use up the one "Bulava needs you".
	if code := post(t, r, `{"token":"`+token+`"}`).Code; code != http.StatusAccepted {
		t.Fatalf("an attention push right after a finished one must go through, got %d", code)
	}
	if code := post(t, r, `{"token":"`+token+`","kind":"finished"}`).Code; code != http.StatusTooManyRequests {
		t.Fatalf("a second finished push within the gap must be refused, got %d", code)
	}
	if code := post(t, r, `{"token":"`+token+`","kind":"shout"}`).Code; code != http.StatusBadRequest {
		t.Fatalf("an unknown kind is refused, got %d", code)
	}
}

func TestAChatThatAnsweredIsDoneWithItsSealedRoute(t *testing.T) {
	r, apns, _ := setup(t)
	sealed := base64.StdEncoding.EncodeToString([]byte("nonce-and-ciphertext-the-relay-cannot-read"))
	if w := post(t, r, `{"token":"`+token+`","kind":"done","sealed":"`+sealed+`"}`); w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d %s", w.Code, w.Body)
	}
	var sent map[string]any
	_ = json.Unmarshal(apns.bodies[0], &sent)
	aps := sent["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["loc-key"] != "PUSH_BODY_REPLIED" || aps["sound"] != "default" || aps["thread-id"] != "bulava-done" {
		t.Fatalf("done is the app's own sentence, with a sound, got %v", aps)
	}
	if sent["sealed"] != sealed || len(sent) != 2 {
		t.Fatalf("the sealed route is passed on as it came and nothing is added, got %v", sent)
	}
	if h := apns.got[0]; h.Get("apns-collapse-id") != "bulava-replied" {
		t.Fatalf("answers collapse into one of their own, got %v", h)
	}
	// Anything that is not a short base64 box is not passed on.
	for _, bad := range []string{`"<script>"`, `"` + strings.Repeat("A", 600) + `"`} {
		if code := post(t, r, `{"token":"`+token+`","kind":"attention","sealed":`+bad+`}`).Code; code != http.StatusBadRequest {
			t.Fatalf("sealed %s: expected 400, got %d", bad[:8], code)
		}
	}
}

const activityToken = "80f3a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"

func TestALiveActivityIsSentItsCountsAndNothingElse(t *testing.T) {
	r, apns, _ := setup(t)
	clock := time.Unix(1_800_000_000, 0)
	r.now = func() time.Time { return clock }
	w := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","environment":"development","event":"start","state":{"working":2,"waiting":1,"ready":0}}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d %s", w.Code, w.Body)
	}
	if !strings.HasPrefix(apns.paths[0], "/sandbox/3/device/"+activityToken) {
		t.Fatalf("sent to %s", apns.paths[0])
	}
	h := apns.got[0]
	for k, v := range map[string]string{"apns-topic": "com.stepanok.bulava.push-type.liveactivity",
		"apns-push-type": "liveactivity", "apns-priority": "10"} {
		if h.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, h.Get(k), v)
		}
	}
	var sent map[string]map[string]any
	_ = json.Unmarshal(apns.bodies[0], &sent)
	aps := sent["aps"]
	if aps["event"] != "start" || aps["attributes-type"] != "ShiftAttributes" || aps["input-push-token"] != float64(1) {
		t.Fatalf("a start names the app's attributes and asks for an update token, got %v", aps)
	}
	if aps["timestamp"] != float64(clock.Unix()) || aps["stale-date"] != float64(clock.Add(25*time.Minute).Unix()) {
		t.Fatalf("the counts carry when they were read and when they go stale, got %v", aps)
	}
	state := aps["content-state"].(map[string]any)
	if len(state) != 3 || state["working"] != float64(2) || state["waiting"] != float64(1) || state["ready"] != float64(0) {
		t.Fatalf("the content state is three counts, got %v", state)
	}
	alert := aps["alert"].(map[string]any)
	if alert["title"].(map[string]any)["loc-key"] != "LIVE_START_TITLE" || alert["body"].(map[string]any)["loc-key"] != "LIVE_START_BODY" {
		t.Fatalf("the start alert is the app's own sentence, got %v", alert)
	}

	// Updates are quiet and low priority; one in five seconds.
	if code := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"update","state":{"working":1,"waiting":1,"ready":1}}`).Code; code != http.StatusAccepted {
		t.Fatalf("update: %d", code)
	}
	if apns.got[1].Get("apns-priority") != "5" {
		t.Fatalf("an update goes at priority 5, got %s", apns.got[1].Get("apns-priority"))
	}
	if code := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"update","state":{"working":1,"waiting":0,"ready":1}}`).Code; code != http.StatusTooManyRequests {
		t.Fatalf("a second update within five seconds is refused, got %d", code)
	}
	// An end always goes through, and lingers an hour.
	if code := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"end","state":{"working":0,"waiting":0,"ready":1}}`).Code; code != http.StatusAccepted {
		t.Fatalf("end: %d", code)
	}
	_ = json.Unmarshal(apns.bodies[2], &sent)
	if sent["aps"]["dismissal-date"] != float64(clock.Add(time.Hour).Unix()) || sent["aps"]["event"] != "end" {
		t.Fatalf("an end says when to leave the Lock Screen, got %v", sent["aps"])
	}
}

func TestTheNamesOfTheWorkTravelOnlySealed(t *testing.T) {
	r, apns, _ := setup(t)
	sealed := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", 900)))
	w := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"update","state":{"working":1,"waiting":0,"ready":0,"sealed":"`+sealed+`"}}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d %s", w.Code, w.Body)
	}
	var sent map[string]map[string]any
	_ = json.Unmarshal(apns.bodies[0], &sent)
	state := sent["aps"]["content-state"].(map[string]any)
	if state["sealed"] != sealed || len(state) != 4 {
		t.Fatalf("the sealed box goes into the content state as it came, got %v", state)
	}
	// An older Mac sends no box, and the content state stays the three counts.
	postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"end","state":{"working":0,"waiting":0,"ready":0}}`)
	_ = json.Unmarshal(apns.bodies[1], &sent)
	if _, has := sent["aps"]["content-state"].(map[string]any)["sealed"]; has {
		t.Fatalf("no box, no key: %v", sent["aps"]["content-state"])
	}
	// Not base64, or more than a Live Activity can carry: refused before Apple sees it.
	for _, bad := range []string{`"not base64!"`, `"` + strings.Repeat("A", 3100) + `"`} {
		body := `{"token":"` + activityToken + `","event":"end","state":{"working":0,"waiting":0,"ready":0,"sealed":` + bad + `}}`
		if code := postTo(t, r, "/v1/activity", body).Code; code != http.StatusBadRequest {
			t.Fatalf("expected 400, got %d", code)
		}
	}
	if len(apns.bodies) != 2 {
		t.Fatalf("refused boxes must not reach APNs, got %d sends", len(apns.bodies))
	}
}

func TestAnActivityThatIsOverIsReportedSoTheMacForgetsIt(t *testing.T) {
	r, apns, _ := setup(t)
	apns.answer = func(string) (int, string) { return http.StatusGone, "ExpiredToken" }
	if code := postTo(t, r, "/v1/activity", `{"token":"`+activityToken+`","event":"update","state":{"working":1,"waiting":0,"ready":0}}`).Code; code != http.StatusGone {
		t.Fatalf("expected 410, got %d", code)
	}
}

func TestActivityNonsenseIsRefusedBeforeAnythingIsSent(t *testing.T) {
	r, apns, _ := setup(t)
	for _, body := range []string{
		`{}`,
		`{"token":"` + activityToken + `","event":"update"}`,
		`{"token":"` + activityToken + `","event":"dance","state":{"working":1,"waiting":0,"ready":0}}`,
		`{"token":"` + activityToken + `","event":"update","state":{"working":-1,"waiting":0,"ready":0}}`,
		`{"token":"` + activityToken + `","event":"update","environment":"staging","state":{"working":1,"waiting":0,"ready":0}}`,
		`{"token":"nothex","event":"update","state":{"working":1,"waiting":0,"ready":0}}`,
	} {
		if code := postTo(t, r, "/v1/activity", body).Code; code != http.StatusBadRequest {
			t.Errorf("%s: expected 400, got %d", body, code)
		}
	}
	if len(apns.bodies) != 0 {
		t.Fatalf("nothing should have reached APNs, got %d", len(apns.bodies))
	}
}

func TestAMacIsToldWhatThisRelayTakes(t *testing.T) {
	r, _, _ := setup(t)
	w := httptest.NewRecorder()
	r.routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/features", nil))
	var got struct {
		Kinds  []string `json:"kinds"`
		Sealed bool     `json:"sealed"`
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &got) != nil {
		t.Fatalf("expected 200 JSON, got %d %s", w.Code, w.Body)
	}
	if strings.Join(got.Kinds, ",") != "attention,finished,done" || !got.Sealed {
		t.Fatalf("every kind and the sealed box, got %+v", got)
	}
}
