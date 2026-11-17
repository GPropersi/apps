package app

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

const (
	alice = "alice@example.test"
	bob   = "bob@example.test"
	carol = "carol@example.test"
)

// as sends a JSON request as the given identity to the real router.
func (hn *harness) as(email, method, path, body string) *httptest.ResponseRecorder {
	hn.t.Helper()
	return hn.do(req{method: method, path: path, body: body, json: true, header: map[string]string{"X-Test-Email": email}})
}

func (hn *harness) wantStatus(rec *httptest.ResponseRecorder, status int, code string) {
	hn.t.Helper()
	if rec.Code != status {
		hn.t.Fatalf("status %d, want %d (body %q)", rec.Code, status, rec.Body.String())
	}
	if code != "" {
		var got struct{ Error string }
		decode(hn.t, rec.Body.String(), &got)
		if got.Error != code {
			hn.t.Fatalf("error %q, want %q", got.Error, code)
		}
	}
}

type bday struct {
	ID              int64   `json:"id"`
	Name            string  `json:"name"`
	Month           int     `json:"month"`
	Day             int     `json:"day"`
	Year            *int    `json:"year"`
	IsMine          bool    `json:"is_mine"`
	OwnerEmail      string  `json:"owner_email"`
	ReminderOffsets []int16 `json:"reminder_offsets"`
}

type gift struct {
	ID          int64  `json:"id"`
	Text        string `json:"text"`
	Shared      bool   `json:"shared"`
	AuthorEmail string `json:"author_email"`
	Mine        bool   `json:"mine"`
}

type detail struct {
	Birthday bday      `json:"birthday"`
	Shares   *[]string `json:"shares"`
	Gifts    []gift    `json:"gifts"`
}

func (hn *harness) create(email, body string) bday {
	hn.t.Helper()
	rec := hn.as(email, "POST", "/api/birthdays", body)
	hn.wantStatus(rec, 201, "")
	var b bday
	decode(hn.t, rec.Body.String(), &b)
	return b
}

func (hn *harness) detail(email string, id int64) (detail, int) {
	hn.t.Helper()
	rec := hn.as(email, "GET", fmt.Sprintf("/api/birthdays/%d", id), "")
	var d detail
	if rec.Code == 200 {
		decode(hn.t, rec.Body.String(), &d)
	}
	return d, rec.Code
}

func (hn *harness) share(owner string, id int64, to string) {
	hn.t.Helper()
	hn.wantStatus(hn.as(owner, "POST", fmt.Sprintf("/api/birthdays/%d/shares", id), `{"email":"`+to+`"}`), 201, "")
}

func (hn *harness) addGift(email string, id int64, text string, shared bool) gift {
	hn.t.Helper()
	rec := hn.as(email, "POST", fmt.Sprintf("/api/birthdays/%d/gifts", id), fmt.Sprintf(`{"text":%q,"shared":%t}`, text, shared))
	hn.wantStatus(rec, 201, "")
	var g gift
	decode(hn.t, rec.Body.String(), &g)
	return g
}

func giftTexts(d detail) []string {
	out := []string{}
	for _, g := range d.Gifts {
		out = append(out, g.Text)
	}
	slices.Sort(out)
	return out
}

const sam = `{"name":"Sam Rivera","month":11,"day":21,"year":1990}`

// realWrites lists every write route of the real router (the probe-router tests do not notice a real route that
// drops stateChanging).
var realWrites = []struct{ method, path string }{
	{"PATCH", "/api/settings"}, {"POST", "/api/birthdays"}, {"PUT", "/api/birthdays/1"}, {"DELETE", "/api/birthdays/1"},
	{"PUT", "/api/birthdays/1/reminders"}, {"POST", "/api/birthdays/1/shares"}, {"DELETE", "/api/birthdays/1/shares"},
	{"POST", "/api/birthdays/1/gifts"}, {"PATCH", "/api/gifts/1"}, {"DELETE", "/api/gifts/1"},
	{"POST", "/api/notify/ntfy"}, {"POST", "/api/notify/ntfy/reset"}, {"POST", "/api/notify/destinations"},
	{"POST", "/api/notify/destinations/1/check"}, {"DELETE", "/api/notify/destinations/1"},
}

