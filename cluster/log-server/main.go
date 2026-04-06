package main

import (
	"bufio"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const defaultLogsDir = "/logs"

// LogEvent is a structured log entry stored as one JSONL line per event.
// Schema matches TOKEN_USE.md §3.1 "Log Events to Capture".
type LogEvent struct {
	Timestamp  string `json:"timestamp"`
	SessionID  string `json:"session_id"`
	EventType  string `json:"event_type"` // llm_call|tool_call|file_read|file_write|test_run|git_op|plan_op

	// llm_call fields
	Model                string `json:"model,omitempty"`
	InputTokens          int    `json:"input_tokens,omitempty"`
	OutputTokens         int    `json:"output_tokens,omitempty"`
	CacheReadTokens      int    `json:"cache_read_tokens,omitempty"`
	CacheCreationTokens  int    `json:"cache_creation_tokens,omitempty"`
	DurationMs           int64  `json:"duration_ms,omitempty"`
	TurnNumber           int    `json:"turn_number,omitempty"`

	// tool_call fields
	ToolName          string `json:"tool_name,omitempty"`
	RequestSizeBytes  int    `json:"request_size_bytes,omitempty"`
	ResponseSizeBytes int    `json:"response_size_bytes,omitempty"`

	// file_read / file_write fields
	Path      string `json:"path,omitempty"`
	SizeBytes int    `json:"size_bytes,omitempty"`
	SHA256    string `json:"sha256,omitempty"`

	// test_run fields
	ExitCode        int `json:"exit_code,omitempty"`
	OutputSizeBytes int `json:"output_size_bytes,omitempty"`

	// git_op fields
	Operation     string `json:"operation,omitempty"`
	SubmodulePath string `json:"submodule_path,omitempty"`

	// plan_op fields
	TaskID string `json:"task_id,omitempty"`
}

// sessionLocks provides per-session write serialization.
var sessionLocks sync.Map

func sessionMu(id string) *sync.Mutex {
	v, _ := sessionLocks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}

// sanitizeID restricts session IDs to safe filename characters.
func sanitizeID(id string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return '_'
		}
	}, id)
}

func sessionPath(logsDir, id string) string {
	return filepath.Join(logsDir, sanitizeID(id)+".jsonl")
}

func appendEvent(logsDir string, ev LogEvent) error {
	mu := sessionMu(ev.SessionID)
	mu.Lock()
	defer mu.Unlock()

	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(sessionPath(logsDir, ev.SessionID),
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	line, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	_, err = f.Write(line)
	return err
}

func readEvents(logsDir, id string) ([]LogEvent, error) {
	mu := sessionMu(id)
	mu.Lock()
	defer mu.Unlock()

	f, err := os.Open(sessionPath(logsDir, id))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var events []LogEvent
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e LogEvent
		if json.Unmarshal(sc.Bytes(), &e) == nil {
			events = append(events, e)
		}
	}
	return events, sc.Err()
}

// verifyToken checks the Bearer token using constant-time comparison.
func verifyToken(r *http.Request, expected string) bool {
	auth := r.Header.Get("Authorization")
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) != 2 || parts[0] != "Bearer" {
		return false
	}
	got := []byte(parts[1])
	exp := []byte(expected)
	if len(got) != len(exp) {
		return false
	}
	return subtle.ConstantTimeCompare(got, exp) == 1
}

// handleHealth returns 200 OK; no auth required.
func handleHealth() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}
}

// handleIngest accepts a JSON LogEvent and appends it to the session file.
// POST /ingest
func handleIngest(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		var ev LogEvent
		if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
			http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
			return
		}
		if ev.SessionID == "" || ev.EventType == "" {
			http.Error(w, "session_id and event_type required", http.StatusBadRequest)
			return
		}
		if ev.Timestamp == "" {
			ev.Timestamp = time.Now().UTC().Format(time.RFC3339)
		}
		if err := appendEvent(logsDir, ev); err != nil {
			log.Printf("ingest error: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"}) //nolint:errcheck
	}
}

// SessionInfo is one entry in the list_sessions response.
type SessionInfo struct {
	SessionID  string `json:"session_id"`
	FirstEvent string `json:"first_event"`
	LastEvent  string `json:"last_event"`
	EventCount int    `json:"event_count"`
}

