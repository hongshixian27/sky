package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	listenAddr = "127.0.0.1:8091"
	cacheFile  = "/data/sky.json"
	maxRecords = 10
)

var fileMu sync.Mutex

type headerRecord struct {
	Fingerprint string              `json:"fingerprint"`
	CapturedAt  string              `json:"captured_at"`
	Path        string              `json:"path"`
	Headers     map[string][]string `json:"headers"`
}

func main() {
	upstreamHost := os.Getenv("UPSTREAM_ADDR")
	if upstreamHost == "" {
		panic("UPSTREAM_ADDR is required")
	}
	target := &url.URL{Scheme: "https", Host: upstreamHost + ":443"}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = upstreamHost
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/account/ws" {
			http.NotFound(w, req)
			return
		}
		cacheHeaders(req)
		proxy.ServeHTTP(w, req)
	})
	server := &http.Server{
		Addr:              listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	panic(server.ListenAndServe())
}

func cacheHeaders(req *http.Request) {
	headers := sanitizedHeaders(req.Header)
	content := struct {
		Path    string
		Headers map[string][]string
	}{"/account/ws", headers}
	encoded, _ := json.Marshal(content)
	sum := sha256.Sum256(encoded)
	record := headerRecord{
		Fingerprint: hex.EncodeToString(sum[:]),
		CapturedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		Path:        content.Path,
		Headers:     content.Headers,
	}
	_ = appendUnique(record)
}

func sanitizedHeaders(headers http.Header) map[string][]string {
	result := make(map[string][]string)
	for name, values := range headers {
		if sensitiveName(name) || volatileInfrastructureHeader(name) || strings.EqualFold(name, "X-Cache-Path") {
			continue
		}
		result[http.CanonicalHeaderKey(name)] = append([]string(nil), values...)
	}
	return result
}

func sensitiveName(name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	switch name {
	case "authorization", "cookie", "set-cookie", "proxy-authorization", "proxy-authenticate", "www-authenticate":
		return true
	}
	return strings.Contains(name, "token") ||
		strings.Contains(name, "session") ||
		strings.Contains(name, "secret") ||
		strings.Contains(name, "api-key") ||
		strings.HasSuffix(name, "-key") ||
		strings.HasSuffix(name, "_key")
}

func volatileInfrastructureHeader(name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	switch name {
	case "age", "cdn-loop", "connection", "date", "forwarded", "server-timing", "via", "x-real-ip", "x-request-id":
		return true
	}
	return strings.HasPrefix(name, "cf-") ||
		strings.HasPrefix(name, "x-b3-") ||
		strings.HasPrefix(name, "x-forwarded-") ||
		strings.HasPrefix(name, "x-koyeb-") ||
		strings.Contains(name, "traceid") ||
		strings.Contains(name, "spanid")
}

func appendUnique(record headerRecord) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}

	fileMu.Lock()
	defer fileMu.Unlock()

	lines := make([]string, 0, maxRecords)
	if existing, err := os.ReadFile(cacheFile); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(existing)), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var metadata struct {
				Fingerprint string `json:"fingerprint"`
			}
			if json.Unmarshal([]byte(line), &metadata) != nil {
				continue
			}
			if metadata.Fingerprint == record.Fingerprint {
				return nil
			}
			lines = append(lines, line)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	lines = append(lines, string(encoded))
	if len(lines) > maxRecords {
		lines = lines[len(lines)-maxRecords:]
	}
	temporary := cacheFile + ".tmp"
	if err := os.WriteFile(temporary, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
		return err
	}
	return os.Rename(temporary, cacheFile)
}