func TestEveryRealWriteRouteHasTheWriteGuard(t *testing.T) {
	hn := newHarness(t)
	hn.create(alice, sam) // id 1 exists, so a missing guard would otherwise reach a handler that answers 200/204
	big := `{"x":"` + strings.Repeat("p", 4096) + `"}`
	for _, rt := range realWrites {
		cross := hn.do(req{method: rt.method, path: rt.path, json: true, body: `{}`, header: map[string]string{"Origin": "https://evil.example"}})
		if cross.Code != 403 {
			t.Errorf("%s %s cross-site = %d, want 403", rt.method, rt.path, cross.Code)
		}
		fetch := hn.do(req{method: rt.method, path: rt.path, json: true, body: `{}`, header: map[string]string{"Sec-Fetch-Site": "cross-site"}})
		if fetch.Code != 403 {
			t.Errorf("%s %s cross-site fetch = %d, want 403", rt.method, rt.path, fetch.Code)
		}
		if rec := hn.do(req{method: rt.method, path: rt.path, body: `{}`, header: map[string]string{"Content-Type": "text/plain"}}); rec.Code != 415 {
			t.Errorf("%s %s text/plain = %d, want 415", rt.method, rt.path, rec.Code)
		}
		if rec := hn.do(req{method: rt.method, path: rt.path, json: true, body: big}); rec.Code != 413 {
			t.Errorf("%s %s oversized = %d, want 413", rt.method, rt.path, rec.Code)
		}
	}
	if d, code := hn.detail(alice, 1); code != 200 || d.Birthday.Name != "Sam Rivera" {
		t.Fatal("a refused write changed the birthday")
	}
}

func TestEveryNewRouteIs401WithoutIdentity(t *testing.T) {
	hn := newHarness(t)
	routes := append([]struct{ method, path string }{
		{"GET", "/api/me"}, {"GET", "/api/birthdays"}, {"GET", "/api/birthdays/1"}, {"GET", "/api/notify/destinations"}}, realWrites...)
	for _, rt := range routes {
		rec := hn.do(req{method: rt.method, path: rt.path, noAuth: true, json: true, body: `{}`})
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", rt.method, rt.path, rec.Code)
		}
	}
}

func TestMeReturnsSettings(t *testing.T) {
	hn := newHarness(t)
	rec := hn.as("  Sam@Example.com ", "GET", "/api/me", "")
	var got struct {
		Email    string
		Settings struct {
			AutoRemind     bool    `json:"auto_remind"`
			DefaultOffsets []int16 `json:"default_offsets"`
			StartTab       string  `json:"start_tab"`
			ColorScheme    string  `json:"color_scheme"`
			Destinations   int     `json:"destinations"`
		}
	}
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Email != "sam@example.com" || got.Settings.AutoRemind || got.Settings.StartTab != "auto" ||
		got.Settings.ColorScheme != "confetti" || !slices.Equal(got.Settings.DefaultOffsets, []int16{7, 1}) {
		t.Fatalf("me = %d %s", rec.Code, rec.Body.String())
	}
}

func TestMixedCaseIdentityIsLowercasedAndMatchesAShare(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	hn.share(alice, b.ID, "sam@example.com")
	rec := hn.as("Sam@Example.com", "GET", "/api/birthdays", "")
	var got struct{ Birthdays []bday }
	decode(t, rec.Body.String(), &got)
	if len(got.Birthdays) != 1 || got.Birthdays[0].ID != b.ID {
		t.Fatalf("a mixed-case identity did not see the share: %s", rec.Body.String())
	}
	if _, ok := hn.store.users["sam@example.com"]; !ok || len(hn.store.users) != 2 {
		t.Fatalf("users = %v, want the lowercase address", hn.store.users)
	}
	// A share typed in mixed case is stored lowercase too.
	hn.wantStatus(hn.as(alice, "POST", fmt.Sprintf("/api/birthdays/%d/shares", b.ID), `{"email":" SAM@example.com "}`), 200, "")
}