// handleListSessions lists sessions with optional limit and since filters.
// GET /sessions?limit=N&since=<RFC3339>
func handleListSessions(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		limit := 100
		if s := r.URL.Query().Get("limit"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n > 0 {
				limit = n
			}
		}

		var since time.Time
		if s := r.URL.Query().Get("since"); s != "" {
			t, err := time.Parse(time.RFC3339, s)
			if err != nil {
				http.Error(w, "invalid since format (RFC3339 required)", http.StatusBadRequest)
				return
			}
			since = t
		}

		entries, err := os.ReadDir(logsDir)
		if err != nil && !os.IsNotExist(err) {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		var sessions []SessionInfo
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
				continue
			}
			id := strings.TrimSuffix(e.Name(), ".jsonl")
			events, err := readEvents(logsDir, id)
			if err != nil || len(events) == 0 {
				continue
			}
			first := events[0].Timestamp
			last := events[len(events)-1].Timestamp
			if !since.IsZero() {
				t, err := time.Parse(time.RFC3339, last)
				if err != nil || t.Before(since) {
					continue
				}
			}
			sessions = append(sessions, SessionInfo{
				SessionID:  id,
				FirstEvent: first,
				LastEvent:  last,
				EventCount: len(events),
			})
		}

		// Sort newest-last-event first.
		sort.Slice(sessions, func(i, j int) bool {
			return sessions[i].LastEvent > sessions[j].LastEvent
		})
		if len(sessions) > limit {
			sessions = sessions[:limit]
		}
		if sessions == nil {
			sessions = []SessionInfo{}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"sessions": sessions}) //nolint:errcheck
	}
}

// SessionSummary is returned by get_session_summary.
type SessionSummary struct {
	SessionID        string         `json:"session_id"`
	LLMCalls         int            `json:"llm_calls"`
	TotalInputTokens int            `json:"total_input_tokens"`
	TotalOutputTokens int           `json:"total_output_tokens"`
	TotalCacheTokens int            `json:"total_cache_read_tokens"`
	ToolCounts       map[string]int `json:"tool_counts"`
	TotalDurationMs  int64          `json:"total_duration_ms"`
	FirstEvent       string         `json:"first_event"`
	LastEvent        string         `json:"last_event"`
}

// handleGetSummary returns aggregate stats for a session.
// GET /sessions/{id}/summary
func handleGetSummary(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		events, err := readEvents(logsDir, id)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		summary := SessionSummary{
			SessionID:  id,
			ToolCounts: make(map[string]int),
		}
		for _, e := range events {
			if summary.FirstEvent == "" {
				summary.FirstEvent = e.Timestamp
			}
			summary.LastEvent = e.Timestamp
			switch e.EventType {
			case "llm_call":
				summary.LLMCalls++
				summary.TotalInputTokens += e.InputTokens
				summary.TotalOutputTokens += e.OutputTokens
				summary.TotalCacheTokens += e.CacheReadTokens
				summary.TotalDurationMs += e.DurationMs
			case "tool_call":
				if e.ToolName != "" {
					summary.ToolCounts[e.ToolName]++
				}
			case "file_read":
				summary.ToolCounts["file_read"]++
			case "test_run":
				summary.ToolCounts["test_run"]++
			case "git_op":
				summary.ToolCounts["git_op"]++
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(summary) //nolint:errcheck
	}
}

// QueryRequest is the body for POST /sessions/{id}/query.
type QueryRequest struct {
	EventType string `json:"event_type"`
	Since     string `json:"since"`
	Until     string `json:"until"`
}

// handleQueryLogs filters session events by type and time range.
// POST /sessions/{id}/query
func handleQueryLogs(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")

		var req QueryRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
			return
		}

		var since, until time.Time
		if req.Since != "" {
			t, err := time.Parse(time.RFC3339, req.Since)
			if err != nil {
				http.Error(w, "invalid since format", http.StatusBadRequest)
				return
			}
			since = t
		}
		if req.Until != "" {
			t, err := time.Parse(time.RFC3339, req.Until)
			if err != nil {
				http.Error(w, "invalid until format", http.StatusBadRequest)
				return
			}
			until = t
		}

		events, err := readEvents(logsDir, id)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		var result []LogEvent
		for _, e := range events {
			if req.EventType != "" && e.EventType != req.EventType {
				continue
			}
			if !since.IsZero() {
				t, err := time.Parse(time.RFC3339, e.Timestamp)
				if err != nil || t.Before(since) {
					continue
				}
			}
			if !until.IsZero() {
				t, err := time.Parse(time.RFC3339, e.Timestamp)
				if err != nil || t.After(until) {
					continue
				}
			}
			result = append(result, e)
		}
		if result == nil {
			result = []LogEvent{}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"events": result}) //nolint:errcheck
	}
}

