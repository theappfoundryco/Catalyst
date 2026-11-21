package project

import (
	"strconv"
	"strings"
)

// Satisfies says whether version fits an npm-style range, as package.json's engines writes them: ">=20", "^18.17.0",
// "20.x", "~20.1", "18 - 20", "^18 || ^20". ok is false for anything else, so a range Catalyst cannot read is never
// judged either way.
func Satisfies(rng, version string) (match, ok bool) {
	have, n := parseVersion(strings.TrimPrefix(versionNumber.FindString(version), "v"))
	if n < 1 {
		return false, false
	}
	for _, set := range strings.Split(rng, "||") {
		bounds, ok := comparators(strings.TrimSpace(set))
		if !ok {
			return false, false
		}
		fits := true
		for _, b := range bounds {
			fits = fits && b.allows(have)
		}
		if fits {
			return true, true
		}
	}
	return false, true
}

type bound struct {
	op string // ">=" or "<"
	v  [3]int
}

func (b bound) allows(v [3]int) bool {
	c := compare(v, b.v)
	if b.op == ">=" {
		return c >= 0
	}
	return c < 0
}

// comparators turns one space-separated set into lower and upper bounds.
func comparators(set string) ([]bound, bool) {
	if set == "" || set == "*" || set == "x" {
		return nil, true
	}
	if lo, hi, found := strings.Cut(set, " - "); found {
		a, na := parseVersion(strings.TrimSpace(lo))
		b, nb := parseVersion(strings.TrimSpace(hi))
		if na < 1 || nb < 1 {
			return nil, false
		}
		return []bound{{">=", a}, {"<", next(b, nb)}}, true
	}
	var out []bound
	for _, c := range strings.Fields(set) {
		op := ""
		for _, o := range []string{">=", "<=", ">", "<", "=", "^", "~"} {
			if strings.HasPrefix(c, o) {
				op, c = o, strings.TrimSpace(c[len(o):])
				break
			}
		}
		v, n := parseVersion(strings.TrimPrefix(c, "v"))
		if n < 0 {
			return nil, false
		}
		switch {
		case n == 0: // * or x after an operator: anything
		case op == ">=":
			out = append(out, bound{">=", v})
		case op == ">":
			out = append(out, bound{">=", next(v, n)})
		case op == "<":
			out = append(out, bound{"<", v})
		case op == "<=":
			out = append(out, bound{"<", next(v, n)})
		case op == "^":
			upper := [3]int{v[0] + 1, 0, 0}
			if v[0] == 0 && n > 1 {
				upper = [3]int{0, v[1] + 1, 0}
			}
			out = append(out, bound{">=", v}, bound{"<", upper})
		case op == "~":
			if n == 1 {
				out = append(out, bound{">=", v}, bound{"<", [3]int{v[0] + 1, 0, 0}})
			} else {
				out = append(out, bound{">=", v}, bound{"<", [3]int{v[0], v[1] + 1, 0}})
			}
		default: // "20", "20.1", "20.x", "=20.1.0": everything that starts that way
			out = append(out, bound{">=", v}, bound{"<", next(v, n)})
		}
	}
	return out, true
}

// parseVersion reads up to three numbers. n is how many were given (x and * end it), or -1 when it is not a version.
func parseVersion(s string) ([3]int, int) {
	var v [3]int
	if i := strings.IndexAny(s, "-+"); i > 0 {
		s = s[:i] // a pre-release or build tag
	}
	if s == "" || s == "*" || s == "x" || s == "X" {
		return v, 0
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return v, -1
	}
	n := 0
	for i, p := range parts {
		if p == "x" || p == "X" || p == "*" {
			break
		}
		x, err := strconv.Atoi(p)
		if err != nil || x < 0 {
			return v, -1
		}
		v[i] = x
		n++
	}
	return v, n
}

// next is the first version past what a partial one covers: 20 gives 21.0.0, 20.1 gives 20.2.0, 20.1.3 gives 20.1.4.
func next(v [3]int, n int) [3]int {
	switch n {
	case 1:
		return [3]int{v[0] + 1, 0, 0}
	case 2:
		return [3]int{v[0], v[1] + 1, 0}
	}
	return [3]int{v[0], v[1], v[2] + 1}
}

func compare(a, b [3]int) int {
	for i := range a {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}