func TestCreateRemindMatrix(t *testing.T) {
	for _, auto := range []bool{false, true} {
		for name, c := range map[string]struct {
			body string
			want []int16
		}{
			"omitted": {sam, map[bool][]int16{false: {}, true: {0, 1}}[auto]},
			"true":    {`{"name":"Sam","month":11,"day":21,"remind":true}`, []int16{0, 1}},
			"false":   {`{"name":"Sam","month":11,"day":21,"remind":false}`, []int16{}},
		} {
			hn := newHarness(t)
			hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", fmt.Sprintf(`{"auto_remind":%t,"default_offsets":[0,1]}`, auto)), 200, "")
			b := hn.create(alice, c.body)
			if !slices.Equal(b.ReminderOffsets, c.want) {
				t.Errorf("auto=%t %s: created offsets %v, want %v", auto, name, b.ReminderOffsets, c.want)
			}
			d, _ := hn.detail(alice, b.ID)
			if !slices.Equal(d.Birthday.ReminderOffsets, c.want) {
				t.Errorf("auto=%t %s: stored offsets %v, want %v", auto, name, d.Birthday.ReminderOffsets, c.want)
			}
		}
	}
}

func TestCreateValidation(t *testing.T) {
	hn := newHarness(t)
	long := strings.Repeat("x", 101)
	for name, c := range map[string]struct{ body, code string }{
		"empty name":      {`{"name":"  ","month":1,"day":1}`, "invalid_name"},
		"long name":       {`{"name":"` + long + `","month":1,"day":1}`, "invalid_name"},
		"nul in name":     {`{"name":"a\u0000b","month":1,"day":1}`, "invalid_name"},
		"not json":        {`nope`, "invalid_name"},
		"month 13":        {`{"name":"A","month":13,"day":1}`, "invalid_date"},
		"month 0":         {`{"name":"A","month":0,"day":1}`, "invalid_date"},
		"huge month":      {`{"name":"A","month":70000,"day":1}`, "invalid_date"},
		"feb 30":          {`{"name":"A","month":2,"day":30}`, "invalid_date"},
		"apr 31":          {`{"name":"A","month":4,"day":31}`, "invalid_date"},
		"feb 29 2023":     {`{"name":"A","month":2,"day":29,"year":2023}`, "invalid_date"},
		"year 1899":       {`{"name":"A","month":1,"day":1,"year":1899}`, "invalid_year"},
		"year 2201":       {`{"name":"A","month":1,"day":1,"year":2201}`, "invalid_year"},
		"huge year":       {`{"name":"A","month":1,"day":1,"year":99999}`, "invalid_year"},
		"fractional year": {`{"name":"A","month":1,"day":1,"year":1990.5}`, "invalid_year"},
		"string month":    {`{"name":"A","month":"x","day":1}`, "invalid_date"},
		"string day":      {`{"name":"A","month":1,"day":"x"}`, "invalid_date"},
	} {
		// The same bodies are rejected the same way by PUT (on a birthday the caller owns).
		for _, rt := range []struct{ method, path string }{{"POST", "/api/birthdays"}, {"PUT", "/api/birthdays/1"}} {
			if rt.method == "PUT" && hn.store.birthdays == nil {
				hn.create(bob, sam) // id 1, owned by bob
			}
			who := alice
			if rt.method == "PUT" {
				who = bob
			}
			rec := hn.as(who, rt.method, rt.path, c.body)
			if rec.Code != 400 {
				t.Errorf("%s %s = %d, want 400 (%s)", name, rt.method, rec.Code, rec.Body.String())
				continue
			}
			var got struct{ Error string }
			decode(t, rec.Body.String(), &got)
			if got.Error != c.code {
				t.Errorf("%s %s error %q, want %q", name, rt.method, got.Error, c.code)
			}
		}
	}
	// Feb 29 with no year and with a leap year, and a trimmed name, are accepted.
	leap := hn.create(alice, `{"name":"  Leap  ","month":2,"day":29}`)
	if b := hn.create(alice, `{"name":"Leap2","month":2,"day":29,"year":2000}`); b.Year == nil || *b.Year != 2000 {
		t.Fatalf("leap year birthday = %+v", b)
	}
	if d, _ := hn.detail(alice, leap.ID); d.Birthday.Name != "Leap" {
		t.Fatalf("name not trimmed: %q", d.Birthday.Name)
	}
}

