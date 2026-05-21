package logging

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/sirupsen/logrus"
)

// Log is the global logger instance
var Log *logrus.Logger

// debugFile holds the file handle for debug log output
var debugFile *os.File

func init() {
	Log = logrus.New()
	Log.SetOutput(os.Stderr)
	Log.SetFormatter(&logrus.TextFormatter{
		FullTimestamp:   true,
		TimestampFormat: "15:04:05",
	})
	Log.SetLevel(logrus.InfoLevel)
}

// SetLevel sets the logging level from a string (debug, info, warn, error)
func SetLevel(level string) {
	switch level {
	case "debug", "DEBUG":
		Log.SetLevel(logrus.DebugLevel)
	case "info", "INFO":
		Log.SetLevel(logrus.InfoLevel)
	case "warn", "WARN", "warning", "WARNING":
		Log.SetLevel(logrus.WarnLevel)
	case "error", "ERROR":
		Log.SetLevel(logrus.ErrorLevel)
	default:
		Log.SetLevel(logrus.InfoLevel)
	}
}

// SetOutput sets the log output destination
func SetOutput(w io.Writer) {
	Log.SetOutput(w)
}

// SetJSONFormat switches to JSON format (for machine parsing)
func SetJSONFormat() {
	Log.SetFormatter(&logrus.JSONFormatter{
		TimestampFormat: "2006-01-02T15:04:05Z",
	})
}

// EnableDebugFile opens a file for debug-level logging.
// Terminal output stays at the configured level (e.g., info).
// The debug file gets ALL log entries (debug and above) in JSON format.
// Returns the file path for reference.
func EnableDebugFile(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", fmt.Errorf("failed to create log directory: %w", err)
	}

	filename := fmt.Sprintf("healthcheck_%s.log", time.Now().Format("20060102_150405"))
	path := filepath.Join(dir, filename)

	f, err := os.Create(path)
	if err != nil {
		return "", fmt.Errorf("failed to create debug log file: %w", err)
	}
	debugFile = f

	// Create a hook that writes debug+ to the file in JSON format
	Log.AddHook(&fileHook{
		file: f,
		formatter: &logrus.JSONFormatter{
			TimestampFormat: "2006-01-02T15:04:05.000Z",
		},
		levels: logrus.AllLevels,
	})

	Log.Info("Debug log file opened: " + path)
	return path, nil
}

// CloseDebugFile closes the debug log file
func CloseDebugFile() {
	if debugFile != nil {
		debugFile.Close()
		debugFile = nil
	}
}

// fileHook writes log entries to a file at all levels, regardless of the
// terminal log level. This lets you keep terminal output at info while
// capturing debug-level detail in the file for post-run review.
type fileHook struct {
	file      *os.File
	formatter logrus.Formatter
	levels    []logrus.Level
}

func (h *fileHook) Levels() []logrus.Level {
	return h.levels
}

func (h *fileHook) Fire(entry *logrus.Entry) error {
	line, err := h.formatter.Format(entry)
	if err != nil {
		return err
	}
	_, err = h.file.Write(line)
	return err
}

// Convenience functions for structured logging with context

// WithCheck returns a logger entry with the check context
func WithCheck(check string) *logrus.Entry {
	return Log.WithField("check", check)
}

// WithCluster returns a logger entry with cluster context
func WithCluster(clusterID, clusterName string) *logrus.Entry {
	return Log.WithFields(logrus.Fields{
		"cluster_id":   clusterID,
		"cluster_name": clusterName,
	})
}

// WithOperator returns a logger entry with operator context
func WithOperator(operator string) *logrus.Entry {
	return Log.WithField("operator", operator)
}

// WithCommand returns a logger entry with the CLI command for reproduction
func WithCommand(cmd string) *logrus.Entry {
	return Log.WithField("command", cmd)
}
