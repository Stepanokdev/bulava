# The relay that wakes an iPhone with "Bulava needs you". See main.go for what it will not carry.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /push-relay .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /push-relay /push-relay
# The APNs key is mounted, never baked in: APNS_KEY_FILE=/run/secrets/apns.p8
ENV LISTEN=:8080
EXPOSE 8080
ENTRYPOINT ["/push-relay"]
