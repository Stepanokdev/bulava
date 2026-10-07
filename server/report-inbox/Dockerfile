# Anonymous error reports from Bulava. See main.go for what it keeps and what it refuses.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /report-inbox .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /report-inbox /report-inbox
ENV LISTEN=:8080 DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["/report-inbox"]
