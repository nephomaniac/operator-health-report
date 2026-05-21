package logging

import (
	"io"
	"os"

	"github.com/sirupsen/logrus"
)

// Logger wraps logrus with structured JSON logging and configurable levels
var Log *logrus.Logger

func init() {
	Log = logrus.New()
	Log.SetOutput(os.Stderr)
	Log.SetFormatter(&logrus.JSONFormatter{
		TimestampFormat: "2006-01-02T15:04:05Z",
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

// SetTextFormat switches to human-readable text format (for terminal use)
func SetTextFormat() {
	Log.SetFormatter(&logrus.TextFormatter{
		FullTimestamp:   true,
		TimestampFormat: "15:04:05",
	})
}

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
