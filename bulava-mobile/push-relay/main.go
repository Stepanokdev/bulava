// Command push-relay reaches an iPhone that has Bulava installed while its app is closed: "Bulava
// needs you", "a report is ready", "the work is done", and the Live Activity on its Lock Screen.
//
// It exists because iOS lets only Apple's push service reach an app that is not running, and that
// service accepts only a sender holding Bulava's APNs key. The Mac cannot hold that key — it would
// ship inside every copy — so this small service does, and the Mac asks it to send.
//
// It carries nothing it can read. The request names a device token and which of the phone's own
// fixed sentences to show; a Live Activity adds three counts. What the work is called travels only
// sealed with a key the phone made and gave its Mac over their own network — an opaque string here,
// opened on the phone. What is waiting, which project, which question — all of that still travels
// only between the phone and the Mac when the phone opens.
package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	cfg, err := configFromEnv(os.Getenv)
	if err != nil {
		log.Fatalf("push-relay: %v", err)
	}
	signer, err := newSigner(cfg.keyPEM, cfg.keyID, cfg.teamID)
	if err != nil {
		log.Fatalf("push-relay: %v", err)
	}
	relay := newRelay(cfg, signer, &http.Client{Timeout: 15 * time.Second})
	server := &http.Server{
		Addr:              cfg.listen,
		Handler:           relay.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      20 * time.Second,
	}
	log.Printf("push-relay listening on %s, topic %s", cfg.listen, cfg.topic)
	log.Fatal(server.ListenAndServe())
}
