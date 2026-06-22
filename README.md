# v2ray-tools

Debian/systemd-oriented helper script for installing Xray and configuring:

- VLESS-TCP-XTLS-Vision-REALITY
- Shadowsocks 2022 with `2022-blake3-aes-256-gcm`
- BBR sysctl settings

## Usage

Run on a Debian server as root:

```bash
bash install-xray.sh
```

The script is menu-based. Protocol ports default to `443`; pressing Enter keeps the default.

## Test

Local static and unit checks:

```bash
bash -n install-xray.sh tests/install_xray_test.sh
bash tests/install_xray_test.sh
```

Debian container smoke test:

```bash
docker build -f Dockerfile.test -t v2ray-tools-test .
docker run --rm v2ray-tools-test bash tests/debian_integration.sh
```
