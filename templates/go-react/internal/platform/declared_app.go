package platform

import (
	"fmt"

	"gopkg.in/yaml.v3"
)

// App is the part of app.yaml the platform helpers read: the app's name and whether it opted in to notifications.
type App struct {
	Name   string
	Notifs bool
}

// DeclaredApp parses the app's embedded app.yaml. A missing `notifs` key is false. An unparsable file is an error;
// callers fail closed (notifs false) and log it.
func DeclaredApp(appYAML []byte) (App, error) {
	var doc struct {
		Name   string `yaml:"name"`
		Notifs bool   `yaml:"notifs"`
	}
	if err := yaml.Unmarshal(appYAML, &doc); err != nil {
		return App{}, fmt.Errorf("platform: app.yaml is not valid: %w", err)
	}
	return App{Name: doc.Name, Notifs: doc.Notifs}, nil
}
