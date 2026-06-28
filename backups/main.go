// Weekly backup of the Immich library: tar + gzip the source tree into a single
// archive, then notify by e-mail. On any failure it sends a [FAILED] mail; on
// success a [OK] heartbeat (so you also notice if the service itself ever dies).
//
// Self-contained: no external tools (tar/gzip/pv/msmtp) and no cron. The process
// stays alive and schedules itself for every Sunday 00:00 in TZ.
//
// Run "backup once" to perform a single backup immediately and exit (useful for
// testing or an ad-hoc run).
package main

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"log"
	"net"
	"net/smtp"
	"os"
	"path/filepath"
	"time"
)

// Configuration, all overridable via environment variables.
var (
	sourceDir = env("SOURCE_DIR", "/source")
	destDir   = env("DEST_DIR", "/destination")
	mailHost  = env("MAIL_HOST", "mail-proxy")
	mailPort  = env("MAIL_PORT", "25")
	mailFrom  = env("MAIL_FROM", "homelab-backup")
	mailTo    = env("MAIL_TO", "")
	tz        = env("TZ", "UTC")
)

const archiveName = "latest_backup.tar.gz"

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

	// Single ad-hoc run: "backup once".
	if len(os.Args) > 1 && os.Args[1] == "once" {
		runBackup()
		return
	}

	loc, err := time.LoadLocation(tz)
	if err != nil {
		log.Printf("unknown TZ %q, falling back to UTC: %v", tz, err)
		loc = time.UTC
	}

	log.Printf("Backup service started. source=%s dest=%s tz=%s", sourceDir, destDir, tz)
	for {
		now := time.Now().In(loc)
		next := nextSunday(now)
		log.Printf("Next backup: %s (in %s)", next.Format(time.RFC1123), next.Sub(now).Truncate(time.Minute))
		time.Sleep(next.Sub(now))
		runBackup()
	}
}

// nextSunday returns the next Sunday 00:00 strictly after now.
func nextSunday(now time.Time) time.Time {
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	daysUntil := (7 - int(now.Weekday())) % 7 // time.Sunday == 0
	next := midnight.AddDate(0, 0, daysUntil)
	if !next.After(now) {
		next = next.AddDate(0, 0, 7)
	}
	return next
}

func runBackup() {
	start := time.Now()
	dest := filepath.Join(destDir, archiveName)
	tmp := dest + ".tmp"
	day := start.Format("2006-01-02")
	log.Println("Backup started")

	// Log periodic progress by watching the growing temp file.
	stop := make(chan struct{})
	go logProgress(tmp, stop)

	err := createArchive(tmp)
	close(stop)
	if err != nil {
		os.Remove(tmp)
		log.Printf("ERROR: %v", err)
		sendMail("[FAILED] Immich backup "+day, fmt.Sprintf(
			"The weekly Immich backup FAILED:\n\n%v\n\nInspect the logs:\n    docker logs weekly-backup", err))
		return
	}

	// Only replace the previous (good) archive once the new one is complete.
	if err := os.Rename(tmp, dest); err != nil {
		os.Remove(tmp)
		log.Printf("ERROR: rename: %v", err)
		sendMail("[FAILED] Immich backup "+day, fmt.Sprintf(
			"Backup was created but could not replace the previous file:\n\n%v", err))
		return
	}

	size := humanSize(fileSize(dest))
	dur := time.Since(start).Truncate(time.Second)
	log.Printf("Backup finished: %s in %s", size, dur)
	sendMail("[OK] Immich backup "+day, fmt.Sprintf(
		"Weekly Immich backup completed successfully.\nSize: %s\nDuration: %s", size, dur))
}

// createArchive walks sourceDir and writes a gzip-compressed tar to tmpPath.
// Files that vanish mid-walk (Immich is live) are skipped rather than failing.
func createArchive(tmpPath string) error {
	f, err := os.Create(tmpPath)
	if err != nil {
		return err
	}
	defer f.Close()

	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)

	skipped := 0
	walkErr := filepath.Walk(sourceDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			// Disappeared between listing and visiting, or not readable by us.
			if os.IsNotExist(err) || os.IsPermission(err) {
				log.Printf("skip %s: %v", path, err)
				skipped++
				return nil
			}
			return err
		}
		rel, err := filepath.Rel(sourceDir, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}

		switch {
		case info.Mode().IsRegular():
			return addFile(tw, path, rel, &skipped)
		case info.Mode()&os.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				log.Printf("skip symlink %s: %v", rel, err)
				skipped++
				return nil
			}
			return addHeader(tw, info, rel, link)
		default: // directories and the like: header only
			return addHeader(tw, info, rel, "")
		}
	})
	if walkErr != nil {
		tw.Close()
		gz.Close()
		return walkErr
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if skipped > 0 {
		log.Printf("note: skipped %d unreadable/vanished entries", skipped)
	}
	return f.Sync()
}

func addHeader(tw *tar.Writer, info os.FileInfo, rel, link string) error {
	hdr, err := tar.FileInfoHeader(info, link)
	if err != nil {
		return err
	}
	hdr.Name = rel
	if info.IsDir() {
		hdr.Name = rel + "/"
	}
	return tw.WriteHeader(hdr)
}

func addFile(tw *tar.Writer, path, rel string, skipped *int) error {
	src, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) || os.IsPermission(err) {
			log.Printf("skip %s: %v", rel, err)
			*skipped++
			return nil
		}
		return err
	}
	defer src.Close()

	// Size the header from the open file so it matches what we copy.
	st, err := src.Stat()
	if err != nil {
		return err
	}
	hdr, err := tar.FileInfoHeader(st, "")
	if err != nil {
		return err
	}
	hdr.Name = rel
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	n, err := io.Copy(tw, src)
	if err != nil {
		return err
	}
	if n != st.Size() {
		return fmt.Errorf("%s changed during read (%d of %d bytes)", rel, n, st.Size())
	}
	return nil
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
	msg := fmt.Sprintf("From: Immich Backup <%s>\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n\r\n%s\r\n",
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

func logProgress(path string, stop <-chan struct{}) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			if s := fileSize(path); s > 0 {
				log.Printf("... in progress: %s written", humanSize(s))
			}
		}
	}
}

func fileSize(path string) int64 {
	fi, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return fi.Size()
}

func humanSize(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}
