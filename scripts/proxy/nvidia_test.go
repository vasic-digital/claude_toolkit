// nvidia_test.go — nvidia cache_control-strip request transform.
//
// Live defect (2026-07-26, aliases-live leg): nvidia4's model
// (mistralai/mistral-small-4-119b-2603) hard-rejects an OpenAI-shaped request
// carrying a MESSAGE-LEVEL Anthropic cache_control key:
//
//	1 validation error for UserMessage cache_control ... Extra inputs are not
//	permitted  (HTTP 400)
//
// while its sibling nvidia aliases tolerate the field. Live LAUNCHES were never
// exposed (ccr's cleancache strips cache_control in the typed Anthropic->OpenAI
// path); the direct-probe chain — and any client that talks to the proxy
// without ccr in front — was. These tests pin the schema-AWARE strip semantics
// of submodules/claude-code-router/internal/translate stripKey: every Anthropic
// cache_control goes (message-level, content-block-level, tool-level, system
// blocks), but a JSON-Schema property legitimately NAMED cache_control inside a
// tool input_schema "properties" bag is USER DATA and is preserved.
package main

import (
	"encoding/json"
	"testing"
)

// decode is a small helper so every case can assert on the transformed tree
// rather than on string containment.
func decode(t *testing.T, v interface{}) map[string]interface{} {
	t.Helper()
	m, ok := v.(map[string]interface{})
	if !ok {
		t.Fatalf("expected map, got %T", v)
	}
	return m
}

func TestNvidiaFix_MessageLevelStrip(t *testing.T) {
	body := map[string]interface{}{
		"model": "mistralai/mistral-small-4-119b-2603",
		"messages": []interface{}{
			map[string]interface{}{
				"role":          "user",
				"content":       "Say OK",
				"cache_control": map[string]interface{}{"type": "ephemeral"},
			},
		},
	}
	out := nvidiaFix(body)
	msg := decode(t, out["messages"].([]interface{})[0])
	if _, present := msg["cache_control"]; present {
		t.Fatalf("message-level cache_control not stripped: %v", msg)
	}
	if msg["content"] != "Say OK" || msg["role"] != "user" {
		t.Fatalf("message content damaged by the strip: %v", msg)
	}
}

func TestNvidiaFix_ContentBlockAndSystemStrip(t *testing.T) {
	body := map[string]interface{}{
		"system": []interface{}{
			map[string]interface{}{
				"type":          "text",
				"text":          "sys",
				"cache_control": map[string]interface{}{"type": "ephemeral"},
			},
		},
		"messages": []interface{}{
			map[string]interface{}{
				"role": "user",
				"content": []interface{}{
					map[string]interface{}{
						"type":          "text",
						"text":          "hi",
						"cache_control": map[string]interface{}{"type": "ephemeral"},
					},
				},
			},
		},
	}
	out := nvidiaFix(body)
	sys := decode(t, out["system"].([]interface{})[0])
	if _, present := sys["cache_control"]; present {
		t.Fatalf("system-block cache_control not stripped: %v", sys)
	}
	msg := decode(t, out["messages"].([]interface{})[0])
	blk := decode(t, msg["content"].([]interface{})[0])
	if _, present := blk["cache_control"]; present {
		t.Fatalf("content-block cache_control not stripped: %v", blk)
	}
	if blk["text"] != "hi" {
		t.Fatalf("content block damaged by the strip: %v", blk)
	}
}

func TestNvidiaFix_ToolLevelStrippedButSchemaPropertyPreserved(t *testing.T) {
	body := map[string]interface{}{
		"tools": []interface{}{
			map[string]interface{}{
				// Anthropic metadata on the tool definition itself — stripped.
				"cache_control": map[string]interface{}{"type": "ephemeral"},
				"type":          "function",
				"function": map[string]interface{}{
					"name":        "cachemgr",
					"description": "manages caches",
					"parameters": map[string]interface{}{
						"type": "object",
						"properties": map[string]interface{}{
							// A property LEGITIMATELY NAMED cache_control — user
							// data, must survive.
							"cache_control": map[string]interface{}{
								"type":        "string",
								"description": "which cache to control",
							},
							"other": map[string]interface{}{"type": "string"},
						},
						"required": []interface{}{"cache_control"},
					},
				},
			},
		},
	}
	out := nvidiaFix(body)
	tool := decode(t, out["tools"].([]interface{})[0])
	if _, present := tool["cache_control"]; present {
		t.Fatalf("tool-level cache_control not stripped: %v", tool)
	}
	fn := decode(t, tool["function"])
	params := decode(t, fn["parameters"])
	props := decode(t, params["properties"])
	if _, present := props["cache_control"]; !present {
		t.Fatalf("schema PROPERTY named cache_control was deleted — self-contradictory schema: %v", props)
	}
	req := params["required"].([]interface{})
	if req[0] != "cache_control" {
		t.Fatalf("required list damaged: %v", req)
	}
}

func TestNvidiaFix_NestedMetadataInsidePropertyStillStripped(t *testing.T) {
	// The "properties" exception covers the property NAME position only: an
	// Anthropic cache_control nested INSIDE a property's own schema is still
	// metadata and still goes (mirrors stripKeyIn: values are walked).
	body := map[string]interface{}{
		"tools": []interface{}{
			map[string]interface{}{
				"function": map[string]interface{}{
					"parameters": map[string]interface{}{
						"properties": map[string]interface{}{
							"x": map[string]interface{}{
								"type":          "object",
								"cache_control": map[string]interface{}{"type": "ephemeral"},
							},
						},
					},
				},
			},
		},
	}
	out := nvidiaFix(body)
	tool := decode(t, out["tools"].([]interface{})[0])
	x := decode(t, decode(t, decode(t, tool["function"])["parameters"])["properties"].(map[string]interface{})["x"])
	if _, present := x["cache_control"]; present {
		t.Fatalf("cache_control nested inside a property schema not stripped: %v", x)
	}
	if x["type"] != "object" {
		t.Fatalf("property schema damaged: %v", x)
	}
}

func TestNvidiaFix_UntouchedShapes(t *testing.T) {
	// No cache_control anywhere: the body must round-trip byte-identical.
	in := map[string]interface{}{
		"model":      "m",
		"max_tokens": float64(8192),
		"messages": []interface{}{
			map[string]interface{}{"role": "user", "content": "plain"},
		},
	}
	before, _ := json.Marshal(in)
	out := nvidiaFix(in)
	after, _ := json.Marshal(out)
	if string(before) != string(after) {
		t.Fatalf("body without cache_control was modified:\nbefore %s\nafter  %s", before, after)
	}
}

func TestNvidiaRegistration_FamilyResolution(t *testing.T) {
	// Same folds as poe2 -> poe: digit-suffixed variant ids resolve to the base.
	if got := providerKey("nvidia"); got != "nvidia" {
		t.Fatalf("providerKey(nvidia) = %q, want nvidia", got)
	}
	if got := providerKey("nvidia4"); got != "nvidia" {
		t.Fatalf("providerKey(nvidia4) = %q, want nvidia", got)
	}
	if !hasTransform("nvidia4") {
		t.Fatalf("hasTransform(nvidia4) = false, want true")
	}
}
