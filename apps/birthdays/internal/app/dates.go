package app

import (
	"fmt"
	"time"
)

// Date is a civil (calendar) date with no time zone. Callers build "today" in the schedule zone first, so these rules
// never depend on the host clock or zone.
type Date struct {
	Year  int
	Month int
	Day   int
}

// String is the ISO form, YYYY-MM-DD.
func (d Date) String() string { return fmt.Sprintf("%04d-%02d-%02d", d.Year, d.Month, d.Day) }

// ParseDate reads YYYY-MM-DD and rejects anything that is not a real calendar date.
func ParseDate(s string) (Date, error) {
	t, err := time.Parse(time.DateOnly, s)
	if err != nil {
		return Date{}, fmt.Errorf("date %q: %w", s, err)
	}
	return Date{Year: t.Year(), Month: int(t.Month()), Day: t.Day()}, nil
}

// DateOf is the civil date of t in t's own location.
func DateOf(t time.Time) Date { return Date{Year: t.Year(), Month: int(t.Month()), Day: t.Day()} }

// days is a day number that is monotonic across the calendar (UTC midnight, so no DST shifts).
func (d Date) days() int64 {
	return time.Date(d.Year, time.Month(d.Month), d.Day, 0, 0, 0, 0, time.UTC).Unix() / 86400
}

// Before reports whether d is earlier than o.
func (d Date) Before(o Date) bool { return d.days() < o.days() }

// AddDays is d moved by n days (negative goes back).
func (d Date) AddDays(n int) Date {
	return DateOf(time.Date(d.Year, time.Month(d.Month), d.Day+n, 0, 0, 0, 0, time.UTC))
}

func isLeap(year int) bool { return year%4 == 0 && (year%100 != 0 || year%400 == 0) }

func daysInMonth(month, year int) int {
	switch month {
	case 2:
		if isLeap(year) {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	default:
		return 31
	}
}

// ValidDate reports whether (month, day, year) is storable: month 1-12, a day that exists in the month with Feb 29
// allowed, a year (when present) in 1900-2200, and Feb 29 with a year only in a leap year. It mirrors the table CHECKs.
func ValidDate(month, day int16, year *int16) bool {
	if month < 1 || month > 12 {
		return false
	}
	maxDay := daysInMonth(int(month), 2000) // 2000 is a leap year: Feb 29 is allowed when no year is given
	if day < 1 || int(day) > maxDay {
		return false
	}
	if year == nil {
		return true
	}
	if *year < 1900 || *year > 2200 {
		return false
	}
	return !(month == 2 && day == 29) || isLeap(int(*year))
}

// occurrenceIn is the birthday's date in the given year; Feb 29 falls on Feb 28 in a common year.
func occurrenceIn(month, day int16, year int) Date {
	if month == 2 && day == 29 && !isLeap(year) {
		return Date{Year: year, Month: 2, Day: 28}
	}
	return Date{Year: year, Month: int(month), Day: int(day)}
}

// Occurrence is the first date on or after from on which the birthday (month, day) is celebrated. A Feb 29 birthday is
// celebrated on Feb 28 in common years. month and day must already satisfy ValidDate.
func Occurrence(month, day int16, from Date) Date {
	occ := occurrenceIn(month, day, from.Year)
	if occ.Before(from) {
		return occurrenceIn(month, day, from.Year+1)
	}
	return occ
}

// DaysUntil is the number of whole days from from to to (0 when equal, negative when to is earlier).
func DaysUntil(from, to Date) int { return int(to.days() - from.days()) }

// Turning is the age the person reaches on occ, or nil when the birth year is unknown or the age would be below 1
// (an occurrence in or before the birth year is not a birthday yet).
func Turning(year *int16, occ Date) *int {
	if year == nil {
		return nil
	}
	age := occ.Year - int(*year)
	if age < 1 {
		return nil
	}
	return &age
}
