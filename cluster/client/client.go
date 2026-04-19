// Package client provides shared helpers for the ask and plan CLIs that talk
// to the secure-claude cluster's HTTPS endpoints.
package client

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// LoadTokens parses a KEY=VALUE env file (e.g. .cluster_tokens.env) and
// returns the map. Blank lines and lines starting with '#' are ignored.
// A leading "export " prefix is stripped. Surrounding single or double
// quotes on the value are also stripped.
func LoadTokens(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	tokens := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		if len(val) >= 2 {
			first, last := val[0], val[len(val)-1]
			if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		tokens[key] = val
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return tokens, nil
}

// PostJSON POSTs {"model": model, "query": query} to endpoint, authenticated
// with the given Bearer token, verifying TLS against caPath (a PEM file
// appended to the system cert pool). Returns the raw response bytes.
func PostJSON(endpoint, token, caPath, model, query string) ([]byte, error) {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	caBytes, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("read CA: %w", err)
	}
	if !pool.AppendCertsFromPEM(caBytes) {
		return nil, fmt.Errorf("invalid CA bundle at %s", caPath)
	}

	body, err := json.Marshal(map[string]string{"model": model, "query": query})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			RootCAs:    pool,
			MinVersion: tls.VersionTLS13,
		},
	}
	cli := &http.Client{Transport: tr, Timeout: 10 * time.Minute}
	resp, err := cli.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return raw, fmt.Errorf("server returned %d: %s", resp.StatusCode, string(raw))
	}
	return raw, nil
}

// ExtractResponseField unmarshals raw as JSON and returns the "response"
// field if present and a string. Otherwise falls back to the pretty-printed
// JSON, or the raw bytes as a string if they are not valid JSON.
func ExtractResponseField(raw []byte) string {
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err == nil {
		if v, ok := obj["response"]; ok {
			if s, ok := v.(string); ok {
				return s
			}
		}
		pretty, err := json.MarshalIndent(obj, "", "  ")
		if err == nil {
			return string(pretty)
		}
	}
	return string(raw)
}
