package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	h, err := newHandlerFromEnv(os.Getenv)
	if err != nil {
		log.Fatalf("testapp: cannot start: %v", err)
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("testapp: listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}
