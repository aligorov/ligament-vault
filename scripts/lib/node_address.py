"""Validate cluster node endpoints and resolve addresses required by IPv4-only consumers."""
import ipaddress
import re
import socket
import sys

_LABEL = re.compile(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?")


def valid_node_address(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        ipaddress.IPv4Address(value)
        return True
    except ValueError:
        labels = value.split(".")
        return (len(value) <= 253 and len(labels) > 1 and not value.replace(".", "").isdigit()
                and all(_LABEL.fullmatch(label) for label in labels))


def ipv4(host):
    if not valid_node_address(host):
        raise ValueError(f"Некорректный адрес ноды: {host}")
    ips = {record[4][0] for record in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)}
    if len(ips) != 1:
        raise ValueError(f"Для адреса отдельной ноды {host} требуется одна A-запись")
    return ips.pop()


if __name__ == "__main__":
    try:
        for endpoint in sys.argv[1:]:
            print(ipv4(endpoint))
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))
