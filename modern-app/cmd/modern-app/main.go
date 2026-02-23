package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/jwtsvid"
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

	jwtSource, err := workloadapi.NewJWTSource(ctx)
	if err != nil {
		log.Fatalf("failed to create SPIFFE jwt source: %v", err)
	}
	defer jwtSource.Close()

	serverSVID, err := waitForSVID(ctx, source)
	if err != nil {
		log.Fatalf("failed to fetch server SVID: %v", err)
	}
	if serverSVID.ID != expectedServerID {
		log.Fatalf("unexpected server SPIFFE ID: got=%s want=%s", serverSVID.ID.String(), expectedServerID.String())
	}

	vaultClient := newVaultClient(
		getEnv("VAULT_ADDR", "http://host.docker.internal:18200"),
		getEnv("VAULT_KV_PATH", "kv/data/legacy-app"),
		getEnv("VAULT_SPIFFE_ROLE", "modern-app"),
		getEnv("SPIFFE_JWT_AUDIENCE", "vault"),
		jwtSource,
	)

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
		if vaultClient != nil {
			message, err := vaultClient.ReadKV(r.Context())
			if err != nil {
				log.Printf("vault kv read failed: %v", err)
			} else if message != "" {
				log.Printf("Vault KV v2 message: %s", message)
			}
		}

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
	cn := cert.Subject.CommonName
	if cn == "" {
		cn = "(empty)"
	}
	log.Printf("peer certificate subject CN: %s", cn)
	if len(cert.DNSNames) > 0 {
		log.Printf("peer certificate DNS SANs: %v", cert.DNSNames)
	}
	if len(cert.URIs) > 0 {
		uriSans := make([]string, 0, len(cert.URIs))
		for _, uri := range cert.URIs {
			if uri != nil {
				uriSans = append(uriSans, uri.String())
			}
		}
		if len(uriSans) > 0 {
			log.Printf("peer certificate URI SANs: %v", uriSans)
		}
	}
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

type vaultClient struct {
	addr      string
	kvPath    string
	role      string
	audience  string
	jwtSource *workloadapi.JWTSource
	client    *http.Client
}

func newVaultClient(addr, kvPath, role, audience string, jwtSource *workloadapi.JWTSource) *vaultClient {
	if addr == "" || kvPath == "" || role == "" || audience == "" || jwtSource == nil {
		return nil
	}
	return &vaultClient{
		addr:      strings.TrimRight(addr, "/"),
		kvPath:    strings.TrimPrefix(kvPath, "/"),
		role:      role,
		audience:  audience,
		jwtSource: jwtSource,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func (v *vaultClient) ReadKV(ctx context.Context) (string, error) {
	token, err := v.login(ctx)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.addr+"/v1/"+v.kvPath, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-Vault-Token", token)

	resp, err := v.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("vault kv read failed with status %d", resp.StatusCode)
	}

	var parsed struct {
		Data struct {
			Data struct {
				Message string `json:"message"`
			} `json:"data"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", err
	}
	return parsed.Data.Data.Message, nil
}

func (v *vaultClient) login(ctx context.Context) (string, error) {
	jwtSVID, err := v.jwtSource.FetchJWTSVID(ctx, jwtsvid.Params{Audience: v.audience})
	if err != nil {
		return "", err
	}
	logJWTSVIDClaims(jwtSVID.Marshal())

	payload, err := json.Marshal(map[string]string{
		"role": v.role,
		"type": "jwt",
	})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.addr+"/v1/auth/spiffe/login", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+jwtSVID.Marshal())

	resp, err := v.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		message := strings.TrimSpace(string(body))
		if message != "" {
			return "", fmt.Errorf("vault spiffe login failed with status %d: %s", resp.StatusCode, message)
		}
		return "", fmt.Errorf("vault spiffe login failed with status %d", resp.StatusCode)
	}

	var parsed struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", err
	}
	if parsed.Auth.ClientToken == "" {
		return "", fmt.Errorf("vault spiffe login returned empty client token")
	}
	return parsed.Auth.ClientToken, nil
}

func logJWTSVIDClaims(token string) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		log.Print("vault jwt svid claims: unable to parse token")
		return
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		log.Printf("vault jwt svid claims: decode failed: %v", err)
		return
	}
	var claims struct {
		Sub string      `json:"sub"`
		Aud interface{} `json:"aud"`
		Exp int64       `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		log.Printf("vault jwt svid claims: unmarshal failed: %v", err)
		return
	}
	log.Printf("vault jwt svid claims: sub=%s aud=%v exp=%d", claims.Sub, claims.Aud, claims.Exp)
}
