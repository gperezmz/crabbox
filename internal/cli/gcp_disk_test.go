package cli

import "testing"

func TestGCPBootDiskType(t *testing.T) {
	cases := map[string]string{"c4-standard-4": "hyperdisk-balanced", "n4-standard-8": "hyperdisk-balanced", "c3-standard-8": "pd-balanced", "n2d-standard-8": "pd-balanced", "e2-micro": "pd-balanced"}
	for in, want := range cases {
		if got := gcpBootDiskType(in); got != want {
			t.Fatalf("%s: got %s want %s", in, got, want)
		}
	}
}
