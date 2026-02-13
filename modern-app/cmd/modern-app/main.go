package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	expectedPeerID, err := spiffeid.FromString(getEnv("EXPECTED_CLIENT_SPIFFE_ID", "spiffe://legacy.lab/ns/legacy/sa/springboot"))
	if err != nil {
		log.Fatalf("invalid EXPECTED_CLIENT_SPIFFE_ID: %v", err)
	}

	expectedServerID, err := spiffeid.FromString(getEnv("MODERN_SERVER_SPIFFE_ID", "spiffe://modern.lab/ns/modern/sa/go"))
	if err != nil {
		log.Fatalf("invalid MODERN_SERVER_SPIFFE_ID: %v", err)
	}

	source, err := workloadapi.NewX509Source(ctx)
	if err != nil {
		log.Fatalf("failed to create SPIFFE x509 source: %v", err)
	}
	defer source.Close()

	serverSVID, err := waitForSVID(ctx, source)
	if err != nil {
		log.Fatalf("failed to fetch server SVID: %v", err)
	}
	if serverSVID.ID != expectedServerID {
		log.Fatalf("unexpected server SPIFFE ID: got=%s want=%s", serverSVID.ID.String(), expectedServerID.String())
	}

	tlsConfig := tlsconfig.MTLSServerConfig(source, source, tlsconfig.AuthorizeID(expectedPeerID))
	tlsConfig.MinVersion = tls.VersionTLS12

	mux := http.NewServeMux()
	mux.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "missing peer certificate", http.StatusUnauthorized)
			return
		}

		peerID, err := x509svid.IDFromCert(r.TLS.PeerCertificates[0])
		if err != nil {
			http.Error(w, fmt.Sprintf("peer certificate is not an x509-SVID: %v", err), http.StatusUnauthorized)
			return
		}

		log.Printf("received request from legacy client %s", peerID.String())
		logPeerCertificate(r.TLS.PeerCertificates[0])
		logClientCertHeaders(r.Header)

		fmt.Fprintf(w, "modern app (%s) accepted client %s\n", serverSVID.ID.String(), peerID.String())
	})

	server := &http.Server{
		Addr:      ":8443",
		Handler:   mux,
		TLSConfig: tlsConfig,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("modern app listening on :8443 with SPIFFE ID %s", serverSVID.ID.String())
	err = server.ListenAndServeTLS("", "")
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server exited with error: %v", err)
	}
}

func waitForSVID(ctx context.Context, source *workloadapi.X509Source) (*x509svid.SVID, error) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	timeout := time.NewTimer(2 * time.Minute)
	defer timeout.Stop()

	for {
		svid, err := source.GetX509SVID()
		if err == nil {
			return svid, nil
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timeout.C:
			return nil, fmt.Errorf("timed out waiting for SPIRE registration: %w", err)
		case <-ticker.C:
		}
	}
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func logPeerCertificate(cert *x509.Certificate) {
	if cert == nil {
		return
	}
	block := &pem.Block{
		Type:  "CERTIFICATE",
		Bytes: cert.Raw,
	}
	pemBytes := pem.EncodeToMemory(block)
	if len(pemBytes) == 0 {
		return
	}
	log.Printf("peer mTLS certificate (PEM):\n%s", string(pemBytes))
}

func logClientCertHeaders(header http.Header) {
	if header == nil {
		return
	}
	names := []string{
		"X-Forwarded-Client-Cert",
		"X-Client-Cert",
		"X-SSL-CERT",
		"X-Client-Certificate",
	}
	found := false
	for _, name := range names {
		if value := header.Get(name); value != "" {
			log.Printf("received client cert header %s: %s", name, value)
			found = true
		}
	}
	if !found {
		log.Print("no client certificate header found; using mTLS peer certificate")
	}
}
