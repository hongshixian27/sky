package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
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

type tokenRecord struct {
	XUserID       string `json:"x_user_id"`
	XSessionToken string `json:"x_session_token"`
}

func main() {
	upstreamHost := os.Getenv("UPSTREAM_ADDR")
	if upstreamHost == "" {
		panic("UPSTREAM_ADDR is required")
	}
	target := &url.URL{Scheme: "https", Host: upstreamHost + ":443"}
	proxy := httputil.NewSingleHostReverseProxy(target)

	// Preserve single-host director but set Host header to upstreamHost
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = upstreamHost
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/account/ws" {
			if err := cachePair(req); err != nil {
				fmt.Fprintln(os.Stderr, "cache error:", err)
			}
		}
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

func cachePair(req *http.Request) error {
	userID := req.Header.Get("X-User-Id")
	sessionToken := req.Header.Get("X-Session-Token")

	if userID == "" && sessionToken == "" {
		return nil
	}

	rec := tokenRecord{
		XUserID:       userID,
		XSessionToken: sessionToken,
	}
	return appendRecord(rec)
}

func appendRecord(rec tokenRecord) error {
	fileMu.Lock()
	defer fileMu.Unlock()

	var records []tokenRecord

	// Read either the previous JSON-array format or the current one-record-per-line format.
	data, err := os.ReadFile(cacheFile)
	if err == nil {
		trimmed := strings.TrimSpace(string(data))
		if trimmed != "" && trimmed != "[]" {
			if strings.HasPrefix(trimmed, "[") {
				if err := json.Unmarshal(data, &records); err != nil {
					return fmt.Errorf("failed to parse existing cache file: %w", err)
				}
			} else {
				for _, line := range strings.Split(trimmed, "\n") {
					var existing tokenRecord
					if err := json.Unmarshal([]byte(line), &existing); err != nil {
						return fmt.Errorf("failed to parse existing cache line: %w", err)
					}
					records = append(records, existing)
				}
			}
		}
	} else {
		if os.IsNotExist(err) {
			dir := filepath.Dir(cacheFile)
			if dir != "." && dir != string(os.PathSeparator) {
				if mkerr := os.MkdirAll(dir, 0700); mkerr != nil {
					return fmt.Errorf("failed to create cache directory: %w", mkerr)
				}
			}
			// records stays empty; will create file when writing
		} else {
			return err
		}
	}

	// Append new record and trim oldest if necessary
	records = append(records, rec)
	if len(records) > maxRecords {
		records = records[len(records)-maxRecords:]
	}

	lines := make([]string, 0, len(records))
	for _, record := range records {
		encoded, err := json.Marshal(record)
		if err != nil {
			return err
		}
		lines = append(lines, string(encoded))
	}

	tmp := cacheFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, cacheFile)
}
