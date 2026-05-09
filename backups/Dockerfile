FROM alpine:latest

RUN apk add --no-cache tar gzip pv

COPY backup.sh /usr/local/bin/backup.sh

RUN chmod +x /usr/local/bin/backup.sh

# Sunday at 00:00
RUN echo "0 0 * * 0 /usr/local/bin/backup.sh" > /etc/crontabs/root

# Run the cron daemon
CMD ["crond", "-f", "-l", "2"]