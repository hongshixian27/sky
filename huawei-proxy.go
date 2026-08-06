package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	listenAddr          = "127.0.0.1:8090"
	defaultAppID        = "C105091411"
	encryptedSourceURL  = "3ryiJkNtsHS+d4Jia4rhiXuUjPowR39PXEJ9eld6K2U4UOpgZVAwao/IGzpkT9iw7p9EYrlTRJjqWJoH3c15kyEGU5arkw=="
	sourceURLKeyEnvName = "APPGALLERY_PROXY_KEY"
)

var appIDPattern = regexp.MustCompile(`^C[0-9]+$`)
var appGalleryURL string

var transport = &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	ForceAttemptHTTP2:     true,
	MaxIdleConns:          32,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ResponseHeaderTimeout: 20 * time.Second,
}

func main() {
	appGalleryURL = decryptSourceURL()
	mux := http.NewServeMux()
	mux.HandleFunc("/apk", apkHandler)
	mux.HandleFunc("/apk/", apkHandler)

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

func decryptSourceURL() string {
	key, err := base64.StdEncoding.DecodeString(os.Getenv(sourceURLKeyEnvName))
	if err != nil || len(key) != 32 {
		log.Fatalf("%s must contain a base64-encoded 32-byte key", sourceURLKeyEnvName)
	}
	blob, err := base64.StdEncoding.DecodeString(encryptedSourceURL)
	if err != nil || len(blob) < 12+16 {
		log.Fatal("invalid encrypted AppGallery source")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		log.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		log.Fatal(err)
	}
	nonce, tag, ciphertext := blob[:12], blob[12:28], blob[28:]
	plaintext, err := gcm.Open(nil, nonce, append(ciphertext, tag...), nil)
	if err != nil {
		log.Fatal("cannot decrypt AppGallery source")
	}
	return string(plaintext)
}

func apkHandler(w http.ResponseWriter, r *http.Request) {
	appID := defaultAppID
	if r.URL.Path == "/apk" {
		// /apk is the short form for the configured default Huawei app.
	} else {
		appID = strings.TrimPrefix(r.URL.Path, "/apk/")
	}
	ok := (r.URL.Path == "/apk" || r.URL.Path == "/apk/"+appID) && appIDPattern.MatchString(appID)
	if !ok {
		http.Error(w, "invalid Huawei app id", http.StatusBadRequest)
		return
	}

	target, status, contentType, err := resolveAppGallery(r.Context(), appID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Location", target.String())
	w.Header().Set("Cache-Control", "no-store")
	if contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.WriteHeader(status)
}

func resolveAppGallery(ctx context.Context, appID string) (*url.URL, int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, appGalleryURL+appID, nil)
	if err != nil {
		return nil, 0, "", err
	}
	// Keep the upstream request independent from all visitor-supplied headers.
	req.Header.Set("User-Agent", "koyeb-appgallery-resolver/1.0")
	client := &http.Client{
		Transport: transport,
		Timeout:   30 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, "", fmt.Errorf("AppGallery request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 300 || resp.StatusCode >= 400 {
		return nil, 0, "", fmt.Errorf("AppGallery returned HTTP %d", resp.StatusCode)
	}
	target, err := resp.Location()
	if err != nil || !allowedHuaweiCDN(target) {
		return nil, 0, "", errors.New("AppGallery returned an invalid download location")
	}
	return target, resp.StatusCode, resp.Header.Get("Content-Type"), nil
}

func allowedHuaweiCDN(target *url.URL) bool {
	host := strings.ToLower(target.Hostname())
	return target.Scheme == "https" && (host == "dbankcloud.com" || strings.HasSuffix(host, ".dbankcloud.com"))
}
