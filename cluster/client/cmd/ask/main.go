// Command ask is the Go reimplementation of query.sh: it POSTs a
// {model, query} JSON document to the secure-claude cluster's /ask
// endpoint and prints either the extracted "response" field (default)
// or the pretty-printed raw JSON (with --raw).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"client"
)

func main() {
	if err := runAsk(os.Args[1:], os.Stdout, ".cluster_tokens.env", "./cluster/certs/ca.crt", "https://localhost:8443/ask"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// runAsk performs the /ask request flow. It is factored out of main so
// unit tests can drive it against an httptest server and a temporary
// tokens file.
func runAsk(args []string, stdout io.Writer, tokensPath, caPath, endpoint string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: ask model \"Your question here\" [--raw]")
	}
	model := args[0]
	query := args[1]

	fs := flag.NewFlagSet("ask", flag.ContinueOnError)
	raw := fs.Bool("raw", false, "print the raw pretty JSON response")
	if err := fs.Parse(args[2:]); err != nil {
		return err
	}

	if _, err := os.Stat(tokensPath); err != nil {
		return fmt.Errorf("%s not found; run ./run.sh first to generate tokens", tokensPath)
	}
	tokens, err := client.LoadTokens(tokensPath)
	if err != nil {
		return fmt.Errorf("load tokens: %w", err)
	}
	token := tokens["CLAUDE_API_TOKEN"]
	if token == "" {
		return fmt.Errorf("CLAUDE_API_TOKEN missing from %s", tokensPath)
	}

	body, err := client.PostJSON(endpoint, token, caPath, model, query)
	if err != nil {
		return err
	}

	if *raw {
		var obj any
		if err := json.Unmarshal(body, &obj); err == nil {
			pretty, err := json.MarshalIndent(obj, "", "  ")
			if err == nil {
				fmt.Fprintln(stdout, string(pretty))
				return nil
			}
		}
		fmt.Fprintln(stdout, string(body))
		return nil
	}

	fmt.Fprintln(stdout, client.ExtractResponseField(body))
	return nil
}
