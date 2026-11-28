package platform

import "testing"

func TestDeclaredApp(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want App
		bad  bool
	}{
		{"true", "name: demo\nnotifs: true\n", App{Name: "demo", Notifs: true}, false},
		{"false", "name: demo\nnotifs: false\n", App{Name: "demo"}, false},
		{"missing", "name: demo\n", App{Name: "demo"}, false},
		{"empty", "", App{}, false},
		{"garbage", "name: [", App{}, true},
		{"wrong type", "name: demo\nnotifs: [a]\n", App{}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := DeclaredApp([]byte(c.in))
			if (err != nil) != c.bad {
				t.Fatalf("err = %v, want error %v", err, c.bad)
			}
			if got != c.want {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
		})
	}
}
