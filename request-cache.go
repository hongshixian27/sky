package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	listenAddress = "127.0.0.1:8091"
	cachePath     = "/data/sky.json"
	maxEntries    = 50
)

type cacheEntry struct {
	Path       string `json:"path"`
	UserAgent  string `json:"user_agent"`
	User       string `json:"user"`
	CapturedAt string `json:"captured_at"`
}

var cacheMu sync.Mutex

var (
	requestPath     = envOrDefault("WS_CACHE_PATH", "/account/ws")
	userAgentHeader = envOrDefault("WS_CACHE_USER_AGENT_HEADER", "User-Agent")
	userHeader      = envOrDefault("WS_CACHE_USER_HEADER", "user")
)

func main() {
	if !strings.HasPrefix(requestPath, "/") || strings.ContainsAny(requestPath, "?#") {
		panic("WS_CACHE_PATH must be an absolute path without a query or fragment")
	}
	if err := validateSafeHeader(userAgentHeader); err != nil {
		panic(fmt.Sprintf("WS_CACHE_USER_AGENT_HEADER: %v", err))
	}
	if err := validateSafeHeader(userHeader); err != nil {
		panic(fmt.Sprintf("WS_CACHE_USER_HEADER: %v", err))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/cache", cacheRequest)
	server := &http.Server{
		Addr:              listenAddress,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		panic(err)
	}
}

func cacheRequest(w http.ResponseWriter, r *http.Request) {
	originalURI, err := url.ParseRequestURI(r.Header.Get("X-Cache-Original-URI"))
	if err != nil {
		http.Error(w, "invalid original URI", http.StatusBadRequest)
		return
	}
	if originalURI.Path != requestPath {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	entry := cacheEntry{
		Path:       originalURI.Path,
		UserAgent:  r.Header.Get(userAgentHeader),
		User:       r.Header.Get(userHeader),
		CapturedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if err := appendEntry(entry); err != nil {
		http.Error(w, "cache write failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func validateSafeHeader(name string) error {
	if !validHeaderName(name) {
		return errors.New("invalid HTTP header name")
	}
	lower := strings.ToLower(name)
	for _, blocked := range []string{"authorization", "cookie", "token", "session", "auth", "secret", "key"} {
		if strings.Contains(lower, blocked) {
			return fmt.Errorf("credential-bearing header %q is not allowed", name)
		}
	}
	return nil
}

func validHeaderName(name string) bool {
	if name == "" {
		return false
	}
	for _, char := range name {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || strings.ContainsRune("!#$%&'*+-.^_`|~", char) {
			continue
		}
		return false
	}
	return true
}

func appendEntry(entry cacheEntry) error {
	cacheMu.Lock()
	defer cacheMu.Unlock()

	entries := make([]cacheEntry, 0, maxEntries)
	data, err := os.ReadFile(cachePath)
	if err == nil && len(data) > 0 {
		if err := json.Unmarshal(data, &entries); err != nil {
			return err
		}
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}

	entries = append(entries, entry)
	if len(entries) > maxEntries {
		entries = entries[len(entries)-maxEntries:]
	}
	encoded, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')

	if err := os.MkdirAll(filepath.Dir(cachePath), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(cachePath), ".sky.json-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)

	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, cachePath)
}
