package platform

import (
	"testing"
	"time"
)

func TestScheduleZoneIsPacificWithDST(t *testing.T) {
	loc, err := ScheduleZone()
	if err != nil {
		t.Fatal(err)
	}
	if loc.String() != "America/Los_Angeles" {
		t.Fatalf("zone = %s", loc)
	}
	// Daylight time is UTC-7 in midsummer and standard time UTC-8 in midwinter.
	_, summer := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC).In(loc).Zone()
	_, winter := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC).In(loc).Zone()
	if summer != -7*3600 || winter != -8*3600 {
		t.Fatalf("offsets summer %d winter %d, want -25200 and -28800", summer, winter)
	}
	// 05:00 UTC on Nov 17 is still Nov 16 in Los Angeles: the day a daily job must pick.
	if got := time.Date(2026, 11, 17, 5, 0, 0, 0, time.UTC).In(loc).Format("2006-01-02"); got != "2026-11-16" {
		t.Fatalf("date = %s, want 2026-11-16", got)
	}
}
