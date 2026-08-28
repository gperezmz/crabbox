package cli

import "testing"

func TestGCPBootDiskType(t *testing.T) {
	cases := map[string]string{
		"c4-standard-4":    "hyperdisk-balanced",
		"c4a-standard-4":   "hyperdisk-balanced",
		"c4d-standard-8":   "hyperdisk-balanced",
		"n4-standard-8":    "hyperdisk-balanced",
		"m4-megamem-56":    "hyperdisk-balanced",
		"x4-megamem-960":   "hyperdisk-balanced",
		"z3-highmem-88":    "hyperdisk-balanced",
		"C4-STANDARD-4":    "hyperdisk-balanced",
		"c3-standard-8":    "pd-balanced",
		"c3d-standard-8":   "pd-balanced",
		"n2d-standard-8":   "pd-balanced",
		"n2-custom-4-8192": "pd-balanced",
		"custom-4-8192":    "pd-balanced",
		"e2-micro":         "pd-balanced",
		"h3-standard-88":   "pd-balanced",
		"a3-highgpu-8g":    "pd-balanced",
	}
	for in, want := range cases {
		if got := gcpBootDiskType(in); got != want {
			t.Fatalf("%s: got %s want %s", in, got, want)
		}
	}
}
