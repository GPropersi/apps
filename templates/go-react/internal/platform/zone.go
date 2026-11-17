package platform

import (
	"fmt"
	"time"
)

// ScheduleZoneName is the platform's schedule time zone: the BACKUP_WINDOW_TZ value, and the zone every `schedule:`
// in app.yaml runs in. An app that decides "today" in a daily job must use this zone, not the container's UTC.
const ScheduleZoneName = "America/Los_Angeles"

// ScheduleZone returns the schedule time zone. It needs zoneinfo, which the final image gets from the `time/tzdata`
// import in cmd/server (distroless/static ships its own, but the binary must not depend on that). Run fails startup
// when this returns an error.
func ScheduleZone() (*time.Location, error) {
	loc, err := time.LoadLocation(ScheduleZoneName)
	if err != nil {
		return nil, fmt.Errorf("platform: schedule zone %s: %w", ScheduleZoneName, err)
	}
	return loc, nil
}
