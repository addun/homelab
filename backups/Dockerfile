FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /backup .

FROM alpine:latest
RUN apk add --no-cache tzdata
COPY --from=build /backup /usr/local/bin/backup
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/backup"]
