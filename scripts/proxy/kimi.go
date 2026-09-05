// kimi.go — REQUEST transform for Kimi (moonshot-flavored) coding endpoints.
//
// Also registered under the alias key "kc": after the v1.27.0 rename the kimi-*
// prefix is vacated for the Kimi CLI family and Claude-over-Kimi-native ids
// carry the "kc-" prefix (kimi-for-coding -> kc-for-coding). Those ids still
// talk to the same moonshot-flavored coding API, so Claude Code's tool schemas
// need the same normalization. providerKey() resolves "kc-for-coding" to the
// dash-prefix "kc", so this alias key is what --has-transform kc-* hits.
//
// Go port of kimi_proxy.py's fix_request (= fix_tools + strip_cache_control)
// and normalize_schema. Kimi's coding API enforces a strict JSON-schema flavor
// for tool definitions: every `$ref` must start with `#/$defs/`. Claude Code
// (via claude-code-router) emits `$ref`s that do NOT match — e.g.
// `#/definitions/orderBy` or bare names — so every tool-carrying request fails.
//
// This transform, for each tool's `parameters`:
//   - hoists $defs AND definitions into a single $defs;
//   - rewrites any $ref not starting with `#/$defs/` to `#/$defs/<last-segment>`
//     when that name is defined;
//   - guarantees type == "object" and a `properties` key;
//   - strips cache_control from messages;
//   - passes everything else through unchanged.
//
// Behavior is a 1:1 port of kimi_proxy.py — see scripts/tests/test_kimi.sh for
// the spec these functions satisfy.
package main

import "strings"

func init() {
	registerRequest("kimi", kimiFix)
	registerRequest("kc", kimiFix)
}

// kimiFix is the Go equivalent of python fix_request(body): normalize tool
// schemas and strip cache_control, returning the (modified) body.
func kimiFix(body map[string]interface{}) map[string]interface{} {
	if body == nil {
		return body
	}
	if _, ok := body["tools"]; ok {
		body["tools"] = kimiFixTools(body["tools"])
	}
	if _, ok := body["messages"]; ok {
		body["messages"] = kimiStripCacheControl(body["messages"])
	}
	return body
}

// kimiFixTools normalizes every tool's function.parameters schema. Mirrors
// python fix_tools: a non-list (or empty) value is returned unchanged, and
// non-object entries in the list are dropped.
func kimiFixTools(v interface{}) interface{} {
	tools, ok := v.([]interface{})
	if !ok || len(tools) == 0 {
		return v
	}
	fixed := make([]interface{}, 0, len(tools))
	for _, item := range tools {
		tool, ok := item.(map[string]interface{})
		if !ok {
			continue // python: `if not isinstance(tool, dict): continue`
		}
		t := make(map[string]interface{}, len(tool))
		for k, val := range tool {
			t[k] = val
		}
		if fn, ok := t["function"].(map[string]interface{}); ok {
			f := make(map[string]interface{}, len(fn))
			for k, val := range fn {
				f[k] = val
			}
			f["parameters"] = kimiNormalizeSchema(f["parameters"])
			t["function"] = f
		}
		fixed = append(fixed, t)
	}
	return fixed
}

// kimiNormalizeSchema normalizes one tool's parameters schema to the moonshot
// flavor. Mirrors python normalize_schema exactly.
func kimiNormalizeSchema(v interface{}) map[string]interface{} {
	schema, ok := v.(map[string]interface{})
	if !ok {
		// python: `if not isinstance(schema, dict): return {...}`
		return map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	}
	// Shallow copy so the input is never mutated (python: `schema = dict(schema)`).
	out := make(map[string]interface{}, len(schema))
	for k, val := range schema {
		out[k] = val
	}
	// Hoist $defs + definitions into a single $defs. The key is popped even when
	// its value is not an object; definitions overrides $defs on a name clash
	// because it is merged second (python iterates ("$defs", "definitions")).
	defs := map[string]interface{}{}
	for _, key := range []string{"$defs", "definitions"} {
		if block, present := out[key]; present {
			delete(out, key)
			if bm, ok := block.(map[string]interface{}); ok {
				for k, val := range bm {
					defs[k] = val
				}
			}
		}
	}
	// Rewrite foreign $refs throughout the (defs-stripped) schema tree.
	fixed, _ := kimiFixRefs(out, defs).(map[string]interface{})
	// Re-attach the raw defs (their own internal refs are intentionally NOT
	// rewritten — matches python, which adds defs after fix() has run).
	if len(defs) > 0 {
		fixed["$defs"] = defs
	}
	if _, present := fixed["type"]; !present {
		fixed["type"] = "object"
	}
	if _, ok := fixed["properties"].(map[string]interface{}); !ok {
		fixed["properties"] = map[string]interface{}{}
	}
	return fixed
}

// kimiFixRefs recursively rebuilds node, rewriting any `$ref` string that does
// not start with `#/$defs/` to `#/$defs/<last-segment>` when that name is
// defined in defs. Mirrors python normalize_schema.fix().
func kimiFixRefs(node interface{}, defs map[string]interface{}) interface{} {
	switch n := node.(type) {
	case map[string]interface{}:
		newRef, rewritten := "", false
		if rs, ok := n["$ref"].(string); ok && !strings.HasPrefix(rs, "#/$defs/") {
			name := kimiLastSegment(rs)
			if _, defined := defs[name]; defined {
				newRef, rewritten = "#/$defs/"+name, true
			}
		}
		out := make(map[string]interface{}, len(n))
		for k, v := range n {
			if k == "$ref" && rewritten {
				out[k] = newRef
			} else {
				out[k] = kimiFixRefs(v, defs)
			}
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(n))
		for i, item := range n {
			out[i] = kimiFixRefs(item, defs)
		}
		return out
	default:
		return node
	}
}

// kimiLastSegment is python `ref.rstrip("/").split("/")[-1]`: drop trailing
// slashes, then take the segment after the final '/'.
func kimiLastSegment(ref string) string {
	trimmed := strings.TrimRight(ref, "/")
	if i := strings.LastIndexByte(trimmed, '/'); i >= 0 {
		return trimmed[i+1:]
	}
	return trimmed
}

// kimiStripCacheControl recursively removes every `cache_control` key from
// nested objects. Mirrors python strip_cache_control.
func kimiStripCacheControl(v interface{}) interface{} {
	switch n := v.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(n))
		for k, val := range n {
			if k == "cache_control" {
				continue
			}
			out[k] = kimiStripCacheControl(val)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(n))
		for i, item := range n {
			out[i] = kimiStripCacheControl(item)
		}
		return out
	default:
		return v
	}
}