func TestPutBirthdayAndOwnerOnlyRule(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	hn.share(alice, b.ID, bob)
	path := fmt.Sprintf("/api/birthdays/%d", b.ID)

	hn.wantStatus(hn.as(bob, "PUT", path, `{"name":"X","month":1,"day":1,"year":null}`), 403, "not_owner")
	hn.wantStatus(hn.as(carol, "PUT", path, `{"name":"X","month":1,"day":1,"year":null}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "PUT", path, `{"name":"X","month":2,"day":30,"year":null}`), 400, "invalid_date")

	rec := hn.as(alice, "PUT", path, `{"name":"Samantha","month":12,"day":1,"year":null}`)
	hn.wantStatus(rec, 200, "")
	var got bday
	decode(t, rec.Body.String(), &got)
	if got.Name != "Samantha" || got.Month != 12 || got.Year != nil || !got.IsMine {
		t.Fatalf("put = %+v", got)
	}
	if d, _ := hn.detail(bob, b.ID); d.Birthday.Name != "Samantha" || d.Birthday.IsMine || d.Birthday.OwnerEmail != alice {
		t.Fatalf("the recipient sees %+v", d.Birthday)
	}
}

func TestStrangerGets404OnEveryPerIDRoute(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	g := hn.addGift(alice, b.ID, "socks", true)
	id := fmt.Sprintf("/api/birthdays/%d", b.ID)
	for _, rt := range []struct{ method, path, body string }{
		{"GET", id, ""}, {"PUT", id, `{"name":"X","month":1,"day":1,"year":null}`}, {"DELETE", id, `{}`},
		{"PUT", id + "/reminders", `{"offsets":[1]}`}, {"POST", id + "/shares", `{"email":"x@example.test"}`},
		{"DELETE", id + "/shares", `{"email":"x@example.test"}`}, {"POST", id + "/gifts", `{"text":"hi"}`},
		{"PATCH", fmt.Sprintf("/api/gifts/%d", g.ID), `{"shared":false}`}, {"DELETE", fmt.Sprintf("/api/gifts/%d", g.ID), `{}`},
		{"GET", "/api/birthdays/999", ""}, {"GET", "/api/birthdays/abc", ""}, {"PATCH", "/api/gifts/999", `{"shared":true}`},
	} {
		rec := hn.as(carol, rt.method, rt.path, rt.body)
		if rec.Code != 404 {
			t.Errorf("stranger %s %s = %d, want 404 (%s)", rt.method, rt.path, rec.Code, rec.Body.String())
		}
	}
	if d, code := hn.detail(alice, b.ID); code != 200 || len(d.Gifts) != 1 {
		t.Fatal("a stranger's request changed the birthday or its gifts")
	}
	rec := hn.as(carol, "GET", "/api/birthdays", "")
	var list struct{ Birthdays []bday }
	decode(t, rec.Body.String(), &list)
	if len(list.Birthdays) != 0 {
		t.Fatalf("a stranger lists %d birthdays", len(list.Birthdays))
	}
}

func TestSharesOwnerOnlyAndValidation(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	path := fmt.Sprintf("/api/birthdays/%d/shares", b.ID)
	hn.share(alice, b.ID, bob)
	hn.wantStatus(hn.as(alice, "POST", path, `{"email":"bob@example.test"}`), 200, "") // existing share
	hn.wantStatus(hn.as(alice, "POST", path, `{"email":"ALICE@example.test"}`), 400, "self_share")
	for _, e := range []string{"", "nope", "a@b", "a b@c.d", "@c.d", strings.Repeat("a", 250) + "@b.cd", "a\u0000@b.co", "é@b.co", "a@b.cé"} {
		body, _ := json.Marshal(map[string]string{"email": e}) // real JSON escapes, so "\u0000" reaches the handler
		hn.wantStatus(hn.as(alice, "POST", path, string(body)), 400, "invalid_email")
	}
	// A recipient cannot share or unshare (403), and sees no share list.
	hn.wantStatus(hn.as(bob, "POST", path, `{"email":"c@example.test"}`), 403, "not_owner")
	hn.wantStatus(hn.as(bob, "DELETE", path, `{"email":"bob@example.test"}`), 403, "not_owner")
	if d, _ := hn.detail(bob, b.ID); d.Shares != nil {
		t.Fatalf("a recipient got the share list %v", *d.Shares)
	}
	if d, _ := hn.detail(alice, b.ID); d.Shares == nil || !slices.Equal(*d.Shares, []string{bob}) {
		t.Fatalf("owner share list = %v", d.Shares)
	}
	// Unsharing an absent address is 204 and removes nothing, even the owner's own reminders and gifts.
	hn.wantStatus(hn.as(alice, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[1]}`), 200, "")
	hn.addGift(alice, b.ID, "mine", false)
	hn.wantStatus(hn.as(alice, "DELETE", path, `{"email":"nobody@example.test"}`), 204, "")
	hn.wantStatus(hn.as(alice, "DELETE", path, `{"email":"alice@example.test"}`), 204, "")
	if d, _ := hn.detail(alice, b.ID); len(d.Gifts) != 1 || !slices.Equal(d.Birthday.ReminderOffsets, []int16{1}) {
		t.Fatalf("an absent-share delete removed the owner's data: %+v", d)
	}
}

