package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	listenAddr      = "127.0.0.1:8091"
	requestFile     = "/data/sky.json"
	responseFile    = "/data/sk.json"
	maxRecords      = 10
	maxCapturedBody = 8 << 20
)

var fileMu sync.Mutex

type requestRecord struct {
	Fingerprint string              `json:"fingerprint"`
	CapturedAt  string              `json:"captured_at"`
	Method      string              `json:"method"`
	Path        string              `json:"path"`
	Query       string              `json:"query,omitempty"`
	Headers     map[string][]string `json:"headers"`
	BodyBase64  string              `json:"body_base64"`
}

type responseRecord struct {
	Fingerprint string              `json:"fingerprint"`
	CapturedAt  string              `json:"captured_at"`
	Status      string              `json:"status"`
	StatusCode  int                 `json:"status_code"`
	Headers     map[string][]string `json:"headers"`
	BodyBase64  string              `json:"body_base64"`
}

func main() {
	cachePath := os.Getenv("IPA_CACHE_PATH")
	upstreamHost := os.Getenv("UPSTREAM_ADDR")
	if cachePath == "" || upstreamHost == "" {
		panic("IPA_CACHE_PATH and UPSTREAM_ADDR are required")
	}

	target := &url.URL{Scheme: "https", Host: upstreamHost + ":443"}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = upstreamHost
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		originalBody := resp.Body
		body, err := readLimited(originalBody)
		_ = originalBody.Close()
		if err != nil {
			return err
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", fmt.Sprintf("%d", len(body)))
		cacheResponse(resp, body)
		return nil
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != cachePath {
			http.NotFound(w, req)
			return
		}
		body, err := readLimited(req.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusRequestEntityTooLarge)
			return
		}
		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		cacheRequest(req, body)
		proxy.ServeHTTP(w, req)
	})

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	panic(server.ListenAndServe())
}

func readLimited(reader io.Reader) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maxCapturedBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxCapturedBody {
		return nil, fmt.Errorf("body exceeds %d bytes", maxCapturedBody)
	}
	return body, nil
}

func cacheRequest(req *http.Request, body []byte) {
	body = sanitizeBody(req.Header.Get("Content-Type"), body)
	headers := sanitizedHeaders(req.Header)
	content := struct {
		Method     string
		Path       string
		Query      string
		Headers    map[string][]string
		BodyBase64 string
	}{req.Method, req.URL.Path, sanitizeQuery(req.URL.RawQuery), headers, base64.StdEncoding.EncodeToString(body)}
	record := requestRecord{
		Fingerprint: fingerprint(content),
		CapturedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		Method:      content.Method,
		Path:        content.Path,
		Query:       content.Query,
		Headers:     content.Headers,
		BodyBase64:  content.BodyBase64,
	}
	_ = appendUnique(requestFile, record.Fingerprint, record)
}

func cacheResponse(resp *http.Response, body []byte) {
	body = sanitizeBody(resp.Header.Get("Content-Type"), body)
	headers := sanitizedHeaders(resp.Header)
	content := struct {
		Status      string
		StatusCode  int
		Headers     map[string][]string
		BodyBase64  string
	}{resp.Status, resp.StatusCode, headers, base64.StdEncoding.EncodeToString(body)}
	record := responseRecord{
		Fingerprint: fingerprint(content),
		CapturedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		Status:      content.Status,
		StatusCode:  content.StatusCode,
		Headers:     content.Headers,
		BodyBase64:  content.BodyBase64,
	}
	_ = appendUnique(responseFile, record.Fingerprint, record)
}

func sanitizedHeaders(headers http.Header) map[string][]string {
	result := make(map[string][]string)
	for name, values := range headers {
		if sensitiveName(name) {
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

func sanitizeBody(contentType string, body []byte) []byte {
	mediaType, _, _ := mime.ParseMediaType(contentType)
	switch mediaType {
	case "application/json", "application/merge-patch+json", "application/problem+json":
		var value any
		if json.Unmarshal(body, &value) == nil {
			value = scrubJSON(value)
			if clean, err := json.Marshal(value); err == nil {
				return clean
			}
		}
	case "application/x-www-form-urlencoded":
		if values, err := url.ParseQuery(string(body)); err == nil {
			for key := range values {
				if sensitiveName(key) || strings.Contains(strings.ToLower(key), "password") {
					values.Set(key, "[REDACTED]")
				}
			}
			return []byte(values.Encode())
		}
	}
	return body
}

func sanitizeQuery(rawQuery string) string {
	if rawQuery == "" {
		return ""
	}
	values, err := url.ParseQuery(rawQuery)
	if err != nil {
		return "[REDACTED_INVALID_QUERY]"
	}
	for key := range values {
		lower := strings.ToLower(key)
		if sensitiveName(key) || strings.Contains(lower, "password") {
			values.Set(key, "[REDACTED]")
		}
	}
	return values.Encode()
}

func scrubJSON(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			lower := strings.ToLower(key)
			if sensitiveName(key) || strings.Contains(lower, "password") {
				typed[key] = "[REDACTED]"
			} else {
				typed[key] = scrubJSON(child)
			}
		}
	case []any:
		for index, child := range typed {
			typed[index] = scrubJSON(child)
		}
	}
	return value
}

func fingerprint(value any) string {
	encoded, _ := json.Marshal(value)
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:])
}

func appendUnique(path, digest string, record any) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}

	fileMu.Lock()
	defer fileMu.Unlock()

	lines := make([]string, 0, maxRecords)
	if existing, err := os.ReadFile(path); err == nil {
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
			if metadata.Fingerprint == digest {
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
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
