package main

import (
	"fmt"
	"os"

	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: yamlcheck <config.yaml>")
		return
	}
	b, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Println("READERR:", err)
		return
	}
	cfg, err := config.Parse(b)
	if err != nil {
		fmt.Println("PARSEERR:", err)
		return
	}
	fmt.Println("PARSE OK")
	fmt.Println("mode:", cfg.General.Mode)
	fmt.Println("proxies:", len(cfg.Proxies))
	for _, p := range cfg.Proxies {
		fmt.Println("  proxy:", p.Name(), p.Type().String(), p.Addr())
	}
	fmt.Println("tun.enable:", cfg.General.Tun.Enable, "fd:", cfg.General.Tun.FileDescriptor, "stack:", cfg.General.Tun.Stack)
	fmt.Println("rules:", len(cfg.Rules))
}
