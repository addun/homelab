// Restore drill: proves the newest snapshot can really be restored, by restoring
// it into a scratch directory and sanity-checking the result, then mailing
// [OK]/[FAILED]. Uses the same repository and password as the backup itself, so
// it does not replace keeping RESTIC_PASSWORD somewhere outside this server.
//
// immich/library (photos, ~90% of the data) is not restored; only its backups/
// subdirectory with the database dumps is. Photo data is covered daily by
// "restic check --read-data-subset" in the backup run.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var restoreDir = env("RESTORE_DIR", "/restore")

func runDrill() {
	start := time.Now()
	day := start.Format("2006-01-02")
	log.Println("Restore drill started")

	var report strings.Builder
	fail := func(step string, err error) {
		log.Printf("ERROR: drill %s: %v", step, err)
		cleanRestoreDir()
		sendMail("[FAILED] Homelab restore drill "+day, fmt.Sprintf(
			"The restore drill FAILED at step %q:\n\n%v\n\n%s\nInspect the logs:\n    docker logs backup", step, err, report.String()))
	}

	cleanRestoreDir()
	if err := os.MkdirAll(restoreDir, 0o755); err != nil {
		fail("prepare", err)
		return
	}

	// Everything except the photo library, then only the DB dumps from it.
	out, err := restic("restore", "latest", "--host", "homelab", "--tag", "files",
		"--target", restoreDir, "--verify", "--exclude", sourceDir+"/immich/library")
	if err != nil {
		fail("restore files", fmt.Errorf("%v\n%s", err, out))
		return
	}
	report.WriteString("== restore ==\n" + tail(out, 4) + "\n")
	out, err = restic("restore", "latest", "--host", "homelab", "--tag", "files",
		"--target", restoreDir, "--verify", "--include", sourceDir+"/immich/library/backups")
	if err != nil {
		fail("restore immich dumps", fmt.Errorf("%v\n%s", err, out))
		return
	}
	root := filepath.Join(restoreDir, sourceDir)

	missing, differing := compareConfigs(sourceDir, root)
	if len(missing) > 0 {
		fail("config files", fmt.Errorf("missing from restore:\n  %s", strings.Join(missing, "\n  ")))
		return
	}
	report.WriteString("== config files == all present")
	if len(differing) > 0 {
		report.WriteString(fmt.Sprintf(", %d changed since the snapshot (expected if edited today):\n  %s",
			len(differing), strings.Join(differing, "\n  ")))
	}
	report.WriteString("\n\n")

	dump, err := checkImmichDump(root)
	if err != nil {
		fail("immich dump", err)
		return
	}
	report.WriteString("== immich dump == ok: " + dump + "\n")

	cleanRestoreDir()
	dur := time.Since(start).Truncate(time.Second)
	log.Printf("Restore drill finished in %s", dur)
	sendMail("[OK] Homelab restore drill "+day, fmt.Sprintf("Restore drill completed successfully.\nDuration: %s\n\n%s", dur, report.String()))
}

func cleanRestoreDir() {
	// Remove the contents, not the directory: it is a bind mount.
	entries, _ := os.ReadDir(restoreDir)
	for _, e := range entries {
		os.RemoveAll(filepath.Join(restoreDir, e.Name()))
	}
}

// compareConfigs checks that every compose file and .env of the live tree exists
// in the restore (missing = failure) and whether its content matches (differing
// is only informational: the files may have been edited after the snapshot).
func compareConfigs(live, restored string) (missing, differing []string) {
	filepath.WalkDir(live, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(live, path)
		if d.IsDir() {
			// Only look at the stacks' top level; skip data dirs and repos.
			if strings.Count(rel, string(filepath.Separator)) >= 1 || rel == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if name != ".env" && !strings.HasPrefix(name, "docker-compose.") {
			return nil
		}
		a, errA := fileHash(path)
		b, errB := fileHash(filepath.Join(restored, rel))
		switch {
		case errB != nil:
			missing = append(missing, rel)
		case errA == nil && a != b:
			differing = append(differing, rel)
		}
		return nil
	})
	sort.Strings(missing)
	sort.Strings(differing)
	return
}

func fileHash(path string) ([32]byte, error) {
	var sum [32]byte
	f, err := os.Open(path)
	if err != nil {
		return sum, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return sum, err
	}
	copy(sum[:], h.Sum(nil))
	return sum, nil
}

// checkImmichDump verifies the newest restored Immich dump decompresses fully
// and really contains the asset table, which is what a restore would need.
func checkImmichDump(root string) (string, error) {
	dumps, _ := filepath.Glob(filepath.Join(root, "immich/library/backups/*.sql.gz"))
	if len(dumps) == 0 {
		return "", fmt.Errorf("no dumps in restored immich/library/backups")
	}
	sort.Strings(dumps)
	newest := dumps[len(dumps)-1]

	f, err := os.Open(newest)
	if err != nil {
		return "", err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return "", fmt.Errorf("%s: %v", filepath.Base(newest), err)
	}
	// Read the whole stream so gzip verifies the CRC; look for the table on the way.
	buf := make([]byte, 1<<20)
	var tail []byte
	found := false
	var size int64
	for {
		n, err := zr.Read(buf)
		size += int64(n)
		chunk := append(tail, buf[:n]...)
		if bytes.Contains(chunk, []byte("COPY public.asset ")) || bytes.Contains(chunk, []byte("CREATE TABLE public.asset ")) {
			found = true
		}
		if len(chunk) > 64 {
			tail = append([]byte(nil), chunk[len(chunk)-64:]...)
		} else {
			tail = append([]byte(nil), chunk...)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", fmt.Errorf("%s: corrupt gzip: %v", filepath.Base(newest), err)
		}
	}
	if !found {
		return "", fmt.Errorf("%s: no asset table in dump", filepath.Base(newest))
	}
	return fmt.Sprintf("%s (%d MB uncompressed)", filepath.Base(newest), size>>20), nil
}
