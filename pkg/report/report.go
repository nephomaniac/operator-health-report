package report

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"

	"github.com/openshift/operator-health-report/pkg/logging"
)

//go:embed template_prefix.html
var templatePrefix string

//go:embed template_suffix.html
var templateSuffix string

// GenerateHTML writes an HTML report from JSON data.
// The JSON data is injected between the template prefix and suffix
// as the healthDataRaw JavaScript variable.
func GenerateHTML(jsonData []byte, outputPath string) error {
	log := logging.Log

	// Validate JSON
	if !json.Valid(jsonData) {
		return fmt.Errorf("invalid JSON data")
	}

	f, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("creating output file: %w", err)
	}
	defer f.Close()

	// Write: prefix + JSON + suffix
	if _, err := f.WriteString(templatePrefix); err != nil {
		return fmt.Errorf("writing template prefix: %w", err)
	}
	if _, err := f.Write(jsonData); err != nil {
		return fmt.Errorf("writing JSON data: %w", err)
	}
	if _, err := f.WriteString(templateSuffix); err != nil {
		return fmt.Errorf("writing template suffix: %w", err)
	}

	log.WithField("output", outputPath).Info("HTML report generated")
	return nil
}

// GenerateHTMLFromFile reads a JSON file and generates the HTML report.
func GenerateHTMLFromFile(jsonPath, htmlPath string) error {
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		return fmt.Errorf("reading JSON file: %w", err)
	}
	return GenerateHTML(data, htmlPath)
}
