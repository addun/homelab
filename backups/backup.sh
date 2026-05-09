#!/bin/sh

echo "Compression started: $(date)"

SIZE=$(du -sb /source | awk '{print $1}')

# The Pipeline:
# 1. tar: bundles files to stdout
# 2. pv: monitors data flow (using -s for total size)
# 3. gzip: compresses the stream
# 4. > redirects to the temp file
tar -cf - -C /source . | pv -n -i 10 -s $SIZE | gzip > /destination/latest_backup.tar.gz.tmp

# Overwrite the previous week's backup
mv /destination/latest_backup.tar.gz.tmp /destination/latest_backup.tar.gz

echo "Compression finished: $(date). Old backup replaced with fresh one."