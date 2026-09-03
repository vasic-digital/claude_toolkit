// cma-proxy — the toolkit's provider-compatibility proxy (Go).
//
// Replaces the per-provider python proxies. The launch wrapper
// (cma_run_provider) starts one instance per proxied provider as
//
//	cma-proxy --provider <id> --port <port>
//
// and points ccr at http://127.0.0.1:<port>/v1/chat/completions. Discovery uses
// `cma-proxy --has-transform <id>` (exit 0 if this binary transforms that
// provider, else 1).
//
// Transform families today: `helixagent` (Hermes tool-call recovery, see
// hermes.go), `poe` (request-schema fixes, poe.go), `kimi` (tool-schema
// normalization, kimi.go), `sarvam` (sarvam.go), and `nvidia` (cache_control
// stripping for strict backends, nvidia.go). Unknown providers are served as
// a transparent pass-through so the binary is always safe to place in front
// of a backend.
//
// Upstream defaults to $HELIXAGENT_PROXY_UPSTREAM, then $CMA_PROVIDER_BASE_URL,
// then a local fallback matching the pinned HelixLLM port. A trailing /v1 is
// stripped (see upstreamRoot) so the request path is never doubled.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// defaultUpstream resolves the backend this proxy forwards to. The environment
// wins — the launch wrapper always exports CMA_PROVIDER_BASE_URL out of the
// provider record — and the literal below is only the last-resort fallback for
// a hand-started proxy with no environment at all.
//
// That fallback is 127.0.0.1:7061 because that is where HelixAgent's
// OpenAI-compatible /v1 actually listens (measured with `ss -ltnp`,
// 2026-09-03). The previous value, :18434, is the llama.cpp coder container —
// a real port, but a DIFFERENT service, and one that is frequently down (it
// was, when measured). A hand-started proxy therefore forwarded either into a
// closed socket or into the wrong backend.
func defaultUpstream() string {
	for _, e := range []string{"HELIXAGENT_PROXY_UPSTREAM", "CMA_PROVIDER_BASE_URL"} {
		if v := os.Getenv(e); v != "" {
			return v
		}
	}
	return "http://127.0.0.1:7061"
}

type proxy struct {
	provider string
	upstream string
	client   *http.Client
}

func (p *proxy) sendJSON(w http.ResponseWriter, status int, obj interface{}) {
	b, _ := json.Marshal(obj)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(b)
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		p.sendJSON(w, http.StatusMethodNotAllowed,
			map[string]interface{}{"error": map[string]string{"message": "method not allowed"}})
		return
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		p.sendJSON(w, http.StatusBadRequest,
			map[string]interface{}{"error": map[string]string{"message": "request read error"}})
		return
	}

	// Best-effort request parse (for tool schemas + the stream flag). A parse
	// failure is non-fatal: forward the body as-is.
	var reqObj map[string]interface{}
	_ = json.Unmarshal(raw, &reqObj)
	paramTypes := buildToolParamTypes(reqObj["tools"])
	isStream, _ := reqObj["stream"].(bool)

	key := providerKey(p.provider)

	// REQUEST transform (poe/kimi/sarvam tool-schema fixes): rewrite the body
	// before forwarding. helixagent has none, so its request bytes go verbatim.
	reqBody := raw
	if fn := reqTransforms[key]; fn != nil && reqObj != nil {
		if nb, mErr := json.Marshal(fn(reqObj)); mErr == nil {
			reqBody = nb
		}
	}

	url := upstreamRoot(p.upstream) + r.URL.Path
	upReq, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		p.sendJSON(w, http.StatusBadGateway,
			map[string]interface{}{"error": map[string]string{"message": "bad upstream url: " + err.Error()}})
		return
	}
	upReq.Header.Set("Content-Type", "application/json")
	if a := r.Header.Get("Authorization"); a != "" {
		upReq.Header.Set("Authorization", a)
	}

	resp, err := p.client.Do(upReq)
	if err != nil {
		// Connection refused, timeout, DNS, etc. — emit a clean 502 JSON body
		// so ccr sees a real error, never an empty reply (review 2026-07-22).
		p.sendJSON(w, http.StatusBadGateway,
			map[string]interface{}{"error": map[string]string{
				"type":    "upstream_error",
				"message": "helixagent proxy could not reach the backend: " + err.Error(),
			}})
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.Header.Get("Content-Encoding") == "gzip" {
		if gr, err := gzip.NewReader(bytes.NewReader(body)); err == nil {
			if dec, derr := io.ReadAll(gr); derr == nil {
				body = dec
			}
		}
	}
	ctype := resp.Header.Get("Content-Type")
	if ctype == "" {
		ctype = "application/json"
	}

	// Response transform — only on a 200 and only for a response-transform provider.
	if respProviders[key] && resp.StatusCode == http.StatusOK {
		var out []byte
		var changed bool
		if isStream {
			out, changed = transformStream(string(body), paramTypes)
		} else {
			out, changed = transformNonStream(body, paramTypes)
		}
		if changed {
			if isStream {
				w.Header().Set("Content-Type", "text/event-stream")
			} else {
				w.Header().Set("Content-Type", "application/json")
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(out)
			return
		}
	}

	// Pass through: original status + the (decoded) body VERBATIM.
	w.Header().Set("Content-Type", ctype)
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func main() {
	port := flag.Int("port", 3457, "listen port")
	provider := flag.String("provider", "", "provider id (selects the transform)")
	upstream := flag.String("upstream", "", "upstream base URL (a trailing /v1 is stripped)")
	hasT := flag.String("has-transform", "", "exit 0 if this provider id has a transform, else 1")
	flag.Parse()

	if *hasT != "" {
		if hasTransform(*hasT) {
			os.Exit(0)
		}
		os.Exit(1)
	}

	up := *upstream
	if up == "" {
		up = defaultUpstream()
	}
	p := &proxy{
		provider: *provider,
		upstream: up,
		client:   &http.Client{Timeout: 300 * time.Second},
	}
	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	fmt.Fprintf(os.Stderr, "cma-proxy listening on http://%s (provider=%s -> %s", addr, *provider, upstreamRoot(up))
	if k := providerKey(*provider); respProviders[k] {
		fmt.Fprint(os.Stderr, ", Hermes tool-call recovery active")
	} else if k != "" {
		fmt.Fprintf(os.Stderr, ", %s request transform active", k)
	}
	fmt.Fprintln(os.Stderr, ")")
	srv := &http.Server{Addr: addr, Handler: p, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, "cma-proxy:", err)
		os.Exit(1)
	}
}
