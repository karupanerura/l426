# l426

Basic loopback IPv6 to IPv4 reverse proxy server for TCP

Send TCP payloads from [::1] to 127.0.0.1 on specified local TCP ports.

## Requirements

Perl 5 only.
No required to install CPAN modules.

## Usage

Proxy from `[::1]:8080` to `127.0.0.1:8080`

```
l426.pl 8080
```

## Install

```
curl -sfL -o /path/to/l426.pl https://raw.githubusercontent.com/karupanerura/l426/v0.0.1/l426.pl
```
