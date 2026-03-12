package main

import (
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"
)

func handleRead(rootDir *os.Root, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		targetPath := r.URL.Query().Get("path")

		log.Printf("Received request for %s", targetPath)

		file, err := rootDir.Open(targetPath)
		if err != nil {
			http.Error(w, "Access denied or file not found", http.StatusNotFound)
			return
		}
		defer file.Close()

		// 2. Read the content into a byte slice
		// Using io.ReadAll is fine for typical workspace files
		data, err := io.ReadAll(file)
		if err != nil {
			log.Printf("Read error: %v", err)
			http.Error(w, "Error reading file", http.StatusInternalServerError)
			return
		}

		// 1. Log the content for your own sanity
		log.Printf("FILE_SUCCESS: Sending raw content: %s", string(data))

		// 2. Set as plain text so the LLM sees it as a direct message
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")

		// 3. SET STATUS CODE SECOND
		w.WriteHeader(http.StatusOK)

		// 3. Write the raw bytes directly to the response
		w.Write(data)
	}
}

func handleRemove(rootDir *os.Root, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		targetPath := r.URL.Query().Get("path")

		// rootDir.Remove is the secure way to delete within the jail
		err := rootDir.Remove(targetPath)
		if err != nil {
			log.Printf("DELETE_ERROR: %v", err)
			http.Error(w, "Failed to delete file", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		log.Printf("FILE_REMOVED: %s", targetPath)
	}
}

func handleCreate(rootDir *os.Root, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		targetPath := r.URL.Query().Get("path")

		// O_CREATE | O_EXCL prevents overwriting existing files
		f, err := rootDir.OpenFile(targetPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
		if err != nil {
			http.Error(w, "File already exists or invalid path", http.StatusBadRequest)
			return
		}
		f.Close()
		w.WriteHeader(http.StatusCreated)
		log.Printf("FILE_CREATED: %s", targetPath)
	}
}

func handleWrite(rootDir *os.Root, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		// Define the expected JSON payload
		var req struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
			return
		}

		// Open file with Truncate to replace whole content
		// 0644 gives read/write to owner and read-only to group/others
		f, err := rootDir.OpenFile(req.Path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
		if err != nil {
			log.Printf("WRITE_ERROR: %v", err)
			http.Error(w, "Could not open file for writing", http.StatusInternalServerError)
			return
		}
		defer f.Close()

		_, err = f.WriteString(req.Content)
		if err != nil {
			log.Printf("WRITE_ERROR: %v", err)
			http.Error(w, "Failed to write content", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
		log.Printf("FILE_WRITTEN: %s (%d bytes)", req.Path, len(req.Content))
	}
}

func handleList(rootDir *os.Root, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		var files []string
		// Use .FS() to satisfy the fs.FS interface for WalkDir
		err := fs.WalkDir(rootDir.FS(), ".", func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // Skip paths that can't be accessed
			}
			if path == "." {
				return nil
			}

			entry := path
			if d.IsDir() {
				entry += "/"
			}
			files = append(files, entry)
			return nil
		})

		if err != nil {
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"files": files,
			"count": len(files),
		})
	}
}

// setupRouter isolates the routing logic so it can be tested independently
func setupRouter(rootDir *os.Root, token string) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/read", handleRead(rootDir, token))

	// Remove File
	mux.HandleFunc("/remove", handleRemove(rootDir, token))

	// Create Empty File
	mux.HandleFunc("/create", handleCreate(rootDir, token))

	// replace file content
	mux.HandleFunc("/write", handleWrite(rootDir, token))

	// list files
	mux.HandleFunc("/list", handleList(rootDir, token))

	return mux
}

func verifyToken(r *http.Request, expectedToken string) bool {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return false
	}

	parts := strings.SplitN(authHeader, " ", 2)
	if len(parts) != 2 || parts[0] != "Bearer" {
		return false
	}

	expectedBytes := []byte(expectedToken)
	providedBytes := []byte(parts[1])

	// ConstantTimeCompare requires equal lengths
	if len(expectedBytes) != len(providedBytes) {
		return false
	}

	return subtle.ConstantTimeCompare(providedBytes, expectedBytes) == 1
}

func main() {
	token := os.Getenv("MCP_API_TOKEN")
	if token == "" {
		log.Fatal("MCP_API_TOKEN is required")
	}

	rootDir, err := os.OpenRoot("/workspace")
	if err != nil {
		log.Fatalf("Failed to open root workspace: %v", err)
	}
	defer rootDir.Close()

	// Mount the isolated router
	mux := setupRouter(rootDir, token)

	server := &http.Server{
		Addr:    ":8443",
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Println("MCP Server listening on :8443 with TLS")
	log.Fatal(server.ListenAndServeTLS("/app/certs/mcp.crt", "/app/certs/mcp.key"))
}