// TokenRecord is one per-call entry in the token breakdown.
type TokenRecord struct {
	Timestamp           string `json:"timestamp"`
	Model               string `json:"model"`
	InputTokens         int    `json:"input_tokens"`
	OutputTokens        int    `json:"output_tokens"`
	CacheReadTokens     int    `json:"cache_read_tokens"`
	CacheCreationTokens int    `json:"cache_creation_tokens,omitempty"`
	DurationMs          int64  `json:"duration_ms"`
	TurnNumber          int    `json:"turn_number,omitempty"`
}

// handleGetTokens returns per-call token data for a session.
// GET /sessions/{id}/tokens
func handleGetTokens(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		events, err := readEvents(logsDir, id)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		var records []TokenRecord
		for _, e := range events {
			if e.EventType != "llm_call" {
				continue
			}
			records = append(records, TokenRecord{
				Timestamp:           e.Timestamp,
				Model:               e.Model,
				InputTokens:         e.InputTokens,
				OutputTokens:        e.OutputTokens,
				CacheReadTokens:     e.CacheReadTokens,
				CacheCreationTokens: e.CacheCreationTokens,
				DurationMs:          e.DurationMs,
				TurnNumber:          e.TurnNumber,
			})
		}
		if records == nil {
			records = []TokenRecord{}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{"token_breakdown": records}) //nolint:errcheck
	}
}

// FileDedupEntry is one entry in the file-dedup response.
type FileDedupEntry struct {
	SHA256          string `json:"sha256"`
	Path            string `json:"path"`
	Bytes           int    `json:"bytes"`
	ReadCount       int    `json:"read_count"`
	DuplicateReads  int    `json:"duplicate_reads"`
	EstWastedTokens int    `json:"est_wasted_tokens"`
}

// handleGetFileDedup groups file_read events by sha256 and surfaces duplicates.
// GET /sessions/{id}/file-dedup
func handleGetFileDedup(token, logsDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")

		// 404 if session file does not exist.
		if _, err := os.Stat(sessionPath(logsDir, id)); os.IsNotExist(err) {
			http.Error(w, "session not found", http.StatusNotFound)
			return
		}

		events, err := readEvents(logsDir, id)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		type entry struct {
			path      string
			bytes     int
			readCount int
		}
		byHash := make(map[string]*entry)
		// Preserve insertion order for deterministic first-seen path.
		var order []string
		for _, e := range events {
			if e.EventType != "file_read" || e.SHA256 == "" {
				continue
			}
			if _, ok := byHash[e.SHA256]; !ok {
				byHash[e.SHA256] = &entry{path: e.Path, bytes: e.SizeBytes}
				order = append(order, e.SHA256)
			}
			byHash[e.SHA256].readCount++
		}

		var result []FileDedupEntry
		for _, h := range order {
			en := byHash[h]
			if en.readCount <= 1 {
				continue
			}
			dups := en.readCount - 1
			result = append(result, FileDedupEntry{
				SHA256:          h,
				Path:            en.path,
				Bytes:           en.bytes,
				ReadCount:       en.readCount,
				DuplicateReads:  dups,
				EstWastedTokens: dups * en.bytes / 4,
			})
		}

		sort.Slice(result, func(i, j int) bool {
			return result[i].EstWastedTokens > result[j].EstWastedTokens
		})
		if result == nil {
			result = []FileDedupEntry{}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result) //nolint:errcheck
	}
}

// setupRouter wires all endpoints. Exported for testing.
func setupRouter(token, logsDir string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", handleHealth())
	mux.HandleFunc("POST /ingest", handleIngest(token, logsDir))
	mux.HandleFunc("GET /sessions", handleListSessions(token, logsDir))
	mux.HandleFunc("GET /sessions/{id}/summary", handleGetSummary(token, logsDir))
	mux.HandleFunc("POST /sessions/{id}/query", handleQueryLogs(token, logsDir))
	mux.HandleFunc("GET /sessions/{id}/tokens", handleGetTokens(token, logsDir))
	mux.HandleFunc("GET /sessions/{id}/file-dedup", handleGetFileDedup(token, logsDir))
	return mux
}

func main() {
	token := os.Getenv("LOG_API_TOKEN")
	if token == "" {
		log.Fatal("LOG_API_TOKEN is required")
	}

	dir := os.Getenv("LOGS_DIR")
	if dir == "" {
		dir = defaultLogsDir
	}

	mux := setupRouter(token, dir)
	server := &http.Server{
		Addr:    ":8443",
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS13,
		},
	}

	log.Println("Log server listening on :8443 with TLS")
	log.Fatal(server.ListenAndServeTLS("/app/certs/log.crt", "/app/certs/log.key"))
}
