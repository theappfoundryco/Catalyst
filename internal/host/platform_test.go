package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/run"
)

// Every file in testdata/os-release was read from the official image of that distribution.
func TestOSReleaseFromRealImages(t *testing.T) {
	want := map[string]struct{ id, family, version string }{
		"debian_11":                            {"debian", "debian", "11"},
		"debian_12":                            {"debian", "debian", "12"},
		"debian_13":                            {"debian", "debian", "13"},
		"ubuntu_20.04":                         {"ubuntu", "debian", "20.04"},
		"ubuntu_22.04":                         {"ubuntu", "debian", "22.04"},
		"ubuntu_24.04":                         {"ubuntu", "debian", "24.04"},
		"fedora_40":                            {"fedora", "fedora", "40"},
		"fedora_41":                            {"fedora", "fedora", "41"},
		"rockylinux_9":                         {"rocky", "rhel", ""},
		"almalinux_8":                          {"almalinux", "rhel", ""},
		"amazonlinux_2023":                     {"amzn", "rhel", "2023"},
		"opensuse_leap_15.6":                   {"opensuse-leap", "suse", "15.6"},
		"opensuse_tumbleweed":                  {"opensuse-tumbleweed", "suse", ""},
		"archlinux_latest":                     {"arch", "arch", ""},
		"alpine_3.18":                          {"alpine", "alpine", ""},
		"alpine_3.20":                          {"alpine", "alpine", ""},
		"ghcr.io_void-linux_void-glibc_latest": {"void", "void", ""},
		"jrei_systemd-debian_12":               {"debian", "debian", "12"},
		"golang_1.27":                          {"debian", "debian", ""},
	}
	files, _ := filepath.Glob("testdata/os-release/*.txt")
	if len(files) < 12 {
		t.Fatalf("only %d recorded files", len(files))
	}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".txt")
		b, _ := os.ReadFile(f)
		fields := ParseOSReleaseFields(string(b))
		w, ok := want[name]
		if !ok {
			t.Errorf("%s: no expectation", name)
			continue
		}
		if w.id == "" {
			continue
		}
		if fields["ID"] != w.id {
			t.Errorf("%s: ID %q", name, fields["ID"])
		}
		if got := FamilyOf(fields["ID"], strings.Fields(fields["ID_LIKE"])); got != w.family {
			t.Errorf("%s: family %q, want %q", name, got, w.family)
		}
		if w.version != "" && !strings.HasPrefix(fields["VERSION_ID"], w.version) {
			t.Errorf("%s: VERSION_ID %q", name, fields["VERSION_ID"])
		}
		if fields["PRETTY_NAME"] == "" || strings.ContainsAny(fields["PRETTY_NAME"], `"\`) {
			t.Errorf("%s: PRETTY_NAME %q", name, fields["PRETTY_NAME"])
		}
	}
}

func TestOSReleaseQuotingAndEscapes(t *testing.T) {
	f := ParseOSReleaseFields("# comment\nNAME='Single'\nPRETTY_NAME=\"Say \\\"hi\\\" \\\\ there\"\nID=plain\nbad line\nID_LIKE=\"rhel centos fedora\"\n")
	if f["NAME"] != "Single" || f["PRETTY_NAME"] != `Say "hi" \ there` || f["ID"] != "plain" || f["ID_LIKE"] != "rhel centos fedora" {
		t.Fatalf("%q", f)
	}
	if _, ok := f["bad line"]; ok {
		t.Fatal("kept a malformed line")
	}
}

func TestFamilyUsesIDBeforeIDLikeAndNeverGuesses(t *testing.T) {
	cases := []struct {
		id   string
		like []string
		want string
	}{
		{"linuxmint", []string{"ubuntu", "debian"}, "debian"},
		{"centos", []string{"rhel", "fedora"}, "rhel"},
		{"fedora", nil, "fedora"},
		{"bazzite", []string{"fedora"}, "fedora"},
		{"pika", []string{"ubuntu"}, "debian"},
		{"somethingnew", nil, "unknown"},
		{"", nil, "unknown"},
	}
	for _, c := range cases {
		if got := FamilyOf(c.id, c.like); got != c.want {
			t.Errorf("%s %v: %s", c.id, c.like, got)
		}
	}
}

func TestLibcAndInit(t *testing.T) {
	if LibcFrom(true, "") != "musl" || LibcFrom(false, "glibc 2.36\n") != "glibc 2.36" || LibcFrom(false, "") != "" || LibcFrom(false, "weird") != "" {
		t.Fatal("libc")
	}
	p := Platform{Libc: "glibc 2.36"}
	if !p.GlibcAtLeast(2, 13) || p.GlibcAtLeast(2, 39) || !p.GlibcAtLeast(2, 36) || (Platform{Libc: "musl"}).GlibcAtLeast(1, 0) {
		t.Fatal("glibc compare")
	}
	for comm, want := range map[string]string{"systemd\n": "systemd", "runit": "runit", "sh": "", "sleep": "", "s6-svscan": "s6"} {
		if got := InitFrom(comm, false); got != want {
			t.Errorf("%q: %q", comm, got)
		}
	}
	if InitFrom("init", true) != "openrc" || InitFrom("init", false) != "" {
		t.Fatal("openrc")
	}
}

func TestContainerSigns(t *testing.T) {
	cases := []struct {
		s    ContainerSigns
		want string
	}{
		{ContainerSigns{}, ""},
		{ContainerSigns{Docker: true}, "docker"},
		{ContainerSigns{Podman: true, Docker: true}, "podman"},
		{ContainerSigns{Systemd: "lxc\n"}, "lxc"},
		{ContainerSigns{Environ: "PATH=/bin\x00container=oci\x00"}, "oci"},
		{ContainerSigns{Cgroup: "0::/system.slice/docker-abc.scope\n"}, "docker"},
		{ContainerSigns{Cgroup: "0::/init.scope\n"}, ""},
		{ContainerSigns{Kernel: "6.6-microsoft-standard-WSL2\n"}, "wsl"},
	}
	for _, c := range cases {
		if got := ContainerFrom(c.s); got != c.want {
			t.Errorf("%+v: %q", c.s, got)
		}
	}
	if (Platform{Container: "wsl"}).InContainer() || !(Platform{Container: "docker"}).InContainer() {
		t.Fatal("WSL is not a container here")
	}
}

// fakeRoot builds a machine's files in a folder, so ReadPlatform runs end to end.
func fakeRoot(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for p, text := range files {
		full := filepath.Join(root, p)
		os.MkdirAll(filepath.Dir(full), 0o755)
		os.WriteFile(full, []byte(text), 0o644)
	}
	return root
}

func linuxEnv(tools ...string) *Env {
	e := ForTest("/home/alex", "linux", &run.Fake{Replies: map[string]run.Result{"uname -r": {Stdout: "6.8.0-49-generic\n"}, "getconf GNU_LIBC_VERSION": {Stdout: "glibc 2.36\n"}}})
	e.Arch = "amd64"
	e.Look = func(n string) (string, error) {
		if slices.Contains(tools, n) {
			return "/usr/bin/" + n, nil
		}
		return "", exec.ErrNotFound
	}
	return e
}

func TestReadPlatformDebianInDocker(t *testing.T) {
	b, _ := os.ReadFile("testdata/os-release/debian_12.txt")
	root := fakeRoot(t, map[string]string{"etc/os-release": string(b), ".dockerenv": "", "proc/1/comm": "bash\n", "var/lib/dpkg/status": "x"})
	p := ReadPlatform(root, linuxEnv("apt-get", "dnf"))
	if p.Family != "debian" || p.Container != "docker" || !p.InContainer() || p.Init != "" || p.Libc != "glibc 2.36" || p.Kernel != "6.8.0-49-generic" {
		t.Fatalf("%+v", p)
	}
	if !slices.Equal(p.Managers, []string{"apt"}) { // dnf is on PATH but has no database here
		t.Fatalf("%v", p.Managers)
	}
	cmd, _ := p.Install(SmartPkgs)
	if strings.Join(cmd, " ") != "apt-get install -y smartmontools" {
		t.Fatalf("%v", cmd)
	}
	if !strings.Contains(p.Describe(), "in a docker container") || !strings.Contains(p.Describe(), "x86_64") {
		t.Fatal(p.Describe())
	}
}

func TestReadPlatformAlpineSaysWhyHomebrewCannotWork(t *testing.T) {
	b, _ := os.ReadFile("testdata/os-release/alpine_3.18.txt")
	root := fakeRoot(t, map[string]string{"etc/os-release": string(b), "lib/ld-musl-x86_64.so.1": "", "lib/apk/db/installed": "", "sbin/openrc": "", "proc/1/comm": "init"})
	p := ReadPlatform(root, linuxEnv("apk"))
	if p.Libc != "musl" || p.Init != "openrc" || p.Family != "alpine" {
		t.Fatalf("%+v", p)
	}
	ok, why := p.Brew()
	if ok || why != "Not available on Alpine: Homebrew needs glibc, and this system uses musl" {
		t.Fatalf("%v %q", ok, why)
	}
	if cmd, _ := p.Install(BuildToolsPkgs); strings.Join(cmd, " ") != "apk add build-base" {
		t.Fatalf("%v", cmd)
	}
}

func TestReadPlatformFallsBackToUsrLib(t *testing.T) {
	root := fakeRoot(t, map[string]string{"usr/lib/os-release": "ID=fedora\nVARIANT_ID=silverblue\nPRETTY_NAME=\"Fedora Linux 41 (Silverblue)\"\n", "run/ostree-booted": "", "var/lib/rpm/x": ""})
	p := ReadPlatform(root, linuxEnv("rpm-ostree", "dnf"))
	if p.Pretty != "Fedora Linux 41 (Silverblue)" || !p.Immutable || p.Variant != "silverblue" {
		t.Fatalf("%+v", p)
	}
	cmd, advice := p.Install(SmartPkgs)
	if cmd != nil || !strings.Contains(advice, "rpm-ostree install smartmontools") {
		t.Fatalf("%v %q", cmd, advice)
	}
}

func TestReadPlatformWithNothingAtAll(t *testing.T) {
	p := ReadPlatform(t.TempDir(), linuxEnv())
	if p.Pretty != "Linux" || p.Family != "unknown" || len(p.Managers) != 0 || p.Container != "" {
		t.Fatalf("%+v", p)
	}
	cmd, advice := p.Install(SmartPkgs)
	if cmd != nil || !strings.Contains(advice, "No package manager here") {
		t.Fatalf("%v %q", cmd, advice)
	}
}

func TestInstallCommandsPerFamily(t *testing.T) {
	cases := map[string]string{
		"dnf":    "dnf install -y @development-tools",
		"zypper": "zypper --non-interactive install -t pattern devel_basis",
		"pacman": "pacman -S --needed --noconfirm base-devel",
		"xbps":   "xbps-install -y base-devel",
	}
	fam := map[string]string{"dnf": "fedora", "zypper": "suse", "pacman": "arch", "xbps": "void"}
	for m, want := range cases {
		p := Platform{OS: "linux", Family: fam[m], Managers: []string{m}}
		if cmd, _ := p.Install(BuildToolsPkgs); strings.Join(cmd, " ") != want {
			t.Errorf("%s: %v", m, cmd)
		}
	}
	if _, adv := (Platform{OS: "linux", ID: "nixos", Family: "nixos", Immutable: true}).Install(SmartPkgs); !strings.Contains(adv, "environment.systemPackages") {
		t.Fatal(adv)
	}
}

func TestBrewOnLinuxLimits(t *testing.T) {
	if ok, _ := (Platform{OS: "linux", Arch: "amd64", Libc: "glibc 2.39"}).Brew(); !ok {
		t.Fatal("supported glibc")
	}
	if ok, why := (Platform{OS: "linux", Arch: "arm", Libc: "glibc 2.39"}).Brew(); ok || !strings.Contains(why, "x86_64 and ARM64") {
		t.Fatal(why)
	}
	if ok, why := (Platform{OS: "linux", Arch: "amd64", Libc: "glibc 2.12"}).Brew(); ok || !strings.Contains(why, "2.13") {
		t.Fatal(why)
	}
	if ok, _ := (Platform{OS: "linux", Arch: "amd64", Libc: "glibc 2.39", Root: true}).Brew(); ok {
		t.Fatal("root")
	}
}

func TestServiceCommandFollowsInit(t *testing.T) {
	if (Platform{Init: "openrc"}).Service("sshd", false) != "rc-service sshd status" || (Platform{Init: "systemd"}).Service("x", true) != "systemctl --user status x" {
		t.Fatal("service")
	}
}
