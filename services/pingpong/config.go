package main

import (
	"log/slog"
	"strings"

	"github.com/knadh/koanf/providers/env"
	"github.com/knadh/koanf/providers/structs"
	"github.com/knadh/koanf/v2"
)

type Config struct {
	Target  string        `config:"target"`
	TickMS  int           `config:"tick_ms"`
	Service ConfigService `config:"service"`
	Metrics ConfigMetrics `config:"metrics"`
}

type ConfigService struct {
	Port int `config:"port"`
}

type ConfigMetrics struct {
	Path string `config:"path"`
	Port int    `config:"port"`
}

var defaultConfig = Config{
	Target: "http://ping-a:8080",
	TickMS: 100,
	Service: ConfigService{
		Port: 8080,
	},
	Metrics: ConfigMetrics{
		Path: "/-/metrics",
		Port: 9080,
	},
}

func loadConfig() (*Config, error) {
	var k = koanf.New(".")

	if err := k.Load(structs.Provider(defaultConfig, "config"), nil); err != nil {
		slog.Error("error loading config", err)

		return nil, err
	}

	err := k.Load(env.Provider("", "__", func(s string) string {
		return strings.ToLower(s)
	}), nil)
	if err != nil {
		slog.Error("error loading config", err)

		return nil, err
	}

	var cfg *Config
	err = k.UnmarshalWithConf("", &cfg, koanf.UnmarshalConf{Tag: "config"})

	return cfg, err
}
