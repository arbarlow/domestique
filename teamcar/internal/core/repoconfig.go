package core

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// repoConfig is the subset of domestique.toml Team Car uses so far.
type repoConfig struct {
	Setup struct {
		Script string   `toml:"script"`
		Copy   []string `toml:"copy"`
	} `toml:"setup"`
	Archive struct {
		Script string `toml:"script"`
	} `toml:"archive"`
}

func loadRepoConfig(dir string) (repoConfig, error) {
	var c repoConfig
	data, err := os.ReadFile(filepath.Join(dir, "domestique.toml"))
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	_, err = toml.Decode(string(data), &c)
	return c, err
}
