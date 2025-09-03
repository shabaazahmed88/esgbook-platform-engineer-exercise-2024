# Use official Go image to build
FROM golang:1.22-alpine AS builder
WORKDIR /app

# Copy go files and download dependencies
COPY go.mod go.sum ./
RUN go mod download

# Copy the source code
COPY . .

# Build the binary
RUN go build -o pingpong

# Use a small base image to run the app
FROM alpine:3.20
WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/pingpong .

# Expose default ports
EXPOSE 8080 9080

# Run app
CMD ["./pingpong"]
