// hermes.go — recover Hermes/Qwen tool calls that llama.cpp leaks as prose.
//
// HelixLLM (llama.cpp --jinja, Qwen3-Coder-30B) emits a proper OpenAI
// tool_calls array only when the tool call IS the whole generation. Claude
// Code's system prompt induces a conversational PREAMBLE first, then the call
// in Qwen's Hermes/XML form:
//
//	I'll read it.\n\n<function=Read>\n<parameter=file_path>\nREADME.md\n</parameter>\n</function>\n</tool_call>
//
// Once prose precedes the call, llama.cpp returns the whole thing as `content`
// (finish_reason "stop", tool_calls null) and Claude Code never engages. These
// pure functions recover such leaked calls into structured tool_calls.
//
// Parsing is delimiter-robust (reviewed 2026-07-22): blocks split on the
// OPENING tags (`<function=`, `<parameter=`), never on the closing tags, and a
// parameter value ends at the LAST `</parameter>` in its segment — so a value
// that itself contains `</function>` or `</parameter>` (e.g. Write-ing a file
// about tool-calling) is preserved verbatim, not truncated. Unbalanced opening
// tags inside a value (the un-separable case) trip the balance guard and the
// caller passes the response through untouched rather than emit a corrupt call.
package main

import (
	"crypto/rand"
	"encoding/json"
	"strconv"
	"strings"
)

// helixagent's response carries Hermes tool calls to recover (see transform* below).
// It also needs parallel tool calls disabled: HelixLLM's streaming path emits
// an unbounded loop of identical tool_calls when parallel_tool_calls is true.
func init() {
	registerResponse("helixagent")
	registerRequest("helixagent", helixagentRequestTransform)
}

// helixagentRequestTransform disables parallel tool calls. HelixLLM (llama.cpp
// Qwen3-Coder-30B) streams an endless, repeated sequence of tool_calls when
// parallel_tool_calls is left true; forcing false yields one clean tool_call.
func helixagentRequestTransform(req map[string]interface{}) map[string]interface{} {
	if tools, ok := req["tools"].([]interface{}); ok && len(tools) > 0 {
		req["parallel_tool_calls"] = false
	}
	return req
}

const idAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

type toolCall struct {
	index int
	id    string
	name  string
	args  string // JSON-encoded arguments object
}

func genID() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "call_helixproxy000000000"
	}
	out := make([]byte, 24)
	for i, x := range b {
		out[i] = idAlphabet[int(x)%len(idAlphabet)]
	}
	return string(out)
}

// coerceValue turns a Hermes parameter string into the JSON type its schema
// declares. A `string`-typed param stays a string verbatim (so a path "123" or
// "true" is never reinterpreted); integer/number/boolean/object/array are
// parsed; unknown/absent type is best-effort JSON with a string fallback.
func coerceValue(valueStr, ptype string) interface{} {
	v := strings.TrimSpace(valueStr)
	switch ptype {
	case "string":
		return v
	case "integer":
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	case "number":
		if strings.ContainsAny(v, ".eE") {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				return f
			}
		} else if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	case "boolean":
		switch strings.ToLower(v) {
		case "true":
			return true
		case "false":
			return false
		}
	case "object", "array":
		var out interface{}
		if json.Unmarshal([]byte(v), &out) == nil {
			return out
		}
	default:
		var out interface{}
		if json.Unmarshal([]byte(v), &out) == nil {
			return out
		}
		return v
	}
	return v // failed coercion falls back to the raw string
}

// buildToolParamTypes maps {toolName: {paramName: jsonType}} from a request's
// tools array (used to coerce recovered arg values by their declared type).
func buildToolParamTypes(tools interface{}) map[string]map[string]string {
	out := map[string]map[string]string{}
	arr, ok := tools.([]interface{})
	if !ok {
		return out
	}
	for _, t := range arr {
		tm, ok := t.(map[string]interface{})
		if !ok {
			continue
		}
		fn, ok := tm["function"].(map[string]interface{})
		if !ok {
			continue
		}
		name, ok := fn["name"].(string)
		if !ok {
			continue
		}
		pmap := map[string]string{}
		if params, ok := fn["parameters"].(map[string]interface{}); ok {
			if props, ok := params["properties"].(map[string]interface{}); ok {
				for pn, ps := range props {
					if psm, ok := ps.(map[string]interface{}); ok {
						if ty, ok := psm["type"].(string); ok {
							pmap[pn] = ty
						}
					}
				}
			}
		}
		out[name] = pmap
	}
	return out
}

