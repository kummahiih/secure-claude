package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestMCPHandlers(t *testing.T) {
	// Setup: Create a real temporary workspace
	tempDir := t.TempDir()
	rootDir, err := os.OpenRoot(tempDir)
	if err != nil {
		t.Fatalf("Failed to open root: %v", err)
	}
	defer rootDir.Close()

	token := "secret-test-token"

	// Helper to create authenticated requests
	newAuthRequest := func(method, url string, body io.Reader) *http.Request {
		req := httptest.NewRequest(method, url, body)
		req.Header.Set("Authorization", "Bearer "+token)
		return req
	}

	t.Run("Create results in Empty File", func(t *testing.T) {
		// 1. Create the file
		filename := "empty_check.txt"
		req := newAuthRequest("POST", "/create?path="+filename, nil)
		rr := httptest.NewRecorder()
		handleCreate(rootDir, token)(rr, req)

		if rr.Code != http.StatusCreated {
			t.Fatalf("Failed to create file: %v", rr.Code)
		}

		// 2. Verify size on disk is exactly 0
		info, err := os.Stat(filepath.Join(tempDir, filename))
		if err != nil {
			t.Fatalf("File does not exist on disk: %v", err)
		}
		if info.Size() != 0 {
			t.Errorf("Expected empty file (0 bytes), but got %d bytes", info.Size())
		}
	})

	t.Run("Read returns Exact Content", func(t *testing.T) {
		// 1. Manually write a file to the temp workspace
		filename := "read_test.txt"
		expectedContent := "This is a secret message for the agent."
		err := os.WriteFile(filepath.Join(tempDir, filename), []byte(expectedContent), 0644)
		if err != nil {
			t.Fatalf("Setup failed: %v", err)
		}

		// 2. Call the /read handler
		req := newAuthRequest("GET", "/read?path="+filename, nil)
		rr := httptest.NewRecorder()
		handleRead(rootDir, token)(rr, req)

		// 3. Verify HTTP response
		if rr.Code != http.StatusOK {
			t.Fatalf("Read handler returned status %v", rr.Code)
		}

		// 4. Verify the Body matches exactly
		gotContent := rr.Body.String()
		if gotContent != expectedContent {
			t.Errorf("Content mismatch!\nWant: %q\nGot:  %q", expectedContent, gotContent)
		}
	})

	t.Run("Write and Overwrite", func(t *testing.T) {
		payload := map[string]string{
			"path":    "data.txt",
			"content": "initial content",
		}
		body, _ := json.Marshal(payload)

		req := newAuthRequest("POST", "/write", bytes.NewBuffer(body))
		rr := httptest.NewRecorder()
		handleWrite(rootDir, token)(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("Write failed: %v", rr.Body.String())
		}

		// Verify disk content
		got, _ := os.ReadFile(filepath.Join(tempDir, "data.txt"))
		if string(got) != "initial content" {
			t.Errorf("Expected 'initial content', got '%s'", string(got))
		}
	})

	t.Run("Recursive List", func(t *testing.T) {
		// Create a nested structure
		os.MkdirAll(filepath.Join(tempDir, "a/b"), 0755)
		os.WriteFile(filepath.Join(tempDir, "a/b/c.txt"), []byte("test"), 0644)

		req := newAuthRequest("GET", "/list", nil)
		rr := httptest.NewRecorder()
		handleList(rootDir, token)(rr, req)

		var resp map[string]interface{}
		json.Unmarshal(rr.Body.Bytes(), &resp)

		files := resp["files"].([]interface{})
		found := false
		for _, f := range files {
			if f.(string) == "a/b/c.txt" {
				found = true
			}
		}
		if !found {
			t.Errorf("List failed to find nested file. Got: %v", files)
		}
	})

	t.Run("Remove File", func(t *testing.T) {
		req := newAuthRequest("DELETE", "/remove?path=data.txt", nil)
		rr := httptest.NewRecorder()
		handleRemove(rootDir, token)(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("Remove failed: %v", rr.Code)
		}

		if _, err := os.Stat(filepath.Join(tempDir, "data.txt")); !os.IsNotExist(err) {
			t.Error("File still exists after removal")
		}
	})

	t.Run("Security: Path Traversal Block", func(t *testing.T) {
		// Attempting to read outside the jail
		req := newAuthRequest("GET", "/read?path=../etc/passwd", nil)
		rr := httptest.NewRecorder()
		handleRead(rootDir, token)(rr, req)

		// os.OpenRoot should naturally prevent this
		if rr.Code == http.StatusOK {
			t.Error("Security Breach: Successfully read file outside of rootDir!")
		}
	})
}
