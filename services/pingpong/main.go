package main

import (
	"bytes"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"
)

func main() {
	initLogging()

	cfg, err := loadConfig()
	if err != nil {
		slog.Error("error loading config", err)

		return
	}

	initMetrics()

	var wg sync.WaitGroup
	wg.Add(3)
	go startPinging(cfg, &wg)
	go startAppServer(cfg, &wg)
	go startMetricsServer(cfg.Metrics, &wg)

	wg.Wait()
}

func initLogging() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)
}

func startPinging(cfg *Config, wg *sync.WaitGroup) {
	defer wg.Done()

	for range time.Tick(time.Duration(cfg.TickMS) * time.Millisecond) {
		slog.Info("pinging", slog.Any("target", cfg.Target))
		resp, err := http.Get(cfg.Target)
		if err != nil {
			slog.Error("error pinging", slog.Any("err", err))

			continue
		}

		if resp.StatusCode != http.StatusOK {
			slog.Error("error pinging", slog.Any("status", resp.StatusCode))

			continue
		}

		buf := new(bytes.Buffer)
		_, err = buf.ReadFrom(resp.Body)
		if err != nil {
			slog.Error("error reading response body", slog.Any("err", err))

			continue
		}

		slog.Info("ping-pong success", slog.Any("status", resp.StatusCode), slog.Any("resp", buf.String()))
	}
}

func startAppServer(cfg *Config, wg *sync.WaitGroup) {
	defer wg.Done()

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", func(writer http.ResponseWriter, request *http.Request) {
		writer.Write([]byte("pong"))
	})

	slog.With(slog.Any("port", cfg.Service.Port)).Info("app server started")
	err := http.ListenAndServe(fmt.Sprintf(":%v", cfg.Service.Port), mux)
	if err != nil {
		slog.Error("error with listen and serve", err)
	}
}
