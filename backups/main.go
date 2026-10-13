// Daily restic backup of the homelab: the whole apps tree into a deduplicated,
// encrypted restic repository, with retention and a [OK]/[FAILED] e-mail after
// every run (so you also notice if the service dies).
//
// The Immich database is not dumped here: Immich writes its own daily dump to
// immich/library/backups (04:00 local), so RUN_AT must stay after that.
//
// Self-contained scheduler: the process stays alive and wakes up every day at
// RUN_AT (default 05:00) in TZ. Run "backup once" to perform a single backup now.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"net"
	"net/smtp"
	"os"
	"os/exec"
	"strings"
	"time"
)

var (
	sourceDir = env("SOURCE_DIR", "/apps")
	mailHost  = env("MAIL_HOST", "mail-proxy")
	mailPort  = env("MAIL_PORT", "25")
	mailFrom  = env("MAIL_FROM", "homelab-backup")
	mailTo    = env("MAIL_TO", "")
	tz        = env("TZ", "UTC")
	runAt     = env("RUN_AT", "05:00")
)

// Paths (relative to sourceDir) that are not worth backing up: raw Postgres files
// (a file copy of a running database is not restorable; Immich's own dump in
// immich/library/backups covers it), caches and regenerable metrics/index data.
var excludes = []string{
	"immich/postgres",
	"immich/deduper/cache",
	"immich/deduper/qdrant",
	"arr/jellyfin/cache",
	"monitoring/prometheus-data",
	"monitoring/loki-data",
	"backups/cache",
	"sandbox",
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	log.SetFlags(log.LstdFlags)
	if mailTo == "" {
		log.Fatal("MAIL_TO is not set")
	}
	if os.Getenv("RESTIC_PASSWORD") == "" {
		log.Fatal("RESTIC_PASSWORD is not set")
	}

	if len(os.Args) > 1 && os.Args[1] == "once" {
		runBackup()
		return
	}

	loc, err := time.LoadLocation(tz)
	if err != nil {
		log.Printf("unknown TZ %q, falling back to UTC: %v", tz, err)
		loc = time.UTC
	}
	hh, mm := 3, 0
	if _, err := fmt.Sscanf(runAt, "%d:%d", &hh, &mm); err != nil {
		log.Fatalf("bad RUN_AT %q (want HH:MM): %v", runAt, err)
	}

	log.Printf("Backup service started. source=%s tz=%s at=%s", sourceDir, tz, runAt)
	for {
		now := time.Now().In(loc)
		next := time.Date(now.Year(), now.Month(), now.Day(), hh, mm, 0, 0, loc)
		if !next.After(now) {
			next = next.AddDate(0, 0, 1)
		}
		log.Printf("Next backup: %s (in %s)", next.Format(time.RFC1123), next.Sub(now).Truncate(time.Minute))
		time.Sleep(next.Sub(now))
		runBackup()
	}
}

func runBackup() {
	start := time.Now()
	day := start.Format("2006-01-02")
	log.Println("Backup started")

	var report strings.Builder
	fail := func(step string, err error) {
		log.Printf("ERROR: %s: %v", step, err)
		sendMail("[FAILED] Homelab backup "+day, fmt.Sprintf(
			"The homelab backup FAILED at step %q:\n\n%v\n\n%s\nInspect the logs:\n    docker logs backup", step, err, report.String()))
	}

	if err := ensureRepo(); err != nil {
		fail("repo init", err)
		return
	}

	// Exit code 3 = snapshot created but some files unreadable; treat as a warning.
	args := []string{"backup", sourceDir, "--tag", "files", "--host", "homelab"}
	for _, e := range excludes {
		args = append(args, "--exclude", sourceDir+"/"+e)
	}
	out, err := restic(args...)
	var ee *exec.ExitError
	if err != nil && !(errors.As(err, &ee) && ee.ExitCode() == 3) {
		fail("files backup", fmt.Errorf("%v\n%s", err, out))
		return
	}
	warn := ""
	if err != nil {
		warn = "WARNING: some files could not be read (see logs).\n"
	}
	report.WriteString("== files ==\n" + warn + tail(out, 8) + "\n")

	if out, err := restic("forget", "--prune", "--host", "homelab",
		"--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6"); err != nil {
		fail("retention", fmt.Errorf("%v\n%s", err, out))
		return
	} else {
		report.WriteString("== retention ==\n" + tail(out, 4) + "\n")
	}

	// Structure check plus a random 2% sample of the actual data each run.
	if out, err := restic("check", "--read-data-subset=2%"); err != nil {
		fail("integrity check", fmt.Errorf("%v\n%s", err, out))
		return
	}
	report.WriteString("== check == ok\n")

	dur := time.Since(start).Truncate(time.Second)
	log.Printf("Backup finished in %s", dur)
	sendMail("[OK] Homelab backup "+day, fmt.Sprintf("Homelab backup completed successfully.\nDuration: %s\n\n%s", dur, report.String()))
}

// ensureRepo initialises the restic repository on first run.
func ensureRepo() error {
	if _, err := restic("cat", "config"); err == nil {
		return nil
	}
	log.Println("Initialising restic repository")
	out, err := restic("init")
	if err != nil {
		return fmt.Errorf("%v\n%s", err, out)
	}
	return nil
}

func restic(args ...string) (string, error) {
	cmd := exec.Command("restic", args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// tail returns the last n non-empty lines of s.
func tail(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// sendMail talks plain SMTP to the relay (no auth, no TLS), mirroring how WUD
// uses the same mail-proxy. Notification failures are logged, never fatal.
func sendMail(subject, body string) {
	addr := net.JoinHostPort(mailHost, mailPort)
	conn, err := net.DialTimeout("tcp", addr, 30*time.Second)
	if err != nil {
		log.Printf("WARNING: could not reach mail relay %s: %v", addr, err)
		return
	}
	c, err := smtp.NewClient(conn, mailHost)
	if err != nil {
		log.Printf("WARNING: smtp client: %v", err)
		conn.Close()
		return
	}
	defer c.Close()

	if err := c.Mail(mailFrom); err != nil {
		log.Printf("WARNING: MAIL FROM: %v", err)
		return
	}
	if err := c.Rcpt(mailTo); err != nil {
		log.Printf("WARNING: RCPT TO: %v", err)
		return
	}
	w, err := c.Data()
	if err != nil {
		log.Printf("WARNING: DATA: %v", err)
		return
	}
	msg := fmt.Sprintf("From: Homelab Backup <%s>\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n\r\n%s\r\n",
		mailFrom, mailTo, subject, time.Now().Format(time.RFC1123Z), body)
	if _, err := w.Write([]byte(msg)); err != nil {
		log.Printf("WARNING: writing message: %v", err)
		return
	}
	if err := w.Close(); err != nil {
		log.Printf("WARNING: closing message: %v", err)
		return
	}
	c.Quit()
}
