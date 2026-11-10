// kbsearch — a small Knowledge-Base search client for the ai-lab stack.
//
// Queries the two KB backends and prints ranked results:
//   * RAGFlow  retrieval API  (vector + keyword chunks over datasets)
//   * LightRAG query API      (knowledge-graph augmented answers)
//
// Usage:
//
//	kbsearch [-d dataset] [-n N] [-graph] <query words...>
//
// Env:
//
//	RAGFLOW_URL      default http://systemd-ragflow:9380
//	RAGFLOW_API_KEY  required (Bearer PAT from scripts/kb-bootstrap.sh)
//	LIGHTRAG_URL     default http://systemd-lightrag:9621
//	LIGHTRAG_API_KEY optional (X-API-Key)
//
// Examples:
//
//	kbsearch agentic attention                    # RAGFlow over all datasets
//	kbsearch -d ai-papers retrieval augmented     # one dataset
//	kbsearch -graph what connects RAGFlow and LightRAG
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

type chunk struct {
	Content          string  `json:"content"`
	DocumentKeyword  string  `json:"document_keyword"`
	DatasetID        string  `json:"dataset_id"`
	Similarity       float64 `json:"similarity"`
	VectorSimilarity float64 `json:"vector_similarity"`
}

type retrievalResp struct {
	Code int    `json:"code"`
	Data struct {
		Total   int     `json:"total"`
		Chunks  []chunk `json:"chunks"`
	} `json:"data"`
}

type dsResp struct {
	Code int `json:"code"`
	Data []struct {
		Name string `json:"name"`
		ID   string `json:"id"`
	} `json:"data"`
}

func getenv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func mustKey() string {
	k := os.Getenv("RAGFLOW_API_KEY")
	if k == "" {
		fmt.Fprintln(os.Stderr, "FATAL: RAGFLOW_API_KEY not set (value never logged)")
		os.Exit(2)
	}
	return k
}

func postJSON(url string, body any, headers map[string]string, out any) error {
	buf, _ := json.Marshal(body)
	req, err := http.NewRequest("POST", url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{Timeout: 300 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%s: HTTP %d: %s", url, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return json.Unmarshal(raw, out)
}

func rfHeaders() map[string]string {
	return map[string]string{"Authorization": "Bearer " + mustKey()}
}

// datasets maps name -> id via the RAGFlow list endpoint.
func datasets(base string) (map[string]string, error) {
	var d dsResp
	url := strings.TrimSuffix(base, "/") + "/api/v1/datasets?page=1&page_size=100"
	req, _ := http.NewRequest("GET", url, nil)
	req.Header = http.Header{}
	for k, v := range rfHeaders() {
		req.Header.Set(k, v)
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		return nil, err
	}
	m := map[string]string{}
	for _, x := range d.Data {
		m[x.Name] = x.ID
	}
	return m, nil
}

func ragflowSearch(base, query, dataset string, top int) error {
	ds, err := datasets(base)
	if err != nil {
		return fmt.Errorf("datasets: %w", err)
	}
	body := map[string]any{"question": query, "page_size": top}
	if dataset != "" {
		id, ok := ds[dataset]
		if !ok {
			return fmt.Errorf("unknown dataset %q (have: %s)", dataset, strings.Join(keys(ds), ", "))
		}
		body["dataset_ids"] = []string{id}
	} else {
		// RAGFlow v1 retrieval requires an explicit dataset_ids set; without
		// it the call errors (code 101). Default: search every dataset.
		all := make([]string, 0, len(ds))
		for _, id := range ds {
			all = append(all, id)
		}
		body["dataset_ids"] = all
	}
	var r retrievalResp
	if err := postJSON(strings.TrimSuffix(base, "/")+"/api/v1/retrieval", body, rfHeaders(), &r); err != nil {
		return err
	}
	if r.Code != 0 {
		return fmt.Errorf("ragflow error code %d", r.Code)
	}
	fmt.Printf("== RAGFlow: %d match(es), showing %d ==\n", r.Data.Total, len(r.Data.Chunks))
	for i, c := range r.Data.Chunks {
		snippet := strings.Join(strings.Fields(c.Content), " ")
		if len(snippet) > 240 {
			snippet = snippet[:240] + "…"
		}
		fmt.Printf("%2d. [%s] (sim %.3f)\n    %s\n", i+1, c.DocumentKeyword, c.Similarity, snippet)
	}
	return nil
}

func lightragQuery(base, query string) error {
	headers := map[string]string{}
	if k := os.Getenv("LIGHTRAG_API_KEY"); k != "" {
		headers["X-API-Key"] = k
	}
	var out struct {
		Response string `json:"response"`
	}
	body := map[string]any{"query": query, "mode": "hybrid", "only_need_context": false}
	if err := postJSON(strings.TrimSuffix(base, "/")+"/query", body, headers, &out); err != nil {
		return err
	}
	fmt.Println("== LightRAG (knowledge graph, hybrid) ==")
	fmt.Println(strings.TrimSpace(out.Response))
	return nil
}

func keys(m map[string]string) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

func main() {
	args := os.Args[1:]
	dataset, top, graph := "", 8, false
	var qwords []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-d":
			i++
			if i < len(args) {
				dataset = args[i]
			}
		case "-n":
			i++
			if i < len(args) {
				fmt.Sscanf(args[i], "%d", &top)
			}
		case "-graph":
			graph = true
		case "-h", "--help":
			usage()
			os.Exit(0)
		default:
			qwords = append(qwords, args[i])
		}
	}
	if len(qwords) == 0 {
		usage()
		os.Exit(2)
	}
	query := strings.Join(qwords, " ")
	if graph {
		if err := lightragQuery(getenv("LIGHTRAG_URL", "http://systemd-lightrag:9621"), query); err != nil {
			fmt.Fprintln(os.Stderr, "lightrag:", err)
			os.Exit(1)
		}
		return
	}
	if err := ragflowSearch(getenv("RAGFLOW_URL", "http://systemd-ragflow:9380"), query, dataset, top); err != nil {
		fmt.Fprintln(os.Stderr, "ragflow:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: kbsearch [-d dataset] [-n N] [-graph] <query>")
}