func TestGiftVisibilityAndUnshareCleanup(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	hn.share(alice, b.ID, bob)
	hn.share(alice, b.ID, carol)
	hn.addGift(alice, b.ID, "a-private", false)
	hn.addGift(alice, b.ID, "a-shared", true)
	hn.wantStatus(hn.as(alice, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[1]}`), 200, "")
	bobPrivate := hn.addGift(bob, b.ID, "b-private", false)
	hn.addGift(bob, b.ID, "b-shared", true)
	hn.wantStatus(hn.as(bob, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[0,7]}`), 200, "")

	for who, want := range map[string][]string{
		alice: {"a-private", "a-shared", "b-shared"},
		bob:   {"a-shared", "b-private", "b-shared"},
		carol: {"a-shared", "b-shared"},
	} {
		d, _ := hn.detail(who, b.ID)
		if got := giftTexts(d); !slices.Equal(got, want) {
			t.Errorf("%s sees %v, want %v", who, got, want)
		}
		for _, g := range d.Gifts {
			if g.Mine != (g.AuthorEmail == who) {
				t.Errorf("%s: gift %q mine=%t author=%s", who, g.Text, g.Mine, g.AuthorEmail)
			}
		}
	}

	// Only the author edits a gift; a recipient who can see a shared idea still gets 404.
	hn.wantStatus(hn.as(alice, "PATCH", fmt.Sprintf("/api/gifts/%d", bobPrivate.ID), `{"shared":true}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/gifts/%d", bobPrivate.ID), `{}`), 404, "not_found")
	rec := hn.as(bob, "PATCH", fmt.Sprintf("/api/gifts/%d", bobPrivate.ID), `{"shared":true}`)
	hn.wantStatus(rec, 200, "")
	if d, _ := hn.detail(carol, b.ID); !slices.Contains(giftTexts(d), "b-private") {
		t.Fatal("a gift marked shared is not visible to a recipient")
	}
	hn.wantStatus(hn.as(bob, "PATCH", fmt.Sprintf("/api/gifts/%d", bobPrivate.ID), `{}`), 400, "invalid_shared")

	// Unshare bob: he loses access, his ideas and reminders go, carol and alice no longer see his shared idea.
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/birthdays/%d/shares", b.ID), `{"email":"bob@example.test"}`), 204, "")
	if _, code := hn.detail(bob, b.ID); code != 404 {
		t.Fatalf("the ex-recipient still reads the birthday (%d)", code)
	}
	hn.wantStatus(hn.as(bob, "PATCH", fmt.Sprintf("/api/gifts/%d", bobPrivate.ID), `{"shared":false}`), 404, "not_found")
	for _, g := range hn.store.gifts {
		if g.AuthorID == hn.store.users[bob].ID {
			t.Fatal("the ex-recipient's gift ideas remain")
		}
	}
	for _, r := range hn.store.reminders {
		if r.UserID == hn.store.users[bob].ID {
			t.Fatal("the ex-recipient's reminders remain")
		}
	}
	if d, _ := hn.detail(carol, b.ID); !slices.Equal(giftTexts(d), []string{"a-shared"}) {
		t.Fatalf("carol sees %v after the unshare", giftTexts(d))
	}
	if d, _ := hn.detail(alice, b.ID); !slices.Equal(giftTexts(d), []string{"a-private", "a-shared"}) || !slices.Equal(d.Birthday.ReminderOffsets, []int16{1}) {
		t.Fatalf("the unshare removed the owner's own data: %+v", d)
	}
	// Re-sharing starts clean.
	hn.share(alice, b.ID, bob)
	if d, _ := hn.detail(bob, b.ID); len(d.Birthday.ReminderOffsets) != 0 || !slices.Equal(giftTexts(d), []string{"a-shared"}) {
		t.Fatalf("a re-shared recipient sees old data: %+v", d)
	}
}

func TestShareCleanupIsOneTransaction(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	hn.share(alice, b.ID, bob)
	hn.addGift(bob, b.ID, "b-idea", true)
	hn.wantStatus(hn.as(bob, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[1]}`), 200, "")

	hn.store.failSharedGifts = errBoom // the last statement of both cleanups fails
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/birthdays/%d/shares", b.ID), `{"email":"bob@example.test"}`), 500, "internal")
	hn.wantStatus(hn.as(bob, "DELETE", fmt.Sprintf("/api/birthdays/%d", b.ID), `{}`), 500, "internal")
	hn.store.failSharedGifts = nil

	if len(hn.store.shares) != 1 || len(hn.store.reminders) != 1 || len(hn.store.gifts) != 1 {
		t.Fatalf("a failed cleanup was partly kept: shares %d reminders %d gifts %d",
			len(hn.store.shares), len(hn.store.reminders), len(hn.store.gifts))
	}
	if _, code := hn.detail(bob, b.ID); code != 200 {
		t.Fatalf("the recipient lost access on a failed unshare (%d)", code)
	}
}

