package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/aszmuda/rhoai-model-usage-observability/external-metering/simulator/internal/simulator"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	if err := run(logger); err != nil {
		logger.Error("external metering simulator stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	addr, err := listenAddress()
	if err != nil {
		return err
	}
	server := &http.Server{
		Addr:              addr,
		Handler:           simulator.New(os.Stdout, logger),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	result := make(chan error, 1)
	go func() { result <- server.ListenAndServe() }()
	logger.Info("external metering simulator started", "address", addr)
	select {
	case err := <-result:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		logger.Info("external metering simulator shutting down")
		return server.Shutdown(shutdown)
	}
}

// LISTEN_ADDR retains the previous Go service's override; PORT matches the
// existing external-metering simulator's deployment configuration.
func listenAddress() (string, error) {
	if addr := os.Getenv("LISTEN_ADDR"); addr != "" {
		return addr, nil
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	value, err := strconv.Atoi(port)
	if err != nil || value < 1 || value > 65535 {
		return "", fmt.Errorf("PORT must be an integer between 1 and 65535")
	}
	return ":" + strconv.Itoa(value), nil
}
