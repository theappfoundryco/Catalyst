package host

import "testing"

func TestGatewayFromProc(t *testing.T) {
	route := "Iface\tDestination\tGateway \tFlags\n" +
		"eth0\t00000000\t0500000A\t0003\n" +
		"eth0\t0000000A\t00000000\t0001\n"
	if got := GatewayFromProc(route); got != "10.0.0.5" {
		t.Fatalf("%q", got)
	}
	if got := GatewayFromProc("Iface\tDestination\tGateway\neth0\t0000000A\t00000000\n"); got != "" {
		t.Fatalf("no default route, got %q", got)
	}
}
