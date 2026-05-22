package thanos

import (
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"strconv"
)

// Response represents a Thanos/Prometheus API response
type Response struct {
	Status string       `json:"status"`
	Data   ResponseData `json:"data"`
}

type ResponseData struct {
	ResultType string   `json:"resultType"`
	Result     []Result `json:"result"`
}

type Result struct {
	Metric map[string]string `json:"metric"`
	Value  []any             `json:"value"`  // instant query: [timestamp, value]
	Values [][]any           `json:"values"` // range query: [[ts, val], ...]
}

// Parse parses a raw Thanos JSON response
func Parse(body string) (*Response, error) {
	if body == "" {
		return nil, fmt.Errorf("empty response")
	}
	var resp Response
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// HasResults returns true if the response has at least one result
func HasResults(body string) bool {
	resp, err := Parse(body)
	if err != nil {
		return false
	}
	return len(resp.Data.Result) > 0
}

// InstantValue extracts the scalar value from the first result of an instant query
func InstantValue(body string) (string, map[string]string, bool) {
	resp, err := Parse(body)
	if err != nil || len(resp.Data.Result) == 0 {
		return "", nil, false
	}
	r := resp.Data.Result[0]
	if len(r.Value) >= 2 {
		return fmt.Sprintf("%v", r.Value[1]), r.Metric, true
	}
	return "", r.Metric, false
}

// InstantFloat extracts the float value from the first result
func InstantFloat(body string) (float64, bool) {
	val, _, ok := InstantValue(body)
	if !ok {
		return 0, false
	}
	f, err := strconv.ParseFloat(val, 64)
	if err != nil {
		return 0, false
	}
	return f, true
}

// Timeseries extracts values from a range query result, merging all series
// into a single sorted timeline (handles pod restarts with multiple result series)
func Timeseries(body string) ([][2]float64, error) {
	resp, err := Parse(body)
	if err != nil {
		return nil, err
	}

	// Merge all result series into one timeline
	seen := map[float64]float64{}
	for _, r := range resp.Data.Result {
		for _, v := range r.Values {
			if len(v) < 2 {
				continue
			}
			ts, ok := toFloat(v[0])
			if !ok {
				continue
			}
			val, ok := toFloat(v[1])
			if !ok {
				continue
			}
			seen[ts] = val
		}
	}

	// Sort by timestamp
	points := make([][2]float64, 0, len(seen))
	for ts, val := range seen {
		points = append(points, [2]float64{ts, val})
	}
	sortPoints(points)
	return points, nil
}

// PerSeriesTimeseries extracts separate timeseries per result series, labeled by a function
func PerSeriesTimeseries(body string, labelFn func(map[string]string) string) ([]LabeledTimeseries, error) {
	resp, err := Parse(body)
	if err != nil {
		return nil, err
	}

	var result []LabeledTimeseries
	for _, r := range resp.Data.Result {
		label := labelFn(r.Metric)
		var points [][2]float64
		for _, v := range r.Values {
			if len(v) < 2 {
				continue
			}
			ts, ok1 := toFloat(v[0])
			val, ok2 := toFloat(v[1])
			if ok1 && ok2 {
				points = append(points, [2]float64{ts, val})
			}
		}
		result = append(result, LabeledTimeseries{
			Label:    label,
			ProbeURL: r.Metric["probe_url"],
			Values:   points,
		})
	}
	return result, nil
}

type LabeledTimeseries struct {
	Label    string       `json:"label"`
	ProbeURL string       `json:"probe_url,omitempty"`
	Values   [][2]float64 `json:"values"`
}

// Peak returns the maximum value from a timeseries
func Peak(points [][2]float64) float64 {
	var max float64
	for _, p := range points {
		if p[1] > max {
			max = p[1]
		}
	}
	return max
}

// Trend calculates the percentage change from first to last point
func Trend(points [][2]float64) (first, last, pctChange float64) {
	if len(points) < 2 {
		return 0, 0, 0
	}
	first = points[0][1]
	last = points[len(points)-1][1]
	if first == 0 {
		return first, last, 0
	}
	pctChange = ((last - first) / first) * 100
	return first, last, pctChange
}

// ToFloat extracts the float value from a Result's instant value
func ToFloat(r Result) (float64, bool) {
	if len(r.Value) < 2 {
		return 0, false
	}
	return toFloat(r.Value[1])
}

// EncodeQuery URL-encodes a PromQL query string for use in API calls
func EncodeQuery(query string) string {
	return url.QueryEscape(query)
}

func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case string:
		f, err := strconv.ParseFloat(n, 64)
		return f, err == nil
	case int:
		return float64(n), true
	default:
		return 0, false
	}
}

func sortPoints(points [][2]float64) {
	n := len(points)
	for i := 1; i < n; i++ {
		for j := i; j > 0 && points[j][0] < points[j-1][0]; j-- {
			points[j], points[j-1] = points[j-1], points[j]
		}
	}
}

// PointsToJSON converts timeseries points to a JSON-compatible format [[ts,val],...]
func PointsToJSON(points [][2]float64) [][]any {
	result := make([][]any, len(points))
	for i, p := range points {
		result[i] = []any{p[0], fmt.Sprintf("%.6f", p[1])}
	}
	return result
}

// FilterNonZero removes zero-value points from a timeseries.
// Use for binary/error metrics where healthy periods are all zeros.
// An empty result means "healthy for the entire period."
func FilterNonZero(points [][2]float64) [][2]float64 {
	var result [][2]float64
	for _, p := range points {
		if p[1] != 0 {
			result = append(result, p)
		}
	}
	return result
}

// Round rounds a float to n decimal places
func Round(f float64, n int) float64 {
	pow := math.Pow(10, float64(n))
	return math.Round(f*pow) / pow
}
