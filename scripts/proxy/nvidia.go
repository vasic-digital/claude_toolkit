// nvidia.go — NVIDIA NIM API request compatibility transform.
//
// Live defect (2026-07-26, aliases-live leg, nvidia4): some NVIDIA-served
// models (mistralai/mistral-small-4-119b-2603 live; siblings on the same
// endpoint tolerate it) hard-reject any Anthropic `cache_control` key in an
// otherwise OpenAI-shaped request:
//
//	1 validation error for UserMessage cache_control ... Extra inputs are not
//	permitted  (HTTP 400)
//
// Live LAUNCHES through ccr were never exposed — the router's cleancache
// transformer strips cache_control in its typed Anthropic->OpenAI path. But
// the cma-proxy chain serves clients WITHOUT ccr in front (the aliases-live
// direct probe POSTs an OpenAI-shaped body with a message-level cache_control
// straight at the proxy/endpoint), and there the field reached the provider
// verbatim. This transform strips every cache_control key from the inbound
// body before forwarding — message-level, content-block-level, tool-definition
// -level, system blocks — matching the poe/kimi/sarvam shim pattern.
//
// The strip is SCHEMA-AWARE, mirroring the semantics of
// submodules/claude-code-router/internal/translate stripKey: a tool's
// input_schema is a JSON Schema, and inside its "properties" object the map
// keys are property NAMES chosen by whoever wrote the tool. A tool may
// legitimately declare a property called "cache_control"; deleting it blindly
// leaves a self-contradictory schema ("properties": {} with
// "required": ["cache_control"]). Property-name positions are therefore
// preserved — but their VALUES are still walked, so an Anthropic cache_control
// nested deeper inside a property's own schema is still removed.
//
// Request-only: NVIDIA responses are standard OpenAI JSON and pass through
// untouched (no registerResponse).
package main

// init registers the request transform so cma-proxy discovers and applies it
// (providerKey folds digit/dash suffixes: nvidia4 -> nvidia).
func init() { registerRequest("nvidia", nvidiaFix) }

// nvidiaStripKeyIn removes every "cache_control" key from the decoded JSON
// tree, EXCEPT where the key sits in a JSON Schema "properties" object (user
// data, not Anthropic metadata). Mutates maps in place, exactly like ccr's
// stripKeyIn — the proxy re-marshals the body afterwards, so an in-place edit
// is the whole job. Mirrors submodules/claude-code-router/internal/translate/
// anthropic.go:stripKeyIn one-for-one.
func nvidiaStripKeyIn(v interface{}, inProperties bool) interface{} {
	switch t := v.(type) {
	case map[string]interface{}:
		if !inProperties {
			delete(t, "cache_control")
		}
		for k, sub := range t {
			// A child map named "properties" is a JSON Schema property bag:
			// its immediate keys are user-chosen names, not metadata.
			t[k] = nvidiaStripKeyIn(sub, k == "properties")
		}
		return t
	case []interface{}:
		for i, sub := range t {
			// Array elements are never property-name positions.
			t[i] = nvidiaStripKeyIn(sub, false)
		}
		return t
	}
	return v
}

// nvidiaFix strips every Anthropic cache_control key from the request body
// (schema-aware — see nvidiaStripKeyIn). Returns the (in-place mutated) body.
// Request-only.
func nvidiaFix(body map[string]interface{}) map[string]interface{} {
	out, _ := nvidiaStripKeyIn(body, false).(map[string]interface{})
	return out
}
