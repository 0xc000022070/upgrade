package main

import (
	"strings"
	"testing"
)

func TestReport(t *testing.T) {
	stream := []string{
		"Resolving dependencies...",
		"  analyzer 13.3.0 (14.5.0 available)",
		"! dart_mosh 0.0.4 from path .dart_tool/dart_mosh (overridden)",
		"Got dependencies!",
		"Because striked depends on nothing_real any, version solving failed.",
		"",
		"which: no vswhere.exe in (/nix/store/a/bin:/nix/store/b/bin)",
		`{"type":"start","time":0}`,
		`{"test":{"id":1,"name":"loading /repo/test/shards/shard_00.dart"},"type":"testStart","time":0}`,
		`{"test":{"id":5,"name":"loading /repo/test/shards/shard_01.dart"},"type":"testStart","time":0}`,
		`{"count":2,"type":"allSuites","time":3}`,
		`{"testID":1,"result":"success","hidden":true,"type":"testDone","time":2400}`,
		"test/x_test.dart:3:5: Error: Method not found: 'Gone'.",
		"a stray line no error repeats",
		`{"testID":5,"error":"Failed to load: test/x_test.dart:3:5: Error: Method not found: 'Gone'.","stackTrace":"","type":"error","time":2500}`,
		`{"testID":5,"result":"error","hidden":true,"type":"testDone","time":2500}`,
		`{"test":{"id":2,"name":"a passes"},"type":"testStart","time":2501}`,
		`{"testID":2,"result":"success","type":"testDone","time":2502}`,
		`{"test":{"id":3,"name":"b breaks"},"type":"testStart","time":2502}`,
		`{"testID":3,"messageType":"print","message":"said this","type":"print","time":2503}`,
		`{"testID":3,"error":"Expected: 1","stackTrace":"b_test.dart 9:5","isFailure":true,"type":"error","time":2504}`,
		`{"testID":3,"result":"failure","type":"testDone","time":2505}`,
		`{"test":{"id":4,"name":"c waits"},"type":"testStart","time":2505}`,
		`{"testID":4,"result":"success","skipped":true,"type":"testDone","time":2505}`,
		`{"success":false,"type":"done","time":2510}`,
	}

	var out strings.Builder
	r := newReport(&out, false, func() int { return 0 })
	for _, line := range stream {
		r.line(line)
	}
	if r.loaded != r.suites {
		t.Errorf("settled %d of %d suites", r.loaded, r.suites)
	}
	if r.finish() {
		t.Error("finish reported success for a failed run")
	}

	got := out.String()
	for _, want := range []string{
		"Because striked depends on nothing_real any, version solving failed.\n",
		"compiled shard_00.dart (1/2) in 2.4s\n",
		"FAIL shard_01.dart\n",
		"a stray line no error repeats\n",
		"FAIL b breaks\n    said this\n    Expected: 1\n    b_test.dart 9:5\n",
		"failed:\n  shard_01.dart\n  b breaks\n",
		"1 passed  2 failed  1 skipped in ",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("output lacks %q:\n%s", want, got)
		}
	}
	for _, gone := range []string{"vswhere", "available)", "overridden", "dependencies", "\n\n\n"} {
		if strings.Contains(got, gone) {
			t.Errorf("output keeps %q:\n%s", gone, got)
		}
	}
	if n := strings.Count(got, "Method not found"); n != 1 {
		t.Errorf("compile error printed %d times:\n%s", n, got)
	}
}
