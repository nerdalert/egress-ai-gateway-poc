// Key-validating inference simulator.
// Returns OpenAI-compatible chat completion responses if the correct
// API key is provided via X-Provider-Api-Key header. Returns 401 if
// the key is missing or wrong.
//
// Usage:
//   provider-sim --port 8000 --api-key sk-poc-hardcoded-api-key-for-testing --model gpt-4-external
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"strings"
	"time"
)

var (
	port   = flag.Int("port", 8000, "Listen port")
	apiKey = flag.String("api-key", "", "Required API key (checked in X-Provider-Api-Key header)")
	model  = flag.String("model", "gpt-4-external", "Model name to report")
)

func main() {
	flag.Parse()
	if *apiKey == "" {
		log.Fatal("--api-key is required")
	}

	// Use a catch-all handler that matches path suffixes.
	// This allows the simulator to work behind path-prefix routing
	// (e.g., /openai/v1/chat/completions or /v1/chat/completions both work).
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/v1/chat/completions"),
			strings.HasSuffix(path, "/v1/completions"):
			handleChatCompletions(w, r)
		case strings.HasSuffix(path, "/v1/models"):
			handleModels(w, r)
		case strings.HasSuffix(path, "/health"),
			strings.HasSuffix(path, "/ready"):
			handleHealth(w, r)
		default:
			http.NotFound(w, r)
		}
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("Starting provider-sim on %s (model=%s, key-validation=enabled)", addr, *model)
	log.Fatal(http.ListenAndServe(addr, handler))
}

func checkKey(w http.ResponseWriter, r *http.Request) bool {
	key := r.Header.Get("X-Provider-Api-Key")
	if key == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(map[string]any{
			"error": map[string]any{
				"message": "Missing API key. Set X-Provider-Api-Key header.",
				"type":    "authentication_error",
				"code":    "missing_api_key",
			},
		})
		return false
	}
	if key != *apiKey {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(map[string]any{
			"error": map[string]any{
				"message": fmt.Sprintf("Invalid API key provided: %s...%s", key[:4], key[len(key)-4:]),
				"type":    "authentication_error",
				"code":    "invalid_api_key",
			},
		})
		return false
	}
	return true
}

func handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	if !checkKey(w, r) {
		return
	}

	// Parse request to get model name
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		req.Model = *model
	}
	if req.Model == "" {
		req.Model = *model
	}

	responses := []string{
		"Today it is partially cloudy and raining. Testing, testing 1,2,3",
		"The API key was validated successfully. This is a simulated response.",
		"Hello from the key-validating provider simulator!",
		"External model inference is working end-to-end with API key injection.",
	}

	promptTokens := rand.Intn(5) + 1
	completionTokens := rand.Intn(20) + 5

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"id":      fmt.Sprintf("chatcmpl-%d", time.Now().UnixNano()),
		"created": time.Now().Unix(),
		"model":   req.Model,
		"object":  "chat.completion",
		"usage": map[string]int{
			"prompt_tokens":     promptTokens,
			"completion_tokens": completionTokens,
			"total_tokens":      promptTokens + completionTokens,
		},
		"choices": []map[string]any{
			{
				"index":         0,
				"finish_reason": "stop",
				"message": map[string]string{
					"role":    "assistant",
					"content": responses[rand.Intn(len(responses))],
				},
			},
		},
	})
}

func handleModels(w http.ResponseWriter, r *http.Request) {
	if !checkKey(w, r) {
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"object": "list",
		"data": []map[string]any{
			{
				"id":       *model,
				"object":   "model",
				"created":  time.Now().Unix(),
				"owned_by": "provider-sim",
				"ready":    true,
			},
		},
	})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}
