package project

import "testing"

func TestSatisfies(t *testing.T) {
	for _, c := range []struct {
		rng, have   string
		match, read bool
	}{
		{">=20", "v20.11.1", true, true}, {">=20", "v18.19.0", false, true},
		{"^18.17.0", "v18.20.4", true, true}, {"^18.17.0", "v18.16.0", false, true}, {"^18.17.0", "v19.0.0", false, true},
		{"20.x", "v20.0.0", true, true}, {"20.x", "v21.1.0", false, true}, {"20", "v20.9.0", true, true},
		{"~20.1", "v20.1.9", true, true}, {"~20.1", "v20.2.0", false, true},
		{">=18 <21", "v20.5.0", true, true}, {">=18 <21", "v22.0.0", false, true},
		{"18 - 20", "v20.11.0", true, true}, {"18 - 20", "v21.0.0", false, true},
		{"^18 || ^20", "v20.1.0", true, true}, {"^18 || ^20", "v19.1.0", false, true},
		{">20", "v20.9.0", false, true}, {"<=20", "v20.9.0", true, true}, {"*", "v8.0.0", true, true},
		{"^0.2.1", "v0.2.9", true, true}, {"^0.2.1", "v0.3.0", false, true},
		{"lts/*", "v20.0.0", false, false}, {">=20", "not a version", false, false}, {"node >= 20", "v20.0.0", false, false},
	} {
		if m, ok := Satisfies(c.rng, c.have); m != c.match || ok != c.read {
			t.Errorf("%q with %s: got %v %v", c.rng, c.have, m, ok)
		}
	}
}
