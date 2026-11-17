//go:build dev

package app

// viteDevOrigin is the Vite dev server, which proxies /api to this server while the SPA is developed.
const viteDevOrigin = "http://localhost:5173"

// extraOriginAllowed accepts, in the `dev` build only, the plain-HTTP origin of the server itself and the Vite dev
// origin, so SPA POSTs work through the Vite proxy. The production build has no such code path.
func extraOriginAllowed(origin, host string) bool {
	return origin == "http://"+host || origin == viteDevOrigin
}
