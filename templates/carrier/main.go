// Carrier binary for the __PRODUCT__ product stack.
//
// This is intentionally thin: it wraps the engine's shared app.Run lifecycle
// (Build + Start + EmitSystemStartup + WaitForSignal + Stop) and blank-imports
// this module's integrations package, whose init() side-effects mount the
// product pack into the carrier binary's engine:
//
//   - the __PRODUCT__ DSL tree (dsl/__PRODUCT__/embed.go ->
//     dsl.RegisterTree("__PRODUCT__", ...))
//   - the product IntegrationProvider (integrations/__PRODUCT__/plugin.go ->
//     memql.RegisterPluginForContract) and its event routing rules
//     (node.RegisterRoutingRule).
//
// Every line of meaningful service behaviour lives in the memql engine repo so
// changes track there; a product carrier only adds its pack.
//
// Default build target: the engine's bff binary (BUILD_TAGS=bff in the
// Dockerfile), so the k8s bff Deployment can run this image with the same
// MEMQL_NODE_TYPE / env / ports as the engine's own bff.
package main

import (
	"log/slog"
	"os"
	"strings"

	"github.com/znasllc-io/memql/app"
	"github.com/znasllc-io/memql/component/genesis"
	"github.com/znasllc-io/memql/component/server"
	"github.com/znasllc-io/memql/component/service"
	"github.com/znasllc-io/memql/core/common"
	"github.com/znasllc-io/memql/core/logger"

	// Blank import: pulls in the product integrations package, which
	// transitively blank-imports the DSL package. The chain of init()
	// side-effects mounts the __PRODUCT__ DSL tree + the Go plugin + routing
	// rules into this carrier binary's engine.
	_ "github.com/__PRODUCT_ORG__/__PRODUCT__-carrier/integrations/__PRODUCT__"
)

// versionFilePath mirrors the engine's convention -- the binary reads a sibling
// VERSION file when the VERSION env var isn't set. The docker build copies a
// VERSION file into the carrier's working directory so this resolves at runtime.
const versionFilePath = "VERSION"

func main() {
	serviceLogger := mustCreateServiceLogger()

	// Decrypt + apply the genesis envelope in-process at boot (cloud model),
	// mirroring the engine's main. Fail closed: a misconfigured auto-load is
	// fatal. No-op when MEMQL_GENESIS_AUTOLOAD is unset, so local dev's
	// env_file path is untouched.
	if res, err := genesis.AutoloadFromEnv(); err != nil {
		serviceLogger.Error("genesis envelope auto-load failed", "err", err)
		os.Exit(1)
	} else if res.Enabled {
		serviceLogger.Info("genesis envelope auto-loaded",
			"source", res.Source,
			"applied", len(res.Applied),
			"skipped", len(res.Skipped))
	}

	// Layer repo-root /.env on top of host-shell + envelope values, mirroring
	// the engine's main so dev knobs work identically.
	if overridden, err := genesis.ApplyLocalOverride("."); err != nil {
		serviceLogger.Warn("local .env override failed -- continuing with envelope values", "err", err)
	} else if len(overridden) > 0 {
		serviceLogger.Info("local .env override applied", "vars", overridden)
	}

	// Bridge any legacy env var names the host shell / .env / sealed envelope
	// still carries onto their MEMQL_ names (set-if-absent, new wins). MUST
	// mirror the engine's main so a legacy value from any layer is honored
	// everywhere identically -- otherwise carrier nodes fail-fast on required
	// MEMQL_ vars while engine nodes boot fine.
	genesis.ApplyLegacyEnvAliases(serviceLogger)

	app.Run(app.RunConfig{
		Logger:  serviceLogger,
		Version: resolveServiceVersion(),
		Overrides: app.Overrides{
			FatalWithLogger:   logger.FatalWithLogger,
			LoadServiceEnvOpt: service.LoadDefaultServiceEnvOptions,
		},
		SetHealth: func(deps []common.Dependency) {
			server.SetHealthDependencies(deps)
		},
	})
}

// resolveServiceVersion mirrors the engine's helper: env var wins; falls back
// to a sibling VERSION file; finally returns "dev".
func resolveServiceVersion() string {
	if value := strings.TrimSpace(os.Getenv("VERSION")); value != "" {
		return value
	}
	if data, err := os.ReadFile(versionFilePath); err == nil {
		if trimmed := strings.TrimSpace(string(data)); trimmed != "" {
			return trimmed
		}
	}
	return "dev"
}

// mustCreateServiceLogger mirrors the engine's helper. Writes to os.Stdout so
// container log capture sees startup INFO the same way it does for the engine's
// bff binary.
func mustCreateServiceLogger() *slog.Logger {
	serviceOpts, err := service.LoadDefaultServiceEnvOptions()
	if err != nil {
		logger.Fatal("failed to load service environment options", "error", err)
	}
	level := slog.LevelInfo
	if strings.TrimSpace(serviceOpts.LoggerLevel) != "" {
		var parsedLevel slog.Level
		if err := parsedLevel.UnmarshalText([]byte(strings.ToLower(serviceOpts.LoggerLevel))); err != nil {
			logger.Fatal("invalid service log level", "error", err)
		}
		level = parsedLevel
	}
	return logger.New(common.ComponentName(serviceOpts.Name), os.Stdout, level)
}
