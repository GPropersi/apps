package platform

import (
	"errors"
	"log"
	"net/http"
)

// RequireAccess wraps a handler so that it only runs for a request carrying a valid Cf-Access-Jwt-Assertion header
// (the cookie is never read). The identity is available through IdentityFrom. Anything else, including a nil
// verifier, answers 401 {"error":"unauthenticated"}; the reason class is logged, never the token or the email.
func RequireAccess(v *AccessVerifier) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if id, ok := devIdentity(); ok {
				next.ServeHTTP(w, r.WithContext(withIdentity(r.Context(), id)))
				return
			}
			if v == nil {
				reject(w, ReasonInvalid)
				return
			}
			id, err := v.Verify(r.Context(), r.Header.Get(accessHeader))
			if err != nil {
				reason := ReasonInvalid
				var ae *AccessError
				if errors.As(err, &ae) {
					reason = ae.Reason
				}
				if reason == ReasonKeysUnavailable && ae != nil && ae.Err != nil {
					reason += " cause=" + fetchCause(ae.Err)
				}
				reject(w, reason)
				return
			}
			next.ServeHTTP(w, r.WithContext(withIdentity(r.Context(), id)))
		})
	}
}

func reject(w http.ResponseWriter, reason string) {
	log.Printf("access: rejected request: reason=%s", reason)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	if _, err := w.Write([]byte(`{"error":"unauthenticated"}`)); err != nil {
		log.Printf("access: writing the 401 body failed: %v", err)
	}
}
