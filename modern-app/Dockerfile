FROM golang:1.24 AS build
WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/modern-app ./cmd/modern-app

FROM gcr.io/distroless/static-debian12:nonroot
USER 1000:1000
COPY --from=build /out/modern-app /modern-app
ENTRYPOINT ["/modern-app"]