func TestRecipientRemovesBirthdayFromTheirList(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	hn.share(alice, b.ID, bob)
	hn.addGift(bob, b.ID, "b-shared", true)
	hn.addGift(alice, b.ID, "a-private", false)
	hn.wantStatus(hn.as(bob, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[1]}`), 200, "")
	hn.wantStatus(hn.as(alice, "PUT", fmt.Sprintf("/api/birthdays/%d/reminders", b.ID), `{"offsets":[0]}`), 200, "")
	hn.wantStatus(hn.as(bob, "DELETE", fmt.Sprintf("/api/birthdays/%d", b.ID), `{}`), 204, "")
	if _, code := hn.detail(bob, b.ID); code != 404 {
		t.Fatalf("the recipient still sees it (%d)", code)
	}
	d, code := hn.detail(alice, b.ID)
	if code != 200 || !slices.Equal(giftTexts(d), []string{"a-private"}) || len(*d.Shares) != 0 || !slices.Equal(d.Birthday.ReminderOffsets, []int16{0}) {
		t.Fatalf("owner view after the recipient left: %+v (%d)", d, code)
	}
	if len(hn.store.reminders) != 1 {
		t.Fatal("the recipient's reminders remain (or the owner's were removed)")
	}
	// The owner's delete removes it for everyone.
	hn.share(alice, b.ID, carol)
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/birthdays/%d", b.ID), `{}`), 204, "")
	if _, code := hn.detail(carol, b.ID); code != 404 || len(hn.store.shares) != 0 {
		t.Fatal("an owner delete left the birthday or its shares")
	}
}

func TestReminderOffsetsValidatedAndDeduped(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	path := fmt.Sprintf("/api/birthdays/%d/reminders", b.ID)
	for _, body := range []string{`{"offsets":[2]}`, `{"offsets":[-1]}`, `{"offsets":[1,3]}`, `{}`, `{"offsets":null}`, `{"offsets":["a"]}`, `nope`} {
		hn.wantStatus(hn.as(alice, "PUT", path, body), 400, "invalid_offsets")
	}
	rec := hn.as(alice, "PUT", path, `{"offsets":[1,1,7,1]}`)
	hn.wantStatus(rec, 200, "")
	var got struct{ Offsets []int16 }
	decode(t, rec.Body.String(), &got)
	if !slices.Equal(got.Offsets, []int16{1, 7}) {
		t.Fatalf("offsets = %v, want the deduped [1 7]", got.Offsets)
	}
	if !slices.Equal(hn.store.reminders[0].Offsets, []int16{1, 7}) {
		t.Fatalf("stored offsets %v", hn.store.reminders[0].Offsets)
	}
	rec = hn.as(alice, "PUT", path, `{"offsets":[]}`)
	hn.wantStatus(rec, 200, "")
	if !strings.Contains(rec.Body.String(), `"offsets":[]`) || len(hn.store.reminders) != 0 {
		t.Fatalf("turning reminders off: %s, rows %d", rec.Body.String(), len(hn.store.reminders))
	}
}

func TestSettingsPatch(t *testing.T) {
	hn := newHarness(t)
	rec := hn.as(alice, "PATCH", "/api/settings", `{"list_view":"calendar"}`)
	hn.wantStatus(rec, 200, "")
	var s struct {
		AutoRemind     bool    `json:"auto_remind"`
		DefaultOffsets []int16 `json:"default_offsets"`
		StartTab       string  `json:"start_tab"`
		ListView       string  `json:"list_view"`
		CalendarZoom   string  `json:"calendar_zoom"`
		ColorScheme    string  `json:"color_scheme"`
	}
	decode(t, rec.Body.String(), &s)
	if s.ListView != "calendar" || s.StartTab != "auto" || s.CalendarZoom != "month" || s.ColorScheme != "confetti" ||
		s.AutoRemind || !slices.Equal(s.DefaultOffsets, []int16{7, 1}) {
		t.Fatalf("a one-field patch changed other fields: %s", rec.Body.String())
	}
	rec = hn.as(alice, "PATCH", "/api/settings", `{"auto_remind":true,"default_offsets":[0,0,1],"color_scheme":"candle"}`)
	hn.wantStatus(rec, 200, "")
	decode(t, rec.Body.String(), &s)
	if !s.AutoRemind || s.ColorScheme != "candle" || s.ListView != "calendar" || !slices.Equal(s.DefaultOffsets, []int16{0, 1}) {
		t.Fatalf("patch = %s", rec.Body.String())
	}
	for body, code := range map[string]string{
		`{}`: "empty", `{"unknown":1}`: "empty",
		`{"start_tab":"nope"}`: "invalid_setting", `{"list_view":"x"}`: "invalid_setting", `{"calendar_zoom":"day"}`: "invalid_setting",
		`{"color_scheme":"neon"}`: "invalid_setting", `{"auto_remind":"yes"}`: "invalid_setting", `nope`: "invalid_setting",
		`{"default_offsets":[]}`: "invalid_offsets", `{"default_offsets":[3]}`: "invalid_offsets",
		`{"list_view":"name","default_offsets":[2]}`: "invalid_offsets",
	} {
		hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", body), 400, code)
	}
	// A rejected patch changed nothing (the earlier valid one stands).
	rec = hn.as(alice, "GET", "/api/me", "")
	if !strings.Contains(rec.Body.String(), `"list_view":"calendar"`) {
		t.Fatalf("me after rejected patches: %s", rec.Body.String())
	}
}

func TestLimits(t *testing.T) {
	hn := newHarness(t)
	for i := 0; i < 500; i++ {
		hn.create(alice, sam)
	}
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", sam), 409, "too_many_birthdays")
	hn.create(bob, sam) // the cap is per owner

	b := hn.create(bob, sam)
	for i := 0; i < 20; i++ {
		hn.share(bob, b.ID, fmt.Sprintf("p%d@example.test", i))
	}
	hn.wantStatus(hn.as(bob, "POST", fmt.Sprintf("/api/birthdays/%d/shares", b.ID), `{"email":"extra@example.test"}`), 409, "too_many_shares")
	hn.wantStatus(hn.as(bob, "POST", fmt.Sprintf("/api/birthdays/%d/shares", b.ID), `{"email":"p3@example.test"}`), 200, "") // existing is not an extra

	for i := 0; i < 50; i++ {
		hn.addGift(bob, b.ID, fmt.Sprintf("idea %d", i), false)
	}
	hn.wantStatus(hn.as(bob, "POST", fmt.Sprintf("/api/birthdays/%d/gifts", b.ID), `{"text":"one more"}`), 409, "too_many_gifts")
	// The gift cap is per author (and per birthday).
	hn.addGift(bob, hn.create(bob, sam).ID, "elsewhere", false)
	hn.wantStatus(hn.as(bob, "POST", fmt.Sprintf("/api/birthdays/%d/gifts", b.ID), `{"text":"still full"}`), 409, "too_many_gifts")
}

func TestGiftValidation(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	path := fmt.Sprintf("/api/birthdays/%d/gifts", b.ID)
	for _, body := range []string{`{"text":""}`, `{"text":"   "}`, `{"text":"` + strings.Repeat("x", 201) + `"}`, `{"text":"a\u0000b"}`, `{}`, `nope`} {
		hn.wantStatus(hn.as(alice, "POST", path, body), 400, "invalid_text")
	}
	g := hn.addGift(alice, b.ID, strings.Repeat("é", 200), false) // 200 runes (400 bytes) is the limit, not the byte count
	if g.Shared || !g.Mine || g.AuthorEmail != alice {
		t.Fatalf("gift = %+v", g)
	}
	rec := hn.as(alice, "POST", path, `{"text":"  trimmed  "}`)
	hn.wantStatus(rec, 201, "")
	if !strings.Contains(rec.Body.String(), `"text":"trimmed"`) {
		t.Fatalf("gift text not trimmed: %s", rec.Body.String())
	}
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/gifts/%d", g.ID), `{}`), 204, "")
	hn.wantStatus(hn.as(alice, "DELETE", fmt.Sprintf("/api/gifts/%d", g.ID), `{}`), 404, "not_found")
}

func TestListBirthdaysLabelsOwnedAndShared(t *testing.T) {
	hn := newHarness(t)
	own := hn.create(bob, `{"name":"Mine","month":1,"day":2,"remind":true}`)
	theirs := hn.create(alice, sam)
	hn.share(alice, theirs.ID, bob)
	rec := hn.as(bob, "GET", "/api/birthdays", "")
	var list struct{ Birthdays []bday }
	decode(t, rec.Body.String(), &list)
	if len(list.Birthdays) != 2 {
		t.Fatalf("list = %s", rec.Body.String())
	}
	seen := map[int64]bool{}
	defer func() {
		if !seen[own.ID] || !seen[theirs.ID] {
			t.Errorf("rows seen %v, want both %d and %d", seen, own.ID, theirs.ID)
		}
	}()
	for _, b := range list.Birthdays {
		seen[b.ID] = true
		switch b.ID {
		case own.ID:
			if !b.IsMine || b.OwnerEmail != bob || !slices.Equal(b.ReminderOffsets, []int16{7, 1}) {
				t.Errorf("owned row %+v", b)
			}
		case theirs.ID:
			if b.IsMine || b.OwnerEmail != alice || b.ReminderOffsets == nil || len(b.ReminderOffsets) != 0 {
				t.Errorf("shared row %+v", b)
			}
		}
	}
	if !strings.Contains(rec.Body.String(), `"reminder_offsets":[]`) {
		t.Fatalf("reminder_offsets must be [] not null: %s", rec.Body.String())
	}
}