// parseHermesToolCalls extracts leaked Hermes tool calls from content.
// Returns (preamble, calls, true) when at least one complete <function=…>
// block is found; (…, false) otherwise (caller then passes through untouched).
func parseHermesToolCalls(content string, paramTypes map[string]map[string]string) (string, []toolCall, bool) {
	if content == "" || !strings.Contains(content, "<function=") {
		return "", nil, false
	}
	// Balance guard: MORE opening <function=/<parameter= than closing tags means
	// a value opened a tag it never closed, which makes the block boundaries
	// un-separable — bail so the caller passes the raw response through rather
	// than emit a corrupt call. (EXTRA closing tags are fine and expected: a
	// value may legitimately contain </function> or </parameter>, which the
	// split-on-opening-tag + last-</parameter> parsing below preserves verbatim.)
	if strings.Count(content, "<function=") > strings.Count(content, "</function>") ||
		strings.Count(content, "<parameter=") > strings.Count(content, "</parameter>") {
		return "", nil, false
	}

	// Preamble = text before the first tool-call marker.
	region := content
	preamble := ""
	marker := earliestMarker(content)
	if marker >= 0 {
		preamble = strings.TrimSpace(content[:marker])
		region = content[marker:]
	}

	var calls []toolCall
	idx := 0
	// Split on the OPENING tag so a </function> inside a value can never create
	// a spurious block.
	for _, part := range strings.Split(region, "<function=")[1:] {
		gt := strings.IndexByte(part, '>')
		if gt < 0 {
			continue
		}
		name := strings.TrimSpace(part[:gt])
		body := part[gt+1:]
		if name == "" || !strings.Contains(body, "</function>") {
			continue // must actually close to count
		}
		args := map[string]interface{}{}
		for _, seg := range strings.Split(body, "<parameter=")[1:] {
			pgt := strings.IndexByte(seg, '>')
			if pgt < 0 {
				continue
			}
			pname := strings.TrimSpace(seg[:pgt])
			rest := seg[pgt+1:]
			// The structural close is the LAST </parameter> in this segment;
			// any earlier one is part of the value.
			cl := strings.LastIndex(rest, "</parameter>")
			if cl < 0 {
				continue
			}
			pvalue := strings.TrimSpace(rest[:cl])
			var ptype string
			if pm, ok := paramTypes[name]; ok {
				ptype = pm[pname]
			}
			args[pname] = coerceValue(pvalue, ptype)
		}
		argsJSON, _ := json.Marshal(args)
		calls = append(calls, toolCall{index: idx, id: genID(), name: name, args: string(argsJSON)})
		idx++
	}
	if len(calls) == 0 {
		return "", nil, false
	}
	return preamble, calls, true
}

// earliestMarker returns the index of the earliest <tool_call> or <function=.
func earliestMarker(s string) int {
	a := strings.Index(s, "<tool_call>")
	b := strings.Index(s, "<function=")
	switch {
	case a < 0:
		return b
	case b < 0:
		return a
	case a < b:
		return a
	default:
		return b
	}
}

// transformNonStream rewrites a non-streaming completion when it leaked a
// Hermes call. Returns (out, true) if rewritten, (nil, false) for passthrough
// (caller then forwards the ORIGINAL bytes verbatim).
func transformNonStream(respBody []byte, paramTypes map[string]map[string]string) ([]byte, bool) {
	var obj map[string]interface{}
	if json.Unmarshal(respBody, &obj) != nil {
		return nil, false
	}
	choices, ok := obj["choices"].([]interface{})
	if !ok || len(choices) == 0 {
		return nil, false
	}
	choice0, ok := choices[0].(map[string]interface{})
	if !ok {
		return nil, false
	}
	msg, ok := choice0["message"].(map[string]interface{})
	if !ok {
		return nil, false
	}
	if tc, ok := msg["tool_calls"]; ok && tc != nil {
		return nil, false // llama.cpp already produced structured tool_calls
	}
	content, _ := msg["content"].(string)
	preamble, calls, ok := parseHermesToolCalls(content, paramTypes)
	if !ok {
		return nil, false
	}
	tcList := make([]interface{}, 0, len(calls))
	for _, c := range calls {
		tcList = append(tcList, map[string]interface{}{
			"id":       c.id,
			"type":     "function",
			"function": map[string]interface{}{"name": c.name, "arguments": c.args},
		})
	}
	if preamble == "" {
		msg["content"] = nil
	} else {
		msg["content"] = preamble
	}
	msg["tool_calls"] = tcList
	choice0["finish_reason"] = "tool_calls"
	out, err := json.Marshal(obj)
	if err != nil {
		return nil, false
	}
	return out, true
}

