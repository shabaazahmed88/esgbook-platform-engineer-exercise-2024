package main

import (
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"sync"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func initMetrics() {
	// TASK: What metrics would be useful for this type of service?
}

func startMetricsServer(cfg ConfigMetrics, wg *sync.WaitGroup) {
	defer wg.Done()

	port := fmt.Sprintf(":%v", cfg.Port)
	slog.With(slog.Any("port", port)).Info("metrics server started")
	http.Handle(cfg.Path, promhttp.Handler())
	err := http.ListenAndServe(port, nil)
	if err != nil {
		log.Printf("error with listen and serve %v", err.Error())
	}
}
