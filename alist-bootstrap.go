package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	apiBase    = "http://127.0.0.1:5244/api"
	backupFile = "/app/alist-backup.enc"
	markerFile = "/data/.alist-backup-restored-v1"
)

type backup struct {
	Settings          []map[string]any `json:"settings"`
	Users             []map[string]any `json:"users"`
	Storages          []map[string]any `json:"storages"`
	Metas             []map[string]any `json:"metas"`
	Labels            []map[string]any `json:"labels"`
	LabelFileBindings []map[string]any `json:"label_file_bindings"`
	Roles             []map[string]any `json:"roles"`
}

type apiResponse struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

type client struct {
	token string
	http  *http.Client
}

func main() {
	if _, err := os.Stat(markerFile); err == nil {
		return
	}

	keyText := os.Getenv("ALIST_BACKUP_KEY")
	password := os.Getenv("ALIST_ADMIN_PASSWORD")
	if keyText == "" || password == "" {
		fatal(errors.New("ALIST_BACKUP_KEY and ALIST_ADMIN_PASSWORD are required"))
	}

	plain, err := decryptBackup(keyText)
	if err != nil {
		fatal(fmt.Errorf("decrypt backup: %w", err))
	}
	defer clear(plain)

	var b backup
	if err := json.Unmarshal(plain, &b); err != nil {
		fatal(fmt.Errorf("parse backup: %w", err))
	}

	c := &client{http: &http.Client{Timeout: 30 * time.Second}}
	if err := c.login(password); err != nil {
		fatal(err)
	}
	if err := c.restore(&b); err != nil {
		fatal(err)
	}
	if err := os.WriteFile(markerFile, []byte("restored\n"), 0600); err != nil {
		fatal(fmt.Errorf("write restore marker: %w", err))
	}
}

func decryptBackup(keyText string) ([]byte, error) {
	key, err := base64.StdEncoding.DecodeString(keyText)
	if err != nil || len(key) != 32 {
		return nil, errors.New("backup key must be base64-encoded 32 bytes")
	}
	defer clear(key)

	sealed, err := os.ReadFile(backupFile)
	if err != nil {
		return nil, err
	}
	if len(sealed) < 4+12+16 || string(sealed[:4]) != "ABK1" {
		return nil, errors.New("invalid encrypted backup envelope")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := sealed[4 : 4+gcm.NonceSize()]
	return gcm.Open(nil, nonce, sealed[4+gcm.NonceSize():], []byte("alist-backup-v1"))
}

func (c *client) login(password string) error {
	data, err := c.call(http.MethodPost, "/auth/login", map[string]any{
		"username": "admin",
		"password": password,
	})
	if err != nil {
		return fmt.Errorf("login for restore: %w", err)
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(data, &result); err != nil || result.Token == "" {
		return errors.New("login response did not contain a token")
	}
	c.token = result.Token
	return nil
}

func (c *client) restore(b *backup) error {
	settings := make([]map[string]any, 0, len(b.Settings))
	for _, item := range b.Settings {
		key, _ := item["key"].(string)
		if key != "version" && key != "index_progress" && key != "default_role" {
			settings = append(settings, item)
		}
	}
	if _, err := c.call(http.MethodPost, "/admin/setting/save", settings); err != nil {
		return fmt.Errorf("restore settings: %w", err)
	}

	storages := make([]map[string]any, 0, len(b.Storages))
	for _, source := range b.Storages {
		item := make(map[string]any, len(source))
		for key, value := range source {
			item[key] = value
		}
		if driver, _ := item["driver"].(string); strings.EqualFold(driver, "GoogleDrive") {
			// Keep Google Drive downloads on the Koyeb/AList data path. An empty
			// proxy URL means AList itself is the download proxy.
			item["web_proxy"] = true
			item["down_proxy_url"] = ""
		}
		storages = append(storages, item)
	}
	if err := c.upsertPage("/admin/storage/list?page=1&per_page=1000", "/admin/storage", "mount_path", storages, false); err != nil {
		return fmt.Errorf("restore storages: %w", err)
	}
	if err := c.upsertPage("/admin/meta/list?page=1&per_page=1000", "/admin/meta", "path", b.Metas, false); err != nil {
		return fmt.Errorf("restore metas: %w", err)
	}
	if err := c.upsertPage("/label/list?page=1&per_page=1000", "/admin/label", "id", b.Labels, false); err != nil {
		return fmt.Errorf("restore labels: %w", err)
	}
	if err := c.upsertPage("/admin/role/list?page=1&per_page=1000", "/admin/role", "name", b.Roles, true); err != nil {
		return fmt.Errorf("restore roles: %w", err)
	}

	if len(b.LabelFileBindings) > 0 {
		body := map[string]any{"keep_ids": true, "override": true, "bindings": b.LabelFileBindings}
		if _, err := c.call(http.MethodPost, "/admin/label_file_binding/restore", body); err != nil {
			return fmt.Errorf("restore label bindings: %w", err)
		}
	}

	// Users are last, and admin is the final request, because updating admin
	// invalidates the restore JWT.
	users := append([]map[string]any(nil), b.Users...)
	sort.SliceStable(users, func(i, j int) bool {
		return !strings.EqualFold(valueKey(users[i]["username"]), "admin") &&
			strings.EqualFold(valueKey(users[j]["username"]), "admin")
	})
	if err := c.upsertPage("/admin/user/list?page=1&per_page=1000", "/admin/user", "username", users, false); err != nil {
		return fmt.Errorf("restore users: %w", err)
	}
	return nil
}

func (c *client) upsertPage(listPath, actionBase, key string, desired []map[string]any, skipAdminRole bool) error {
	if len(desired) == 0 {
		return nil
	}
	data, err := c.call(http.MethodGet, listPath, nil)
	if err != nil {
		return err
	}
	var page struct {
		Content []map[string]any `json:"content"`
	}
	if err := json.Unmarshal(data, &page); err != nil {
		return err
	}
	existing := make(map[string]map[string]any, len(page.Content))
	for _, item := range page.Content {
		existing[valueKey(item[key])] = item
	}

	for _, original := range desired {
		item := cloneMap(original)
		name := valueKey(item[key])
		if skipAdminRole && strings.EqualFold(name, "admin") {
			continue
		}
		endpoint := actionBase + "/create"
		if current, ok := existing[name]; ok {
			endpoint = actionBase + "/update"
			item["id"] = current["id"]
		} else {
			item["id"] = 0
		}
		if _, err := c.call(http.MethodPost, endpoint, item); err != nil {
			return fmt.Errorf("%s %q: %w", endpoint, name, err)
		}
	}
	return nil
}

func (c *client) call(method, path string, body any) (json.RawMessage, error) {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, apiBase+path, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	var result apiResponse
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("HTTP %d returned invalid JSON", resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || result.Code != 200 {
		return nil, fmt.Errorf("HTTP %d, code %d: %s", resp.StatusCode, result.Code, result.Message)
	}
	return result.Data, nil
}

func valueKey(v any) string {
	return fmt.Sprint(v)
}

func cloneMap(src map[string]any) map[string]any {
	dst := make(map[string]any, len(src))
	for k, v := range src {
		dst[k] = v
	}
	return dst
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