// reassembleStream concatenates content deltas from a buffered SSE stream and
// reports whether the backend already emitted structured tool_calls, plus the
// first chunk's id/model/created/system_fingerprint for faithful re-emission.
func reassembleStream(sseText string) (string, bool, map[string]interface{}) {
	var parts strings.Builder
	hadToolCalls := false
	meta := map[string]interface{}{}
	for _, line := range strings.Split(sseText, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(line[5:])
		if payload == "" || payload == "[DONE]" {
			continue
		}
		var chunk map[string]interface{}
		if json.Unmarshal([]byte(payload), &chunk) != nil {
			continue
		}
		if len(meta) == 0 {
			for _, k := range []string{"id", "model", "created", "system_fingerprint"} {
				if v, ok := chunk[k]; ok && v != nil {
					meta[k] = v
				}
			}
		}
		choices, ok := chunk["choices"].([]interface{})
		if !ok {
			continue
		}
		for _, ch := range choices {
			chm, ok := ch.(map[string]interface{})
			if !ok {
				continue
			}
			delta, ok := chm["delta"].(map[string]interface{})
			if !ok {
				continue
			}
			if c, ok := delta["content"].(string); ok {
				parts.WriteString(c)
			}
			if tc, ok := delta["tool_calls"]; ok && tc != nil {
				hadToolCalls = true
			}
		}
	}
	return parts.String(), hadToolCalls, meta
}

func metaVal(meta map[string]interface{}, k string, def interface{}) interface{} {
	if v, ok := meta[k]; ok && v != nil {
		return v
	}
	return def
}

// buildStream synthesizes a valid OpenAI SSE stream carrying the recovered
// call(s): a content (preamble) chunk, one tool_calls delta per call, a
// finish_reason chunk, then [DONE].
func buildStream(preamble string, calls []toolCall, meta map[string]interface{}) []byte {
	base := map[string]interface{}{
		"id":      metaVal(meta, "id", "chatcmpl-helixproxy"),
		"object":  "chat.completion.chunk",
		"created": metaVal(meta, "created", 0),
		"model":   metaVal(meta, "model", ""),
	}
	if v, ok := meta["system_fingerprint"]; ok {
		base["system_fingerprint"] = v
	}
	var sb strings.Builder
	emit := func(delta map[string]interface{}, finish interface{}) {
		c := map[string]interface{}{}
		for k, v := range base {
			c[k] = v
		}
		c["choices"] = []interface{}{map[string]interface{}{"index": 0, "delta": delta, "finish_reason": finish}}
		b, _ := json.Marshal(c)
		sb.WriteString("data: ")
		sb.Write(b)
		sb.WriteString("\n\n")
	}
	emit(map[string]interface{}{"role": "assistant", "content": preamble}, nil)
	for _, c := range calls {
		emit(map[string]interface{}{"tool_calls": []interface{}{map[string]interface{}{
			"index": c.index, "id": c.id, "type": "function",
			"function": map[string]interface{}{"name": c.name, "arguments": c.args},
		}}}, nil)
	}
	emit(map[string]interface{}{}, "tool_calls")
	sb.WriteString("data: [DONE]\n\n")
	return []byte(sb.String())
}

// transformStream returns rewritten SSE bytes if a Hermes call leaked, else
// (nil, false) for passthrough.
func transformStream(sseText string, paramTypes map[string]map[string]string) ([]byte, bool) {
	content, hadToolCalls, meta := reassembleStream(sseText)
	if hadToolCalls {
		return nil, false
	}
	preamble, calls, ok := parseHermesToolCalls(content, paramTypes)
	if !ok {
		return nil, false
	}
	return buildStream(preamble, calls, meta), true
}

// upstreamRoot strips a trailing /v1 so appending the request path never
// doubles it.
func upstreamRoot(upstream string) string {
	root := strings.TrimRight(upstream, "/")
	return strings.TrimSuffix(root, "/v1")
}
