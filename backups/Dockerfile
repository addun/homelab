FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /backup .

FROM alpine:3.22
RUN apk add --no-cache tzdata restic docker-cli
COPY --from=build /backup /usr/local/bin/backup
ENTRYPOINT ["/usr/local/bin/backup"]
