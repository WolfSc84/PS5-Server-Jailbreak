FROM python:3.12-alpine

# Install openssl for automatic SSL certificate generation if certificates are not present
RUN apk add --no-cache openssl ca-certificates

WORKDIR /app

# Ensure Python output is sent straight to terminal without buffering
ENV PYTHONUNBUFFERED=1

# Copy static web assets and server script (HTML, JavaScript, Python, offsets)
COPY index.html serve.py ./
COPY src/ ./src/
COPY offsets/ ./offsets/

# Ensure payloads directory exists inside container
RUN mkdir -p /app/payloads

# Expose HTTP (80), HTTPS (443), and DNS (53 TCP/UDP)
EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 53/tcp
EXPOSE 53/udp

CMD ["python3", "serve.py"]
